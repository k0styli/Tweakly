import Foundation

/// Cumulative scheduler ticks for one CPU or the whole machine.
struct CPUTicks: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var total: UInt64 { user &+ system &+ idle &+ nice }
}

struct CPULoad: Equatable {
    var user: Double
    var system: Double
    var usage: Double { user + system }

    /// The load between two readings, or nil if no time passed or the counters went backwards.
    init?(from old: CPUTicks, to new: CPUTicks) {
        guard new.total > old.total, new.user >= old.user, new.system >= old.system, new.nice >= old.nice else {
            return nil
        }
        let total = Double(new.total - old.total)
        user = Double((new.user - old.user) + (new.nice - old.nice)) / total
        system = Double(new.system - old.system) / total
    }
}

/// Average load over the last few minutes. Ticks only ever grow, so comparing today's total with an
/// old checkpoint gives an exact average however rarely the checkpoints were taken.
struct UsageAverages {
    private struct Checkpoint {
        let time: TimeInterval
        let ticks: CPUTicks
    }

    private static let spacing: TimeInterval = 15
    /// How much older than its window a checkpoint may be. After a long pause the only checkpoints are
    /// hours old, and a "last minute" figure from those would be misleading.
    private static let allowedOverrun: TimeInterval = spacing * 2
    /// Enough for the longest window, with room for the checkpoint just before it.
    private static let capacity = 62

    private var checkpoints: [Checkpoint] = []

    mutating func record(_ ticks: CPUTicks, at time: TimeInterval) {
        if let last = checkpoints.last, time - last.time < Self.spacing { return }
        checkpoints.append(Checkpoint(time: time, ticks: ticks))
        if checkpoints.count > Self.capacity { checkpoints.removeFirst() }
    }

    /// Nil until the app has been watching for about that long, rather than a figure for less time.
    func average(over window: TimeInterval, current: CPUTicks, at now: TimeInterval) -> Double? {
        let latestAcceptable = now - window + Self.spacing / 2
        guard let start = checkpoints.last(where: { $0.time <= latestAcceptable }),
            now - start.time <= window + Self.allowedOverrun
        else { return nil }
        return CPULoad(from: start.ticks, to: current)?.usage
    }
}

final class CPUSampler: MetricSampler {
    /// Each sensor read crosses into the SMC, and temperature and frequency do not need a faster pace.
    private static let sensorInterval: TimeInterval = 3

    private var previous: CPUTicks?
    private var previousTime: TimeInterval = 0
    private var previousCores: [CPUTicks] = []
    private var last: CPUSnapshot?
    private var history = RingBuffer(capacity: historyCapacity)
    private var averages = UsageAverages()

    private var thermal: ThermalReader?
    private var frequencyReader: CPUFrequencyReader?
    private var sensorsOpen = false
    private var lastSensorRead: TimeInterval = 0
    private var temperature: Double?
    private var frequencies: CPUFrequencies?

    init() {
        takeBaseline()
    }

    func reset() {
        takeBaseline()
        // Otherwise the value from before the sleep shows as if it were current, and the graph and the averages put
        // the hours before it right next to the moments after: their clock stood still while the Mac slept.
        last = nil
        history = RingBuffer(capacity: historyCapacity)
        averages = UsageAverages()
        closeDetails()
    }

    func closeDetails() {
        // Otherwise the next time details open, the first figure per core covers the whole time since.
        previousCores = []
        closeSensors()
    }

    private func takeBaseline() {
        previous = readTotal()
        previousTime = uptimeSeconds()
        if let previous { averages.record(previous, at: previousTime) }
    }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        let now = uptimeSeconds()
        if now - previousTime >= minimumSampleInterval, let ticks = readTotal() {
            if let previous, let load = CPULoad(from: previous, to: ticks) {
                last = CPUSnapshot(usage: load.usage, user: load.user, system: load.system)
                history.append(Float(load.usage))
            }
            previous = ticks
            previousTime = now
            averages.record(ticks, at: now)
        }
        if level < .summary { closeSensors() }
        // A metric that just started has no meaningful value yet; showing 0 % would be wrong.
        guard var snapshot = last else { return nil }
        guard level >= .overview else { return .cpu(snapshot) }
        snapshot.history = history.values
        guard level >= .summary else { return .cpu(snapshot) }
        readSensors(now: now, withFrequency: level == .detail)
        snapshot.temperature = temperature
        guard level == .detail else { return .cpu(snapshot) }
        snapshot.cores = readCoreLoads()
        snapshot.frequencies = frequencies
        if let previous {
            snapshot.averages = CPUAverages(
                oneMinute: averages.average(over: 60, current: previous, at: now),
                fiveMinutes: averages.average(over: 300, current: previous, at: now),
                fifteenMinutes: averages.average(over: 900, current: previous, at: now)
            )
        }
        return .cpu(snapshot)
    }

    /// Sensors stay closed unless they are on screen, so the menu bar value never pays for them.
    private func readSensors(now: TimeInterval, withFrequency: Bool) {
        if !sensorsOpen {
            sensorsOpen = true
            thermal = ThermalReader()
            temperature = thermal?.cpuTemperature()
            if withFrequency {
                frequencyReader = CPUFrequencyReader()
                _ = frequencyReader?.read()
            }
            lastSensorRead = now
            return
        }
        // Frequency needs two readings, so the first real value should not wait for the full interval.
        let isWaitingForFirstValue = frequencies == nil && frequencyReader != nil
        guard now - lastSensorRead >= (isWaitingForFirstValue ? minimumSampleInterval : Self.sensorInterval) else {
            return
        }
        lastSensorRead = now
        temperature = thermal?.cpuTemperature() ?? temperature
        frequencies = frequencyReader?.read()
    }

    private func closeSensors() {
        guard sensorsOpen else { return }
        sensorsOpen = false
        thermal = nil
        frequencyReader = nil
        temperature = nil
        frequencies = nil
    }

    /// The kernel rate-limits this call and answers with cached values past its limit, which only
    /// means an unchanged reading here: the previous value stays on screen until the next one.
    private func readTotal() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(machHost, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private func readCoreLoads() -> [Double] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return [] }
        defer {
            vm_deallocate(
                machTask,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        let current = (0..<Int(coreCount)).map { core in
            CPUTicks(
                user: UInt64(UInt32(bitPattern: info[core * stride + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[core * stride + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[core * stride + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[core * stride + Int(CPU_STATE_NICE)]))
            )
        }
        defer { previousCores = current }
        // Without a previous reading there is nothing to compare; zeros would look like idle cores.
        guard previousCores.count == current.count else { return [] }
        return zip(previousCores, current).map { CPULoad(from: $0, to: $1)?.usage ?? 0 }
    }
}
