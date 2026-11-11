import Foundation
import Observation
import SystemMetrics

/// Live values for the Home page. Samples only while that page can actually be seen.
///
/// What was last read stays while the page is out of sight, as in the task manager, so coming back shows the page as
/// it was rather than an empty one. A new engine delivers nothing that needs two readings until it has them, about a
/// quarter of a second, and fresh values of the rest at once, so nothing drops to zero on the way.
final class OverviewFeed {
    let data = StatsLiveData()
    private var engine: MetricsEngine?

    func setVisible(_ isVisible: Bool) {
        guard isVisible != (engine != nil) else { return }
        guard isVisible else {
            engine = nil
            return
        }
        let engine = MetricsEngine { [weak self] updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil else { return }
                    updates.forEach(self.data.apply)
                }
            }
        }
        var levels: [MetricKind: SamplingLevel] = [:]
        // The page has nothing about the fans, whose sensors are not free to read.
        for kind in MetricKind.available where kind != .fans { levels[kind] = .overview }
        // The page lists what is working the hardest, and none of it needs the processor's sensors or its cores.
        engine.apply(SamplingPlan(levels: levels, kindsListingProcesses: [.cpu]))
        self.engine = engine
    }
}

extension MetricKind {
    /// The metrics this Mac can report. Read once, because a Mac does not gain or lose a battery or a fan.
    static let available: [MetricKind] = {
        let (hasBattery, hasFans) = (SystemInfo.hasBattery, SystemInfo.hasFans)
        return allCases.filter { ($0 != .battery || hasBattery) && ($0 != .fans || hasFans) }
    }()
}
