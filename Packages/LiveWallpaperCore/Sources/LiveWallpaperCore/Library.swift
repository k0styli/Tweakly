import Foundation

/// What this Mac keeps: downloaded and added wallpapers, and which of them are favourites. Saved as JSON next to the
/// files, and read by both the window and the agent.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var wallpaper: Wallpaper
        /// The video or picture in the wallpapers folder.
        public var fileName: String
        /// For a video, a full-size frame of it: the desktop picture while it plays, and what shows while it loads.
        public var stillName: String?
        public var byteCount: Int64
        public var added: Date
        public var lastUsed: Date
        /// True once a video has been through `VideoOptimization`, whether it was converted or found light already, so
        /// it is never looked at again. Missing in libraries from before it existed.
        public var optimized: Bool?
        /// True once its files were written anew by the sandboxed cleaner, see `MediaInbox`. Missing for files added
        /// before it existed, which go through it once.
        public var cleaned: Bool?
        /// The copy with fewer frames that economy mode made before smaller copies existed, kept until the wallpaper
        /// goes. See `EconomyMode`.
        public var economyName: String?
        /// Smaller copies, with fewer frames too while economy mode is on, made for the displays it was shown on. See
        /// `WallpaperVariant`.
        public var variants: [String]?

        public init(
            wallpaper: Wallpaper, fileName: String, stillName: String? = nil, byteCount: Int64 = 0, added: Date,
            lastUsed: Date? = nil
        ) {
            self.wallpaper = wallpaper
            self.fileName = fileName
            self.stillName = stillName
            self.byteCount = byteCount
            self.added = added
            self.lastUsed = lastUsed ?? added
        }

        /// A video that has not been through optimization yet.
        public var needsOptimization: Bool {
            wallpaper.kind == .video && optimized != true
        }

        /// Files from before the cleaner, still as they came.
        public var needsCleaning: Bool { cleaned != true }

        /// The file, its still and every copy of them.
        public var fileNames: [String] {
            [fileName] + [stillName, economyName].compactMap { $0 } + (variants ?? [])
        }

        /// The size it is shown at, turned as it plays.
        public var pixelSize: PixelSize { PixelSize(width: wallpaper.width, height: wallpaper.height) }

        /// What goes on the desktop as the picture: the picture itself, or the video's still.
        public var desktopPictureName: String? {
            wallpaper.kind == .picture ? fileName : stillName
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var entries: [String: Entry]
    /// In the order they were marked.
    public var favourites: [String]

    public init(entries: [String: Entry] = [:], favourites: [String] = []) {
        version = Self.currentVersion
        self.entries = entries
        self.favourites = favourites
    }

    /// Newest first, as a new download should be the first thing seen.
    public var newestFirst: [Entry] {
        entries.values.sorted { lhs, rhs in
            lhs.added != rhs.added ? lhs.added > rhs.added : lhs.wallpaper.id < rhs.wallpaper.id
        }
    }

    public var favouriteSet: Set<String> { Set(favourites) }

    public func isFavourite(_ id: String) -> Bool { favourites.contains(id) }

    public mutating func setFavourite(_ id: String, _ isFavourite: Bool) {
        if isFavourite {
            guard entries[id] != nil, !favourites.contains(id) else { return }
            favourites.append(id)
        } else {
            favourites.removeAll { $0 == id }
        }
    }

    public mutating func store(_ entry: Entry) {
        entries[entry.wallpaper.id] = entry
    }

    /// Forgets a wallpaper, returning the files to delete.
    @discardableResult
    public mutating func remove(_ id: String) -> [String] {
        favourites.removeAll { $0 == id }
        guard let entry = entries.removeValue(forKey: id) else { return [] }
        return entry.fileNames
    }

    /// Records a finished optimization: what its files take now and the new size of the picture, if it was converted.
    public mutating func markOptimized(_ id: String, byteCount: Int64? = nil, width: Int? = nil, height: Int? = nil) {
        guard var entry = entries[id] else { return }
        entry.optimized = true
        if let byteCount { entry.byteCount = byteCount }
        if let width, let height {
            entry.wallpaper.width = width
            entry.wallpaper.height = height
        }
        entries[id] = entry
    }

    /// Records files written anew by the cleaner: their names and what they take now.
    public mutating func markCleaned(_ id: String, fileName: String, stillName: String?, byteCount: Int64) {
        guard var entry = entries[id] else { return }
        entry.cleaned = true
        entry.fileName = fileName
        entry.stillName = stillName
        entry.byteCount = byteCount
        entries[id] = entry
    }

    /// Records a smaller or slower copy, and what all the wallpaper's files take now.
    public mutating func markVariant(_ id: String, name: String, byteCount: Int64) {
        guard var entry = entries[id] else { return }
        var variants = entry.variants ?? []
        if !variants.contains(name) { variants.append(name) }
        entry.variants = variants
        entry.byteCount = byteCount
        entries[id] = entry
    }

    public mutating func markUsed(_ id: String, at date: Date) {
        entries[id]?.lastUsed = date
    }

    public mutating func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[id]?.wallpaper.title = trimmed
    }

    public func stored(inUse: Set<String>) -> [StoredWallpaper] {
        entries.values.map {
            StoredWallpaper(
                id: $0.wallpaper.id, byteCount: $0.byteCount, lastUsed: $0.lastUsed,
                isImported: $0.wallpaper.origin == .imported, isInUse: inUse.contains($0.wallpaper.id),
                isFavourite: favourites.contains($0.wallpaper.id))
        }
    }

    /// A name for a file in the wallpapers folder, safe whatever the id holds.
    public static func fileName(for id: String, extension pathExtension: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let safe = String(id.map { allowed.contains($0) ? $0 : "_" })
        let ext = pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return ext.isEmpty ? safe : "\(safe).\(ext)"
    }

    /// The choice that puts this wallpaper on a display.
    public func choice(for id: String, fit: VideoFit) -> WallpaperChoice? {
        guard let entry = entries[id] else { return nil }
        return WallpaperChoice(
            wallpaperID: id, kind: entry.wallpaper.kind, fileName: entry.fileName, stillName: entry.stillName, fit: fit)
    }
}

/// How the video covers a display, as in System Settings › Wallpaper.
public enum VideoFit: String, Codable, CaseIterable, Hashable, Sendable {
    /// Covers the whole screen, cutting off what does not fit.
    case fill
    /// Shows the whole video, with bars where the shapes differ.
    case fit
    case stretch
}

/// What one display shows.
public struct WallpaperChoice: Codable, Hashable, Sendable {
    public var wallpaperID: String
    public var kind: Wallpaper.Kind
    /// In the wallpapers folder, so the process that plays needs nothing else.
    public var fileName: String
    public var stillName: String?
    public var fit: VideoFit

    public init(
        wallpaperID: String, kind: Wallpaper.Kind = .video, fileName: String, stillName: String? = nil,
        fit: VideoFit = .fill
    ) {
        self.wallpaperID = wallpaperID
        self.kind = kind
        self.fileName = fileName
        self.stillName = stillName
        self.fit = fit
    }

    /// The file that becomes the system's desktop picture: the picture itself, or the video's still.
    public var desktopPictureName: String? {
        kind == .picture ? fileName : stillName
    }
}

/// Which display plays what. Displays are known by the system's UUID for them, which stays the same across restarts
/// and reconnections.
public struct DisplayAssignments: Codable, Equatable, Sendable {
    /// One video for every display, including ones connected later.
    public var sameOnAll: Bool
    public var shared: WallpaperChoice?
    public var perDisplay: [String: WallpaperChoice]

    public init(sameOnAll: Bool = true, shared: WallpaperChoice? = nil, perDisplay: [String: WallpaperChoice] = [:]) {
        self.sameOnAll = sameOnAll
        self.shared = shared
        self.perDisplay = perDisplay
    }

    public func choice(forDisplay key: String) -> WallpaperChoice? {
        sameOnAll ? shared : perDisplay[key]
    }

    /// Sets what one display plays, or every display while they share one.
    public mutating func set(_ choice: WallpaperChoice?, forDisplay key: String) {
        if sameOnAll {
            shared = choice
        } else {
            perDisplay[key] = choice
        }
    }

    /// Turning sharing off gives every display it knows what they all had, so nothing changes on screen.
    public mutating func setSameOnAll(_ same: Bool, displays: [String]) {
        guard same != sameOnAll else { return }
        if same {
            let first = displays.compactMap { perDisplay[$0] }.first
            shared = shared ?? first ?? perDisplay.values.first
        } else if let shared {
            for display in displays where perDisplay[display] == nil { perDisplay[display] = shared }
        }
        sameOnAll = same
    }

    /// Whether some display that is connected now plays a video, which is when the process that plays has to run.
    public func hasVideo(forDisplays keys: [String]) -> Bool {
        keys.contains { choice(forDisplay: $0)?.kind == .video }
    }

    /// Wallpapers on a display now, or on one that may come back, which the limit on downloads must not remove.
    public var usedIDs: Set<String> {
        var ids = Set(perDisplay.values.map(\.wallpaperID))
        if let shared { ids.insert(shared.wallpaperID) }
        return ids
    }

    public var isEmpty: Bool { shared == nil && perDisplay.isEmpty }

    /// Points every display showing a wallpaper at its new files, keeping how each covers its screen.
    public mutating func renameFiles(of id: String, fileName: String, stillName: String?) {
        func renamed(_ choice: WallpaperChoice?) -> WallpaperChoice? {
            guard var choice, choice.wallpaperID == id else { return choice }
            choice.fileName = fileName
            choice.stillName = stillName
            return choice
        }
        shared = renamed(shared)
        for key in perDisplay.keys { perDisplay[key] = renamed(perDisplay[key]) }
    }

    /// Takes a video off every display, as when its file is removed.
    public mutating func remove(_ wallpaperID: String) {
        if shared?.wallpaperID == wallpaperID { shared = nil }
        perDisplay = perDisplay.filter { $0.value.wallpaperID != wallpaperID }
    }

    public mutating func setFit(_ fit: VideoFit, forDisplay key: String) {
        if sameOnAll {
            shared?.fit = fit
        } else {
            perDisplay[key]?.fit = fit
        }
    }
}
