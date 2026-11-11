/// What a fan does.
public enum FanMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The system runs it, as if none of this were here.
    case system
    /// One speed all the time.
    case fixed
    /// Follows a temperature.
    case curve

    public var id: String { rawValue }
}

/// Which temperature a curve follows.
public enum FanSensor: String, CaseIterable, Codable, Identifiable, Sendable {
    case hottestCPU, averageCPU, gpu, battery
    /// Whichever of the processor and the graphics is hotter.
    case hottest

    public var id: String { rawValue }
}

/// What one fan is set to do, or all of them when they share one.
public struct FanSetup: Codable, Equatable, Sendable {
    public var mode = FanMode.system
    public var fixedPercent = 50.0
    public var curve = FanPreset.balanced.curve
    public var sensor = FanSensor.hottest

    public init() {}

    /// Whether two setups do the same thing: the curve of a fan at a fixed speed does not matter, for one.
    public func isSame(as other: FanSetup) -> Bool {
        guard mode == other.mode else { return false }
        switch mode {
        case .system: return true
        case .fixed: return fixedPercent == other.fixedPercent
        case .curve: return curve == other.curve && sensor == other.sensor
        }
    }

    /// What came from preferences, which anyone can edit. A broken curve means the system keeps the fan.
    public var validated: FanSetup {
        var setup = self
        setup.fixedPercent = fixedPercent.isFinite ? min(max(fixedPercent, 0), 100) : 50
        if mode == .curve, !curve.isUsable { setup.mode = .system }
        return setup
    }
}

/// How a whole set of fans is run: on one setup, or each on its own, for one source of power.
public struct FanPlan: Codable, Equatable, Sendable {
    public var isLinked = true
    public var shared = FanSetup()
    public var separate: [FanSetup] = []

    public init() {}

    public func setup(ofFan index: Int) -> FanSetup {
        guard !isLinked, separate.indices.contains(index) else { return shared.validated }
        return separate[index].validated
    }

    public mutating func setSetup(_ setup: FanSetup, ofFan index: Int, fanCount: Int) {
        guard !isLinked else {
            shared = setup
            return
        }
        while separate.count < fanCount { separate.append(shared) }
        if separate.indices.contains(index) { separate[index] = setup }
    }

    /// Whether two plans do the same thing, whatever is left over from settings that are not in use.
    public func isSame(as other: FanPlan) -> Bool {
        guard isLinked == other.isLinked else { return false }
        return isLinked
            ? shared.isSame(as: other.shared) : zip(separate, other.separate).allSatisfy { $0.isSame(as: $1) }
    }

    /// Whether anything here takes a fan from the system at all. With separate setups, those are all that count: asked about
    /// more fans than the Mac has, the rest would fall back on the shared one, which nothing is using.
    public func usesFans(count: Int) -> Bool {
        let asked = isLinked || separate.isEmpty ? count : min(count, separate.count)
        return (0..<asked).contains { setup(ofFan: $0).mode != .system }
    }
}

/// How a fan gets from one speed to another.
public struct FanTuning: Codable, Equatable, Sendable {
    /// How long a temperature has to last to count in full, in seconds. A short spike then does not reach the fans.
    public var smoothingSeconds = 10.0
    /// The most a fan may speed up or slow down, in rpm a second. Slowing down is the gentler by default, because a fan
    /// that drops away is what people notice.
    public var fastestRise = 500.0
    public var fastestFall = 150.0
    /// A smaller change of speed is left alone, so that a fan does not hunt around its target.
    public var smallestChange = 60.0
    /// Above this the system takes over whatever else is set, and gets it back only well below it.
    public var emergencyTemperature = 95.0

    public static let smoothingRange: ClosedRange<Double> = 0...60
    public static let riseRange: ClosedRange<Double> = 50...2000
    public static let fallRange: ClosedRange<Double> = 50...2000
    public static let changeRange: ClosedRange<Double> = 0...500
    public static let emergencyRange: ClosedRange<Double> = 70...105

    public init() {}

    /// What came from preferences, which anyone can edit, kept within what makes sense.
    public var validated: FanTuning {
        var tuning = self
        tuning.smoothingSeconds = Self.clamp(smoothingSeconds, Self.smoothingRange, 10)
        tuning.fastestRise = Self.clamp(fastestRise, Self.riseRange, 500)
        tuning.fastestFall = Self.clamp(fastestFall, Self.fallRange, 150)
        tuning.smallestChange = Self.clamp(smallestChange, Self.changeRange, 60)
        tuning.emergencyTemperature = Self.clamp(emergencyTemperature, Self.emergencyRange, 95)
        return tuning
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

/// Everything someone chose about the fans. Off means the system, and off is where it starts.
public struct FanSettings: Codable, Equatable, Sendable {
    public var adapter = FanPlan()
    /// Nil uses the same plan on battery as on the adapter.
    public var battery: FanPlan?
    public var tuning = FanTuning()
    /// Whole sets of choices someone saved under a name, to come back to.
    public var savedProfiles: [SavedFanProfile] = []

    public init() {}

    public func plan(onBattery: Bool) -> FanPlan {
        onBattery ? battery ?? adapter : adapter
    }

    /// Which profile a plan is, if it is one. Nil means someone's own settings that were not saved.
    public func profile(of plan: FanPlan) -> FanProfileChoice? {
        if let profile = FanProfile.allCases.first(where: { $0.plan.isSame(as: plan) }) { return .builtIn(profile) }
        return savedProfiles.first { $0.plan.isSame(as: plan) }.map { .saved($0.id) }
    }

    public func plan(of choice: FanProfileChoice) -> FanPlan? {
        switch choice {
        case .builtIn(let profile): profile.plan
        case .saved(let id): savedProfiles.first { $0.id == id }?.plan
        }
    }
}

/// The profiles that come with the app.
public enum FanProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case system, quiet, balanced, performance, maximum

    public var id: String { rawValue }

    public var plan: FanPlan {
        var plan = FanPlan()
        switch self {
        case .system:
            break
        case .quiet:
            plan.shared.mode = .curve
            plan.shared.curve = FanPreset.quiet.curve
        case .balanced:
            plan.shared.mode = .curve
            plan.shared.curve = FanPreset.balanced.curve
        case .performance:
            plan.shared.mode = .curve
            plan.shared.curve = FanPreset.performance.curve
        case .maximum:
            plan.shared.mode = .fixed
            plan.shared.fixedPercent = 100
        }
        return plan
    }
}

public struct SavedFanProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var plan: FanPlan

    public init(id: String, name: String, plan: FanPlan) {
        self.id = id
        self.name = name
        self.plan = plan
    }
}

public enum FanProfileChoice: Equatable, Hashable, Sendable {
    case builtIn(FanProfile)
    case saved(String)
}
