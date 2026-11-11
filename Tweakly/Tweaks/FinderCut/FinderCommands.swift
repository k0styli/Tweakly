import AppKit
import Carbon
import FinderCutCore

/// Talks to Finder. These calls wait for Finder, which a stuck network volume can hold up, so they run on a queue of
/// their own, and events go to Finder alone, so they cannot land anywhere else or trigger the shortcuts again.
nonisolated enum FinderCommands {
    static let bundleID = "com.apple.finder"

    private static let queue = DispatchQueue(label: "me.tweakly.Tweakly.finder-commands", qos: .userInteractive)
    private static let answerTimeout: Float = 0.3

    /// Reports where the keyboard is and which app has it, then runs on the main actor. Finder stays in front and goes on
    /// naming its own focus while a panel like Spotlight takes the keyboard, so keys meant for that panel would reach Finder
    /// and move files.
    static func readFocus(pid: pid_t, then: @escaping @MainActor @Sendable (FinderFocus, pid_t) -> Void) {
        queue.async {
            let panel = panelHoldingKeyboard(besides: pid)
            let focus = panel == nil ? FinderFocus(role: focusedRole(pid: pid)) : .text
            DispatchQueue.main.async { MainActor.assumeIsolated { then(focus, panel ?? pid) } }
        }
    }

    static func pressKey(_ keyCode: Int, flags: CGEventFlags, pid: pid_t) {
        queue.async {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
                event?.flags = flags
                event?.postToPid(pid)
            }
        }
    }

    /// An app over Finder that calls itself frontmost and has its focus in text. On macOS 27.2 that tells Spotlight from a
    /// note left floating on top, which has a text field in focus too but does not call itself frontmost. Finder calls itself
    /// frontmost as well all the while, which is why Finder alone cannot say.
    private static func panelHoldingKeyboard(besides finder: pid_t) -> pid_t? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as NSArray?
        else { return nil }
        var asked: Set<pid_t> = [finder, getpid()]
        // Front to back, so what floats comes first, and the first ordinary window ends it.
        for case let info as NSDictionary in list {
            guard let layer = info[kCGWindowLayer] as? Int, layer > 0 else { break }
            guard let owner = info[kCGWindowOwnerPID] as? Int32, asked.insert(owner).inserted else { continue }
            let app = AXUIElementCreateApplication(owner)
            AXUIElementSetMessagingTimeout(app, answerTimeout)
            var frontmost: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
                frontmost as? Bool == true, FinderFocus(role: focusedRole(pid: owner)) == .text
            else { continue }
            return owner
        }
        return nil
    }

    private static func focusedRole(pid: pid_t) -> String? {
        let finder = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(finder, answerTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(finder, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, answerTimeout)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
            return nil
        }
        return role as? String
    }
}
