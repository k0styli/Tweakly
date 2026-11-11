/// One process, told apart from a later one that is given the same number.
public struct ProcessKey: Hashable, Sendable, Comparable {
    public let pid: Int32
    /// When it started, in whatever units the reader has. Zero when the start cannot be read.
    public let start: UInt64

    public init(pid: Int32, start: UInt64) {
        self.pid = pid
        self.start = start
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.pid != rhs.pid ? lhs.pid < rhs.pid : lhs.start < rhs.start
    }
}

/// What the system reports about a process at one moment. Counters only ever grow while the process lives. A value is nil
/// when it cannot be read, which for another user's process is most of them unless a helper with more rights reads them.
public struct ProcessCounters: Sendable, Equatable {
    public var key: ProcessKey
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String
    public var path: String?
    /// Nanoseconds on the processor, user and system together.
    public var cpuTime: UInt64?
    /// What Activity Monitor calls Memory: the physical footprint.
    public var memory: UInt64?
    public var diskRead: UInt64?
    public var diskWritten: UInt64?
    public var threads: Int?
    /// Nanoseconds of GPU time.
    public var gpuTime: UInt64?
    /// Bytes per second, as the network reader measures them over a window of its own: the system counts traffic per
    /// connection, and connections come and go between readings.
    public var receiveRate: Double?
    public var sendRate: Double?
    /// An Intel program running under Rosetta.
    public var isTranslated: Bool?

    public init(
        key: ProcessKey, parentPID: Int32, userID: UInt32, name: String, path: String? = nil, cpuTime: UInt64? = nil,
        memory: UInt64? = nil, diskRead: UInt64? = nil, diskWritten: UInt64? = nil, threads: Int? = nil,
        gpuTime: UInt64? = nil, receiveRate: Double? = nil, sendRate: Double? = nil, isTranslated: Bool? = nil
    ) {
        self.key = key
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.path = path
        self.cpuTime = cpuTime
        self.memory = memory
        self.diskRead = diskRead
        self.diskWritten = diskWritten
        self.threads = threads
        self.gpuTime = gpuTime
        self.receiveRate = receiveRate
        self.sendRate = sendRate
        self.isTranslated = isTranslated
    }
}

/// A process as the table shows it: amounts and rates rather than counters. Also stands for a whole group, with each value
/// added up over its processes.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var key: ProcessKey
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String {
        didSet { sortName = name.lowercased() }
    }
    /// The name in lower case, made once, for the order of lines whose figures are equal. Comparing names the way
    /// Finder does on every one of those took most of the time of putting 450 lines in order.
    public private(set) var sortName: String
    public var path: String?
    /// 1.0 is one core fully used, as in Activity Monitor.
    public var cpu: Double?
    /// Seconds on the processor since the process started.
    public var cpuTime: Double?
    public var memory: UInt64?
    /// Bytes per second.
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    /// The share of the GPU's time, where 1.0 is all of it.
    public var gpu: Double?
    /// Bytes per second.
    public var receiveRate: Double?
    public var sendRate: Double?
    public var threads: Int?
    public var isTranslated: Bool?

    public var id: ProcessKey { key }
    public var pid: Int32 { key.pid }

    public init(
        key: ProcessKey, parentPID: Int32 = 0, userID: UInt32 = 0, name: String, path: String? = nil,
        cpu: Double? = nil, cpuTime: Double? = nil, memory: UInt64? = nil, diskReadRate: Double? = nil,
        diskWriteRate: Double? = nil, gpu: Double? = nil, receiveRate: Double? = nil, sendRate: Double? = nil,
        threads: Int? = nil, isTranslated: Bool? = nil
    ) {
        self.key = key
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        sortName = name.lowercased()
        self.path = path
        self.cpu = cpu
        self.cpuTime = cpuTime
        self.memory = memory
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.gpu = gpu
        self.receiveRate = receiveRate
        self.sendRate = sendRate
        self.threads = threads
        self.isTranslated = isTranslated
    }

    /// Reading and writing together, which is what the Disk column shows.
    public var diskRate: Double? { Self.sum(diskReadRate, diskWriteRate) }
    /// Both directions together, which is what the Network column shows.
    public var networkRate: Double? { Self.sum(receiveRate, sendRate) }

    static func sum(_ left: Double?, _ right: Double?) -> Double? {
        guard left != nil || right != nil else { return nil }
        return (left ?? 0) + (right ?? 0)
    }
}

/// Turns counters into rates between two readings.
///
/// A process seen for the first time has used nothing yet in the time this tracker has watched it, so its rates are zero
/// rather than unknown, and so are everyone's on the very first reading: a table that opens shows zeros in their usual
/// colour rather than dashes until there is an interval to measure. Only a figure that cannot be read at all stays
/// unknown. A counter that went backwards belongs to something new, such as a closed socket, and counts as nothing for
/// that interval.
public struct UsageTracker: Sendable {
    private struct Rates: Sendable {
        var cpu: Double?
        var gpu: Double?
        var diskRead: Double?
        var diskWrite: Double?
    }

    private var previous: [Int32: ProcessCounters] = [:]
    private var previousTime: Double?
    /// What the last measured interval found, shown again by a reading too close to it to measure anything.
    private var lastRates: [ProcessKey: Rates] = [:]

    /// A rate over a shorter window than this is mostly noise.
    static let shortestInterval = 0.1

    public init() {}

    /// `time` is in seconds on a clock that does not run during sleep.
    public mutating func update(_ counters: [ProcessCounters], at time: Double) -> [ProcessUsage] {
        let elapsed = previousTime.map { time - $0 }
        // Readings too close together keep the earlier baseline, so the next interval is long enough to mean something.
        let measures = elapsed.map { $0 >= Self.shortestInterval } ?? false
        let usages = counters.map { current in
            var usage = ProcessUsage(
                key: current.key, parentPID: current.parentPID, userID: current.userID, name: current.name,
                path: current.path, cpuTime: current.cpuTime.map { Double($0) / 1_000_000_000 },
                memory: current.memory, receiveRate: current.receiveRate, sendRate: current.sendRate,
                threads: current.threads, isTranslated: current.isTranslated)
            guard measures, let elapsed else {
                let kept = lastRates[current.key]
                func held(_ value: KeyPath<ProcessCounters, UInt64?>, _ rate: Double?) -> Double? {
                    current[keyPath: value] == nil ? nil : rate ?? 0
                }
                usage.cpu = held(\.cpuTime, kept?.cpu)
                usage.gpu = held(\.gpuTime, kept?.gpu)
                usage.diskReadRate = held(\.diskRead, kept?.diskRead)
                usage.diskWriteRate = held(\.diskWritten, kept?.diskWrite)
                return usage
            }
            let last = previous[current.key.pid].flatMap { $0.key == current.key ? $0 : nil }
            func rate(_ value: KeyPath<ProcessCounters, UInt64?>) -> Double? {
                guard let now = current[keyPath: value] else { return nil }
                guard let then = last?[keyPath: value], now >= then else { return 0 }
                return Double(now - then) / elapsed
            }
            usage.cpu = rate(\.cpuTime).map { $0 / 1_000_000_000 }
            // Work queued in parallel can add up to more than the time that passed, but this is a share of the GPU.
            usage.gpu = rate(\.gpuTime).map { min($0 / 1_000_000_000, 1) }
            usage.diskReadRate = rate(\.diskRead)
            usage.diskWriteRate = rate(\.diskWritten)
            return usage
        }
        if previousTime == nil || measures {
            previous = Dictionary(counters.map { ($0.key.pid, $0) }, uniquingKeysWith: { first, _ in first })
            previousTime = time
        }
        if measures {
            lastRates = Dictionary(
                usages.map {
                    ($0.key, Rates(cpu: $0.cpu, gpu: $0.gpu, diskRead: $0.diskReadRate, diskWrite: $0.diskWriteRate))
                }, uniquingKeysWith: { first, _ in first })
        }
        return usages
    }
}
