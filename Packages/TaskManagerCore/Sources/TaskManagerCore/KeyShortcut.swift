/// A key with its modifiers, in the terms `RegisterEventHotKey` takes.
public struct KeyShortcut: Hashable, Sendable, Codable {
    /// The Carbon modifier bits, kept here so this file needs no system framework.
    public enum Modifier {
        public static let command = 1 << 8
        public static let shift = 1 << 9
        public static let option = 1 << 11
        public static let control = 1 << 12
        public static let all = command | shift | option | control
    }

    /// A virtual key code, which names a place on the keyboard rather than a letter.
    public var keyCode: Int
    public var modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Modifier.all
    }

    static let escapeKey = 53
    static let tabKey = 48
    static let spaceKey = 49
    /// F1 to F20, which work alone as shortcuts because no app types them.
    static let functionKeys: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Control-Shift-Escape, as in Windows. macOS gives it no meaning of its own.
    public static let standard = KeyShortcut(keyCode: escapeKey, modifiers: Modifier.control | Modifier.shift)
    /// The system's Force Quit window, which must stay the system's.
    public static let forceQuitWindow = KeyShortcut(keyCode: escapeKey, modifiers: Modifier.command | Modifier.option)

    public enum Problem: Equatable, Sendable {
        /// Typed alone or with Shift it would be a character, and with Command alone it is an app's own command.
        case needsControlOrOption
        case forceQuitWindow
        /// The system already uses it, for example to switch apps or take a screenshot.
        case takenBySystem
    }

    /// Why this cannot be the shortcut, or nil when it can. `system` holds the shortcuts macOS has turned on.
    public func problem(against system: Set<KeyShortcut> = []) -> Problem? {
        if self == Self.forceQuitWindow { return .forceQuitWindow }
        if !Self.functionKeys.contains(keyCode), modifiers & (Modifier.control | Modifier.option) == 0 {
            return .needsControlOrOption
        }
        if system.contains(self) || Self.reserved.contains(self) { return .takenBySystem }
        return nil
    }

    /// Shortcuts the system keeps whether or not they show up among its symbolic hot keys.
    static let reserved: Set<KeyShortcut> = [
        KeyShortcut(keyCode: spaceKey, modifiers: Modifier.control),
        KeyShortcut(keyCode: spaceKey, modifiers: Modifier.control | Modifier.option),
        KeyShortcut(keyCode: tabKey, modifiers: Modifier.control),
        KeyShortcut(keyCode: tabKey, modifiers: Modifier.control | Modifier.shift),
    ]

    /// The modifiers in the order Apple writes them: ⌃⌥⇧⌘.
    public var modifierSymbols: String {
        var symbols = ""
        if modifiers & Modifier.control != 0 { symbols += "⌃" }
        if modifiers & Modifier.option != 0 { symbols += "⌥" }
        if modifiers & Modifier.shift != 0 { symbols += "⇧" }
        if modifiers & Modifier.command != 0 { symbols += "⌘" }
        return symbols
    }
}
