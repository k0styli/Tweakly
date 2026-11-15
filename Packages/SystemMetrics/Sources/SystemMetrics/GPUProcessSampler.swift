import Foundation
import IOKit

/// Ranks processes by GPU time. Every process using the GPU has client entries under the accelerator in
/// the I/O Registry, each adding up the time it has used. The keys are not formally documented, so a
/// missing key only leaves the list empty. No privileges are needed. Checked on macOS 27.2 on an M2.
final class GPUProcessSampler {
    struct Client {
        var time: UInt64
        var lastSubmitted: UInt64
        let name: String
    }

    /// What one app, or one process on its own, adds up to.
    private struct Row {
        let owner: ProcessOwner
        var share = 0.0
        var isActive = false
        var lastSubmitted: UInt64 = 0
        var pids: [Int32] = []
    }

    private static let listSize = 5
    private static let interval: TimeInterval = 2
    /// Use takes two readings, and the list should fill in soon after details open.
    private static let firstInterval: TimeInterval = 0.2

    private var lastTimes: [Int32: UInt64] = [:]
    private var lastTime: TimeInterval = 0
    private var identities = ProcessIdentities()
    private var ranking: [ProcessEntry] = []

    func rank(accelerator: io_service_t) -> [ProcessEntry] {
        let now = uptimeSeconds()
        let hadBaseline = lastTime > 0
        let required = hadBaseline && ranking.isEmpty ? Self.firstInterval : Self.interval
        guard now - lastTime >= required * 0.9 else { return ranking }
        let elapsed = now - lastTime
        lastTime = now

        let clients = Self.readClients(of: accelerator)
        defer { lastTimes = clients.mapValues(\.time) }
        identities.forgetEnded()
        guard hadBaseline, elapsed > 0 else { return ranking }

        // An app's processes count as one row, as in the other lists. Work in parallel can add up to more than the time
        // that passed, but this is a share of the GPU.
        var rows: [ProcessOwner.Key: Row] = [:]
        var order: [ProcessOwner.Key] = []
        for (pid, client) in clients.sorted(by: { $0.key < $1.key }) {
            let owner = identities.owner(of: pid, fallbackName: client.name)
            var row = rows[owner.key] ?? Row(owner: owner)
            if row.pids.isEmpty { order.append(owner.key) }
            row.pids.append(pid)
            // A process that closed a client adds up to less than before, which only means an unknown window.
            if let last = lastTimes[pid], client.time > last {
                row.share += Double(client.time - last) / 1_000_000_000 / elapsed
                row.isActive = true
            }
            row.lastSubmitted = max(row.lastSubmitted, client.lastSubmitted)
            rows[owner.key] = row
        }
        let all = order.compactMap { rows[$0] }
        // Few processes draw at any one moment. The most recent of the others fill the remaining rows, so
        // the list holds its size instead of leaving a hole that comes and goes.
        let shown =
            all.filter(\.isActive).sorted { $0.share > $1.share }
            + all.filter { !$0.isActive && $0.lastSubmitted > 0 }.sorted { $0.lastSubmitted > $1.lastSubmitted }
        ranking = shown.prefix(Self.listSize).map { row in
            var entry = identities.entry(for: row.owner, pids: row.pids)
            entry.gpu = min(row.share, 1)
            return entry
        }
        return ranking
    }

    static func readClients(of accelerator: io_service_t) -> [Int32: Client] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var clients: [Int32: Client] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let values = properties?.takeRetainedValue() as? [String: Any],
                let creator = (values["IOUserClientCreator"] as? String).flatMap(owner(fromCreator:))
            else { continue }
            let usage = values["AppUsage"] as? [[String: Any]] ?? []
            var client = clients[creator.pid] ?? Client(time: 0, lastSubmitted: 0, name: creator.name)
            for queue in usage {
                client.time &+= (queue["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                client.lastSubmitted = max(
                    client.lastSubmitted, (queue["lastSubmittedTime"] as? NSNumber)?.uint64Value ?? 0)
            }
            clients[creator.pid] = client
        }
        return clients
    }

    /// Reads a creator such as `pid 415, WindowServer`. The kernel cuts the name to 16 characters, so it
    /// only stands in when a process's real path cannot be read.
    static func owner(fromCreator creator: String) -> (pid: Int32, name: String)? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ","),
            let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]), pid > 0
        else { return nil }
        return (pid, creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces))
    }
}
