import Foundation

/// The system resources Tweakly can report.
public enum MetricKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, gpu, memory, disk, network, battery, fans
    public var id: String { rawValue }
}

/// How much data a consumer currently needs for a metric. Higher levels cost more, so each
/// consumer asks for the lowest level that serves what is on screen.
public enum SamplingLevel: Int, Comparable, Sendable {
    /// Only the value shown in the menu bar. Delivered only when that value changes.
    case menu
    /// The value and its history, delivered on every sample.
    case overview
    /// The value, its main parts and the temperature, for a short list of several metrics at once. Nothing per core or
    /// per process, and nothing that sends packets, so all of them together stay cheaper than one metric's details.
    case summary
    /// Everything, including expensive per-core and per-process data.
    case detail

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the engine should sample right now. An empty plan means no timer and no work at all.
public struct SamplingPlan: Equatable, Sendable {
    public var levels: [MetricKind: SamplingLevel]
    public var menuInterval: TimeInterval
    /// Metrics that update at a pace of their own rather than `menuInterval`.
    public var menuIntervals: [MetricKind: TimeInterval]
    public var isPaused: Bool
    /// A label that draws a chart needs every reading, while any other only needs to hear about a change.
    public var kindsReportingEverySample: Set<MetricKind>
    /// Metrics that want the list of busiest processes without the rest of their details, whose sensors cost more.
    public var kindsListingProcesses: Set<MetricKind>

    public init(
        levels: [MetricKind: SamplingLevel] = [:],
        menuInterval: TimeInterval = 2,
        menuIntervals: [MetricKind: TimeInterval] = [:],
        isPaused: Bool = false,
        kindsReportingEverySample: Set<MetricKind> = [],
        kindsListingProcesses: Set<MetricKind> = []
    ) {
        self.levels = levels
        self.menuInterval = menuInterval
        self.menuIntervals = menuIntervals
        self.isPaused = isPaused
        self.kindsReportingEverySample = kindsReportingEverySample
        self.kindsListingProcesses = kindsListingProcesses
    }

    func listsProcesses(of kind: MetricKind, at level: SamplingLevel) -> Bool {
        guard kind != .gpu, kind != .network, kind != .fans else { return false }
        return level == .detail || kindsListingProcesses.contains(kind)
    }

    /// Seconds between samples, or nil when the metric is driven by system events instead of a timer.
    func cadence(of kind: MetricKind, at level: SamplingLevel) -> TimeInterval? {
        switch (kind, level) {
        case (.battery, .menu), (.battery, .overview): nil
        case (.disk, .menu), (.disk, .overview), (.disk, .summary): 120
        case (_, .menu): menuIntervals[kind] ?? menuInterval
        case (_, .overview), (_, .summary), (_, .detail): 1
        }
    }

    /// The fastest cadence any active metric needs, or nil when no timer is required.
    var timerInterval: TimeInterval? {
        guard !isPaused else { return nil }
        return levels.compactMap { cadence(of: $0.key, at: $0.value) }.min()
    }
}

/// A byte rate rounded the way it is displayed, so an unchanged label can be detected without building a string.
public struct CompactRate: Equatable, Sendable {
    public enum Unit: Sendable { case kilobytes, megabytes, gigabytes }

    /// The value in `unit`, multiplied by ten to keep one decimal.
    public let tenths: Int
    public let unit: Unit

    /// Far above any link, and small enough to turn into a whole number whatever a counter comes up with.
    private static let highestRate = 1e15

    public init(bytesPerSecond: Double) {
        let rate = bytesPerSecond.isFinite ? min(max(bytesPerSecond, 0), Self.highestRate) : 0
        switch rate {
        case ..<999_500:
            (tenths, unit) = (Int((rate / 1_000).rounded()) * 10, .kilobytes)
        case ..<9_950_000:
            (tenths, unit) = (Int((rate / 100_000).rounded()), .megabytes)
        case ..<999_500_000:
            (tenths, unit) = (Int((rate / 1_000_000).rounded()) * 10, .megabytes)
        default:
            (tenths, unit) = (Int((rate / 100_000_000).rounded()), .gigabytes)
        }
    }

    /// Whether the decimal digit is meaningful. Larger values read better, and jitter less, without it.
    public var showsDecimal: Bool { unit != .kilobytes && tenths < 100 }
}

/// The value shown in the menu bar for a metric.
public enum MenuValue: Equatable, Sendable {
    case unavailable
    case percent(Int)
    case rates(up: CompactRate, down: CompactRate)
    case battery(percent: Int, isCharging: Bool, isPluggedIn: Bool = false)
    /// The speed, how far it is along the fan's range, and the hottest temperature there is.
    case fan(rpm: Int, percent: Int, temperature: Int?)
}

/// A fixed-capacity history of samples, oldest first when read.
public struct RingBuffer: Equatable, Sendable {
    private var storage: ContiguousArray<Float>
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        storage = ContiguousArray(repeating: 0, count: capacity)
    }

    public mutating func append(_ value: Float) {
        storage[head] = value
        head = (head + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    public var values: [Float] {
        let start = (head - count + storage.count) % storage.count
        return (0..<count).map { storage[(start + $0) % storage.count] }
    }
}

/// Turns an ever-growing counter into a rate. Returns nil until two readings exist, and treats a
/// counter that went backwards (an interface or disk reset) as a new baseline instead of a spike.
struct RateCounter {
    private var last: (value: UInt64, time: TimeInterval)?

    mutating func rate(value: UInt64, time: TimeInterval) -> Double? {
        defer { last = (value, time) }
        guard let last, time > last.time, value >= last.value else { return nil }
        return Double(value - last.value) / (time - last.time)
    }

    mutating func reset() { last = nil }
}

/// Turns traffic counters added up over several interfaces into rates. An adapter that goes away takes its whole count out
/// of the sum and brings it back when it returns, which on its own would read as all its traffic so far passing in a moment,
/// and then fill the chart with that. A change in which interfaces answered therefore starts anew.
struct TrafficCounter {
    private var down = RateCounter()
    private var up = RateCounter()
    private var counted: [Int32] = []

    mutating func rates(
        down downBytes: UInt64, up upBytes: UInt64, from interfaces: [Int32], time: TimeInterval
    ) -> (down: Double?, up: Double?) {
        if interfaces != counted {
            counted = interfaces
            reset()
        }
        return (down.rate(value: downBytes, time: time), up.rate(value: upBytes, time: time))
    }

    mutating func reset() {
        down.reset()
        up.reset()
    }
}

/// Monotonic seconds that do not advance during sleep.
func uptimeSeconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// The number of history samples kept per metric.
let historyCapacity = 120

/// A rate measured over a shorter window than this is mostly noise: one burst of traffic can read as
/// hundreds of MB/s, and a few scheduler ticks can read as 0 % or 20 %.
let minimumSampleInterval: TimeInterval = 0.2

// Every call to these adds a reference to the port that nothing releases, so they are made only once.
let machHost = mach_host_self()
let machTask = task_self_trap()
