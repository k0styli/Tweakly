import Foundation

/// What a file is, told from its first bytes rather than from its name, before anything parses it.
///
/// Only formats that wallpapers come in are recognised, and only these reach a decoder. A PDF named `.gif`, as in the
/// FORCEDENTRY attack, an app, a script, an archive or a page saved as `.mp4` is refused unread. TIFF, BMP, PSD, PDF
/// and SVG are left out: wallpapers hardly come in them, and their decoders have had the most flaws.
public struct SniffedMedia: Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        case jpeg, png, gif, webp, heif, avif
        /// An MPEG-4 file, such as `.mp4` or `.m4v`.
        case mpeg4
        /// A QuickTime movie, such as `.mov`.
        case quickTime
    }

    public var kind: Wallpaper.Kind
    public var format: Format

    /// The extension the cleaner gives the file, so that the system opens it with the right reader.
    public var fileExtension: String {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        case .gif: "gif"
        case .webp: "webp"
        case .heif: "heic"
        case .avif: "avif"
        case .mpeg4: "mp4"
        case .quickTime: "mov"
        }
    }

    /// The types ImageIO may report for a picture of this format, so that the bytes and the reader agree.
    public var imageTypes: Set<String> {
        switch format {
        case .jpeg: ["public.jpeg"]
        case .png: ["public.png"]
        case .gif: ["com.compuserve.gif"]
        case .webp: ["org.webmproject.webp"]
        case .heif: ["public.heic", "public.heif"]
        case .avif: ["public.avif"]
        case .mpeg4, .quickTime: []
        }
    }

    /// Codecs a cleaned video may carry: what every Apple silicon Mac decodes in its media engine.
    public static let videoCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1"]

    /// How many bytes `sniff` needs to see.
    public static let headerLength = 16

    /// Nil for anything that is not a picture or video in one of the formats above.
    public static func sniff(_ header: [UInt8]) -> SniffedMedia? {
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            header.count >= offset + bytes.count && Array(header[offset..<offset + bytes.count]) == bytes
        }
        func text(_ string: String, at offset: Int) -> Bool { starts(Array(string.utf8), at: offset) }

        if starts([0xFF, 0xD8, 0xFF]) { return SniffedMedia(kind: .picture, format: .jpeg) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return SniffedMedia(kind: .picture, format: .png)
        }
        if text("GIF87a", at: 0) || text("GIF89a", at: 0) { return SniffedMedia(kind: .picture, format: .gif) }
        if text("RIFF", at: 0), text("WEBP", at: 8) { return SniffedMedia(kind: .picture, format: .webp) }
        // ISO base media files, which HEIF and AVIF pictures share with MPEG-4 and QuickTime videos: the major brand
        // tells them apart.
        if text("ftyp", at: 4), header.count >= 12 {
            let brand = String(decoding: header[8..<12], as: UTF8.self)
            if heifBrands.contains(brand) { return SniffedMedia(kind: .picture, format: .heif) }
            if avifBrands.contains(brand) { return SniffedMedia(kind: .picture, format: .avif) }
            return SniffedMedia(kind: .video, format: brand == "qt  " ? .quickTime : .mpeg4)
        }
        // Older QuickTime movies begin with an atom other than `ftyp`.
        for atom in ["moov", "mdat", "wide", "free", "skip", "pnot"] where text(atom, at: 4) {
            return SniffedMedia(kind: .video, format: .quickTime)
        }
        return nil
    }

    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
    private static let avifBrands: Set<String> = ["avif", "avis"]
}

/// The folder files from outside pass through on their way into the library. The cleaner's sandbox may read and write
/// here and nowhere else, see `TweaklyMediaCleaner`.
public enum MediaInbox {
    /// Below the home folder. The same path is in the cleaner's entitlements, which cannot name a variable.
    public static let homeRelativePath = "Library/Caches/Tweakly Media Inbox"
    /// Nothing larger is read: a wallpaper is a few hundred megabytes at most, and more would only fill the disk.
    public static let largestFile: Int64 = 4 << 30

    /// Whether a job folder is one folder directly inside the inbox, with nothing in its path that could lead out.
    public static func isJobFolder(_ path: String, inbox: String) -> Bool {
        let root = (inbox as NSString).standardizingPath
        let folder = (path as NSString).standardizingPath
        guard (folder as NSString).deletingLastPathComponent == root else { return false }
        return isPlainName((folder as NSString).lastPathComponent)
    }

    /// A file name with no way into another folder.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && !name.hasPrefix(".")
    }
}

/// What the app asks the cleaner: clean `input` in `folder`, writing the results next to it.
public struct CleanRequest: Codable, Equatable, Sendable {
    public var folder: String
    public var input: String
    public var thumbnailWidth: Int
    /// No Mac screen needs a still sharper than this, and a 5K or 8K one would only take memory while it shows.
    public var stillLongestSide: Int

    public init(folder: String, input: String, thumbnailWidth: Int = 640, stillLongestSide: Int = 3840) {
        self.folder = folder
        self.input = input
        self.thumbnailWidth = thumbnailWidth
        self.stillLongestSide = stillLongestSide
    }
}

/// The files the cleaner wrote, all in the job's folder, and what they hold.
public struct CleanedMedia: Codable, Equatable, Sendable {
    public var kind: Wallpaper.Kind
    /// The video with its container written anew, or the picture decoded and written anew as PNG.
    public var fileName: String
    /// For a video, its first frame as JPEG.
    public var stillName: String?
    public var thumbnailName: String
    public var width: Int
    public var height: Int
    public var duration: TimeInterval

    public init(
        kind: Wallpaper.Kind, fileName: String, stillName: String?, thumbnailName: String, width: Int, height: Int,
        duration: TimeInterval = 0
    ) {
        self.kind = kind
        self.fileName = fileName
        self.stillName = stillName
        self.thumbnailName = thumbnailName
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// Whether every name stays inside the job's folder, which the app checks before it moves anything.
    public var namesArePlain: Bool {
        [fileName, thumbnailName].allSatisfy(MediaInbox.isPlainName)
            && (stillName.map(MediaInbox.isPlainName) ?? true)
    }
}

public enum CleanReply: Codable, Equatable, Sendable {
    case cleaned(CleanedMedia)
    case refused(ImportProblem)
}

/// The cleaner's interface over XPC. Requests and replies travel as JSON, so that nothing but plain data crosses.
@objc public protocol MediaCleaning {
    func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}
