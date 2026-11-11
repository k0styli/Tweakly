import AppKit
import LiveWallpaperCore
import os

/// Puts the system's own wallpaper choices back exactly, an Aerial and every Space included, through WallpaperAgent's
/// store. Before Tweakly first changes a desktop picture, the store is copied; when the tweak goes off, each desktop
/// entry that shows one of Tweakly's pictures gets back what the copy held, and WallpaperAgent is restarted to read it.
/// The store is undocumented, so anything unexpected leaves it alone and the public way is used instead. See
/// `WallpaperStore`.
enum SystemWallpaperStore {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")
    private static let agentIdentifier = "com.apple.wallpaper.agent"

    private static var store: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Next to the library rather than in it, so that clearing out stray files never takes it.
    private static var snapshot: URL? {
        WallpaperFolder.files?.deletingLastPathComponent().appendingPathComponent("System Wallpaper Store.plist")
    }

    /// The store as it was before the last restore, in case one ever needs undoing by hand.
    private static var lastReplaced: URL? {
        WallpaperFolder.files?.deletingLastPathComponent().appendingPathComponent(
            "System Wallpaper Store Before Restore.plist")
    }

    /// A test copy shares the person's store, so it never copies or writes it.
    private static var isAllowed: Bool {
        #if TWEAKLY_AUTOMATION
            false
        #else
            true
        #endif
    }

    static var hasSnapshot: Bool {
        guard let snapshot else { return false }
        return FileManager.default.fileExists(atPath: snapshot.path)
    }

    /// Copies the store once, before the first picture of ours goes in.
    static func takeSnapshotIfNeeded() {
        guard isAllowed, !hasSnapshot, let snapshot, let data = try? Data(contentsOf: store),
            read(data) != nil
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: snapshot, options: .atomic)
        } catch {
            log.error("Could not copy the wallpaper store: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether the store holds the person's own choices again. False leaves the public way to do what it can.
    static func restore() -> Bool {
        guard isAllowed, let snapshot, let before = try? Data(contentsOf: snapshot) else { return false }
        guard let saved = read(before) else {
            log.error("The copy of the wallpaper store could not be read")
            forget()
            return false
        }
        guard let data = try? Data(contentsOf: store), let current = read(data) else {
            // The public way puts back what it can. A copy kept for later would bring back an older choice once the
            // person had picked a new one and turned the tweak on again.
            log.error("The wallpaper store could not be read")
            forget()
            return false
        }
        switch WallpaperStore.restored(current.store, from: saved.store, isOurs: isOurs) {
        case .unknownShape:
            log.error("The wallpaper store has an unknown shape, so it was left alone")
            forget()
            return false
        case .unchanged:
            // None of the store's choices is ours, which may also mean a new macOS keeps them elsewhere: the public
            // way still puts back a display that shows our picture, and does nothing to any other.
            forget()
            return false
        case .changed(let restored):
            do {
                let output = try PropertyListSerialization.data(
                    fromPropertyList: restored, format: current.format, options: 0)
                if let lastReplaced { try? data.write(to: lastReplaced, options: .atomic) }
                try output.write(to: store, options: .atomic)
            } catch {
                log.error("Could not write the wallpaper store: \(error.localizedDescription, privacy: .public)")
                forget()
                return false
            }
            forget()
            restartAgent()
            return true
        }
    }

    /// A picture in the library of this or any other copy of Tweakly, test copies included.
    private static func isOurs(_ path: String) -> Bool {
        guard let library = WallpaperFolder.files?.standardizedFileURL else { return false }
        let support = library.deletingLastPathComponent().deletingLastPathComponent().path
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standard.hasPrefix(support + "/me.tweakly.Tweakly") else { return false }
        return standard.contains("/\(library.lastPathComponent)/")
    }

    private static func read(_ data: Data) -> (
        store: [String: Any], format: PropertyListSerialization.PropertyListFormat
    )? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let store = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
            WallpaperStore.locations(in: store) != nil
        else { return nil }
        return (store, format)
    }

    private static func forget() {
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    /// WallpaperAgent reads its store when it starts, and launchd starts it again at once, as it is kept alive.
    private static func restartAgent() {
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: agentIdentifier)
        guard !agents.isEmpty else { return }
        for agent in agents { agent.forceTerminate() }
        log.info("Restarted WallpaperAgent to read the restored store")
    }
}
