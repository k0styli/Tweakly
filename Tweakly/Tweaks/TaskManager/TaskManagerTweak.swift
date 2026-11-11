import AppKit
import Carbon
import TaskManagerCore

/// The agent's part of the task manager: the keyboard shortcut that opens it from any app. Nothing else runs here; the
/// window and everything it samples live in the window's process, which exits when the window closes.
final class TaskManagerTweak {
    private lazy var hotKeys = GlobalHotKeys { _ in WindowProcess.openTaskManager() }
    private var registered: GlobalHotKeys.Shortcut?

    func update(shortcut: KeyShortcut) {
        let wanted = GlobalHotKeys.Shortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        guard wanted != registered else { return }
        if let registered { hotKeys.set(registered, enabled: false) }
        hotKeys.set(wanted, enabled: true)
        registered = wanted
    }

    /// Lets the settings page hear the keys while it records a new shortcut. The next change of settings, which ends the
    /// recording either way, brings the shortcut back.
    func pause() {
        if let registered { hotKeys.set(registered, enabled: false) }
        registered = nil
    }

    func stop() {
        hotKeys.invalidate()
        registered = nil
    }
}

extension KeyShortcut {
    /// How the system writes a shortcut in its menus: `⌃⇧⎋`, `⌥⌘T`.
    var displayText: String { modifierSymbols + Self.keyName(keyCode) }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= Modifier.control }
        if flags.contains(.option) { modifiers |= Modifier.option }
        if flags.contains(.shift) { modifiers |= Modifier.shift }
        if flags.contains(.command) { modifiers |= Modifier.command }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    /// The shortcuts macOS has turned on, such as switching input sources or taking a screenshot, from the system's own
    /// list. A new shortcut must not take one of them.
    static func systemShortcuts() -> Set<KeyShortcut> {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        var shortcuts: Set<KeyShortcut> = []
        for entry in array where (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { continue }
            shortcuts.insert(KeyShortcut(keyCode: code, modifiers: modifiers))
        }
        return shortcuts
    }

    private static let named: [Int: String] = [
        kVK_Escape: "⎋", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: String(localized: "Space"), kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
        kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character the key types on the current Latin layout, as the system's menus show it whatever layout is on.
    private static func keyName(_ keyCode: Int) -> String {
        if let name = named[keyCode] { return name }
        guard let code = UInt16(exactly: keyCode),
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
