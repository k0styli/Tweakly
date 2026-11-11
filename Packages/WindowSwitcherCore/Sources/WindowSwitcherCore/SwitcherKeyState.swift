/// What the keyboard asks the switcher to do.
public enum SwitcherCommand: Equatable, Sendable {
    case begin(backward: Bool)
    case next
    case previous
    case move(SwitcherLayout.Direction)
    case commit
    case cancel
    case quitSelected
    case hideSelected
}

/// Decides what each key means. Kept apart from the event tap so it can be tested, and small because it runs
/// inside the callback that every held-Command key press in the whole system waits for.
public struct SwitcherKeyState: Sendable {
    /// Virtual key codes, which name the physical key, so they work on any keyboard layout.
    private enum Key {
        static let tab: Int64 = 0x30
        static let grave: Int64 = 0x32
        static let escape: Int64 = 0x35
        static let returnKey: Int64 = 0x24
        static let keypadEnter: Int64 = 0x4C
        static let left: Int64 = 0x7B
        static let right: Int64 = 0x7C
        static let down: Int64 = 0x7D
        static let up: Int64 = 0x7E
        static let q: Int64 = 0x0C
        static let h: Int64 = 0x04
    }

    public struct Modifiers: Equatable, Sendable {
        public var command: Bool
        public var shift: Bool
        /// Control or Option, with which Cmd-Tab is someone else's shortcut.
        public var other: Bool

        public init(command: Bool, shift: Bool = false, other: Bool = false) {
            self.command = command
            self.shift = shift
            self.other = other
        }
    }

    public struct Decision: Equatable, Sendable {
        public var swallow: Bool
        public var command: SwitcherCommand?

        public init(swallow: Bool, command: SwitcherCommand? = nil) {
            self.swallow = swallow
            self.command = command
        }
    }

    public private(set) var isSessionActive = false
    /// The key that ended the last session, for as long as it may go on repeating.
    private var endingKey: Int64?

    public init() {}

    /// - Parameter isRepeat: whether this is a held key repeating, rather than a new press.
    public mutating func keyDown(code: Int64, modifiers: Modifiers, isRepeat: Bool = false) -> Decision {
        // Held a little too long, Return would go on to the app just chosen as Command-Return, which sends a message in
        // many of them.
        if let endingKey {
            if isRepeat, code == endingKey { return Decision(swallow: true) }
            self.endingKey = nil
        }
        // Should the event for releasing Command ever be lost, this ends the session at the next key press,
        // so the keyboard can never stay taken.
        guard modifiers.command else {
            guard isSessionActive else { return Decision(swallow: false) }
            isSessionActive = false
            return Decision(swallow: false, command: .commit)
        }
        guard isSessionActive else {
            guard code == Key.tab, !modifiers.other else { return Decision(swallow: false) }
            isSessionActive = true
            return Decision(swallow: true, command: .begin(backward: modifiers.shift))
        }
        return Decision(swallow: true, command: command(for: code, shift: modifiers.shift, isRepeat: isRepeat))
    }

    public mutating func keyUp() -> Decision {
        Decision(swallow: isSessionActive)
    }

    /// Returns the command to run when Command is released during a session.
    public mutating func commandChanged(held: Bool) -> SwitcherCommand? {
        endingKey = nil
        guard !held, isSessionActive else { return nil }
        isSessionActive = false
        return .commit
    }

    /// For when a session ends some other way, such as a click on a tile.
    public mutating func endSession() {
        isSessionActive = false
    }

    private mutating func command(for code: Int64, shift: Bool, isRepeat: Bool) -> SwitcherCommand? {
        switch code {
        case Key.tab: return shift ? .previous : .next
        case Key.grave: return shift ? .next : .previous
        case Key.left: return .move(.left)
        case Key.right: return .move(.right)
        case Key.up: return .move(.up)
        case Key.down: return .move(.down)
        case Key.returnKey, Key.keypadEnter:
            isSessionActive = false
            endingKey = code
            return .commit
        case Key.escape:
            isSessionActive = false
            endingKey = code
            return .cancel
        // Once for each press: quitting moves the selection on, so a held Q would quit one app after another.
        case Key.q: return isRepeat ? nil : .quitSelected
        case Key.h: return isRepeat ? nil : .hideSelected
        default: return nil
        }
    }
}
