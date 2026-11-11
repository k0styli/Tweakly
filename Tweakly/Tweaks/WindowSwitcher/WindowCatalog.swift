import AppKit
import SystemMetrics
import WindowSwitcherCore

/// One tile: a window, or a running app with no window, which would otherwise be out of reach.
struct SwitcherItem {
    let app: NSRunningApplication
    let appName: String
    let window: WindowRecord?

    var aspect: CGFloat {
        guard let frame = window?.frame, frame.height > 0 else { return 1 }
        return frame.width / frame.height
    }

    var accessibilityLabel: String {
        guard let title = window?.title, !title.isEmpty else { return appName }
        return "\(appName), \(title)"
    }
}

/// Reads what can be switched to, once per session rather than keeping it up to date.
enum WindowCatalog {
    /// Asked on the main thread, and only about a window not seen before, so a hung app costs this much at a time.
    private static let listingTimeout: Float = 0.15
    /// Several hung apps must not add up, so past this the rest are not asked, and their windows are judged
    /// by what the window server says.
    private static let listingBudget: Duration = .milliseconds(150)

    #if TWEAKLY_AUTOMATION
        /// Keeps a test to its own windows, so screenshots show nothing else.
        static var onlyExecutablesForTesting: Set<String>?
    #endif

    /// - Returns: the tiles in the order of last use, and whether the first one is what the person is using now.
    static func snapshot(
        recency: inout WindowRecency, kinds: inout [CGWindowID: WindowKind], tuning: SwitcherTuning = SwitcherTuning()
    ) -> (items: [SwitcherItem], firstIsCurrent: Bool) {
        var apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        #if TWEAKLY_AUTOMATION
            if let names = onlyExecutablesForTesting {
                apps = apps.filter { names.contains($0.executableURL?.lastPathComponent ?? "") }
            }
        #endif
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in apps { appsByPID[app.processIdentifier] = app }

        let regularApps = Set(appsByPID.keys)
        var listings: [pid_t: [CGWindowID: WindowKind]?] = [:]
        let listingDeadline = ContinuousClock.now + listingBudget
        let everyWindow = records(.optionAll, ownedBy: regularApps)
        let open = Set(everyWindow.map(\.id))
        kinds = kinds.filter { open.contains($0.key) }
        var windows = WindowFilter.switchable(
            onScreen: records(.optionOnScreenOnly, ownedBy: regularApps),
            all: everyWindow, regularApps: regularApps,
            spaceCount: WindowServerBridge.spaceCount,
            kind: { window in
                if let known = kinds[window.id] { return known }
                let pid = window.ownerPID
                if listings[pid] == nil {
                    listings[pid] =
                        ContinuousClock.now < listingDeadline
                        ? listedWindows(of: pid, until: listingDeadline) : .some(nil)
                    if let listing = listings[pid] ?? nil { kinds.merge(listing) { _, new in new } }
                }
                // What is not listed may only not be listed yet, so that answer is not kept.
                return (listings[pid] ?? nil).map { $0[window.id] ?? .notListed }
            })
        // Each answer is a question to the window server, asked once a window and a press.
        var onCurrentSpace: [CGWindowID: Bool?] = [:]
        func isOnCurrentSpace(_ id: CGWindowID) -> Bool? {
            if let known = onCurrentSpace[id] { return known }
            let answer = WindowServerBridge.isOnCurrentSpace(id)
            onCurrentSpace[id] = .some(answer)
            return answer
        }
        if tuning.filtersWindowsOutOfSight {
            windows.removeAll { window in
                !tuning.shows(
                    isOnScreen: window.isOnScreen,
                    isOnCurrentDesktop: window.isOnScreen ? nil : isOnCurrentSpace(window.id))
            }
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let front = windows.first { $0.isOnScreen && $0.ownerPID == frontPID }?.id
        let ordered = recency.order(windows, front: front) { window in
            !window.isOnScreen && isOnCurrentSpace(window.id) == true
        }

        var items: [SwitcherItem] = ordered.compactMap { window in
            appsByPID[window.ownerPID].map { SwitcherItem(app: $0, appName: name(of: $0), window: window) }
        }
        if tuning.showsAppsWithoutWindows {
            let withWindows = Set(windows.map(\.ownerPID))
            items +=
                apps.filter {
                    !withWindows.contains($0.processIdentifier)
                        && WindowFilter.getsTileWithoutWindows(bundleID: $0.bundleIdentifier)
                }
                .map { SwitcherItem(app: $0, appName: name(of: $0), window: nil) }
        }
        return (items, front != nil && items.first?.window?.id == front)
    }

    /// The windows of one app for the Dock's panel, in the order they were opened, which stays put while someone looks
    /// for one, as on a taskbar: the window server numbers windows as it makes them. The same windows as Command-Tab
    /// shows, minimized ones and those on other Spaces included.
    static func windows(of app: NSRunningApplication, kinds: inout [CGWindowID: WindowKind]) -> [SwitcherItem] {
        let pid = app.processIdentifier
        let owners: Set<pid_t> = [pid]
        let deadline = ContinuousClock.now + listingBudget
        var listing: [CGWindowID: WindowKind]??
        let windows = WindowFilter.switchable(
            onScreen: records(.optionOnScreenOnly, ownedBy: owners), all: records(.optionAll, ownedBy: owners),
            regularApps: owners, spaceCount: WindowServerBridge.spaceCount,
            kind: { window in
                if let known = kinds[window.id] { return known }
                if listing == nil {
                    listing = .some(listedWindows(of: pid, until: deadline))
                    if let fresh = listing ?? nil { kinds.merge(fresh) { _, new in new } }
                }
                return (listing ?? nil).map { $0[window.id] ?? .notListed }
            })
        let name = name(of: app)
        return windows.sorted { $0.id < $1.id }.map { SwitcherItem(app: app, appName: name, window: $0) }
    }

    /// Whether the app has a window on screen now, for the click on its Dock icon. Anything smaller than a window, its
    /// stand-ins included, does not count.
    static func hasWindowInSight(of pid: pid_t) -> Bool {
        records(.optionOnScreenOnly, ownedBy: [pid]).contains {
            $0.layer == 0 && $0.alpha > 0 && $0.frame.width >= 100 && $0.frame.height >= 60
        }
    }

    /// The window in front of each of these apps on screen, for keeping track of what was used when apps change.
    static func frontWindows(of apps: Set<pid_t>) -> [pid_t: CGWindowID] {
        var result: [pid_t: CGWindowID] = [:]
        // Front to back, so the first of each app wins. A title tells a window from most of what floats above it.
        for window in records(.optionOnScreenOnly, ownedBy: apps) where window.layer == 0 && !window.title.isEmpty {
            if result[window.ownerPID] == nil { result[window.ownerPID] = window.id }
        }
        return result
    }

    #if TWEAKLY_AUTOMATION
        /// What one press costs on the main thread, on whatever windows are open. Only numbers come out of it.
        static func benchForTesting(rounds: Int) -> String {
            func average(_ body: () -> Void) -> Double {
                let clock = ContinuousClock()
                let total = clock.measure { for _ in 0..<rounds { body() } }
                return Double(total / .microseconds(1)) / Double(rounds) / 1000
            }
            var recency = WindowRecency()
            var kinds: [CGWindowID: WindowKind] = [:]
            var unknown: [CGWindowID: WindowKind] = [:]
            let object: [String: Any] = [
                "snapshotFirstMs": average {
                    unknown = [:]
                    _ = snapshot(recency: &recency, kinds: &unknown)
                },
                "snapshotMs": average { _ = snapshot(recency: &recency, kinds: &kinds) },
                "frontMs": average {
                    _ = frontWindows(of: [NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0])
                },
                "items": snapshot(recency: &recency, kinds: &kinds).items.count,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// What Accessibility says each window it lists for an app is, or nil if it cannot say. It lists no sheets, which are
    /// parts of a window to it, and no window on another Space.
    private static func listedWindows(of pid: pid_t, until deadline: ContinuousClock.Instant) -> [CGWindowID:
        WindowKind]?
    {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, listingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let elements = value as? [AXUIElement], !elements.isEmpty
        else { return nil }
        var kinds: [CGWindowID: WindowKind] = [:]
        for element in elements {
            // An app slow to answer about each of many windows would otherwise add up to seconds on the main thread.
            guard ContinuousClock.now < deadline else { return nil }
            // An element has its own timeout, and otherwise a hung app would hold the press for the system's six seconds.
            AXUIElementSetMessagingTimeout(element, listingTimeout)
            var values: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(
                    element, [kAXRoleAttribute, kAXSubroleAttribute] as CFArray, [], &values) == .success,
                let attributes = values as? [Any], attributes.count == 2, let role = attributes[0] as? String
            else { return nil }
            let kind = WindowKind(role: role, subrole: attributes[1] as? String)
            if let number = WindowServerBridge.windowID(of: element) {
                kinds[number] = kind
            } else if kind != .part {
                // Finder lists its desktop here with no number, which is fine. A window with none means the call is gone.
                return nil
            }
        }
        return kinds
    }

    /// Most of the list is other processes' windows. Bridging it to Swift would build a dictionary of every entry,
    /// so entries are read as they are, and only as far as it takes to skip them.
    private static func records(_ option: CGWindowListOption, ownedBy owners: Set<pid_t>) -> [WindowRecord] {
        guard let list = CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID) as NSArray?
        else { return [] }
        var records: [WindowRecord] = []
        for case let info as NSDictionary in list {
            guard let owner = info[kCGWindowOwnerPID] as? Int32, owners.contains(owner),
                let id = info[kCGWindowNumber] as? UInt32, let bounds = info[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            records.append(
                WindowRecord(
                    id: id, ownerPID: owner, title: info[kCGWindowName] as? String ?? "", frame: frame,
                    layer: info[kCGWindowLayer] as? Int ?? 0, alpha: info[kCGWindowAlpha] as? Double ?? 1,
                    isOnScreen: info[kCGWindowIsOnscreen] as? Bool ?? false))
        }
        return records
    }
}
