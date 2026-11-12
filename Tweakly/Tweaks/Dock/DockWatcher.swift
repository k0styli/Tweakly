import AppKit
import os

/// An icon in the Dock under the pointer.
struct DockIcon: Equatable {
    /// The app it stands for, if that is an app and it is running.
    let app: NSRunningApplication?
    /// In AppKit's screen coordinates, with the origin at the bottom left of the main screen.
    let frame: CGRect
    /// The Dock's row of icons, the same way.
    let dock: CGRect
}

/// Hears the Dock say which icon the pointer is on. The Dock reports every change through Accessibility, leaving it
/// included, so nothing here asks again and again: no timer and no mouse monitor. Checked on macOS 27.2: one notice per
/// icon entered, one more as the pointer leaves the Dock, with the last icon still selected.
///
/// If the Dock restarts, its row of icons goes with it, and the watcher looks for the new one.
final class DockWatcher {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "dock")
    /// The Dock answers at once, but a busy one must not hold up the main thread.
    private static let messagingTimeout: Float = 0.25
    /// After the Dock restarts, how long to wait before each look for its new row of icons.
    private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16]

    var onChange: ((DockIcon?) -> Void)?
    private(set) var current: DockIcon?

    private var observer: AXObserver?
    private var list: AXUIElement?
    private var retry: DispatchWorkItem?
    private var attempt = 0
    /// While the Dock cannot be found: the Dock is an LSUIElement app, which `didLaunchApplicationNotification` is never
    /// posted for, so its relaunch shows only as a change of the running apps.
    private var launchObservation: NSKeyValueObservation?
    /// The running app behind each icon's file, so a hover does not go through every running app.
    private var apps: [URL: NSRunningApplication] = [:]

    /// Starts watching, and keeps looking for the Dock if it cannot be reached yet: at login it may still be coming up,
    /// or busy past the messaging timeout, and giving up then would leave the tweak dead until some setting changed.
    func start() {
        guard !attach() else { return }
        Self.log.notice("The Dock cannot be reached yet; looking for it again")
        scheduleRetry()
    }

    func stop() {
        retry?.cancel()
        retry = nil
        detach()
        launchObservation = nil
        apps = [:]
        current = nil
    }

    private func attach() -> Bool {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        // An element made from another does not take its timeout, and a Dock busy at login could hold the agent's main
        // thread for the system's 6 s on each.
        guard
            let children = Self.attribute(kAXChildrenAttribute, of: app) as? [AXUIElement],
            let list = children.first(where: { child in
                AXUIElementSetMessagingTimeout(child, Self.messagingTimeout)
                return Self.attribute(kAXRoleAttribute, of: child) as? String == kAXListRole
            })
        else { return false }
        AXUIElementSetMessagingTimeout(list, Self.messagingTimeout)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, info in
            guard let info else { return }
            let name = notification as String
            // The observer's source runs on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<DockWatcher>.fromOpaque(info).takeUnretainedValue().heard(name)
            }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else {
            return false
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXSelectedChildrenChangedNotification, kAXUIElementDestroyedNotification] {
            guard AXObserverAddNotification(created, list, name as CFString, info) == .success else { return false }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.list = list
        attempt = 0
        launchObservation = nil
        return true
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        list = nil
    }

    private func heard(_ notification: String) {
        if notification == kAXUIElementDestroyedNotification as String {
            Self.log.notice("The Dock went away; looking for it again")
            detach()
            report(nil)
            scheduleRetry()
            return
        }
        report(readIcon())
    }

    /// The Dock was relaunched, by someone or by a change of its settings.
    private func reattach() {
        retry?.cancel()
        retry = nil
        attempt = 0
        if !attach() { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard attempt < Self.retryDelays.count else {
            Self.log.error("The Dock could not be found again; waiting for it to launch")
            waitForLaunch()
            return
        }
        let delay = Self.retryDelays[attempt]
        attempt += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retry = nil
                if !self.attach() { self.scheduleRetry() }
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Nothing is asked again from here on: a Dock that launches shows as a new running app, and that is when it is
    /// looked for once more, with the retries that follow a restart.
    private func waitForLaunch() {
        guard launchObservation == nil else { return }
        launchObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) {
            [weak self] _, change in
            let launched = change.newValue?.contains { $0.bundleIdentifier == "com.apple.dock" } ?? false
            guard launched else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reattach() } }
        }
    }

    private func report(_ icon: DockIcon?) {
        guard icon != current else { return }
        current = icon
        onChange?(icon)
    }

    /// The icon the Dock has selected, if the pointer is still on it: leaving the Dock is reported with the last icon
    /// still selected.
    private func readIcon() -> DockIcon? {
        guard let list, let dock = Self.frame(of: list),
            let selected = (Self.attribute(kAXSelectedChildrenAttribute, of: list) as? [AXUIElement])?.first
        else { return nil }
        AXUIElementSetMessagingTimeout(selected, Self.messagingTimeout)
        guard let frame = Self.frame(of: selected) else { return nil }
        let pointer = NSEvent.mouseLocation
        // An icon magnified by the Dock reaches beyond its row.
        guard dock.contains(pointer) || frame.contains(pointer) else { return nil }
        let isApp = Self.attribute(kAXSubroleAttribute, of: selected) as? String == "AXApplicationDockItem"
        let isRunning = Self.attribute("AXIsApplicationRunning", of: selected) as? Bool ?? false
        let url = isApp && isRunning ? Self.attribute(kAXURLAttribute, of: selected) as? URL : nil
        return DockIcon(app: url.flatMap(app(at:)), frame: frame, dock: dock)
    }

    private func app(at url: URL) -> NSRunningApplication? {
        if let known = apps[url], !known.isTerminated { return known }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        let app = running.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL } ?? running.first
        apps[url] = app
        return app
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Accessibility measures from the top left of the main screen, AppKit from its bottom left.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: element),
            let size = attribute(kAXSizeAttribute, of: element),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            let mainHeight = NSScreen.screens.first?.frame.maxY
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // Both checked to be AXValues just above, and a Core Foundation type cannot be cast conditionally.
        AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        return CGRect(x: point.x, y: mainHeight - point.y - extent.height, width: extent.width, height: extent.height)
    }
}
