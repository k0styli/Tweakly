import AppKit
import MouseCore
import os

/// The mouse as the person wants it, the trackpad as it was. The pointer's speed and acceleration are set on the mouse
/// itself, through a passive HID client that needs no permission, and cost nothing afterwards; the wheel and side buttons pass through an event tap that sees only them. While
/// on and nobody scrolls, nothing here runs: no timer, no polling, only notices from the system.
final class MouseTweak {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "mouse")
    private static let naturalScrollingChanged = "SwipeScrollDirectionDidChangeNotification"

    private var settings = MouseSettings()
    private let devices = MouseDevices()
    private var tap: MouseEventTap?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityChanges: AccessibilityChanges?
    private var naturalScrollingObserved = false
    private var hasApplied = false
    /// What the tap's thread was last given.
    private var apps: [pid_t: String] = [:]
    private var games: Set<pid_t> = []

    init() {
        observeSystem()
    }

    func update(_ settings: MouseSettings) {
        // Settings come again with every change on any page. Writing the same values to every mouse would also undo a
        // change made in System Settings meanwhile; a mouse that wakes or arrives gets them anyway.
        if settings != self.settings || !hasApplied {
            devices.apply(settings)
            hasApplied = true
        }
        self.settings = settings
        // The wheel and the buttons need Accessibility; the pointer's settings do not.
        if AXIsProcessTrusted() {
            if tap == nil {
                let tap = MouseEventTap()
                if tap.start() {
                    self.tap = tap
                    refreshApps()
                } else {
                    Self.log.error(
                        "Staying without the wheel and buttons: no event tap, though Accessibility reads as allowed")
                }
            }
        } else {
            tap?.stop()
            tap = nil
        }
        tap?.update(rules)
    }

    /// Every mouse as it was, and nothing left running.
    func stop() {
        tap?.stop()
        tap = nil
        devices.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        accessibilityChanges = nil
        if naturalScrollingObserved {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(Self.naturalScrollingChanged as CFString), nil)
            naturalScrollingObserved = false
        }
    }

    private var rules: MouseEventTap.Rules {
        MouseEventTap.Rules(
            flipsWheel: WheelScroll.flips(wanted: settings.scrollDirection, systemNatural: Self.systemNatural),
            linesPerNotch: settings.scrollAcceleration && !settings.smoothScrolling ? nil : settings.linesPerNotch,
            smooth: settings.smoothScrolling, sideButtonSwipes: settings.sideButtonSwipes)
    }

    /// Natural scrolling in Trackpad and Mouse settings, which the system applies to every device.
    private static var systemNatural: Bool {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool
            ?? true
    }

    private func observeSystem() {
        func workspaceApp(
            _ center: NotificationCenter, _ name: Notification.Name, _ key: String,
            _ action: @escaping @MainActor (MouseTweak, NSRunningApplication) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[key] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    if let self { action(self, app) }
                }
            }
            observers.append((center, observer))
        }
        func watch(
            _ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (MouseTweak) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // A mouse can come back from sleep with the system's settings, and the tap turned off without a word.
        watch(workspace, NSWorkspace.didWakeNotification) {
            $0.devices.apply($0.settings)
            $0.tap?.update($0.rules)
        }
        let appKey = NSWorkspace.applicationUserInfoKey
        workspaceApp(workspace, NSWorkspace.didLaunchApplicationNotification, appKey) { $0.appLaunched($1) }
        workspaceApp(workspace, NSWorkspace.didTerminateApplicationNotification, appKey) { $0.appTerminated($1) }
        accessibilityChanges = AccessibilityChanges { [weak self] in
            guard let self else { return }
            self.update(self.settings)
        }
        // The setting changes in System Settings, a process away; the distributed notice says when, at once.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                MainActor.assumeIsolated {
                    let tweak = Unmanaged<MouseTweak>.fromOpaque(observer).takeUnretainedValue()
                    tweak.tap?.update(tweak.rules)
                }
            }, Self.naturalScrollingChanged as CFString, nil, .deliverImmediately)
        naturalScrollingObserved = true
    }

    /// Which app each process is, and which are games, for the tap's thread to look up without asking anyone. Reading
    /// these for every running app takes about 15 ms, so it happens when the tap starts, and then one app at a time as
    /// apps come and go.
    private func refreshApps() {
        guard let tap else { return }
        apps = [:]
        games = []
        for app in NSWorkspace.shared.runningApplications { note(app) }
        tap.update(apps: apps, games: games)
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard let tap else { return }
        note(app)
        tap.update(apps: apps, games: games)
    }

    private func appTerminated(_ app: NSRunningApplication) {
        guard let tap, apps[app.processIdentifier] != nil else { return }
        apps[app.processIdentifier] = nil
        games.remove(app.processIdentifier)
        tap.update(apps: apps, games: games)
    }

    private func note(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return }
        apps[app.processIdentifier] = bundleID
        if Self.isGame(app) { games.insert(app.processIdentifier) }
    }

    /// What the app says it is in its Info.plist, as the App Store files it.
    private static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL,
            let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        else { return false }
        return category.contains("games")
    }

    #if TWEAKLY_AUTOMATION
        var automationDescription: String {
            let rules = rules
            let object: [String: Any] = [
                "tap": tap != nil, "flips": rules.flipsWheel, "lines": rules.linesPerNotch ?? 0,
                "smooth": rules.smooth, "swipes": rules.sideButtonSwipes, "systemNatural": Self.systemNatural,
                "mice": devices.state,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
