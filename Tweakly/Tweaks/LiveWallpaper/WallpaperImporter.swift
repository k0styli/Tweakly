import AVFoundation
import AppKit
import ImageIO
import LiveWallpaperCore
import UniformTypeIdentifiers
import VideoToolbox
import os

/// Adds a wallpaper to the library. Tweakly never parses a file from outside itself: the sandboxed cleaner checks it
/// and writes it anew (`MediaCleanerClient`), and only the cleaner's files are moved here, under the wallpaper's own
/// names. Used for files someone adds and for finished downloads alike.
enum WallpaperImporter {
    struct Failure: Error {
        let problem: ImportProblem
    }

    /// Where a file came from, for its entry.
    struct Source {
        var origin: Wallpaper.Origin
        var title: String
        var site: String?
        var pageURL: URL?
    }

    /// As wide as a tile in the grid at twice its size.
    nonisolated static let thumbnailWidth = 640

    /// Someone's file, cloned into the inbox: on the same APFS volume the copy takes no space of its own.
    static func importFile(at source: URL) async throws -> LibraryIndex.Entry {
        // The file itself, never a link to somewhere else, nor a folder or an app named like a video.
        let file = source.resolvingSymlinksInPath()
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw Failure(problem: .unsupported)
        }
        let origin = Source(
            origin: .imported, title: ImportCheck.title(fromFileName: source.lastPathComponent), site: nil,
            pageURL: nil)
        return try place(try await MediaCleanerClient.clean(file, moving: false), from: origin)
    }

    /// A finished download, moved out of the browser's folder. What it is comes from its bytes, not from the site.
    static func addDownload(at file: URL, from source: Source) async throws -> LibraryIndex.Entry {
        try place(try await MediaCleanerClient.clean(file, moving: true), from: source)
    }

    /// Moves what the cleaner wrote into the library under the wallpaper's own names.
    private static func place(_ job: MediaCleanerClient.Job, from source: Source) throws -> LibraryIndex.Entry {
        defer { job.discard() }
        let media = job.media
        let id = "\(source.origin.rawValue)-\(UUID().uuidString)"
        let folder = try WallpaperFolder.ensureFiles()
        let fileName = LibraryIndex.fileName(for: id, extension: (media.fileName as NSString).pathExtension)
        let stillName = media.stillName.map { _ in LibraryIndex.fileName(for: id + "-still", extension: "jpg") }
        let target = folder.appendingPathComponent(fileName)
        try move(job.file(media.fileName), to: target)
        if let still = media.stillName, let stillName {
            do {
                try move(job.file(still), to: folder.appendingPathComponent(stillName))
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
        placeThumbnail(job.file(media.thumbnailName), for: id)
        let wallpaper = Wallpaper(
            id: id, kind: media.kind, origin: source.origin, title: source.title, site: source.site,
            pageURL: source.pageURL, width: media.width, height: media.height, duration: media.duration)
        var entry = LibraryIndex.Entry(
            wallpaper: wallpaper, fileName: fileName, stillName: stillName,
            byteCount: [fileName, stillName].compactMap { $0 }.reduce(0) {
                $0 + byteCount(of: folder.appendingPathComponent($1))
            }, added: .now)
        entry.cleaned = true
        return entry
    }

    /// A wallpaper from before the cleaner goes through it once. Its new files take the old ones' places, a picture's
    /// under a new name as it becomes PNG. The old file, if its name changed, is left for the caller to remove once
    /// nothing points to it.
    static func reclean(_ entry: LibraryIndex.Entry) async throws -> (fileName: String, stillName: String?) {
        guard let file = WallpaperFolder.file(named: entry.fileName) else { throw CocoaError(.fileNoSuchFile) }
        let job = try await MediaCleanerClient.clean(file, moving: false)
        defer { job.discard() }
        let media = job.media
        let id = entry.wallpaper.id
        let folder = try WallpaperFolder.ensureFiles()
        let fileName = LibraryIndex.fileName(for: id, extension: (media.fileName as NSString).pathExtension)
        try replace(folder.appendingPathComponent(fileName), with: job.file(media.fileName))
        var stillName: String?
        if let still = media.stillName {
            let name = entry.stillName ?? LibraryIndex.fileName(for: id + "-still", extension: "jpg")
            try replace(folder.appendingPathComponent(name), with: job.file(still))
            stillName = name
        }
        placeThumbnail(job.file(media.thumbnailName), for: id)
        return (fileName, stillName)
    }

    /// Ordinary permissions whatever the file had: read and write for its owner, never run.
    private static func move(_ file: URL, to target: URL) throws {
        try FileManager.default.moveItem(at: file, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    }

    /// A display playing the old file goes on with it until its player starts again.
    private static func replace(_ target: URL, with file: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: file)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        } else {
            try move(file, to: target)
        }
    }

    private static func placeThumbnail(_ file: URL, for id: String) {
        guard (try? WallpaperFolder.ensureThumbnails()) != nil, let url = thumbnailURL(for: id) else { return }
        try? replace(url, with: file)
    }

    static func byteCount(of url: URL?) -> Int64 {
        Int64((try? url?.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    /// The thumbnail of a wallpaper on this Mac. Made again from the file if the caches were emptied.
    nonisolated static func thumbnailURL(for id: String) -> URL? {
        WallpaperFolder.thumbnails?.appendingPathComponent(LibraryIndex.fileName(for: id, extension: "jpg"))
    }

    /// Makes a missing thumbnail again, from the still of a video or from the picture itself. Off the main thread: after
    /// the caches were emptied, every tile of the page asks for one, each from a picture up to 8K.
    nonisolated static func remakeThumbnail(for entry: LibraryIndex.Entry) -> URL? {
        guard let url = thumbnailURL(for: entry.wallpaper.id) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Only from what the cleaner wrote: a file from before it is read by the cleaner first.
        guard !entry.needsCleaning else { return nil }
        guard let name = entry.desktopPictureName, let file = WallpaperFolder.file(named: name),
            let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let image = downsampled(source, longestSide: thumbnailWidth)
        else { return nil }
        writeThumbnail(image, for: entry.wallpaper.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decodes no more pixels than asked for, turned the way the picture says.
    private nonisolated static func downsampled(_ source: CGImageSource, longestSide: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: longestSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
    }

    /// The picture is no larger than a thumbnail already, see `downsampled`.
    private nonisolated static func writeThumbnail(_ image: CGImage, for id: String) {
        guard (try? WallpaperFolder.ensureThumbnails()) != nil, let url = thumbnailURL(for: id) else { return }
        try? writeJPEG(image, quality: 0.8, to: url)
    }

    /// For a video Tweakly wrote itself, such as a conversion's result. A file from outside goes to the cleaner.
    static func facts(of url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return VideoFacts(
                hasVideo: false, isPlayable: playable, isProtected: protected, codec: "", isHardwareDecoded: false,
                width: 0, height: 0, duration: duration.seconds)
        }
        let (size, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let codecType = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let turned = CGRect(origin: .zero, size: size).applying(transform)
        return VideoFacts(
            hasVideo: true, isPlayable: playable, isProtected: protected, codec: VideoFacts.codecName(codecType),
            isHardwareDecoded: VTIsHardwareDecodeSupported(codecType), width: Int(abs(turned.width).rounded()),
            height: Int(abs(turned.height).rounded()), duration: duration.seconds)
    }

    private nonisolated static func writeJPEG(_ image: CGImage, quality: Double, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
