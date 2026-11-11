import AppKit
import SystemMetrics
import WindowSwitcherCore
import os

/// Brings one exact window forward. `NSRunningApplication.activate()` returns true from a background app on
/// macOS 27.2 but does nothing, so this goes through Accessibility. Those calls wait for the target app, which
/// may be slow or hung, so they run on a queue of their own and the panel closes without waiting.
nonisolated enum WindowActivator {
    private static let queue = DispatchQueue(label: "me.tweakly.Tweakly.switcher-activate", qos: .userInteractive)
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "switcher")
    /// A hung app must not delay the next switch for long.
    private static let messagingTimeout: Float = 0.5
    /// The search for a window on another Space takes about 160 ms on a small app.
    private static let searchLimit: Duration = .milliseconds(500)
    private static let unhideAttempts = 6
    private static let unhideRetryMicroseconds: useconds_t = 50_000

    /// What the activation needs, copied so that nothing from the main actor crosses over.
    struct Target: Sendable {
        let pid: pid_t
        let window: CGWindowID?
        let title: String
        let frame: CGRect
        let bundleURL: URL?
        let isHidden: Bool
    }

    static func activate(_ target: Target) {
        queue.async {
            guard target.window != nil else {
                openApp(target)
                return
            }
            let started = ContinuousClock.now
            // Elements made from others do not inherit a timeout, so this is the one way to cover them all.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
            let app = AXUIElementCreateApplication(target.pid)
            if target.isHidden { AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString, kCFBooleanFalse) }
            var listed: CFTypeRef?
            // A hung app would make every step below wait out the timeout too, and hold up the next switch.
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listed) == .cannotComplete {
                log.info("The app did not answer, so opening it instead of its window")
                openApp(target)
                return
            }
            var (window, found) = element(for: target, among: listed as? [AXUIElement] ?? [])
            var raised = AXError.noValue
            if let window {
                if boolAttribute(kAXMinimizedAttribute, of: window) == true {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            } else if target.window != nil, pressWindowMenuItem(titled: target.title, of: app) {
                found = "chosen in the Window menu"
                raised = .success
            }
            let result = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            log.info(
                "Window \(target.window ?? 0, privacy: .public): \(found, privacy: .public), raise \(raised.rawValue, privacy: .public), front \(result.rawValue, privacy: .public), \(started.duration(to: .now), privacy: .public)"
            )
            // Some apps do not answer Accessibility at all, and the person still asked to go there.
            if result != .success { openApp(target) }
            if target.isHidden { retryFrontmost(app) }
        }
    }

    /// Puts every window of the app that is in sight into the Dock, as a click on a taskbar button does in Windows. Only
    /// windows that can be minimized: a panel or a sheet cannot.
    static func minimizeWindows(of pid: pid_t) {
        queue.async {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
            var listed: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &listed) == .success,
                let windows = listed as? [AXUIElement]
            else { return }
            for window in windows where boolAttribute(kAXMinimizedAttribute, of: window) == false {
                var settable: DarwinBoolean = false
                guard
                    AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
                    settable.boolValue
                else { continue }
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Coming back from hidden takes a moment on macOS 27.2, and an app asked to the front before that reports
    /// success and stays behind.
    private static func retryFrontmost(_ app: AXUIElement) {
        for _ in 0..<unhideAttempts {
            usleep(unhideRetryMicroseconds)
            if boolAttribute(kAXFrontmostAttribute, of: app) == true { return }
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// For an app with no window, setting frontmost through Accessibility reports success on macOS 27.2 and
    /// does nothing. This is what a click on its Dock icon does, so the app may open a new window, as it does then.
    private static func openApp(_ target: Target) {
        guard let url = target.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The element and, for the log, how it was found.
    private static func element(for target: Target, among windows: [AXUIElement]) -> (AXUIElement?, String) {
        let numbers = windows.map { WindowServerBridge.windowID(of: $0) }
        if let id = target.window, let index = numbers.firstIndex(of: id) {
            return (windows[index], "listed")
        }
        // With windows named by number, one that is not listed is on another Space: matching it by title among those
        // listed could only find the wrong one, such as the app's other window with the same page open.
        if let id = target.window, windows.isEmpty || numbers.contains(where: { $0 != nil }) {
            let hidden = WindowServerBridge.hiddenWindowElement(of: id, in: target.pid, deadline: .now + searchLimit)
            return (hidden, hidden == nil ? "not reachable on another Space" : "on another Space")
        }
        let candidates = windows.map { (title: stringAttribute(kAXTitleAttribute, of: $0) ?? "", frame: frame(of: $0)) }
        let matched = WindowMatcher.bestIndex(title: target.title, frame: target.frame, among: candidates)
        return (matched.map { windows[$0] }, matched == nil ? "not found" : "matched by title and frame")
    }

    /// For a window on another Space that has no element within reach: Firefox numbers its elements with those of the
    /// pages, so the window it makes on going full screen is past any search. A Cocoa app lists its windows in its
    /// Window menu, and choosing one there is what a person would do; the system then moves to its Space. Only that
    /// menu, told by Minimize on Command-M in any language, and only an item that alone has the window's title: other
    /// menus, such as a browser's History, list pages under the same titles.
    private static func pressWindowMenuItem(titled title: String, of app: AXUIElement) -> Bool {
        guard !title.isEmpty, let bar = elementAttribute(kAXMenuBarAttribute, of: app) else { return false }
        // The Window menu is near the end, before Help.
        for top in children(of: bar).reversed() {
            guard let menu = children(of: top).first else { continue }
            let items = children(of: menu)
            guard
                items.contains(where: {
                    stringAttribute(kAXMenuItemCmdCharAttribute, of: $0) == "M"
                        && intAttribute(kAXMenuItemCmdModifiersAttribute, of: $0) == 0
                })
            else { continue }
            let matches = items.filter { stringAttribute(kAXTitleAttribute, of: $0) == title }
            guard matches.count == 1 else { return false }
            return AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func intAttribute(_ name: String, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        {
            AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &position)
        }
        value = nil
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        {
            AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}
