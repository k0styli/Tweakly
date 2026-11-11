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
    private var identities = ProcessIdentities()
    private var ranking = Ranking()

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    func rank() -> Ranking {
        let now = uptimeSeconds()
        let hadBaseline = lastTime > 0
        let required = hadBaseline && ranking.byCPU.isEmpty ? Self.firstInterval : Self.interval
        guard now - lastTime >= required * 0.9 else { return ranking }
        let elapsed = now - lastTime
        lastTime = now

        var count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        if count >= Int32(pids.count) {
            pids = [pid_t](repeating: 0, count: pids.count * 2)
            count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return ranking }

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

        // Without a baseline every CPU figure would be zero, and the order meaningless.
        // In the very short first window, this app's own figure is mostly the cost of opening the details
        // that asked for the list, which says nothing about how busy it is.
        let isFirstWindow = ranking.byCPU.isEmpty
        let ownPID = getpid()
        ranking.byCPU =
            hadBaseline
            ? top(readings.filter { $0.cpu > 0 && !(isFirstWindow && $0.pid == ownPID) }) { $0.cpu > $1.cpu }
            : []
        ranking.byMemory = top(readings) { $0.memory > $1.memory }
        // Few processes touch the disk at one moment. Those that have used it most so far fill the remaining
        // rows, so the list holds its size instead of leaving a hole that comes and goes.
        ranking.byDisk = top(readings.filter { $0.diskTotal > 0 }) {
            let (left, right) = ($0.diskRead + $0.diskWrite, $1.diskRead + $1.diskWrite)
            return left != right ? left > right : $0.diskTotal > $1.diskTotal
        }
        return ranking
    }

    private func top(_ readings: [Reading], by order: (Reading, Reading) -> Bool) -> [ProcessEntry] {
        Self.first(Self.listSize, of: readings, by: order).map { reading in
            let identity = identities.identity(of: reading.pid)
            return ProcessEntry(
                pid: reading.pid,
                name: identity.name,
                path: identity.path,
                cpu: reading.cpu,
                memory: reading.memory,
                diskRead: reading.diskRead,
                diskWrite: reading.diskWrite
            )
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

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

/// Names and paths of running processes, looked up once each because they do not change.
struct ProcessIdentities {
    struct Identity {
        let name: String
        let path: String?
    }

    private var known: [Int32: Identity] = [:]

    mutating func identity(of pid: Int32, fallbackName: String? = nil) -> Identity {
        if let identity = known[pid] { return identity }
        let path = ProcessSampler.path(of: pid)
        let identity = Identity(name: ProcessSampler.displayName(path: path) ?? fallbackName ?? "\(pid)", path: path)
        known[pid] = identity
        return identity
    }

    mutating func removeAll(where isGone: (Int32) -> Bool) {
        known = known.filter { !isGone($0.key) }
    }
}
