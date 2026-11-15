import Foundation
import Synchronization

/// Ranks processes by network traffic. macOS has no public API for this short of `nettop`, whose counters
/// cover every user's processes without privileges. Each run costs 15–35 ms of CPU and most of its
/// time is spent waiting, off the sampling queue, so this only runs while details are on screen.
///
/// On macOS 27.2 a run answers about 5 seconds after it starts, whatever `-s` and `-L` say, so with the
/// pause between runs a rate covers about 6 seconds. Asked to keep running with `-L 0`, it spins above a
/// full core instead.
final class NetworkProcessSampler {
    struct Usage {
        let name: String
        let received: UInt64
        let sent: UInt64
    }

    private struct State {
        var last: [Int32: Usage] = [:]
        var lastTime: TimeInterval?
        var identities = ProcessIdentities()
        var ranking: [ProcessEntry] = []
        var isStopped = false
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    /// What one app, or one process on its own, adds up to.
    private struct Row {
        let owner: ProcessOwner
        var down = 0.0
        var up = 0.0
        var isActive = false
        var total: UInt64 = 0
        var pids: [Int32] = []
    }

    private static let listSize = 5
    private static let pause: TimeInterval = 1
    /// A tool that keeps failing is not worth starting every second.
    static let pauseAfterFailure: TimeInterval = 30
    /// Well past the 5 seconds a run takes. A limit of 5 seconds fired on every run and lost 2 runs of 33,
    /// each of which froze the list for the 30-second pause after a failure.
    private static let timeout: TimeInterval = 12

    /// What every process has sent and received so far, from one run of `nettop`; nil if it failed. The popover's
    /// list and the task manager's rates both read it.
    static func readTotals() -> [Int32: Usage]? {
        let arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"]
        return ExternalTool.run("/usr/bin/nettop", arguments: arguments, timeout: timeout)
            .map { parse(String(decoding: $0, as: UTF8.self)) }
    }

    private let shared = Shared()

    init() {
        Self.scheduleRun(shared, after: 0)
    }

    deinit {
        shared.state.withLock { $0.isStopped = true }
    }

    func ranking() -> [ProcessEntry] {
        shared.state.withLock { $0.ranking }
    }

    private static func scheduleRun(_ shared: Shared, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            guard !shared.state.withLock({ $0.isStopped }) else { return }
            let usage = readTotals()
            if let usage { update(shared, usage: usage, now: uptimeSeconds()) }
            scheduleRun(shared, after: usage == nil ? pauseAfterFailure : pause)
        }
    }

    private static func update(_ shared: Shared, usage: [Int32: Usage], now: TimeInterval) {
        shared.state.withLock { state in
            let elapsed = state.lastTime.map { now - $0 }
            // An app's processes count as one row, as in the other lists.
            var rows: [ProcessOwner.Key: Row] = [:]
            var order: [ProcessOwner.Key] = []
            state.identities.removeAll { usage[$0] == nil }
            for (pid, current) in usage.sorted(by: { $0.key < $1.key }) {
                let owner = state.identities.owner(of: pid, fallbackName: current.name)
                var row = rows[owner.key] ?? Row(owner: owner)
                if row.pids.isEmpty { order.append(owner.key) }
                row.pids.append(pid)
                row.total &+= current.received &+ current.sent
                // A process that closed a socket adds up to less than before, which only means an unknown window.
                if let elapsed, elapsed > 0, let last = state.last[pid],
                    current.received >= last.received, current.sent >= last.sent,
                    current.received > last.received || current.sent > last.sent
                {
                    row.down += Double(current.received - last.received) / elapsed
                    row.up += Double(current.sent - last.sent) / elapsed
                    row.isActive = true
                }
                rows[owner.key] = row
            }
            let all = order.compactMap { rows[$0] }
            // Few processes transfer anything at one moment. Those with the most traffic so far fill the
            // remaining rows, so the list holds its size instead of leaving a hole that comes and goes.
            let shown =
                all.filter(\.isActive).sorted { $0.down + $0.up > $1.down + $1.up }
                + all.filter { !$0.isActive && $0.total > 0 }.sorted { $0.total > $1.total }
            state.ranking = shown.prefix(listSize).map { row in
                var entry = state.identities.entry(for: row.owner, pids: row.pids)
                entry.downRate = row.down
                entry.upRate = row.up
                return entry
            }
            state.last = usage
            state.lastTime = now
        }
    }

    /// Reads lines such as `Claude Helper.27096,1975620,2226247,`. A name can hold dots, so the process
    /// number is what follows the last one.
    static func parse(_ output: String) -> [Int32: Usage] {
        var usage: [Int32: Usage] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                let pid = Int32(fields[0][fields[0].index(after: dot)...]), pid > 0,
                let received = UInt64(fields[1]), let sent = UInt64(fields[2])
            else { continue }
            usage[pid] = Usage(name: String(fields[0][..<dot]), received: received, sent: sent)
        }
        return usage
    }
}
