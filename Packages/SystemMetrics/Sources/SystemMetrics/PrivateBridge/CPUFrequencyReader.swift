import Foundation

/// PRIVATE INTERFACE. Works out how fast each CPU cluster actually runs, which no public API reports.
///
/// `libIOReport` says how long each cluster spent in each performance state, and the power manager's
/// device tree node holds the frequency of each state. Checked on macOS 27.2 on an M2.
final class CPUFrequencyReader {
    private let report: IOReportSubscription
    private let efficiencyTable: [Double]
    private let performanceTable: [Double]

    init?() {
        // `voltage-states1-sram` describes the efficiency cluster and `voltage-states5-sram` the performance one.
        let tables = PowerManagerTables.read { table -> (efficiency: [Double], performance: [Double])? in
            let efficiency = table("voltage-states1-sram")
            let performance = table("voltage-states5-sram")
            return efficiency.isEmpty && performance.isEmpty ? nil : (efficiency, performance)
        }
        guard let tables,
            let report = IOReportSubscription(group: "CPU Stats", subgroup: "CPU Complex Performance States")
        else { return nil }
        self.report = report
        efficiencyTable = tables.efficiency
        performanceTable = tables.performance
    }

    /// The frequencies since the previous call. The first call only takes the baseline, so returns nil.
    func read() -> CPUFrequencies? {
        guard let channels = report.changes() else { return nil }
        var efficiency = ClusterActivity()
        var performance = ClusterActivity()
        for channel in channels {
            guard let name = report.name(of: channel) else { continue }
            if name.hasPrefix("ECPU") {
                efficiency.add(states: report.states(of: channel), table: efficiencyTable)
            } else if name.hasPrefix("PCPU") {
                performance.add(states: report.states(of: channel), table: performanceTable)
            }
        }
        return CPUFrequencies(efficiency: efficiency, performance: performance)
    }
}

/// How long a cluster was active and at what frequency.
struct ClusterActivity: Equatable {
    struct State: Equatable {
        let name: String
        let residency: Int64
    }

    private static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    private(set) var activeTime = 0.0
    private(set) var weightedFrequency = 0.0

    /// Ignores a channel whose states do not line up with the table, rather than guess at frequencies.
    mutating func add(states: [State], table: [Double]) {
        let active = states.filter { !Self.inactiveStates.contains($0.name) }
        guard active.count == table.count else { return }
        for (state, frequency) in zip(active, table) {
            activeTime += Double(state.residency)
            weightedFrequency += Double(state.residency) * frequency
        }
    }

    /// In megahertz, or nil if the cluster was idle the whole time.
    var averageFrequency: Double? { activeTime > 0 ? weightedFrequency / activeTime : nil }
}

extension CPUFrequencies {
    init(efficiency: ClusterActivity, performance: ClusterActivity) {
        self.init(efficiency: efficiency.averageFrequency, performance: performance.averageFrequency)
        let active = efficiency.activeTime + performance.activeTime
        overall = active > 0 ? (efficiency.weightedFrequency + performance.weightedFrequency) / active : nil
    }
}
