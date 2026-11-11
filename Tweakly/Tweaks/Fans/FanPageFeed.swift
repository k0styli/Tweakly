import FanControlCore
import Foundation
import Observation
import SystemMetrics

/// Live values for the fans' page in the window, only while it can be seen.
@Observable final class FanPageFeed {
    private(set) var snapshot: FanSnapshot?
    private(set) var driverStatus = FanDriverStatus.fine
    @ObservationIgnored private var engine: MetricsEngine?

    func setVisible(_ isVisible: Bool) {
        guard isVisible != (engine != nil) else { return }
        // The last reading stays, so that a window coming back into view does not have its page jump while the next arrives.
        guard isVisible else {
            engine = nil
            return
        }
        let engine = MetricsEngine { [weak self] updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(updates) }
            }
        }
        engine.apply(SamplingPlan(levels: [.fans: .overview]))
        self.engine = engine
    }

    private func apply(_ updates: [MetricUpdate]) {
        guard engine != nil else { return }
        for case .fans(let fans) in updates { snapshot = fans }
        UserDefaults.standard.synchronize()
        let status =
            UserDefaults.standard.string(forKey: FanDriverStatus.key).flatMap(FanDriverStatus.init(rawValue:)) ?? .fine
        // Setting an observed value redraws whatever reads it even when it is the same, and this comes every second.
        if status != driverStatus { driverStatus = status }
    }
}
