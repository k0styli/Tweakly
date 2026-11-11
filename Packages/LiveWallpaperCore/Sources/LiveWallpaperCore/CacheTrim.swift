import Foundation

/// A wallpaper kept on this Mac, as the limit on downloads sees it.
public struct StoredWallpaper: Equatable, Sendable {
    public var id: String
    public var byteCount: Int64
    public var lastUsed: Date
    /// Someone's own file. Never removed to make room, and does not count against the limit.
    public var isImported: Bool
    /// On a display now. Never removed.
    public var isInUse: Bool
    /// Marked by someone. Never removed by the limit or the button either.
    public var isFavourite: Bool

    public init(
        id: String, byteCount: Int64, lastUsed: Date, isImported: Bool = false, isInUse: Bool = false,
        isFavourite: Bool = false
    ) {
        self.id = id
        self.byteCount = byteCount
        self.lastUsed = lastUsed
        self.isImported = isImported
        self.isInUse = isInUse
        self.isFavourite = isFavourite
    }
}

/// Keeps downloaded wallpapers within a size, as Safari keeps its cache: what was used longest ago goes first.
public enum DownloadLimit {
    /// The choices on the page, in bytes. Nil means no limit.
    public static let choices: [Int64?] = [1, 2, 5, 10, 20].map { Int64($0) * 1_000_000_000 } + [nil]
    public static let standard: Int64 = 5_000_000_000

    /// What counts against the limit.
    public static func usedBytes(_ videos: [StoredWallpaper]) -> Int64 {
        videos.filter { !$0.isImported }.reduce(0) { $0 + $1.byteCount }
    }

    /// The wallpapers to remove so that downloads fit in `limit`, oldest first. What is on a display or a favourite
    /// stays, even if that leaves downloads over the limit.
    public static func toRemove(_ videos: [StoredWallpaper], limit: Int64?) -> [String] {
        guard let limit else { return [] }
        var used = usedBytes(videos)
        guard used > limit else { return [] }
        let removable = videos.filter(isRemovable).sorted { lhs, rhs in
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed < rhs.lastUsed }
            return lhs.id < rhs.id
        }
        var removed: [String] = []
        for video in removable where used > limit {
            removed.append(video.id)
            used -= video.byteCount
        }
        return removed
    }

    /// What the button that empties downloads removes: every downloaded wallpaper that is not on a display or a
    /// favourite.
    public static func clearable(_ videos: [StoredWallpaper]) -> [String] {
        videos.filter(isRemovable).map(\.id)
    }

    private static func isRemovable(_ wallpaper: StoredWallpaper) -> Bool {
        !wallpaper.isImported && !wallpaper.isInUse && !wallpaper.isFavourite
    }
}
