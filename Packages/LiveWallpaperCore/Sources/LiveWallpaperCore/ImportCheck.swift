import Foundation

/// What the system says about a video file, read before it is added.
public struct VideoFacts: Equatable, Sendable {
    public var hasVideo: Bool
    public var isPlayable: Bool
    /// Bought or rented films from the TV app, which cannot play outside it.
    public var isProtected: Bool
    /// The four letters of the codec, such as `avc1` or `hvc1`.
    public var codec: String
    /// Whether the Mac's media engine decodes it. Anything else would be decoded by the processor on every frame.
    public var isHardwareDecoded: Bool
    public var width: Int
    public var height: Int
    public var duration: TimeInterval

    public init(
        hasVideo: Bool, isPlayable: Bool, isProtected: Bool = false, codec: String, isHardwareDecoded: Bool,
        width: Int, height: Int, duration: TimeInterval
    ) {
        self.hasVideo = hasVideo
        self.isPlayable = isPlayable
        self.isProtected = isProtected
        self.codec = codec
        self.isHardwareDecoded = isHardwareDecoded
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// A codec's four letters as Core Media gives them in one number, `avc1` say, without the spaces that pad a shorter
    /// code.
    public static func codecName(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Why a file cannot be a wallpaper.
public enum ImportProblem: Codable, Equatable, Sendable, Error {
    /// Neither a video nor a picture the system reads.
    case unsupported
    case protected
    case unplayable
    /// A codec the media engine does not decode, which would keep the processor busy.
    case needsSoftwareDecoding(codec: String)
    case tooShort
    case tooLarge
    case tooSmall
    /// The cleaner could not finish with it, or stopped while reading it: a damaged file, or one made to attack a
    /// decoder. Either way it stays out.
    case couldNotCheck
}

public enum ImportCheck {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    /// What the file chooser offers. What a file is, though, is told from its bytes by `SniffedMedia`.
    public static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "avif"]
    /// Shorter than this, a loop would flicker.
    public static let shortestDuration: TimeInterval = 1
    /// Beyond 8K, no Mac screen gains anything, and the media engine may refuse it.
    public static let largestVideoSide = 8192
    /// A picture so small it would be a blur on any screen is most likely a thumbnail saved by mistake.
    public static let smallestPictureSide = 480

    public static func kind(ofExtension fileExtension: String) -> Wallpaper.Kind? {
        let ext = fileExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if pictureExtensions.contains(ext) { return .picture }
        return nil
    }

    public static func problem(with facts: VideoFacts) -> ImportProblem? {
        guard facts.hasVideo else { return .unsupported }
        guard !facts.isProtected else { return .protected }
        guard facts.isPlayable, facts.width > 0, facts.height > 0 else { return .unplayable }
        guard facts.isHardwareDecoded else { return .needsSoftwareDecoding(codec: facts.codec) }
        guard facts.duration >= shortestDuration else { return .tooShort }
        guard max(facts.width, facts.height) <= largestVideoSide else { return .tooLarge }
        return nil
    }

    /// For a picture the system could read, of this size. Checked before it is decoded, so a small file that claims to
    /// be enormous cannot take all the memory.
    public static func problem(withPictureWidth width: Int, height: Int) -> ImportProblem? {
        guard width > 0, height > 0 else { return .unsupported }
        guard max(width, height) <= largestVideoSide else { return .tooLarge }
        guard max(width, height) >= smallestPictureSide else { return .tooSmall }
        return nil
    }

    /// A title from the file's name, as Finder would show it.
    public static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let spaced = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return spaced.isEmpty ? name : spaced
    }
}
