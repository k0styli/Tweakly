import Foundation
import Synchronization

/// macOS's own "Maximum Capacity", the figure System Settings shows. The system works it out privately
/// and no API or registry key reports it: on the Mac this was checked on it is 92 %, where the raw
/// capacities give 90 %. `system_profiler` does report it, so it runs now and then, off the sampling
/// queue. The figure barely changes from one month to the next.
enum SystemBatteryHealth {
    enum Reading: Equatable {
        case pending
        case known(percent: Int)
        case unavailable
    }

    private struct State {
        var reading = Reading.pending
        var lastAttempt: TimeInterval?
        var isRunning = false
    }

    private static let refreshInterval: TimeInterval = 3600
    private static let timeout: TimeInterval = 10
    private static let state = Mutex(State())

    /// The latest answer, asking for a new one in the background when it is due.
    static func current() -> Reading {
        let now = uptimeSeconds()
        let (reading, isDue) = state.withLock { state in
            let isDue = !state.isRunning && state.lastAttempt.map { now - $0 >= refreshInterval } ?? !state.isRunning
            if isDue {
                state.isRunning = true
                state.lastAttempt = now
            }
            return (state.reading, isDue)
        }
        if isDue {
            DispatchQueue.global(qos: .utility).async { refresh() }
        }
        return reading
    }

    private static func refresh() {
        let output = ExternalTool.run(
            "/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"], timeout: timeout)
        let percent = output.flatMap(maximumCapacity(fromProfilerOutput:))
        state.withLock { state in
            state.isRunning = false
            if let percent {
                state.reading = .known(percent: percent)
            } else if state.reading == .pending {
                state.reading = .unavailable
            }
        }
    }

    /// Reads a value such as `"92 %"`. Its keys are undocumented, so anything else counts as no answer.
    static func maximumCapacity(fromProfilerOutput data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }
        for section in sections {
            guard let health = section["sppower_battery_health_info"] as? [String: Any],
                let text = health["sppower_battery_health_maximum_capacity"] as? String,
                let percent = Int(text.filter(\.isNumber)), (1...100).contains(percent)
            else { continue }
            return percent
        }
        return nil
    }
}
