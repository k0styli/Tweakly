import Foundation

/// A video as the converter sees it: its codec, its size as shown and how fast it plays.
public struct VideoSource: Equatable, Sendable {
    /// The four letters of the codec, such as `avc1` or `hvc1`.
    public var codec: String
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double

    public init(codec: String, width: Int, height: Int, framesPerSecond: Double) {
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }

    public var isHEVC: Bool { codec == "hvc1" || codec == "hev1" }
    /// H.264 under either of its names, which the media engine decodes as it does HEVC.
    public var isH264: Bool { codec == "avc1" || codec == "avc3" }
}

/// What a video is converted to.
public struct ConversionPlan: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// The encoder's constant quality, from 0 to 1.
    public var quality: Double
    public var framesPerSecond: Double

    public init(width: Int, height: Int, quality: Double, framesPerSecond: Double) {
        self.width = width
        self.height = height
        self.quality = quality
        self.framesPerSecond = framesPerSecond
    }

    /// Whether the conversion makes the video lighter to play: a picture shrunk, frames dropped or a codec replaced.
    /// The encoder's even size takes a line off an odd one, and a file says 60.02 frames for 60: neither is lighter,
    /// and either would cost the video a lossy pass for nothing.
    public func makesPlayingLighter(for source: VideoSource) -> Bool {
        let sourcePixels = WallpaperSizing.even(Double(source.width)) * WallpaperSizing.even(Double(source.height))
        return width * height < sourcePixels
            || framesPerSecond < source.framesPerSecond - Self.frameRateSlack
            || (!source.isHEVC && !source.isH264)
    }

    /// How far a frame rate the file states may stray from a whole rate before dropping to it means anything.
    static let frameRateSlack = 0.5
}

/// Decides which videos are converted, once, to play more lightly, and to what: HEVC with no sound track, at the
/// encoder's constant quality, no larger than 4K or the biggest display needs, and at most 60 frames a second.
///
/// What a video costs to play is set by its frame size and frame rate, not its codec. Measured on 2026-11-08 on a
/// MacBook Air M2, counting the system's decoder service as well as the process that plays: a 4K 60 fps wallpaper held
/// 268 MB in the decoder at 5.3 % CPU as H.264 and 274–283 MB at 5.0–5.4 % as HEVC at any quality, and a 1080p 30 fps
/// one 52 MB at 2.4 % either way. Re-encoding an H.264 or HEVC video of the same size and rate therefore only saves
/// disk space and always loses a little of the picture: the first version did it to
/// save space, at 3 Mbit/s for 1080p, and each loop began visibly soft (VMAF 80 on the first frames). So such a video
/// stays as it came, and only a conversion that makes playing lighter is done.
///
/// When one is done it uses constant quality 0.9: on the 1080p wallpaper VMAF 94 and never below 92, on the 4K one 97,
/// where a bit rate left the first frames of each loop soft. Here a video up to 4K keeps its size, and only a larger one
/// is shrunk; making it no larger than a display is `PlaybackSize`'s job, with a copy for each display.
public enum VideoOptimization {
    /// The encoder's constant quality, measured above.
    public static let quality = 0.9
    public static let highestFrameRate = 60.0
    /// When nothing is known about the displays.
    public static let standardDisplay = (width: 3840, height: 2160)

    /// What to convert to, or nil when the video stays as it is.
    /// - Parameter displays: the pixel sizes of the connected displays.
    public static func plan(for source: VideoSource, displays: [(width: Int, height: Int)]) -> ConversionPlan? {
        guard source.width > 0, source.height > 0, source.framesPerSecond > 0 else { return nil }
        let (width, height) = size(for: source, displays: displays.isEmpty ? [standardDisplay] : displays)
        let plan = ConversionPlan(
            width: width, height: height, quality: quality,
            framesPerSecond: min(source.framesPerSecond, highestFrameRate))
        return plan.makesPlayingLighter(for: source) ? plan : nil
    }

    /// The video's own size up to 4K. A larger one is shrunk to what fills the biggest display, but not below 4K.
    static func size(for source: VideoSource, displays: [(width: Int, height: Int)]) -> (Int, Int) {
        let pixels = Double(source.width * source.height)
        let fourK = 3840.0 * 2160.0
        guard pixels > fourK * 1.05 else { return (even(Double(source.width)), even(Double(source.height))) }
        let shape = Double(source.width) / Double(source.height)
        var needed = fourK
        for display in displays where display.width > 0 && display.height > 0 {
            let width =
                shape >= Double(display.width) / Double(display.height)
                ? Double(display.height) * shape : Double(display.width)
            needed = max(needed, width * width / shape)
        }
        let factor = min(1, (needed / pixels).squareRoot())
        return (even(Double(source.width) * factor), even(Double(source.height) * factor))
    }

    private static func even(_ value: Double) -> Int { WallpaperSizing.even(value) }
}
