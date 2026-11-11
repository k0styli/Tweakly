/// How long the keyboard stays off unless someone turns it back on sooner.
public enum CleaningLength: Int, CaseIterable, Identifiable, Sendable {
    case halfMinute = 30
    case minute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    public var id: Int { rawValue }
    public var seconds: Double { Double(rawValue) }
}

/// When the keyboard comes back. Times are in seconds on a steady clock, so moving the time of day changes nothing.
///
/// There is always an end, however often time is added: this is what makes being locked out forever impossible.
public struct CleaningClock: Equatable, Sendable {
    /// Adding time can never push the end further away than this.
    public static let longestRemaining: Double = 15 * 60

    public private(set) var endsAt: Double

    public init(now: Double, seconds: Double) {
        endsAt = now + min(seconds, Self.longestRemaining)
    }

    public func remaining(now: Double) -> Double {
        max(endsAt - now, 0)
    }

    public func isOver(now: Double) -> Bool {
        now >= endsAt
    }

    public mutating func add(seconds: Double, now: Double) {
        endsAt = min(endsAt + seconds, now + Self.longestRemaining)
    }

    /// As shown on screen. Rounded up, so it reads 0:01 until the very end, and never 0:00 with the keyboard still off.
    public static func text(remaining: Double) -> String {
        let total = Int(remaining.rounded(.up))
        let seconds = total % 60
        return "\(total / 60):\(seconds < 10 ? "0" : "")\(seconds)"
    }
}

/// Holding both Command keys turns the keyboard back on, for when there is no working pointer. Wiping a keyboard
/// presses many keys, but holding exactly these two for this long does not happen by accident.
public struct UnlockChord: Equatable, Sendable {
    public static let holdTime: Double = 3

    private var bothHeldSince: Double?

    public init() {}

    public mutating func update(leftHeld: Bool, rightHeld: Bool, now: Double) {
        if leftHeld, rightHeld {
            if bothHeldSince == nil { bothHeldSince = now }
        } else {
            bothHeldSince = nil
        }
    }

    public func isComplete(now: Double) -> Bool {
        guard let bothHeldSince else { return false }
        return now - bothHeldSince >= Self.holdTime
    }
}

/// Which modifier keys an event says are down. These are the device-dependent bits of its flags, the only part
/// that tells the two Command keys apart.
public struct DeviceModifiers: Equatable, Sendable {
    private static let leftCommand: UInt64 = 0x08
    private static let rightCommand: UInt64 = 0x10

    public let leftCommandHeld: Bool
    public let rightCommandHeld: Bool

    public init(flags: UInt64) {
        leftCommandHeld = flags & Self.leftCommand != 0
        rightCommandHeld = flags & Self.rightCommand != 0
    }
}
