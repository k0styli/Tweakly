/// Which input source a tap of Fn turns on. Input sources are named by the system's identifiers, such as
/// `com.apple.keylayout.ABC`.
public enum InputSourceChoice {
    /// The one used before the current one, as the system's own globe key and Control-Space choose, so that with three
    /// or more a tap goes back and forth between the two in use. If that one has been removed, the next in the list.
    /// - Parameter available: the input sources that can be selected, in the system's order.
    /// - Returns: nil when there is nothing to switch to.
    public static func next(current: String?, previous: String?, available: [String]) -> String? {
        let others = available.filter { $0 != current }
        guard let first = others.first else { return nil }
        if let previous, others.contains(previous) { return previous }
        if let current, let index = available.firstIndex(of: current) {
            return available[(index + 1) % available.count]
        }
        return first
    }
}

/// The current input source and the one before it, followed through the system's notice of every change, whoever
/// made it: the menu bar, a shortcut or this tweak.
public struct InputSourceHistory: Equatable, Sendable {
    public private(set) var current: String?
    public private(set) var previous: String?

    public init(current: String?) {
        self.current = current
    }

    public mutating func selected(_ source: String) {
        guard source != current else { return }
        previous = current
        current = source
    }
}
