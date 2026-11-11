import Darwin
import FanControlCore
import Foundation
import os

private let log = Logger(subsystem: "me.tweakly.Tweakly.fanhelper", category: "processes")

/// The task manager's part of the helper: reading the figures of processes, and ending one process. Both take only the
/// process numbers the app passes, and nothing here keeps running between calls.
enum ProcessService {
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }()

    static func figures(of pids: [Int32]) -> [NSNumber] {
        var numbers: [NSNumber] = []
        numbers.reserveCapacity(min(pids.count, ProcessFigures.mostPerRequest) * ProcessFigures.count)
        for pid in pids.prefix(ProcessFigures.mostPerRequest) where pid >= 0 {
            guard let usage = usage(of: pid) else { continue }
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? UInt64(task.pti_threadnum) : 0
            let cpu = UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * nanosecondsPerTick)
            let row: [UInt64] = [
                UInt64(UInt32(bitPattern: pid)), usage.ri_proc_start_abstime, cpu, usage.ri_phys_footprint,
                usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten, threads,
            ]
            numbers.append(contentsOf: row.map { NSNumber(value: $0) })
        }
        return numbers
    }

    static func end(_ pid: Int32, start: UInt64, force: Bool) -> String? {
        // The kernel and launchd take the whole Mac with them, and the helper would end its own answer.
        guard pid > 1, pid != getpid() else { return "refused" }
        if start != 0 {
            guard let usage = usage(of: pid) else { return "no such process" }
            guard usage.ri_proc_start_abstime == start else { return "a different process has that number now" }
        }
        let signal = force ? SIGKILL : SIGTERM
        guard kill(pid, signal) == 0 else { return String(cString: strerror(errno)) }
        log.notice("Ended \(pid, privacy: .public) with signal \(signal, privacy: .public) at the app's request")
        return nil
    }

    private static func usage(of pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }
}
