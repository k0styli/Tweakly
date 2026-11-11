import Foundation

/// A site in the browser's list. People download from it themselves, under its own terms, for their own desktop; the
/// app only shows the site and takes in what they download.
public struct WallpaperSite: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let address: URL
    public let offers: Set<Wallpaper.Kind>

    public init(id: String, name: String, address: URL, offers: Set<Wallpaper.Kind>) {
        self.id = id
        self.name = name
        self.address = address
        self.offers = offers
    }

    /// The two best-known live wallpaper sites, three stock libraries with plain
    /// licences, and one for pictures.
    public static let builtIn: [WallpaperSite] = [
        site("moewalls", "MoeWalls", "https://moewalls.com/", [.video]),
        site("motionbgs", "MotionBGs", "https://motionbgs.com/", [.video]),
        site("pexels", "Pexels", "https://www.pexels.com/videos/", [.video]),
        site("pixabay", "Pixabay", "https://pixabay.com/videos/", [.video]),
        site("mixkit", "Mixkit", "https://mixkit.co/free-stock-video/", [.video]),
        site("wallhaven", "Wallhaven", "https://wallhaven.cc/", [.picture]),
    ].compactMap { $0 }

    private static func site(_ id: String, _ name: String, _ address: String, _ offers: Set<Wallpaper.Kind>)
        -> WallpaperSite?
    {
        URL(string: address).map { WallpaperSite(id: id, name: name, address: $0, offers: offers) }
    }

    /// An address someone typed, as Safari reads it: `https://` is added when missing, and only web addresses open.
    public static func url(fromTyped text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = url.host, host.contains(".")
        else { return nil }
        return url
    }
}

/// What the browser does with a response and a download.
public enum DownloadRule {
    private static let videoTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v"]
    /// The pictures the media cleaner takes, as `SniffedMedia` knows them: a TIFF would download only to be refused.
    private static let pictureTypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif", "image/avif",
    ]

    /// Whether a response becomes a download rather than a page: whatever the browser cannot show, what the site
    /// sends as an attachment, and a video or picture opened on its own, which is what a full-size link leads to.
    public static func shouldDownload(
        isMainFrame: Bool, mimeType: String?, contentDisposition: String?, canShow: Bool
    ) -> Bool {
        if !canShow { return true }
        if contentDisposition?.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("attachment") == true {
            return true
        }
        guard isMainFrame, let type = mimeType?.lowercased() else { return false }
        return type.hasPrefix("video/") || type.hasPrefix("image/")
    }

    /// The kind of wallpaper a download is, or nil to refuse it. The file's own name decides when the type is
    /// generic, as many sites send `application/octet-stream`.
    public static func kind(mimeType: String?, fileName: String) -> Wallpaper.Kind? {
        let type = mimeType?.lowercased() ?? ""
        if videoTypes.contains(type) { return .video }
        if pictureTypes.contains(type) { return .picture }
        let ext = (fileName as NSString).pathExtension
        if type.isEmpty || type == "application/octet-stream" || type == "binary/octet-stream"
            || type == "application/force-download"
        {
            return ImportCheck.kind(ofExtension: ext)
        }
        // A type the app does not take, such as WebM, is refused even if the name says otherwise.
        if type.hasPrefix("video/") || type.hasPrefix("image/") { return nil }
        return ImportCheck.kind(ofExtension: ext)
    }

    /// A new window a page asks for opens in place when it stays on the same site, as a download button often does,
    /// or when it leads straight to a video or picture. Anything else is most likely an advertisement and is refused.
    public static func opensInPlace(_ target: URL, from page: URL?) -> Bool {
        if ImportCheck.kind(ofExtension: target.pathExtension) != nil { return true }
        guard let page, let targetDomain = registrableDomain(of: target), let pageDomain = registrableDomain(of: page)
        else { return false }
        return targetDomain == pageDomain
    }

    /// The trick ad scripts play on a click: the page opens itself in a new window, then sends this one to an
    /// advertisement. Seen on MoeWalls on 2026-11-08.
    public static func isPopUnder(_ target: URL, on page: URL?) -> Bool {
        guard let page else { return false }
        return withoutFragment(target) == withoutFragment(page)
    }

    /// After a pop-under, the page's own script sending it to another site is the advertisement, and is refused. A
    /// click on a link, a download and anything on the same site still go through.
    public static func blocksRedirect(
        to target: URL, from page: URL?, isMainFrame: Bool, isLinkClick: Bool, afterPopUnder: Bool
    ) -> Bool {
        guard afterPopUnder, isMainFrame, !isLinkClick, let page else { return false }
        return registrableDomain(of: target) != registrableDomain(of: page)
    }

    private static func withoutFragment(_ url: URL) -> String {
        url.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url.absoluteString
    }

    /// `cdn.moewalls.com` and `moewalls.com` are the same site; so are `a.b.co.uk` and `b.co.uk`.
    public static func registrableDomain(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        // An address in numbers has no site name to shorten to.
        if host.contains(":") || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        guard labels.count >= 2 else { return host }
        let shortSecondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or"]
        let count =
            labels.count >= 3 && labels[labels.count - 1].count == 2
                && shortSecondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }
}

/// How a download is named in the library.
public enum DownloadNaming {
    /// Phrases sites put in page titles that say nothing about the picture.
    private static let filler = [
        "live wallpaper", "free stock video", "stock video", "free video", "free download", "download",
        "wallpaper engine", "wallpapers", "wallpaper", "4k", "hd",
    ]

    /// The site a page or file belongs to, as people say it: `moewalls.com` for `go.moewalls.com` as well, so that
    /// a site's downloads from its other servers count as the site's own.
    public static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return DownloadRule.registrableDomain(of: url)
    }

    /// The page's title without the site's name and filler, or else the file's name made readable.
    public static func title(pageTitle: String?, fileName: String, site: String?) -> String {
        let siteWord = site.flatMap { $0.split(separator: ".").first.map(String.init) }?.lowercased()
        if let fromPage = cleaned(pageTitle ?? "", siteWord: siteWord), !fromPage.isEmpty {
            return fromPage
        }
        let base = (fileName as NSString).deletingPathExtension
        let words = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
            .filter { word in
                let lower = word.lowercased()
                if lower == siteWord || lower == "com" || lower == "www" { return false }
                // Sizes and frame rates, such as 3840, 2160p, 1080p, 24fps or uhd.
                if lower.allSatisfy(\.isNumber) { return false }
                if ["uhd", "fhd", "hd", "4k", "8k"].contains(lower) { return false }
                if lower.hasSuffix("p") || lower.hasSuffix("fps"), lower.first?.isNumber == true { return false }
                return true
            }
        let joined = words.joined(separator: " ")
        guard let first = joined.first else { return ImportCheck.title(fromFileName: fileName) }
        return first.uppercased() + joined.dropFirst()
    }

    private static func cleaned(_ title: String, siteWord: String?) -> String? {
        let separators = [" - ", " | ", " – ", " — ", " · ", " :: "]
        var parts = [title]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let kept = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { part in
            let lower = part.lowercased()
            guard !lower.isEmpty else { return false }
            // The site's own name, written as one word in any case, as in "MoeWalls" or "Pixabay.com".
            if let siteWord, siteWord.count >= 3, lower.filter(\.isLetter).contains(siteWord) { return false }
            return !filler.contains(lower)
        }
        guard var best = kept.first else { return nil }
        for phrase in filler {
            if best.lowercased().hasSuffix(" " + phrase) {
                best = String(best.dropLast(phrase.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return best
    }
}

/// The system's desktop picture of each display from before the tweak changed it, to give back when it goes off.
///
/// Only a plain picture can be given back: the system reports an Aerial or a shuffle as its default picture, so after
/// one of those the page asks the person to choose it again.
public struct DesktopPictureMemory: Codable, Equatable, Sendable {
    public struct Original: Codable, Equatable, Sendable {
        public var path: String
        /// The system's options for it, such as the fill and the colour behind, as property list values.
        public var options: [String: Double]

        public init(path: String, options: [String: Double] = [:]) {
            self.path = path
            self.options = options
        }
    }

    public var originals: [String: Original]

    public init(originals: [String: Original] = [:]) {
        self.originals = originals
    }

    /// Notes what a display shows before the first change. A picture the tweak itself put there is never taken for
    /// the original, as it would be after a crash or a second process.
    public mutating func remember(display: String, current: Original?, isOurs: Bool) {
        guard originals[display] == nil, let current, !isOurs else { return }
        originals[display] = current
    }

    /// What to put back on a display, and forgets it. Nothing if the person chose another picture in the meantime.
    public mutating func takeBack(display: String, currentIsOurs: Bool) -> Original? {
        guard let original = originals.removeValue(forKey: display) else { return nil }
        return currentIsOurs ? original : nil
    }

    /// The system's own default picture, which also stands for an Aerial, a shuffle or anything else that is not a
    /// file.
    public static func isSystemDefault(_ path: String) -> Bool {
        path.hasSuffix("/CoreServices/DefaultDesktop.heic")
    }
}
