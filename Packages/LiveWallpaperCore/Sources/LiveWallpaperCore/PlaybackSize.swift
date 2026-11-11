import Foundation

/// How large wallpapers are shown: no larger than the display, by default, or no
/// larger than a preset. What a video costs is mostly the system's decoder, which holds about twenty decoded frames, so
/// it follows the frame size. Measured with a 4K 30 fps wallpaper on a MacBook Air M2: the decoder held 199 MB
/// at 3840×2160, 104 MB at the panel's 2958×1664 and 48 MB at 1920×1080, at 3.5, 3.0 and 2.6 % CPU. A picture costs
/// the system's wallpaper service less: 141 MB for an 8K one against 127 MB for one the size of the panel.
public enum PlaybackSize: String, Codable, CaseIterable, Sendable {
    /// No larger than each display's own panel. The default.
    case display
    case fullHD = "1080p"
    case quadHD = "1440p"
    case ultraHD = "2160p"
    /// Every file as it came.
    case original

    /// The short side a preset holds a wallpaper to.
    public var shortSide: Int? {
        switch self {
        case .fullHD: 1080
        case .quadHD: 1440
        case .ultraHD: 2160
        case .display, .original: nil
        }
    }
}

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixels: Int { width * height }
}

public enum WallpaperSizing {
    /// A smaller copy is made only when it leaves out at least this share of the pixels: below that the decoder saves
    /// too little to be worth encoding the video again.
    public static let smallestSaving = 0.15

    /// The size a wallpaper of `source` pixels is shown at on a display whose panel has `panel` pixels, or nil to show
    /// the file as it is. On a display it covers the panel, as Fill shows it, so Fit and Stretch need no more. It never
    /// grows, and it keeps its shape.
    public static func size(of source: PixelSize, setting: PlaybackSize, panel: PixelSize?) -> PixelSize? {
        guard source.width > 0, source.height > 0 else { return nil }
        let scale: Double
        if let shortSide = setting.shortSide {
            scale = Double(shortSide) / Double(min(source.width, source.height))
        } else if setting == .display, let panel, panel.width > 0, panel.height > 0 {
            scale = max(Double(panel.width) / Double(source.width), Double(panel.height) / Double(source.height))
        } else {
            return nil
        }
        guard scale < 1 else { return nil }
        let size = PixelSize(width: even(Double(source.width) * scale), height: even(Double(source.height) * scale))
        return Double(size.pixels) <= Double(source.pixels) * (1 - smallestSaving) ? size : nil
    }

    /// Rounded to an even number, as the encoder needs, and never past what the source has.
    static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }
}

/// The smaller copies of a wallpaper, with fewer frames too while economy mode is on, next to the file itself.
public enum WallpaperVariant {
    /// The copy's name, such as `video-2958x1664-economy.mp4`; the file's own name when it is neither smaller nor
    /// slower. A copy with fewer frames alone is named as `EconomyMode` has always named it.
    public static func name(for fileName: String, size: PixelSize?, economy: Bool) -> String {
        guard size != nil || economy else { return fileName }
        let name = fileName as NSString
        var stem = name.deletingPathExtension
        if let size { stem += "-\(size.width)x\(size.height)" }
        if economy { stem += "-economy" }
        return name.pathExtension.isEmpty ? stem : stem + "." + name.pathExtension
    }

    /// What a display plays: the closest copy that exists, the smaller one first, as it saves the most, and the file
    /// itself when none is made yet.
    public static func fileToPlay(
        _ fileName: String, size: PixelSize?, economy: Bool, exists: (String) -> Bool
    ) -> String {
        var candidates: [String] = []
        if let size {
            if economy { candidates.append(name(for: fileName, size: size, economy: true)) }
            candidates.append(name(for: fileName, size: size, economy: false))
        }
        if economy { candidates.append(name(for: fileName, size: nil, economy: true)) }
        return candidates.first(where: exists) ?? fileName
    }

    /// The copies a wallpaper needs, one for each size its displays ask for. Economy mode decides for each video
    /// itself whether it has frames to leave out, so it is only asked for here.
    public static func needed(
        source: PixelSize, kind: Wallpaper.Kind, setting: PlaybackSize, panels: [PixelSize], economy: Bool
    ) -> [Request] {
        var requests: [Request] = []
        for panel in panels {
            let size = WallpaperSizing.size(of: source, setting: setting, panel: panel)
            let request = Request(size: size, economy: kind == .video && economy)
            guard request.size != nil || request.economy, !requests.contains(request) else { continue }
            requests.append(request)
        }
        return requests
    }

    public struct Request: Hashable, Sendable {
        public var size: PixelSize?
        public var economy: Bool

        public init(size: PixelSize?, economy: Bool) {
            self.size = size
            self.economy = economy
        }
    }
}
