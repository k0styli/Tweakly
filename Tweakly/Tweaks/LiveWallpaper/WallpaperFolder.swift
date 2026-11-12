import AppKit
import LiveWallpaperCore
import os

/// Where live wallpapers keep their files. Videos, their stills and pictures in Application Support, as they are
/// someone's choice and must outlive a cleanup of caches; thumbnails in Caches, as they can always be made again. Both in
/// folders named for the bundle, so that a test copy has a library of its own.
enum WallpaperFolder {
    static let indexName = "Library.json"
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    private nonisolated static var bundleFolderName: String { Bundle.main.bundleIdentifier ?? "Tweakly" }

    nonisolated static var files: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }

    nonisolated static var thumbnails: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }

    nonisolated static func file(named name: String) -> URL? {
        files?.appendingPathComponent(name, isDirectory: false)
    }

    /// Where the cleaner's files wait, out of its reach, until they are renamed into the library: on the same volume as
    /// the library, and away from its own folder so that nothing half taken is ever mistaken for a wallpaper.
    nonisolated static var incoming: URL? {
        files?.deletingLastPathComponent().appendingPathComponent("Incoming", isDirectory: true)
    }

    /// Downloads and conversions in progress, up to 4 GB each. Of this copy of the app alone, as the temporary folder is
    /// shared by every app of the person, a test copy's too.
    nonisolated static var work: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Wallpaper Work", isDirectory: true)
    }

    /// A new file in `work`, made by whoever writes it, with an extension no app opens unless one is given.
    nonisolated static func newWorkFile(extension ext: String = "download") -> URL {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// What a window that closed in the middle of a download, a conversion or an import left behind. Only the window's
    /// process writes there, and only one runs at a time, so nothing in them is still in use when a new one starts.
    nonisolated static func removeLeftovers() {
        let manager = FileManager.default
        for folder in [work, incoming].compactMap({ $0 }) {
            for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? manager.removeItem(at: item)
            }
        }
    }

    /// A new folder for one job's files.
    nonisolated static func newIncoming() throws -> URL {
        guard let incoming else { throw CocoaError(.fileNoSuchFile) }
        let folder = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Creates the folder when missing.
    static func ensureFiles() throws -> URL {
        guard let files else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        return files
    }

    nonisolated static func ensureThumbnails() throws -> URL {
        guard let thumbnails else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        return thumbnails
    }

    static func readIndex() -> LibraryIndex {
        guard let url = files?.appendingPathComponent(indexName),
            let data = try? Data(contentsOf: url)
        else { return LibraryIndex() }
        do {
            return try JSONDecoder().decode(LibraryIndex.self, from: data)
        } catch {
            // A damaged index must not lose the files, so they stay where they are, out of the library until added again.
            // The index itself is put aside, as the next change would write an empty one over it, and with it the only
            // record of which file is which wallpaper; an index from a newer version of the app survives the same way.
            log.error("Library index unreadable: \(error.localizedDescription, privacy: .public)")
            let aside = url.deletingLastPathComponent().appendingPathComponent(
                "Library unreadable \(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return LibraryIndex()
        }
    }

    static func write(_ index: LibraryIndex) throws {
        let folder = try ensureFiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: folder.appendingPathComponent(indexName), options: .atomic)
    }

    /// The displays wallpapers go on. A quiet test copy has only its own invisible display.
    static var screens: [NSScreen] {
        #if TWEAKLY_AUTOMATION
            if QuietScreen.isActive { return [QuietScreen.screen].compactMap { $0 } }
        #endif
        return NSScreen.screens
    }

    /// The display's own UUID, which the system keeps across restarts and reconnections.
    static func key(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen),
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// `kDisplayModeNativeFlag` from IOKit's `IOGraphicsTypes.h`.
    private static let nativeFlag: UInt32 = 0x0200_0000
    /// Each display's native mode as the panel lies, nil for one without, found once as a panel does not change. How
    /// it is turned, and what a display without one draws, can change, so those are worked out each time.
    private static var nativeModes: [CGDirectDisplayID: PixelSize?] = [:]

    /// The pixels of a display's own panel, which is as sharp as anything on it can be. A MacBook Air M2 draws its
    /// desktop at 2940×1912 and shrinks it to its 2560×1664 panel, so more than the panel is never seen. The mode the
    /// system marks native says it; a display without one, such as a virtual one, counts what it draws.
    static func panelSize(of screen: NSScreen) -> PixelSize {
        let drawn = PixelSize(
            width: Int(screen.frame.width * screen.backingScaleFactor),
            height: Int(screen.frame.height * screen.backingScaleFactor))
        guard let id = displayID(of: screen) else { return drawn }
        let native: PixelSize?
        if let known = nativeModes[id] {
            native = known
        } else {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            native = modes.filter { $0.ioFlags & nativeFlag != 0 }
                .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
                .map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) }
            nativeModes[id] = .some(native)
        }
        // A display turned on its side reports its modes as the panel lies, so they follow the desktop's shape.
        var size = native ?? drawn
        if (size.width > size.height) != (drawn.width > drawn.height) {
            size = PixelSize(width: size.height, height: size.width)
        }
        return size
    }
}
