import Foundation

/// Which part of the library to look at.
public enum WallpaperCollection: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case favourites
    /// Downloaded in the app's browser.
    case downloaded
    /// Files someone added.
    case imported
}

/// What the library shows: a search, a part of the library, and limits on kind, site, shape and sharpness.
public struct WallpaperFilter: Equatable, Sendable {
    public var query: String
    public var collection: WallpaperCollection
    /// Nil shows videos and pictures.
    public var kind: Wallpaper.Kind?
    /// Nil shows every site.
    public var site: String?
    /// Empty allows every shape.
    public var aspects: Set<AspectRatio>
    public var minimumResolution: Resolution

    public init(
        query: String = "", collection: WallpaperCollection = .all, kind: Wallpaper.Kind? = nil, site: String? = nil,
        aspects: Set<AspectRatio> = [], minimumResolution: Resolution = .low
    ) {
        self.query = query
        self.collection = collection
        self.kind = kind
        self.site = site
        self.aspects = aspects
        self.minimumResolution = minimumResolution
    }

    /// The words of the search, each of which has to be found somewhere.
    public var words: [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    /// Whether anything narrows the list beyond the search and the collection, for the filter button to show it.
    public var narrows: Bool {
        kind != nil || site != nil || !aspects.isEmpty || minimumResolution != .low
    }

    public func matches(_ wallpaper: Wallpaper, isFavourite: Bool) -> Bool {
        switch collection {
        case .all: break
        case .favourites: guard isFavourite else { return false }
        case .downloaded: guard wallpaper.origin == .downloaded else { return false }
        case .imported: guard wallpaper.origin == .imported else { return false }
        }
        if let kind, wallpaper.kind != kind { return false }
        if let site, wallpaper.site != site { return false }
        if !aspects.isEmpty, !aspects.contains(wallpaper.aspect) { return false }
        if wallpaper.resolution < minimumResolution { return false }
        let haystack = [wallpaper.title, wallpaper.site ?? ""]
        return words.allSatisfy { word in
            haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public func apply(to wallpapers: [Wallpaper], favourites: Set<String>) -> [Wallpaper] {
        wallpapers.filter { matches($0, isFavourite: favourites.contains($0.id)) }
    }

    /// The sites to offer in the filter: those of the wallpapers there are, most used first.
    public static func sites(in wallpapers: [Wallpaper]) -> [String] {
        let counts = Dictionary(wallpapers.compactMap(\.site).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.keys.sorted { lhs, rhs in
            counts[lhs] != counts[rhs] ? (counts[lhs] ?? 0) > (counts[rhs] ?? 0) : lhs < rhs
        }
    }
}
