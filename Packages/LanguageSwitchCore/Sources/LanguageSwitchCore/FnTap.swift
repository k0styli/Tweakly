/// A press of Fn, the globe key, on its own: down and up again quickly, with nothing else pressed meanwhile.
///
/// Held longer, or together with another key, a modifier or a click, Fn stays the modifier it always is, so Fn-F1,
/// Fn-Delete and the globe shortcuts keep working.
///
/// Times are the events' own, in seconds, so a callback that runs late judges the press as it happened.
public struct FnTap: Equatable, Sendable {
    /// Longer than a quick press and shorter than holding Fn for a shortcut, as in FnLangSwitch.
    public static let longestPress: Double = 0.4

    private var pressedAt: Double?
    private var isSpoiled = false
    private var firstOtherInput: Double?

    public init() {}

    /// Whether Fn is down, as far as the changes seen so far say.
    public var isPressed: Bool { pressedAt != nil }

    /// - Parameters:
    ///   - fn: whether Fn is down now.
    ///   - others: whether Shift, Control, Option or Command is down now. Caps Lock is a state rather than a key held, so
    ///     it does not count.
    ///   - time: when the modifiers changed.
    /// - Returns: whether Fn has just come up from a tap that should switch the input source.
    public mutating func modifiersChanged(fn: Bool, others: Bool, at time: Double) -> Bool {
        if fn {
            if pressedAt == nil {
                pressedAt = time
                isSpoiled = others
                firstOtherInput = nil
            } else if others {
                isSpoiled = true
            }
            return false
        }
        guard let start = pressedAt else { return false }
        pressedAt = nil
        let held = time - start
        // Input that the release itself set off, or that was only reported first, comes at or after it.
        let hadOtherInput = firstOtherInput.map { $0 < time } ?? false
        return !isSpoiled && !hadOtherInput && !others && held >= 0 && held <= Self.longestPress
    }

    /// A key, a click or a media key went down. Between Fn going down and up, that makes it a shortcut. It may be
    /// reported before the release that came first, so it is judged when Fn comes up, by its time.
    public mutating func otherInput(at time: Double) {
        guard let pressedAt, time >= pressedAt else { return }
        firstOtherInput = min(firstOtherInput ?? time, time)
    }

    /// Forgets a press under way, for when events may have been missed, as across sleep.
    public mutating func reset() {
        pressedAt = nil
        isSpoiled = false
        firstOtherInput = nil
    }
}
