import Foundation
import os

/// Where failures of the system interfaces go. A value that cannot be read simply disappears from the
/// screen, so this is how anyone can find out why.
let metricsLog = Logger(subsystem: "me.tweakly.Tweakly", category: "metrics")

/// Runs the short-lived system tools that are the only public source of some figures.
enum ExternalTool {
    /// The tool's output, or nil if it fails. Blocks the calling thread, so never call this on the sampling
    /// queue. A tool that hangs is killed, rather than tying up a thread and a process for good.
    static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            metricsLog.notice(
                "Could not start \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let identifier = process.processIdentifier
        let watchdog = DispatchWorkItem {
            metricsLog.notice("Killing \(path, privacy: .public), which did not finish in time")
            kill(identifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            metricsLog.notice("\(path, privacy: .public) exited with \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return data
    }
}
