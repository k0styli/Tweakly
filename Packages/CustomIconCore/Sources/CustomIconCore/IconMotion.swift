/// How an icon in the menu bar moves. Whether it also fills up is a separate choice, see `IconMotion.fills`.
public enum IconMotionMode: String, CaseIterable, Identifiable, Sendable {
    /// Always its first frame.
    case still
    /// Round and round at a chosen speed.
    case loop
    /// Faster the busier the Mac is.
    case load

    public var id: String { rawValue }
}

/// What "how busy the Mac is" means to an icon that follows it.
public enum IconLoadSource: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory
    /// Whichever of the processor and the graphics works harder. Memory stays out of it, because it sits high all the
    /// time on a healthy Mac and would keep the icon at full speed.
    case busiest

    public var id: String { rawValue }
}

public struct IconMotion: Equatable, Sendable {
    /// As a multiple of the speed the file asks for. Below this it stops looking like movement, and above it the frames
    /// of a typical icon start to blur into each other.
    public static let speeds: ClosedRange<Double> = 0.25...4

    /// Following the load is the point of an animated icon here: it says how busy the Mac is without being looked at.
    public var mode = IconMotionMode.load
    public var loopSpeed = 1.0
    public var idleSpeed = 0.5
    public var busySpeed = 3.0
    public var source = IconLoadSource.cpu
    /// Stays dim and fills from the bottom up the busier the Mac is, whatever the icon and however it moves.
    public var fills = false
    public var fillSource = IconLoadSource.cpu

    public init() {}

    /// What came from preferences, which anyone can edit, kept within what makes sense.
    public var validated: IconMotion {
        var motion = self
        motion.loopSpeed = Self.clamp(loopSpeed, to: 1)
        motion.idleSpeed = Self.clamp(idleSpeed, to: 0.5)
        motion.busySpeed = Self.clamp(busySpeed, to: 3)
        return motion
    }

    /// An icon with one frame has nothing to play. The setting stays for when an animated one is chosen again.
    public func shownMode(isAnimated: Bool) -> IconMotionMode {
        isAnimated ? mode : .still
    }

    public func speed(atLoad load: Double) -> Double {
        let share = load.isFinite ? min(max(load, 0), 1) : 0
        return idleSpeed + (busySpeed - idleSpeed) * share
    }

    private static func clamp(_ value: Double, to fallback: Double) -> Double {
        value.isFinite ? min(max(value, speeds.lowerBound), speeds.upperBound) : fallback
    }
}

/// Turns readings of load into changes of speed, as few as still look right. Load jumps about from second to second, and
/// each change has to reach the render server, which is the only thing an icon playing there costs the app.
public struct IconSpeedFollower: Sendable {
    /// The share of a new reading that counts at once, so that the icon speeds up and calms down instead of twitching.
    private static let newReadingShare = 0.5
    /// A smaller change of speed cannot be seen.
    private static let smallestChange = 0.08

    private var load: Double?
    private var speed: Double?

    public init() {}

    /// The speed to play at from now on, or nil if the one in use is still good.
    public mutating func next(load reading: Double, motion: IconMotion) -> Double? {
        let smoothed = load.map { $0 + (reading - $0) * Self.newReadingShare } ?? reading
        load = smoothed
        let wanted = motion.speed(atLoad: smoothed)
        if let speed, abs(wanted - speed) / speed < Self.smallestChange { return nil }
        speed = wanted
        return wanted
    }

    public mutating func reset() {
        load = nil
        speed = nil
    }
}

/// Turns readings of load into how full an icon looks, as seldom as still looks right, for the same reason.
public struct IconFillFollower: Sendable {
    /// The share of a new reading that counts at once, so that the level rises and settles instead of twitching.
    private static let newReadingShare = 0.5
    /// Two physical pixels of an icon's height. The load wobbles by about one from reading to reading, which nobody can
    /// read off an icon this size, and each change wakes the app and reaches the render server.
    private static let smallestChange = 2 / Double(IconFit.pointHeight * IconFit.pixelsPerPoint)

    private var load: Double?
    private var level: Double?

    public init() {}

    /// How full to show the icon from now on, from 0 to 1, or nil if the level in use is still good.
    public mutating func next(load reading: Double) -> Double? {
        let share = reading.isFinite ? min(max(reading, 0), 1) : 0
        let smoothed = load.map { $0 + (share - $0) * Self.newReadingShare } ?? share
        load = smoothed
        if let level, abs(smoothed - level) < Self.smallestChange { return nil }
        level = smoothed
        return smoothed
    }

    public mutating func reset() {
        load = nil
        level = nil
    }
}
