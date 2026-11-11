import Foundation

/// Economy mode: a video faster than 30 frames a second plays from a copy with
/// fewer frames. What a wallpaper costs is mostly the system's decoder, and that follows the frame rate, not the codec
/// or the way the video is shown.
///
/// The copy sits next to the video, which stays as it came, so turning the mode off brings back every frame at once.
/// Since 2026-11-09 it is made with the smaller copy for a display, as one file, and only for wallpapers on a display.
public enum EconomyMode {
    public static let highestFrameRate = 30.0
    /// The encoder's constant quality for the copy. Its frames could not be told from the video's as macOS draws them
    /// (PSNR 48–50 dB on a 4K wallpaper), and at 33 Mbit/s the decoder and the player held 175 and 18 MB, against 193 and
    /// 22 MB at 0.9 and 60 Mbit/s: they keep a few seconds of the compressed video ahead.
    public static let quality = 0.85

    /// The copy's frame rate, keeping every second, third or later frame so that the motion stays even, or nil when the
    /// video is slow enough already or could only lose frames unevenly.
    public static func frameRate(for source: Double) -> Double? {
        guard source > 0 else { return nil }
        let step = (source / highestFrameRate).rounded()
        guard step >= 2 else { return nil }
        return source / step
    }
}
