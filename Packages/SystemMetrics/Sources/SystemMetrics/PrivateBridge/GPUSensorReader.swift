import Foundation

/// PRIVATE INTERFACE. The GPU's frequency and power, how busy the Neural Engine is and the frame rate on
/// screen, from `libIOReport`.
/// Each value has its own channel, so losing one to a macOS update leaves the others working. Checked on
/// macOS 27.2 on an M2.
final class GPUSensorReader {
    struct Reading: Equatable {
        /// Megahertz, averaged over the active time. Nil if the GPU was off the whole time.
        var frequency: Double?
        /// Watts.
        var power: Double?
        /// The share of time the Neural Engine was busy.
        var neuralEngine: Double?
    }

    private let performanceStates = IOReportSubscription(group: "GPU Stats", subgroup: "GPU Performance States")
    private let energy = IOReportSubscription(group: "Energy Model", subgroup: nil)
    private let socFloor = IOReportSubscription(group: "PMP", subgroup: "SOC Floor")
    private let builtInDisplay = IOReportSubscription(group: "DCP", subgroup: "swap")
    private let externalDisplays = IOReportSubscription(group: "DCPEXT", subgroup: "swap")
    private var lastFrameRead: TimeInterval?
    private let frequencyLevels: [Double]
    private var lastRead: TimeInterval?

    init() {
        let table = PowerManagerTables.read { table -> [Double]? in
            let sram = table("voltage-states9-sram")
            return sram.isEmpty ? table("voltage-states9") : sram
        }
        // The table can start with a zero for the off state, which `P1` does not count.
        frequencyLevels = Array((table ?? []).drop { $0 == 0 })
    }

    /// The values since the previous call. The first call only takes the baselines, so its values are nil.
    func read(now: TimeInterval) -> Reading {
        defer { lastRead = now }
        var reading = Reading()
        if let report = performanceStates,
            let channel = report.changes()?.first(where: { report.name(of: $0) == "GPUPH" })
        {
            reading.frequency = Self.averageFrequency(states: report.states(of: channel), levels: frequencyLevels)
        }
        if let report = energy, let channel = report.changes()?.first(where: { report.name(of: $0) == "GPU Energy" }),
            let lastRead, now > lastRead, let joules = report.unit(of: channel).flatMap(Self.joulesPerUnit),
            let energy = report.value(of: channel)
        {
            reading.power = Double(energy) * joules / (now - lastRead)
        }
        if let report = socFloor, let channel = report.changes()?.first(where: { report.name(of: $0) == "ANE-BW" }) {
            reading.neuralEngine = Self.activeShare(report.states(of: channel))
        }
        return reading
    }

    /// New frames per second on the busiest display since the previous call. The first call only takes
    /// the baseline, so returns nil. These count frames handed to the display, which fall to one or two
    /// on a still screen, unlike the display's `scanout` channels that stay at its refresh rate.
    func framesPerSecond(now: TimeInterval) -> Double? {
        defer { lastFrameRead = now }
        let frames = [builtInDisplay, externalDisplays].compactMap { report -> Int64? in
            guard let report, let channels = report.changes() else { return nil }
            // Each display repeats the same channel names, so the largest stands for the busiest one.
            var largest: [String: Int64] = [:]
            for channel in channels {
                guard let name = report.name(of: channel) else { continue }
                largest[name] = max(largest[name] ?? 0, report.value(of: channel) ?? 0)
            }
            return largest.values.reduce(0, +)
        }
        guard let busiest = frames.max(), let lastFrameRead, now > lastFrameRead else { return nil }
        return Double(busiest) / (now - lastFrameRead)
    }

    /// States are named `OFF`, then `P1` upwards, and `Pn` runs at the nth level of the table. There are
    /// more states than levels, so a value is dropped rather than guessed if an unlisted state was used.
    static func averageFrequency(states: [ClusterActivity.State], levels: [Double]) -> Double? {
        var active = 0.0
        var weighted = 0.0
        for state in states where state.residency > 0 && state.name != "OFF" {
            // Compared one by one: a range would trap on the empty table of a chip without these keys.
            guard state.name.hasPrefix("P"), let number = Int(state.name.dropFirst()), number >= 1,
                number <= levels.count
            else { return nil }
            active += Double(state.residency)
            weighted += Double(state.residency) * levels[number - 1]
        }
        return active > 0 ? weighted / active : nil
    }

    /// The share of time spent above the lowest state. The Neural Engine has no utilisation counter, but
    /// it raises this voltage floor whenever it runs: under known loads this tracked the time spent in
    /// inference in a straight line, and read exactly zero at rest.
    static func activeShare(_ states: [ClusterActivity.State]) -> Double? {
        let total = states.reduce(0) { $0 + $1.residency }
        guard total > 0, let lowest = states.first(where: { $0.name == "VMIN" }) else { return nil }
        return Double(total - lowest.residency) / Double(total)
    }

    private static func joulesPerUnit(_ unit: String) -> Double? {
        switch unit {
        case "nJ": 1e-9
        case "uJ", "µJ": 1e-6
        case "mJ": 1e-3
        case "J": 1
        default: nil
        }
    }
}
