import Foundation

public struct ProcessEntry: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    public let path: String?
    /// Activity Monitor style: 1.0 is one fully used core.
    public let cpu: Double
    public let memory: UInt64
    /// The share of the GPU's time, where 1.0 is all of it.
    public var gpu: Double = 0
    /// Bytes per second.
    public var downRate: Double = 0
    public var upRate: Double = 0
    /// Bytes per second.
    public var diskRead: Double = 0
    public var diskWrite: Double = 0
    public var id: Int32 { pid }

    /// The outermost app this process belongs to, so that an app's helpers share its identity.
    public var appBundlePath: String? {
        guard let range = path?.range(of: ".app/"), let path else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}

/// Average load over recent time. A value is nil until the app has been watching for that long.
public struct CPUAverages: Equatable, Sendable {
    public var oneMinute: Double?
    public var fiveMinutes: Double?
    public var fifteenMinutes: Double?
}

/// Effective frequencies in megahertz, weighted by how long each state was active. A value is nil
/// when that cluster was idle the whole time.
public struct CPUFrequencies: Equatable, Sendable {
    public var efficiency: Double?
    public var performance: Double?
    public var overall: Double?
}

public struct CPUSnapshot: Equatable, Sendable {
    public var usage: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var cores: [Double] = []
    public var temperature: Double?
    public var frequencies: CPUFrequencies?
    public var averages: CPUAverages?
    public var topProcesses: [ProcessEntry] = []
    public var history: [Float] = []
}

public struct GPUSnapshot: Equatable, Sendable {
    public var usage: Double?
    public var renderer: Double?
    public var tiler: Double?
    public var memoryInUse: UInt64?
    public var memoryAllocated: UInt64?
    public var temperature: Double?
    /// In megahertz, averaged over the active time. Nil when the GPU was off the whole time.
    public var frequency: Double?
    /// In watts.
    public var power: Double?
    /// The share of time the Neural Engine was busy. It is a separate block, reported here because
    /// it has no metric of its own.
    public var neuralEngine: Double?
    /// New frames per second on the busiest display.
    public var framesPerSecond: Double?
    public var topProcesses: [ProcessEntry] = []
    public var history: [Float] = []
}

public enum MemoryPressure: Sendable { case normal, warning, critical }

public struct MemorySnapshot: Equatable, Sendable {
    /// The memory installed.
    public var total: UInt64 = 0
    /// The part macOS gets to use. The hardware keeps the rest, so it is never free or in use.
    public var usable: UInt64 = 0
    public var used: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    public var topProcesses: [ProcessEntry] = []
    public var history: [Float] = []

    /// What programs can have at once: free pages, plus file caches the system gives up on demand.
    public var available: UInt64 { free + cached }

    public var usedFraction: Double { share(of: used) }

    /// The share of the memory macOS can use, which is what the parts of memory add up to.
    public func share(of part: UInt64) -> Double {
        let whole = usable > 0 ? usable : total
        return whole > 0 ? Double(part) / Double(whole) : 0
    }
}

public struct VolumeInfo: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let total: UInt64
    /// What can be used right now, counting what the system would clear on demand.
    public let available: UInt64
    /// The part of `available` that holds caches and the like until the space is needed.
    public var purgeable: UInt64 = 0
    public var id: String { path }
    public var usedFraction: Double { total > 0 ? 1 - Double(available) / Double(total) : 0 }
}

/// What the built-in drive reports about itself.
public struct DriveHealth: Equatable, Sendable {
    public var model: String?
    /// In degrees Celsius.
    public var temperature: Double?
    /// The drive's own estimate of how much of its rated life is used, where 1.0 is all of it.
    public var wear: Double
    /// Over the drive's whole life.
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    /// The drive itself reports a critical condition.
    public var hasWarning: Bool
}

public struct DiskSnapshot: Equatable, Sendable {
    public var main: VolumeInfo?
    public var others: [VolumeInfo] = []
    public var readRate: Double?
    public var writeRate: Double?
    public var drive: DriveHealth?
    public var topProcesses: [ProcessEntry] = []
    public var readHistory: [Float] = []
    public var writeHistory: [Float] = []
}

public struct NetworkInterfaceInfo: Equatable, Sendable {
    public let bsdName: String
    public let displayName: String?
    public let address: String?
    public let hardwareAddress: String?
}

/// The quality of the Wi-Fi link.
public struct WiFiDetails: Equatable, Sendable {
    public enum Band: Sendable { case twoPointFour, five, six }

    /// In dBm.
    public let signal: Int
    /// In megabits per second.
    public let transmitRate: Double
    public let channel: Int?
    public let band: Band?
    /// The number in the "Wi-Fi 6" naming.
    public let generation: Int?
}

/// How the connection to the internet is doing.
public struct NetworkLatency: Equatable, Sendable {
    /// How many packets the history covers.
    public static let capacity = 40

    /// Milliseconds for each recent packet, oldest first. Nil means it was lost.
    public var samples: [Double?] = []
    /// In milliseconds.
    public var average: Double?
    /// In milliseconds.
    public var jitter: Double?
    /// The share of recent packets that were lost.
    public var loss: Double?
}

/// The address the internet sees.
public struct PublicAddress: Equatable, Sendable {
    public let address: String
    /// The two-letter code of the country that address belongs to.
    public let countryCode: String?
}

public struct NetworkSnapshot: Equatable, Sendable {
    public var downRate: Double = 0
    public var upRate: Double = 0
    public var totalDown: UInt64 = 0
    public var totalUp: UInt64 = 0
    public var interface: NetworkInterfaceInfo?
    public var wifi: WiFiDetails?
    public var latency: NetworkLatency?
    public var publicAddress: PublicAddress?
    public var topProcesses: [ProcessEntry] = []
    public var downHistory: [Float] = []
    public var upHistory: [Float] = []
}

public enum BatteryState: Sendable { case charging, charged, notCharging, discharging }

public struct BatteryHealth: Equatable, Sendable {
    /// What a full charge holds today, in mAh. macOS's own "Maximum Capacity" percentage is smoothed
    /// privately and differs from this ratio, so raw values are reported rather than a competing figure.
    public var fullChargeCapacity: Int?
    public var designCapacity: Int?
    /// macOS's own figure for how much capacity is left, as System Settings shows it.
    public var maximumCapacityPercent: Int?
    public var cycleCount: Int?
    /// How many cycles the battery is designed for.
    public var designCycleCount: Int?
    public var temperature: Double?
    /// Milliamps, negative while discharging. Updated by the system only every so often.
    public var current: Int?
    public var voltage: Double?
    /// Watts flowing out of the battery when positive and into it when negative.
    public var power: Double?
    public var adapterWatts: Int?
}

public struct BatterySnapshot: Equatable, Sendable {
    public var isPresent = false
    public var percent = 0
    public var state: BatteryState = .discharging
    /// Minutes until empty or full, nil while the system is still estimating.
    public var minutesRemaining: Int?
    public var health: BatteryHealth?
    /// Watts the Mac itself uses right now, leaving out any power going into the battery.
    public var powerDraw: Double?
    /// Watts coming in from the power adapter right now, which include those going into the battery.
    public var adapterPower: Double?
    public var topProcesses: [ProcessEntry] = []
}

/// One fan as the Mac reports it.
public struct FanReading: Equatable, Sendable {
    public var index: Int
    /// Revolutions a minute. Zero means it stands still, as many fans do while the Mac is cool.
    public var actual: Double
    /// What the fan is being told to reach. Zero while it stands still.
    public var target: Double
    public var minimum: Double
    public var maximum: Double
    /// Whether something other than the system is setting its speed.
    public var isManual: Bool

    public init(index: Int, actual: Double, target: Double, minimum: Double, maximum: Double, isManual: Bool) {
        self.index = index
        self.actual = actual
        self.target = target
        self.minimum = minimum
        self.maximum = maximum
        self.isManual = isManual
    }

    /// How far along its range it is, from 0 at a standstill or its lowest speed to 1 at its highest.
    public var share: Double {
        guard maximum > minimum else { return 0 }
        return min(max((actual - minimum) / (maximum - minimum), 0), 1)
    }
}

/// The temperatures a fan can follow. Each is nil while its sensors report nothing believable.
public struct FanTemperatures: Equatable, Sendable {
    public var hottestCPU: Double?
    public var typicalCPU: Double?
    public var hottestGPU: Double?
    public var battery: Double?

    public init(
        hottestCPU: Double? = nil, typicalCPU: Double? = nil, hottestGPU: Double? = nil, battery: Double? = nil
    ) {
        self.hottestCPU = hottestCPU
        self.typicalCPU = typicalCPU
        self.hottestGPU = hottestGPU
        self.battery = battery
    }

    /// The hotter of the processor and the graphics, which is what usually decides.
    public var hottest: Double? {
        [hottestCPU, hottestGPU].compactMap { $0 }.max()
    }
}

public struct FanSnapshot: Equatable, Sendable {
    public var fans: [FanReading] = []
    public var temperatures = FanTemperatures()
    /// The average share of the fans' range, oldest first. Empty below the overview level.
    public var history: [Float] = []

    public init(fans: [FanReading] = [], temperatures: FanTemperatures = FanTemperatures()) {
        self.fans = fans
        self.temperatures = temperatures
    }

    /// The average of the fans, standing ones included: half of them standing is half the noise.
    public var averageRPM: Double {
        fans.isEmpty ? 0 : fans.map(\.actual).reduce(0, +) / Double(fans.count)
    }

    public var averageShare: Double {
        fans.isEmpty ? 0 : fans.map(\.share).reduce(0, +) / Double(fans.count)
    }
}

/// One sample of one metric.
public enum MetricUpdate: Equatable, Sendable {
    case cpu(CPUSnapshot)
    case gpu(GPUSnapshot)
    case memory(MemorySnapshot)
    case disk(DiskSnapshot)
    case network(NetworkSnapshot)
    case battery(BatterySnapshot)
    case fans(FanSnapshot)

    public var kind: MetricKind {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .battery: .battery
        case .fans: .fans
        }
    }

    public var menuValue: MenuValue {
        switch self {
        case .cpu(let cpu):
            .percent(Self.percent(cpu.usage))
        case .gpu(let gpu):
            gpu.usage.map { .percent(Self.percent($0)) } ?? .unavailable
        case .memory(let memory):
            memory.total > 0 ? .percent(Self.percent(memory.usedFraction)) : .unavailable
        case .disk(let disk):
            disk.main.map { .percent(Self.percent($0.usedFraction)) } ?? .unavailable
        case .network(let network):
            .rates(up: CompactRate(bytesPerSecond: network.upRate), down: CompactRate(bytesPerSecond: network.downRate))
        case .battery(let battery):
            battery.isPresent
                ? .battery(
                    percent: battery.percent, isCharging: battery.state == .charging,
                    isPluggedIn: battery.state != .discharging)
                : .unavailable
        case .fans(let fans):
            // To the nearest ten: a fan's speed wobbles by a few rpm, and each new value costs a redraw.
            fans.fans.isEmpty
                ? .unavailable
                : .fan(
                    rpm: (Int(exactly: (fans.averageRPM / 10).rounded()) ?? 0) * 10,
                    percent: Self.percent(fans.averageShare),
                    temperature: fans.temperatures.hottest.flatMap { Int(exactly: $0.rounded()) })
        }
    }

    /// Anything that is not a number counts as nothing. It would stop the app as a whole number, and the app has no way to
    /// know what every reading on every future Mac can come out as.
    private static func percent(_ fraction: Double) -> Int {
        Int(exactly: (min(max(fraction, 0), 1) * 100).rounded()) ?? 0
    }
}
