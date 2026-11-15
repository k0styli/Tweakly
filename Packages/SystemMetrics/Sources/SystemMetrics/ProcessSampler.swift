import Darwin
import Foundation

/// Ranks the user's processes by CPU and memory. Only runs while a detail view is on screen, because
/// it touches every process. Processes owned by other users refuse access and are simply skipped.
final class ProcessSampler {
    struct Ranking {
        var byCPU: [ProcessEntry] = []
        var byMemory: [ProcessEntry] = []
        var byDisk: [ProcessEntry] = []
    }

    /// The lists something on screen shows. Only those get rows made, each with a name to find.
    struct Lists: OptionSet {
        let rawValue: Int
        static let cpu = Lists(rawValue: 1)
        static let memory = Lists(rawValue: 2)
        static let disk = Lists(rawValue: 4)
        static let all: Lists = [.cpu, .memory, .disk]

        init(rawValue: Int) { self.rawValue = rawValue }

        init(listing kind: MetricKind) {
            switch kind {
            case .cpu, .battery: self = .cpu
            case .memory: self = .memory
            case .disk: self = .disk
            case .gpu, .network, .fans: self = []
            }
        }
    }

    /// What one app, or one process on its own, adds up to.
    private struct Row {
        let owner: ProcessOwner
        var cpu = 0.0
        var memory: UInt64 = 0
        var diskRead = 0.0
        var diskWrite = 0.0
        var diskTotal: UInt64 = 0
        var pids: [Int32] = []
    }

    private struct Reading {
        let pid: Int32
        let cpu: Double
        let memory: UInt64
        let diskRead: Double
        let diskWrite: Double
        let diskTotal: UInt64
    }

    private static let listSize = 5
    private static let interval: TimeInterval = 2
    /// CPU use takes two readings, and the list should fill in soon after details open.
    private static let firstInterval: TimeInterval = 0.2

    private let nanosecondsPerTick: Double
    private var pids = [pid_t](repeating: 0, count: 2048)
    private var lastCPUTime: [Int32: UInt64] = [:]
    private var lastDisk: [Int32: (read: UInt64, written: UInt64)] = [:]
    private var lastTime: TimeInterval = 0
    /// Readings taken since the baseline, the first of which covers only a fifth of a second.
    private var windows = 0
    private var identities = ProcessIdentities()
    /// Everything the last reading added up, from which a list asked for later is made without reading again.
    private var rows: [Row] = []
    private var ranking = Ranking()
    private var madeLists: Lists = []

    /// The first reading only takes the baseline and looks up who every process is, which costs several times a usual
    /// reading. It is best taken where nothing waits for it.
    var hasBaseline: Bool { lastTime > 0 }

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    func rank(lists: Lists = .all) -> Ranking {
        let now = uptimeSeconds()
        let hadBaseline = lastTime > 0
        let required = hadBaseline && windows == 0 ? Self.firstInterval : Self.interval
        guard now - lastTime >= required * 0.9 else { return make(lists) }
        let elapsed = now - lastTime
        lastTime = now

        var count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        if count >= Int32(pids.count) {
            pids = [pid_t](repeating: 0, count: pids.count * 2)
            count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return make(lists) }

        var readings: [Reading] = []
        readings.reserveCapacity(Int(count))
        var cpuTimes: [Int32: UInt64] = [:]
        cpuTimes.reserveCapacity(Int(count))
        var disk: [Int32: (read: UInt64, written: UInt64)] = [:]
        disk.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0, let usage = Self.usage(of: pid) else { continue }
            let total = usage.ri_user_time &+ usage.ri_system_time
            cpuTimes[pid] = total
            var cpu = 0.0
            if hadBaseline, elapsed > 0, let last = lastCPUTime[pid], total >= last {
                cpu = Double(total - last) * nanosecondsPerTick / 1_000_000_000 / elapsed
            }
            let read = usage.ri_diskio_bytesread
            let written = usage.ri_diskio_byteswritten
            disk[pid] = (read, written)
            var diskRead = 0.0
            var diskWrite = 0.0
            if hadBaseline, elapsed > 0, let last = lastDisk[pid], read >= last.read, written >= last.written {
                diskRead = Double(read - last.read) / elapsed
                diskWrite = Double(written - last.written) / elapsed
            }
            readings.append(
                Reading(
                    pid: pid, cpu: cpu, memory: usage.ri_phys_footprint, diskRead: diskRead, diskWrite: diskWrite,
                    diskTotal: read &+ written
                )
            )
        }
        lastCPUTime = cpuTimes
        lastDisk = disk
        identities.removeAll { cpuTimes[$0] == nil }

        // Every process counts towards its app before the busiest are chosen, or an app spread over many processes, each
        // modest, would never make the list however much it uses in all.
        // In the very short first window, this app's own figure is mostly the cost of opening the details
        // that asked for the list, which says nothing about how busy it is.
        let isFirstWindow = hadBaseline && windows == 0
        if hadBaseline { windows += 1 }
        let ownPID = getpid()
        var byOwner: [ProcessOwner.Key: Row] = [:]
        byOwner.reserveCapacity(readings.count)
        // In the order the system lists them, so rows with equal figures keep their places from one update to the next.
        var order: [ProcessOwner.Key] = []
        for reading in readings {
            let owner = identities.owner(of: reading.pid)
            var row = byOwner[owner.key] ?? Row(owner: owner)
            if row.pids.isEmpty { order.append(owner.key) }
            if !(isFirstWindow && reading.pid == ownPID) { row.cpu += reading.cpu }
            row.memory &+= reading.memory
            row.diskRead += reading.diskRead
            row.diskWrite += reading.diskWrite
            row.diskTotal &+= reading.diskTotal
            row.pids.append(reading.pid)
            byOwner[owner.key] = row
        }
        rows = order.compactMap { byOwner[$0] }
        madeLists = []
        return make(lists)
    }

    /// The lists asked for that the last reading has not made yet.
    private func make(_ lists: Lists) -> Ranking {
        let missing = lists.subtracting(madeLists)
        madeLists.formUnion(missing)
        // Without a baseline every CPU figure would be zero, and the order meaningless.
        if missing.contains(.cpu) {
            ranking.byCPU =
                windows > 0
                ? entries(Self.first(Self.listSize, of: rows.filter { $0.cpu > 0 }) { $0.cpu > $1.cpu }) : []
        }
        if missing.contains(.memory) {
            ranking.byMemory = entries(Self.first(Self.listSize, of: rows) { $0.memory > $1.memory })
        }
        // Few processes touch the disk at one moment. Those that have used it most so far fill the remaining
        // rows, so the list holds its size instead of leaving a hole that comes and goes.
        if missing.contains(.disk) {
            ranking.byDisk = entries(
                Self.first(Self.listSize, of: rows.filter { $0.diskTotal > 0 }) {
                    let (left, right) = ($0.diskRead + $0.diskWrite, $1.diskRead + $1.diskWrite)
                    return left != right ? left > right : $0.diskTotal > $1.diskTotal
                })
        }
        return ranking
    }

    private func entries(_ rows: [Row]) -> [ProcessEntry] {
        rows.map { row in
            var entry = identities.entry(for: row.owner, pids: row.pids)
            entry.cpu = row.cpu
            entry.memory = row.memory
            entry.diskRead = row.diskRead
            entry.diskWrite = row.diskWrite
            return entry
        }
    }

    /// The first few of many in order, without the cost of putting the hundreds of others in order too. Elements
    /// that compare equal keep their original order, as with `sorted`.
    static func first<Element>(_ count: Int, of elements: [Element], by order: (Element, Element) -> Bool) -> [Element]
    {
        var best: [Element] = []
        best.reserveCapacity(count + 1)
        for element in elements {
            if best.count == count, let last = best.last, !order(element, last) { continue }
            let position = best.firstIndex { order(element, $0) } ?? best.endIndex
            best.insert(element, at: position)
            if best.count > count { best.removeLast() }
        }
        return best
    }

    private static func usage(of pid: Int32) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info : nil
    }

    /// The name people recognise: the app bundle when the executable lives directly inside one, and
    /// the executable itself otherwise, so helpers stay distinguishable from their parent app.
    static func displayName(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let components = path.split(separator: "/")
        if components.count >= 4,
            components[components.count - 2] == "MacOS",
            components[components.count - 3] == "Contents",
            components[components.count - 4].hasSuffix(".app")
        {
            return String(components[components.count - 4].dropLast(4))
        }
        return components.last.map(String.init)
    }
}
