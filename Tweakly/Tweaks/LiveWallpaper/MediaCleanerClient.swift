import Foundation
import LiveWallpaperCore
import os

/// Hands a file from outside to the sandboxed cleaner, `TweaklyMediaCleaner`, and takes back what it wrote. Tweakly
/// itself never parses such a file: it only moves or clones its bytes into a job folder in the inbox. A cleaner that
/// crashes, hangs or answers nonsense counts as a refusal, so a hostile file stays out either way.
enum MediaCleanerClient {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "media-cleaner")
    /// A large 4K video takes a few seconds; this is for one that never ends.
    private static let timeLimit = Duration.seconds(600)
    /// Job folders older than this are what a crash left behind.
    private static let staleAfter: TimeInterval = 24 * 3600

    static var inbox: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            MediaInbox.homeRelativePath, isDirectory: true)
    }

    /// The service's name, read from the bundle, as a test copy's service carries its own.
    private static var serviceName: String? {
        Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/TweaklyMediaCleaner.xpc"))?
            .bundleIdentifier
    }

    /// The cleaner's files for one file from outside, in a folder of their own until the library takes them.
    struct Job {
        let folder: URL
        let media: CleanedMedia

        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

        func discard() { try? FileManager.default.removeItem(at: folder) }
    }

    /// Moves a download, or clones someone's file, into a new job folder and has the cleaner check and rewrite it.
    static func clean(_ file: URL, moving: Bool) async throws -> Job {
        removeStaleJobs()
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = try CleanerOutput.Identity(of: folder.path)
        do {
            let input = folder.appendingPathComponent("input")
            if moving {
                try FileManager.default.moveItem(at: file, to: input)
            } else {
                // A clone on the same volume, but a real copy of up to 4 GB from another drive: not on the main thread.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: file, to: input)
                }.value
            }
            switch try await ask(CleanRequest(folder: folder.path, input: input.lastPathComponent)) {
            case .refused(let problem):
                throw WallpaperImporter.Failure(problem: problem)
            case .cleaned(let media):
                // Whatever the cleaner says, only files it wrote in the job's own folder are taken, and taken out of
                // its reach before anything else looks at them: a cleaner taken over by a hostile file keeps running,
                // and could leave a link to someone's own file in their place, or swap the folder itself.
                let names = [media.fileName, media.thumbnailName] + (media.stillName.map { [$0] } ?? [])
                guard media.namesArePlain else { throw WallpaperImporter.Failure(problem: .couldNotCheck) }
                let taken = try takeOut(names, from: folder, madeAs: made)
                try? FileManager.default.removeItem(at: folder)
                return Job(folder: taken, media: media)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Into a folder of the library's own, next to the wallpapers, so the files can be renamed into place.
    private static func takeOut(_ names: [String], from folder: URL, madeAs made: CleanerOutput.Identity) throws -> URL
    {
        let taken = try WallpaperFolder.newIncoming()
        do {
            try CleanerOutput.take(names, from: folder.path, madeAs: made, into: taken.path)
            return taken
        } catch {
            log.error("The cleaner's files were not taken: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: taken)
            throw WallpaperImporter.Failure(problem: .couldNotCheck)
        }
    }

    private static func ask(_ request: CleanRequest) async throws -> CleanReply {
        guard let name = serviceName else {
            log.error("The media cleaner is missing from the bundle")
            throw WallpaperImporter.Failure(problem: .couldNotCheck)
        }
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: MediaCleaning.self)
        let answer = Answer()
        connection.interruptionHandler = { answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck))) }
        connection.invalidationHandler = { answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck))) }
        connection.resume()
        defer { connection.invalidate() }
        let timer = Task {
            try await Task.sleep(for: timeLimit)
            log.error("The media cleaner took too long")
            answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck)))
        }
        defer { timer.cancel() }
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck)))
            } as? MediaCleaning
        guard let proxy else {
            answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck)))
            return try await answer.value()
        }
        proxy.clean(data) { reply in
            if let decoded = try? JSONDecoder().decode(CleanReply.self, from: reply) {
                answer.give(.success(decoded))
            } else {
                answer.give(.failure(WallpaperImporter.Failure(problem: .couldNotCheck)))
            }
        }
        return try await answer.value()
    }

    #if TWEAKLY_AUTOMATION
        /// For tests: has the cleaner try what its sandbox must forbid, and returns what it wrote down.
        static func probeSandbox() async -> String {
            let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try? await ask(CleanRequest(folder: folder.path, input: "sandbox-probe"))
            return (try? String(contentsOf: folder.appendingPathComponent("probe.txt"), encoding: .utf8))
                ?? "no answer"
        }
    #endif

    private static func removeStaleJobs() {
        let manager = FileManager.default
        guard
            let folders = try? manager.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date.now.timeIntervalSince(created) > staleAfter { try? manager.removeItem(at: folder) }
        }
    }
}

/// The first of the cleaner's reply, its crash, its error or the time limit, whichever comes first.
///
/// `@unchecked Sendable`: `result` and `waiter` are read and written only under `lock`.
private nonisolated final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CleanReply, Error>?
    private var waiter: CheckedContinuation<CleanReply, Error>?

    func give(_ outcome: Result<CleanReply, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func value() async throws -> CleanReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
