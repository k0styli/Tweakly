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
            log.error("Library index unreadable: \(error.localizedDescription, privacy: .public)")
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
