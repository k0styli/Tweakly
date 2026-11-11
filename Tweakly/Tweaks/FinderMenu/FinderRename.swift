import AppKit
import Carbon
import os

/// Selects a new file in Finder and starts editing its name, as Finder does after New Folder.
///
/// On the desktop the file is selected through Accessibility, as revealing it would open a window of the Desktop
/// folder. Elsewhere Finder reveals it in the window that shows its folder. Return starts the editing only once
/// Finder's focus is in the view that has exactly this file selected, so it can never rename anything else. Without
/// Accessibility the file is just there, as Finder shows any new file.
nonisolated enum FinderRename {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "finder-menu")
    private static let queue = DispatchQueue(label: "me.tweakly.Tweakly.finder-menu.rename", qos: .userInitiated)
    private static let answerTimeout: Float = 0.3
    /// Finder shows a new file once it hears of it from the file system, which has no event for this process. So this
    /// looks again this often, for this long after the file was made.
    private static let checkInterval: TimeInterval = 0.05
    private static let checks = 30

    @MainActor static func start(for file: URL) {
        guard AXIsProcessTrusted(),
            let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == FinderCommands.bundleID
        else { return }
        let pid = finder.processIdentifier
        let onDesktop = file.deletingLastPathComponent().standardizedFileURL == desktop
        queue.async {
            // Elements are not passed between steps, as they may not cross threads: each step asks Finder anew.
            let app = finderElement(pid)
            if onDesktop, let group = desktopGroup(app), isFocused(group, in: app) {
                selectOnDesktop(file, pid: pid, checksLeft: checks)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    queue.async { waitForSelection(file, pid: pid, checksLeft: checks) }
                }
            }
        }
    }

    private static func finderElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, answerTimeout)
        return app
    }

    private static var desktop: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "Desktop").standardizedFileURL
    }

    private static func selectOnDesktop(_ file: URL, pid: pid_t, checksLeft: Int) {
        let group = desktopGroup(finderElement(pid))
        if let group, let icon = children(of: group).first(where: { points(at: file, $0) }) {
            AXUIElementSetAttributeValue(group, kAXSelectedChildrenAttribute as CFString, [icon] as CFArray)
            waitForSelection(file, pid: pid, checksLeft: checksLeft)
        } else if checksLeft > 0 {
            queue.asyncAfter(deadline: .now() + checkInterval) {
                selectOnDesktop(file, pid: pid, checksLeft: checksLeft - 1)
            }
        } else {
            log.notice("The new file did not show on the desktop in time")
        }
    }

    /// Return goes to Finder only while its focus has this one file selected.
    private static func waitForSelection(_ file: URL, pid: pid_t, checksLeft: Int) {
        let selected = element(finderElement(pid), kAXFocusedUIElementAttribute).map(selection(of:)) ?? []
        if selected.count == 1, points(at: file, selected[0]) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    FinderCommands.pressKey(kVK_Return, flags: [], pid: pid)
                }
            }
        } else if checksLeft > 0 {
            queue.asyncAfter(deadline: .now() + checkInterval) {
                waitForSelection(file, pid: pid, checksLeft: checksLeft - 1)
            }
        } else {
            log.notice("Finder did not select the new file in time, so it is left unnamed")
        }
    }

    /// The desktop is the scroll area directly under Finder, with one group of icons.
    private static func desktopGroup(_ app: AXUIElement) -> AXUIElement? {
        children(of: app).first { role(of: $0) == kAXScrollAreaRole }.flatMap { children(of: $0).first }
    }

    private static func isFocused(_ element: AXUIElement, in app: AXUIElement) -> Bool {
        guard let focused = self.element(app, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, element)
    }

    /// Icons in a group and on the desktop, rows in a list.
    private static func selection(of view: AXUIElement) -> [AXUIElement] {
        let icons = elements(view, kAXSelectedChildrenAttribute) ?? []
        return icons.isEmpty ? elements(view, kAXSelectedRowsAttribute) ?? [] : icons
    }

    /// An icon names its file itself; a row of a list does through one of its cells.
    private static func points(at file: URL, _ item: AXUIElement) -> Bool {
        if url(of: item) == file.standardizedFileURL { return true }
        return children(of: item).contains { cell in
            url(of: cell) == file.standardizedFileURL
                || children(of: cell).contains { url(of: $0) == file.standardizedFileURL }
        }
    }

    private static func url(of item: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL)?.standardizedFileURL
    }

    private static func role(of item: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    private static func children(of item: AXUIElement) -> [AXUIElement] {
        elements(item, kAXChildrenAttribute) ?? []
    }

    private static func element(_ item: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elements(_ item: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
