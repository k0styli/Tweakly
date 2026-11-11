import AppKit
import UninstallerCore
import os

/// Moves an app and the files it left to the Trash, from where all of it can be put back until the Trash is emptied.
/// Nothing is deleted outright.
///
/// The app is asked to quit first. What only an administrator can touch, such as an App Store app or a system service,
/// goes behind one request for a password, before anything else moves: a person who cancels it keeps everything.
@MainActor enum AppRemover {
    private nonisolated static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "uninstaller")
    /// How long an app gets to save its work and quit, which Finder does not wait for at all.
    private static let quitTimeout: Duration = .seconds(10)

    struct Outcome {
        var moved: [Leftover] = []
        var failed: [Leftover] = []
        var wasCancelled = false
        /// Why nothing was done.
        var problem: String?
    }

    static func remove(_ items: [Leftover], of app: InstalledApp) async -> Outcome {
        if let problem = await quit(app) { return Outcome(problem: problem) }
        var outcome = Outcome()
        // The app itself goes first, and if it cannot, nothing else goes: its data gone with the app still there would
        // be a reset nobody asked for. Only an uninstall lists the app.
        let bundle = items.first { $0.place == nil }
        let appStays = String(localized: "“\(app.name)” could not be moved to the Trash, so nothing else was.")
        if let bundle, !bundle.needsAdministrator {
            let (moved, _) = await moveToTrash([(bundle, URL(fileURLWithPath: bundle.path))])
            guard !moved.isEmpty else { return Outcome(problem: appStays) }
            outcome.moved += moved
        }
        let rest = items.filter { $0.place != nil }
        let toTrash = rest.filter { !$0.needsAdministrator }.map { ($0, URL(fileURLWithPath: $0.path)) }
        var privileged = rest.filter(\.needsAdministrator)
        let appFirst = bundle?.needsAdministrator == true
        if appFirst, let bundle { privileged.insert(bundle, at: 0) }
        if !privileged.isEmpty {
            guard let trash = personsTrash() else {
                return Outcome(problem: String(localized: "macOS did not let Tweakly move the files."))
            }
            switch moveWithAdministratorRights(
                privileged, toTrash: trash, appName: app.name, appFirst: appFirst, isAppStore: app.isAppStore)
            {
            case .cancelled:
                return Outcome(wasCancelled: true)
            case .failed(let message):
                return Outcome(problem: message)
            case .moved(let moved, let failed):
                if appFirst, let bundle, failed.contains(bundle) { return Outcome(problem: appStays) }
                outcome.moved += moved
                outcome.failed += failed
            }
        }
        // The person's own agents stop before their plists go, or they would run on until the next login.
        for item in items where !item.needsAdministrator {
            if let job = item.job { await launchctl(job.arguments) }
        }
        let (moved, failed) = await moveToTrash(toTrash)
        outcome.moved += moved
        outcome.failed += failed
        return outcome
    }

    /// The person's Trash, made if it is missing, so that root never makes it and keeps it.
    private static func personsTrash() -> String? {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash").path
        var info = stat()
        if lstat(trash, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? trash : nil }
        do {
            try FileManager.default.createDirectory(
                atPath: trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return trash
        } catch {
            log.error("No Trash to move into: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Steps

    /// The app and every app running from inside its bundle, as its login items and helpers.
    static func running(_ app: InstalledApp) -> [NSRunningApplication] {
        let inside = app.identity.path + "/"
        return NSWorkspace.shared.runningApplications.filter { process in
            guard let path = process.bundleURL?.path else { return false }
            return path == app.identity.path || path.hasPrefix(inside)
        }
    }

    /// Nil once every process of the app has quit, or why not.
    private static func quit(_ app: InstalledApp) async -> String? {
        let running = running(app)
        guard !running.isEmpty else { return nil }
        for process in running { process.terminate() }
        let deadline = ContinuousClock.now + quitTimeout
        while running.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard running.allSatisfy(\.isTerminated) else {
            return String(localized: "“\(app.name)” did not quit. Save your work in it, quit it and try again.")
        }
        return nil
    }

    private enum PrivilegedResult {
        case moved(moved: [Leftover], failed: [Leftover])
        case cancelled
        case failed(String)
    }

    /// One request for a password for everything that needs it. The script stops the system's jobs and moves each item
    /// straight into the person's Trash: a root-owned App Store app cannot be handed over first, as App Management
    /// guards what is inside it even from root, and Finder's way to the Trash refuses what is not the person's.
    private static func moveWithAdministratorRights(
        _ items: [Leftover], toTrash trash: String, appName: String, appFirst: Bool, isAppStore: Bool
    ) -> PrivilegedResult {
        let paths = items.map(\.path)
        let script = AdministratorScript.removal(
            moving: paths, toTrash: trash, stopping: items.compactMap(\.job), owner: getuid(), group: getgid(),
            firstMustMove: appFirst, keepingOwner: appFirst && isAppStore ? [0] : [])
        let prompt = String(localized: "Tweakly is moving “\(appName)” and its system files to the Trash.")
        let output: String
        switch AdministratorPrompt.run(script, prompt: prompt) {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            log.error("The administrator's part failed: \(message ?? "no reason", privacy: .public)")
            return .failed(message ?? String(localized: "macOS did not let Tweakly move the files."))
        case .done(let printed):
            output = printed
        }
        let places = AdministratorScript.movedItems(in: output)
        log.notice(
            "The administrator's part moved \(places.count, privacy: .public) of \(items.count, privacy: .public)")
        // What is no longer in place has gone, whether the script moved it or it went by itself meanwhile, as a cache
        // an app clears as it quits: otherwise it would be listed as left behind, and every new try would fail too.
        var moved: [Leftover] = []
        var failed: [Leftover] = []
        for item in items {
            var info = stat()
            if lstat(item.path, &info) != 0 {
                moved.append(item)
            } else {
                failed.append(item)
            }
        }
        return .moved(moved: moved, failed: failed)
    }

    /// As Finder does it, so each item can be put back from the Trash.
    private static func moveToTrash(_ items: [(Leftover, URL)]) async -> (moved: [Leftover], failed: [Leftover]) {
        guard !items.isEmpty else { return ([], []) }
        do {
            _ = try await NSWorkspace.shared.recycle(items.map(\.1))
        } catch {
            log.error("Moving to the Trash failed in part: \(error.localizedDescription, privacy: .public)")
        }
        var moved: [Leftover] = []
        var failed: [Leftover] = []
        for (item, url) in items {
            if FileManager.default.fileExists(atPath: url.path) {
                // One more try on its own, which gets past a batch that stopped at another item.
                if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                    moved.append(item)
                } else {
                    failed.append(item)
                }
            } else {
                moved.append(item)
            }
        }
        return (moved, failed)
    }

    private static func launchctl(_ arguments: [String]) async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Self.log.error("launchctl did not run: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

}
