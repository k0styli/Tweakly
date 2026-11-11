import Foundation
import Synchronization

/// Bytes a second each process receives and sends, for a table of every process.
///
/// `nettop` is the only public source. On macOS 27.2 it answers about 5 seconds after it starts, whatever the sampling
/// options, and asked to keep running it spins at more than a full core. So it runs once at a time, back to back, and a
/// rate covers the time between two answers. Each run costs about 20 ms of CPU.
public final class NetworkRateReader: Sendable {
    public struct Rates: Sendable, Equatable {
        public let receive: Double
        public let send: Double

        public init(receive: Double, send: Double) {
            self.receive = receive
            self.send = send
        }
    }

    private struct State {
        var last: [Int32: NetworkProcessSampler.Usage] = [:]
        var lastTime: TimeInterval?
        var rates: [Int32: Rates] = [:]
        var isStopped = false
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let shared = Shared()

    public init() {
        Self.scheduleRun(shared, after: 0)
    }

    deinit {
        shared.state.withLock { $0.isStopped = true }
    }

    /// Empty until two runs have answered, about 10 seconds after this starts.
    public func rates() -> [Int32: Rates] {
        shared.state.withLock { $0.rates }
    }

    private static func scheduleRun(_ shared: Shared, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            guard !shared.state.withLock({ $0.isStopped }) else { return }
            let usage = NetworkProcessSampler.readTotals()
            if let usage { update(shared, usage: usage, now: uptimeSeconds()) }
            scheduleRun(shared, after: usage == nil ? NetworkProcessSampler.pauseAfterFailure : 0)
        }
    }

    private static func update(_ shared: Shared, usage: [Int32: NetworkProcessSampler.Usage], now: TimeInterval) {
        shared.state.withLock { state in
            defer {
                state.last = usage
                state.lastTime = now
            }
            guard let lastTime = state.lastTime, now - lastTime > minimumSampleInterval else { return }
            let elapsed = now - lastTime
            var rates: [Int32: Rates] = [:]
            for (pid, current) in usage {
                // A process that closed a connection adds up to less than before, which only means an unknown window.
                guard let last = state.last[pid], current.received >= last.received, current.sent >= last.sent else {
                    continue
                }
                rates[pid] = Rates(
                    receive: Double(current.received - last.received) / elapsed,
                    send: Double(current.sent - last.sent) / elapsed)
            }
            state.rates = rates
        }
    }
}
