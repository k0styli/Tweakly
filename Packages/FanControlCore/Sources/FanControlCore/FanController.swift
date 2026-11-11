/// The limits and state of one fan as read from the Mac.
public struct FanLimits: Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double

    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var isUsable: Bool { minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum > minimum }

    /// A percent of the range, so 0 is the slowest it can spin rather than standing still.
    public func rpm(atPercent percent: Double) -> Double {
        minimum + (maximum - minimum) * min(max(percent, 0), 100) / 100
    }
}

/// What to tell a fan.
public enum FanCommand: Equatable, Sendable {
    /// Back to the system, or stay there.
    case system
    case rpm(Double)
}

/// Why a fan is not doing what someone chose.
public enum FanHoldReason: Equatable, Sendable {
    case emergency
    case noTemperature
}

/// What the helper is told, which it goes through by position: an rpm for each fan in the order of their numbers, and a
/// negative number for the system.
public struct FanTargets: Sendable {
    /// What the system's fans get.
    public static let system = -1.0
    /// Readings in a row with nothing about a fan before it goes back: about as long as the lease would have given it.
    static let missesAllowed = 5

    private var misses: [Int: Int] = [:]

    public init() {}

    /// - Parameters:
    ///   - decided: what this reading says, by fan number.
    ///   - last: what was sent last. A fan with no reading this time keeps its place in the list and what it was doing:
    ///     moving up would hand it another fan's speed, and giving it back would stop it for half a minute over one failed
    ///     read. Not for ever, as nothing can tell how it is doing.
    public mutating func merged(_ decided: [Int: Double], last: [Double]?) -> [Double] {
        let count = max((decided.keys.max() ?? -1) + 1, last?.count ?? 0)
        return (0..<count).map { number in
            if let target = decided[number] {
                misses[number] = 0
                return target
            }
            let missed = (misses[number] ?? 0) + 1
            misses[number] = missed
            guard missed < Self.missesAllowed, let last, last.indices.contains(number) else { return Self.system }
            return last[number]
        }
    }
}

/// Decides what one fan does next, one reading at a time. It holds no clock of its own, so that a test can run an hour in
/// a moment.
public struct FanController: Sendable {
    /// Below the emergency temperature by this much, the choice applies again. Without a gap it would flip at the line.
    public static let emergencyRecovery = 8.0
    /// Readings in a row at the line before it counts. Under load one sensor jumps for a moment, and full speed for that
    /// is noise for nothing.
    static let emergencyReadings = 2
    /// A curve lets go a little below where it took over, for the same reason.
    static let startRecovery = 3.0
    /// Readings in a row with no temperature before giving up: one can be a passing failure.
    static let failuresAllowed = 5

    private var smoothed: Double?
    private var lastRPM: Double?
    private var lastTime: Double?
    private var isFollowing = false
    private var isInEmergency = false
    private var hotReadings = 0
    private var failures = 0

    public private(set) var hold: FanHoldReason?

    public init() {}

    /// The next command for a fan. `current` is the speed it actually has, where a change of speed starts from. `hottest`
    /// is what the emergency watches, because a curve may follow something cooler; without it, that is the reading itself.
    public mutating func next(
        setup: FanSetup, tuning: FanTuning, limits: FanLimits, temperature reading: Double?, hottest: Double? = nil,
        current: Double, now: Double
    ) -> FanCommand {
        guard limits.isUsable else { return .system }
        let elapsed = lastTime.map { max(now - $0, 0) } ?? 0
        lastTime = now
        hold = nil

        if setup.mode == .system {
            reset()
            return .system
        }

        let heat = hottest ?? reading
        noteHeat(heat, line: tuning.emergencyTemperature)

        // Full speed rather than back to the system, which on an M1 Pro stops the fans for half a minute when it takes them
        // and then left them standing at 82 °C under full load. Ahead of asking for
        // the reading, as a block that is off says nothing, and a curve that follows it must not sleep through a hot chip.
        if isInEmergency, heat?.isFinite == true {
            if reading?.isFinite == true { failures = 0 }
            hold = .emergency
            smoothed = nil
            lastRPM = limits.maximum
            return .rpm(limits.maximum)
        }

        // A fixed speed follows nothing, so all it asks is that the heat can still be watched.
        let followed = setup.mode == .fixed ? heat : reading
        guard let followed, followed.isFinite else {
            failures += 1
            guard failures >= Self.failuresAllowed else {
                return lastRPM.map(FanCommand.rpm) ?? .system
            }
            hold = .noTemperature
            // What the emergency has noted stays, or a chip getting hot while what is followed stays silent would never add
            // up to it. And it goes on saying so until a reading returns, not for one reading in every few.
            smoothed = nil
            lastRPM = nil
            isFollowing = false
            failures = Self.failuresAllowed
            return .system
        }
        failures = 0

        let wanted: Double
        switch setup.mode {
        case .system:
            return .system
        case .fixed:
            wanted = limits.rpm(atPercent: setup.fixedPercent)
        case .curve:
            let temperature = smooth(followed, seconds: tuning.smoothingSeconds, elapsed: elapsed)
            let edge = isFollowing ? setup.curve.start - Self.startRecovery : setup.curve.start
            guard temperature >= edge else {
                isFollowing = false
                lastRPM = nil
                return .system
            }
            isFollowing = true
            wanted = limits.rpm(atPercent: setup.curve.percent(at: max(temperature, setup.curve.start)) ?? 0)
        }
        return .rpm(step(toward: wanted, from: lastRPM ?? current, tuning: tuning, limits: limits, elapsed: elapsed))
    }

    private mutating func noteHeat(_ heat: Double?, line: Double) {
        guard let heat, heat.isFinite else { return }
        if heat >= line {
            hotReadings += 1
            if hotReadings >= Self.emergencyReadings { isInEmergency = true }
        } else {
            hotReadings = 0
            if heat <= line - Self.emergencyRecovery { isInEmergency = false }
        }
    }

    private mutating func smooth(_ reading: Double, seconds: Double, elapsed: Double) -> Double {
        guard let smoothed, seconds > 0 else {
            self.smoothed = reading
            return reading
        }
        // A share that depends on the time passed, so that the same setting behaves the same at any pace of readings.
        let value = smoothed + (reading - smoothed) * min(elapsed / seconds, 1)
        self.smoothed = value
        return value
    }

    private mutating func step(
        toward wanted: Double, from start: Double, tuning: FanTuning, limits: FanLimits, elapsed: Double
    ) -> Double {
        let from = min(max(start, limits.minimum), limits.maximum)
        var result = from
        if abs(wanted - from) >= tuning.smallestChange || lastRPM == nil {
            let rise = lastRPM == nil ? .infinity : tuning.fastestRise * elapsed
            let fall = lastRPM == nil ? .infinity : tuning.fastestFall * elapsed
            result = wanted > from ? min(wanted, from + rise) : max(wanted, from - fall)
        }
        lastRPM = result
        return result
    }

    private mutating func reset() {
        smoothed = nil
        lastRPM = nil
        isFollowing = false
        isInEmergency = false
        hotReadings = 0
        failures = 0
    }
}
