import FanControlCore
import Foundation
import Synchronization

/// The task manager's side of the root helper: the figures of processes the app cannot read, and ending one of them. The
/// helper is the fans' one, installed once with an administrator's password; launchd starts it when this connects, and
/// it leaves 20 seconds after the last call. Only processes the app passes are read, and only one is ended at a time.
nonisolated final class SystemProcessHelper {
    enum State: Equatable, Sendable {
        case notInstalled
        /// An older helper, which has no process calls.
        case outdated
        case working
        /// Installed and current, but not answering, which the next update tries again.
        case failing
    }

    struct Figures: Sendable {
        var start: UInt64
        var cpuTime: UInt64
        var memory: UInt64
        var diskRead: UInt64
        var diskWritten: UInt64
        var threads: Int
    }

    /// A slow helper must not hold the table up: the next update simply asks again.
    private static let timeout: TimeInterval = 2

    private static var label: String { FanHelper.label(forApp: Bundle.main.bundleIdentifier ?? "") }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanHelper.launchdPlist(forApp: Bundle.main.bundleIdentifier ?? ""))
    }

    private var connection: NSXPCConnection?
    private var version: Int?

    deinit {
        connection?.invalidate()
    }

    /// Whether the helper can be asked, checking its version once for each connection.
    func state() async -> State {
        guard Self.isInstalled else {
            close()
            return .notInstalled
        }
        if version == nil {
            version = await call(nil) { proxy, done in proxy.version { done($0) } }
        }
        guard let version else {
            // A connection the helper's reinstall or removal invalidated stays dead: the next try makes a new one.
            close()
            return .failing
        }
        return version >= FanHelper.currentVersion ? .working : .outdated
    }

    func figures(of pids: [Int32]) async -> [Int32: Figures]? {
        guard !pids.isEmpty else { return [:] }
        let numbers = pids.prefix(ProcessFigures.mostPerRequest).map { NSNumber(value: $0) }
        guard let flat: [NSNumber] = await call(nil, { proxy, done in proxy.processFigures(numbers) { done($0) } })
        else {
            close()
            return nil
        }
        var figures: [Int32: Figures] = [:]
        let width = ProcessFigures.count
        for start in stride(from: 0, to: flat.count - width + 1, by: width) {
            func field(_ field: ProcessFigures.Field) -> UInt64 { flat[start + field.rawValue].uint64Value }
            figures[Int32(truncatingIfNeeded: field(.pid))] = Figures(
                start: field(.start), cpuTime: field(.cpuTime), memory: field(.memory), diskRead: field(.diskRead),
                diskWritten: field(.diskWritten), threads: Int(clamping: field(.threads)))
        }
        return figures
    }

    /// Nil when it went well, otherwise what went wrong.
    func end(_ pid: Int32, start: UInt64, force: Bool) async -> String? {
        let answer: String?? = await call(nil) { proxy, done in
            proxy.endProcess(pid, start: start, force: force) { done($0) }
        }
        guard let answer else {
            close()
            return "the helper did not answer"
        }
        return answer
    }

    private func close() {
        connection?.invalidate()
        connection = nil
        version = nil
    }

    /// One call, whose answer comes once: from the helper, from an error, or from the timeout, whichever is first.
    private func call<Answer: Sendable>(
        _ fallback: Answer?,
        _ body: @escaping (FanHelperProtocol, @escaping @Sendable (Answer) -> Void) -> Void
    ) async -> Answer? {
        let connection = connection ?? makeConnection()
        self.connection = connection
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            // On XPC's own queues, where nothing tied to the main thread may run.
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(fallback) }
                as? FanHelperProtocol
            guard let proxy else {
                once.resume(fallback)
                return
            }
            body(proxy) { @Sendable answer in once.resume(answer) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout) {
                once.resume(fallback)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: Self.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.resume()
        return connection
    }
}

/// Resumes a continuation once, however many of the answers arrive.
nonisolated private final class Once<Answer: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Answer?, Never>?>

    init(_ continuation: CheckedContinuation<Answer?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ answer: Answer?) {
        continuation.withLock { stored in
            stored?.resume(returning: answer)
            stored = nil
        }
    }
}
