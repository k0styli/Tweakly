import Darwin
import Foundation
import IOKit

/// One process as libproc reports it. Another user's process answers only who it is: the rest needs root.
public struct ProcessReading: Sendable {
    public let pid: Int32
    /// When it started, in mach time. Zero when it cannot be read.
    public let start: UInt64
    public let parentPID: Int32
    public let userID: UInt32
    /// The executable's file name, in full, unlike the kernel's own name for it, which is cut to 16 characters.
    public let name: String
    public let path: String?
    /// Nanoseconds.
    public let cpuTime: UInt64?
    /// The physical footprint, which Activity Monitor calls Memory.
    public let memory: UInt64?
    public let diskRead: UInt64?
    public let diskWritten: UInt64?
    public let threads: Int?
    /// An Intel program under Rosetta.
    public let isTranslated: Bool?
}

/// Reads every process on the Mac, for a table of them. Costs about 3 ms for 450 processes on an M2, so it runs only
/// while that table is on screen.
public final class ProcessCounterReader {
    private struct Identity {
        let start: UInt64
        let shortName: String
        let name: String
        let path: String?
        let isTranslated: Bool?
    }

    private let nanosecondsPerTick: Double
    private var pids = [pid_t](repeating: 0, count: 2048)
    private var identities: [Int32: Identity] = [:]
    private var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    /// Threads cost a call of their own for each process, so they are read only when asked for.
    public func read(includingThreads: Bool) -> [ProcessReading] {
        var count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        if count >= Int32(pids.count) {
            pids = [pid_t](repeating: 0, count: Int(count) * 2)
            count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        var readings: [ProcessReading] = []
        readings.reserveCapacity(Int(count))
        var seen: Set<Int32> = []
        seen.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            // The kernel is process 0 and answers nothing about itself.
            guard pid >= 0, let short = Self.shortInfo(of: pid) else { continue }
            seen.insert(pid)
            let usage = Self.usage(of: pid)
            let start = usage?.ri_proc_start_abstime ?? 0
            let identity = identity(of: pid, start: start, shortName: Self.name(of: short))
            var threads: Int?
            if includingThreads, usage != nil {
                var task = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.stride)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size { threads = Int(task.pti_threadnum) }
            }
            readings.append(
                ProcessReading(
                    pid: pid, start: start, parentPID: Int32(bitPattern: short.pbsi_ppid), userID: short.pbsi_uid,
                    name: identity.name, path: identity.path,
                    cpuTime: usage.map { UInt64(Double($0.ri_user_time &+ $0.ri_system_time) * nanosecondsPerTick) },
                    memory: usage?.ri_phys_footprint, diskRead: usage?.ri_diskio_bytesread,
                    diskWritten: usage?.ri_diskio_byteswritten, threads: threads,
                    isTranslated: identity.isTranslated))
        }
        if identities.count > seen.count { identities = identities.filter { seen.contains($0.key) } }
        return readings
    }

    /// Looked up once for each process, as a path does not change. A process whose start cannot be read is known again
    /// by its kernel name, which tells most reused numbers apart.
    private func identity(of pid: Int32, start: UInt64, shortName: String) -> Identity {
        if let known = identities[pid], known.start == start, known.shortName == shortName { return known }
        let path = path(of: pid)
        var arch = proc_archinfo()
        let size = Int32(MemoryLayout<proc_archinfo>.stride)
        let isTranslated =
            proc_pidinfo(pid, PROC_PIDARCHINFO, 0, &arch, size) == size ? arch.p_cputype == CPU_TYPE_X86_64 : nil
        let name = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? shortName
        let identity = Identity(start: start, shortName: shortName, name: name, path: path, isTranslated: isTranslated)
        identities[pid] = identity
        return identity
    }

    private func path(of pid: Int32) -> String? {
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return pathBuffer.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeRawBufferPointer(start: buffer.baseAddress, count: Int(length)), as: UTF8.self)
        }
    }

    private static func shortInfo(of pid: Int32) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func name(of info: proc_bsdshortinfo) -> String {
        withUnsafeBytes(of: info.pbsi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func usage(of pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }

    /// The name of a user, looked up by the caller once for each user.
    public static func userName(of userID: UInt32) -> String? {
        guard let entry = getpwuid(userID), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}

/// GPU time for each process using the GPU, from the same client entries `GPUProcessSampler` reads. Needs no rights.
public final class GPUTimeReader {
    private var service: io_service_t = 0

    public init() {}

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Nanoseconds of GPU time so far for each process.
    public func read() -> [Int32: UInt64] {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        }
        guard service != 0 else { return [:] }
        return GPUProcessSampler.readClients(of: service).mapValues(\.time)
    }
}
