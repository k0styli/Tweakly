import Foundation

/// One wallpaper in the library: a video that plays on the desktop, or a picture that becomes the desktop picture.
/// Either was downloaded in the app's browser or added from a file.
public struct Wallpaper: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case video, picture
    }

    public enum Origin: String, Codable, CaseIterable, Hashable, Sendable {
        /// Downloaded in the app's browser.
        case downloaded
        /// A file someone added, copied into the app's folder.
        case imported
    }

    /// A fresh UUID with the origin in front, stable across launches.
    public let id: String
    public var kind: Kind
    public var origin: Origin
    public var title: String
    /// The site it came from, such as `moewalls.com`, for search and for the site filter.
    public var site: String?
    /// The page it was downloaded from, to go back to it.
    public var pageURL: URL?
    /// In pixels, as it shows: a video turned by its own transform counts as turned.
    public var width: Int
    public var height: Int
    /// Zero for a picture.
    public var duration: TimeInterval

    public init(
        id: String, kind: Kind, origin: Origin, title: String, site: String? = nil, pageURL: URL? = nil, width: Int,
        height: Int, duration: TimeInterval = 0
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.title = title
        self.site = site
        self.pageURL = pageURL
        self.width = width
        self.height = height
        self.duration = duration
    }

    public var aspect: AspectRatio { AspectRatio(width: width, height: height) }
    public var resolution: Resolution { Resolution(width: width, height: height) }
}

/// The shape of a picture, as the filters name it.
public enum AspectRatio: String, Codable, CaseIterable, Hashable, Sendable {
    /// 16:9, 16:10 and 4:3: the usual screen.
    case standard
    /// 21:9.
    case wide
    /// 32:9.
    case superWide
    case portrait
    case square

    public init(width: Int, height: Int) {
        guard width > 0, height > 0 else {
            self = .standard
            return
        }
        let ratio = Double(width) / Double(height)
        switch ratio {
        case ..<0.9: self = .portrait
        case ..<1.2: self = .square
        case ..<2.0: self = .standard
        case ..<2.9: self = .wide
        default: self = .superWide
        }
    }
}

/// How sharp a wallpaper is, by its number of pixels, so that ultrawide sizes count with the screens of the same
/// height.
public enum Resolution: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case low = 0
    case hd = 720
    case fullHD = 1080
    case quadHD = 1440
    case ultraHD = 2160

    public init(width: Int, height: Int) {
        let pixels = Double(width) * Double(height)
        // A little below each size still counts as it, as videos are often cropped by a few pixels.
        let tolerance = 0.9
        switch pixels {
        case (3840.0 * 2160 * tolerance)...: self = .ultraHD
        case (2560.0 * 1440 * tolerance)...: self = .quadHD
        case (1920.0 * 1080 * tolerance)...: self = .fullHD
        case (1280.0 * 720 * tolerance)...: self = .hd
        default: self = .low
        }
    }

    public static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.rawValue < rhs.rawValue }
}
