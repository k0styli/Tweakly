import Foundation

/// What a person can set about a mouse, as opposed to a trackpad, which this leaves alone. The defaults: the pointer
/// moves exactly as the mouse does, the wheel scrolls as on Windows, three lines a notch and no
/// acceleration, and nothing else changes until it is turned on.
public struct MouseSettings: Equatable, Sendable, Codable {
    public enum ScrollDirection: String, CaseIterable, Sendable, Codable {
        /// As on Windows: turning the wheel towards you moves the page up and shows what is below.
        case standard
        /// As on a trackpad with natural scrolling: the page follows the wheel.
        case natural
    }

    /// Multiples of the speed the system gives the mouse, on a scale people can feel in even steps.
    public static let speedChoices: [Double] = [0.25, 0.35, 0.5, 0.7, 1, 1.4, 2, 2.8, 4]
    public static let linesRange = 1...10

    /// Off: the pointer moves in proportion to the mouse, at any speed, as games and drawing need.
    public var acceleration = false
    /// 1 is the system's own speed for the mouse.
    public var speed: Double = 1
    public var scrollDirection = ScrollDirection.standard
    /// Off: every notch scrolls the same distance, however fast the wheel turns.
    public var scrollAcceleration = false
    public var linesPerNotch = 3
    /// The page glides to each notch's distance instead of jumping there.
    public var smoothScrolling = false
    /// The side buttons go back and forward in apps that do not know them, such as Safari and Finder, through the
    /// trackpad's swipe. Apps that know them, Chrome and games among them, get the buttons as they are, either way.
    public var sideButtonSwipes = false

    public init() {}

    /// Each value within reach, whatever was stored.
    public var validated: MouseSettings {
        var result = self
        result.speed = Self.speedChoices.min { abs($0 - speed) < abs($1 - speed) } ?? 1
        result.linesPerNotch = min(max(linesPerNotch, Self.linesRange.lowerBound), Self.linesRange.upperBound)
        return result
    }
}

/// The pointer's speed as the mouse's resolution: the system moves the pointer by the counts the mouse reports divided
/// by the counts it says make an inch, so claiming more counts an inch slows the pointer down, and fewer speeds it up,
/// with no work done per movement. The resolution is kept within what the system accepts.
public enum PointerSpeed {
    public static let lowestResolution: Double = 10
    public static let highestResolution: Double = 1995

    public static func resolution(original: Double, speed: Double) -> Double {
        guard speed > 0, original > 0 else { return original }
        return min(max(original / speed, lowestResolution), highestResolution)
    }
}

/// What the wheel of a mouse does, decided per notch. A trackpad's scrolling, and a Magic Mouse's, which is continuous,
/// are never changed.
public enum WheelScroll {
    /// The system turns every device's scrolling round when natural scrolling is on, so the wheel is turned back only
    /// when what the person wants for the mouse differs from that.
    public static func flips(wanted: MouseSettings.ScrollDirection, systemNatural: Bool) -> Bool {
        (wanted == .natural) != systemNatural
    }

    /// Lines for one notch, or for several notches reported together, signed as the wheel turned.
    public static func lines(notches: Int64, linesPerNotch: Int) -> Int64 {
        notches * Int64(linesPerNotch)
    }
}

/// Notches from what the system reports for a wheel. Each notch arrives as one event, and the system's whole lines in
/// it are at least one, while its exact lines are its acceleration's guess: a slow notch comes as a tenth of a line and a
/// quick turn as 3, 4 and up to 8 lines, as measured on a Razer DeathAdder V4 Pro, with no setting on the mouse to stop
/// it. So an event with any whole lines is one notch, as LinearMouse counts it too. A wheel that reports finer than a
/// notch, as some Logitech ones do, sends events with no whole line in them, whose parts add up.
public struct WheelNotches: Equatable, Sendable {
    public private(set) var partial: Double = 0

    public init() {}

    /// `wholeLines` is the event's integer delta, `lines` its exact one; both signed as the wheel turned.
    public mutating func notches(wholeLines: Int64, lines: Double) -> Int64 {
        if wholeLines != 0 {
            partial = 0
            return wholeLines > 0 ? 1 : -1
        }
        guard lines != 0 else { return 0 }
        // Turning back starts again rather than paying off what was gathered the other way.
        if partial != 0, (partial > 0) != (lines > 0) { partial = 0 }
        partial += lines
        let whole = Int64(partial.rounded(.towardZero))
        partial -= Double(whole)
        return whole
    }
}

/// Glides the page through each notch's distance: every notch adds to what is still to go, and each frame scrolls a
/// share of that, large at first and smaller as it arrives, as Mos and the system's own smooth scrolling do. The page
/// lands exactly where the notches send it, with nothing lost to rounding.
public struct SmoothScroll: Equatable, Sendable {
    /// Points one line is worth, as on Windows with three lines a notch for 48 pt.
    public static let pointsPerLine: Double = 16
    /// How quickly it settles: after this long, about two thirds of the way is done.
    public static let timeConstant: Double = 0.065
    /// Below this the glide is over, and what is left goes at once.
    public static let finish: Double = 0.5

    public private(set) var remaining: Double = 0

    public init() {}

    public var isGliding: Bool { remaining != 0 }

    /// A notch, or several, in lines; up is positive, as the system's scrolling is.
    public mutating func add(lines: Int64) {
        let distance = Double(lines) * Self.pointsPerLine
        // Turning the wheel the other way stops the glide and goes the new way at once.
        if remaining != 0, (remaining > 0) != (distance > 0) { remaining = 0 }
        remaining += distance
    }

    /// The points to scroll in a frame `seconds` long.
    public mutating func step(seconds: Double) -> Double {
        guard remaining != 0 else { return 0 }
        let share = 1 - exp(-max(seconds, 0) / Self.timeConstant)
        var points = remaining * share
        if abs(remaining - points) < Self.finish { points = remaining }
        remaining -= points
        return points
    }

    public mutating func stop() {
        remaining = 0
    }
}

/// What the side buttons do. Most apps that understand them, Chrome and games among them, get them as they are. Apps
/// that do not, the ones LinearMouse lists from years of use, get the trackpad's swipe to go back or forward when the
/// person has asked for it.
public enum SideButtons {
    public enum Swipe: Equatable, Sendable {
        case back, forward
    }

    /// The buttons the system numbers 3 and 4, the fourth and fifth of a mouse.
    public static let backButton: Int64 = 3
    public static let forwardButton: Int64 = 4

    private static let swipeApps = [
        "com.apple.", "com.binarynights.ForkLift", "org.mozilla.firefox", "com.operasoftware.Opera",
    ]

    public static func swipe(button: Int64, bundleID: String?, enabled: Bool) -> Swipe? {
        guard enabled, let bundleID, needsSwipe(bundleID) else { return nil }
        switch button {
        case backButton: return .back
        case forwardButton: return .forward
        default: return nil
        }
    }

    static func needsSwipe(_ bundleID: String) -> Bool {
        swipeApps.contains { prefix in
            prefix.hasSuffix(".") ? bundleID.hasPrefix(prefix) : bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
    }
}
