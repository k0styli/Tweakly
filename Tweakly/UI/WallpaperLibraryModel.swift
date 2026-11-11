import AppKit
import ImageIO
import LiveWallpaperCore
import Observation
import os

/// The wallpapers on this Mac, for the page and the browser of the window process. Every change is written to the
/// library's index at once, where the agent reads it.
@Observable final class WallpaperLibraryModel {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    private(set) var index = WallpaperFolder.readIndex() {
        didSet { all = index.newestFirst }
    }
    /// Newest first, sorted once per change rather than on every look.
    private(set) var all: [LibraryIndex.Entry] = []
    var filter = WallpaperFilter()
    /// Videos being converted, for optimization or economy mode, with how far each has got, for the tiles and the
    /// browser's list.
    private(set) var optimizing: [String: Double] = [:]
    /// Files being added right now, for the page to show it is busy.
    private(set) var importsInProgress = 0
    /// What went wrong with the last files added, one line each, for an alert.
    var importProblems: [String] = []
    /// Wallpapers from before the cleaner that it refused, and so were taken out of the library, one line each.
    var removedProblems: [String] = []
    /// Set by the page, so that changes to the choice of wallpaper go through the settings.
    @ObservationIgnored var settings: AppSettings?
    @ObservationIgnored private var browser: WallpaperBrowserController?
    /// Called when the browser is closed and nothing is left to download or optimize, for the process to end if no
    /// window is left.
    @ObservationIgnored var onIdle: (() -> Void)?
    /// Brings the main window forward on this page, from the browser.
    @ObservationIgnored var onShowLibrary: (() -> Void)?
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored private var optimizationQueue: [Job] = []
    @ObservationIgnored private var optimizationTask: Task<Void, Never>?

    init() {
        all = index.newestFirst
    }

    var shown: [LibraryIndex.Entry] {
        let favourites = index.favouriteSet
        return all.filter { filter.matches($0.wallpaper, isFavourite: favourites.contains($0.wallpaper.id)) }
    }

    var sites: [String] { WallpaperFilter.sites(in: all.map(\.wallpaper)) }

    /// Whether the process has work left after its window closes: the browser, a download, an import or an
    /// optimization.
    var isBusy: Bool { (browser?.isBusy ?? false) || optimizationTask != nil || importsInProgress > 0 }

    #if TWEAKLY_AUTOMATION
        var browserDownloads: [BrowserDownloads.Item] { browser?.downloads.items ?? [] }
        var browserLog: [String] { browser?.navigationLog ?? [] }
        func runBrowserScript(_ script: String) { browser?.runScript(script) }
        func closeBrowser() { browser?.close() }
    #endif

    func reload() {
        index = WallpaperFolder.readIndex()
        optimizePending()
    }

    func entry(_ id: String) -> LibraryIndex.Entry? { index.entries[id] }

    func isFavourite(_ id: String) -> Bool { index.isFavourite(id) }

    func setFavourite(_ id: String, _ isFavourite: Bool) {
        change { $0.setFavourite(id, isFavourite) }
    }

    func rename(_ id: String, to title: String) {
        change { $0.rename(id, to: title) }
    }

    /// Takes a wallpaper off every display, then deletes its files.
    func remove(_ id: String) {
        if let settings, settings.liveWallpaperAssignments.usedIDs.contains(id) {
            settings.liveWallpaperAssignments.remove(id)
        }
        var names: [String] = []
        change { names = $0.remove(id) }
        for name in names {
            if let url = WallpaperFolder.file(named: name) { try? FileManager.default.removeItem(at: url) }
        }
        if let thumbnail = WallpaperImporter.thumbnailURL(for: id) {
            try? FileManager.default.removeItem(at: thumbnail)
        }
        thumbnails.forget(id)
    }

    /// Puts a wallpaper on a display, or on all of them while they share one, and turns the tweak on.
    func choose(_ id: String, forDisplay key: String) {
        guard let settings else { return }
        let fit = settings.liveWallpaperAssignments.choice(forDisplay: key)?.fit ?? .fill
        guard let choice = index.choice(for: id, fit: fit) else { return }
        var assignments = settings.liveWallpaperAssignments
        assignments.set(choice, forDisplay: key)
        settings.liveWallpaperAssignments = assignments
        settings.liveWallpaperStopReason = nil
        UserDefaults.standard.removeObject(forKey: DesktopPicture.restoredDefaultKey)
        if !settings.liveWallpaperEnabled { settings.liveWallpaperEnabled = true }
        change { $0.markUsed(id, at: .now) }
        // The display plays the file until its own copy is made, then moves to it from the same moment.
        enqueue(.variants(id))
    }

    /// Adds files someone dropped or picked, one at a time, as each may be large.
    func importFiles(_ urls: [URL]) {
        let files = urls.filter { ImportCheck.kind(ofExtension: $0.pathExtension) != nil || $0.hasDirectoryPath }
        let refused = urls.count - files.count
        if refused > 0 {
            importProblems = [String(localized: "Only videos (MOV, MP4, M4V) and pictures can be added.")]
        }
        guard !files.isEmpty else { return }
        importsInProgress += files.count
        Task {
            var problems: [String] = []
            for file in files {
                let access = file.startAccessingSecurityScopedResource()
                defer {
                    if access { file.stopAccessingSecurityScopedResource() }
                    importsInProgress -= 1
                }
                do {
                    let entry = try await WallpaperImporter.importFile(at: file)
                    change { $0.store(entry) }
                    prepare(entry.wallpaper.id)
                } catch {
                    problems.append(Self.describe(error, file: file.lastPathComponent))
                }
            }
            if !problems.isEmpty { importProblems = problems }
            // The window may have closed meanwhile, and the process waited for this alone.
            if !isBusy { onIdle?() }
        }
    }

    /// A finished download from the browser.
    func add(_ entry: LibraryIndex.Entry) {
        change { $0.store(entry) }
        // Room is made for it, never by it: with favourites filling the limit, it would go the moment it came.
        trimDownloads(keeping: entry.wallpaper.id)
        prepare(entry.wallpaper.id)
    }

    /// From the browser's list: on every display while they share one, or on the main display.
    func chooseForDesktop(_ id: String) {
        guard let key = WallpaperFolder.screens.first.flatMap(WallpaperFolder.key(of:)) else { return }
        choose(id, forDisplay: key)
    }

    /// Whether the page the browser shows is one a wallpaper in the library came from.
    func isInLibrary(page: URL) -> Bool {
        let wanted = Self.comparable(page)
        return all.contains { $0.wallpaper.pageURL.map(Self.comparable) == wanted }
    }

    private static func comparable(_ url: URL) -> String {
        var text = url.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: "://www.", with: "://").lowercased()
    }

    // MARK: Optimization and copies for the displays

    /// Work on one wallpaper in the media engine. One at a time, as each keeps it busy for a while.
    private enum Job: Equatable {
        /// A wallpaper from before the cleaner, read by it once. See `MediaCleanerClient`.
        case clean(String)
        case optimize(String)
        /// The smaller or slower copies the displays showing it ask for. See `PlaybackSize` and `EconomyMode`.
        case variants(String)

        var id: String {
            switch self {
            case .clean(let id), .optimize(let id), .variants(let id): id
            }
        }
    }

    /// Copies that could not be made, not tried again while the window is open.
    @ObservationIgnored private var failedVariants: Set<String> = []

    /// Every wallpaper not yet looked at: for the cleaner and optimization, such as those added before they existed,
    /// and for the copies the displays ask for.
    func optimizePending() {
        // What is on a display first: it is what the system and the player read most.
        let inUse = settings?.liveWallpaperAssignments.usedIDs ?? []
        for entry in all.filter(\.needsCleaning).sorted(by: {
            inUse.contains($0.wallpaper.id) && !inUse.contains($1.wallpaper.id)
        }) {
            enqueue(.clean(entry.wallpaper.id))
        }
        for entry in all where entry.needsOptimization { enqueue(.optimize(entry.wallpaper.id)) }
        playbackChanged()
    }

    /// Called when economy mode, the size or the displays change: whatever is on a display gets the copies it now
    /// needs. Copies made stay, so going back is immediate.
    func playbackChanged() {
        for id in settings?.liveWallpaperAssignments.usedIDs ?? [] { enqueue(.variants(id)) }
    }

    /// After a wallpaper is added or cleaned: optimized if it needs it, then given the copies its displays ask for.
    private func prepare(_ id: String) {
        enqueue(.optimize(id))
        enqueue(.variants(id))
    }

    private func enqueue(_ job: Job) {
        guard let entry = index.entries[job.id], !optimizationQueue.contains(job) else { return }
        switch job {
        case .clean: guard entry.needsCleaning else { return }
        // Conversions read the file in this process, so only once the cleaner has written it.
        case .optimize: guard entry.needsOptimization, !entry.needsCleaning else { return }
        // Copies are made from the optimized file, which an optimization queued before them leaves.
        case .variants: guard !entry.needsCleaning, !variantRequests(for: entry).isEmpty else { return }
        }
        optimizationQueue.append(job)
        guard optimizationTask == nil else { return }
        optimizationTask = Task { [weak self] in
            while let self, !self.optimizationQueue.isEmpty {
                let next = self.optimizationQueue.removeFirst()
                await self.run(next)
            }
            self?.optimizationTask = nil
            if self?.isBusy == false { self?.onIdle?() }
        }
    }

    /// The copies the displays showing a wallpaper ask for, while the tweak is on.
    private func variantRequests(for entry: LibraryIndex.Entry) -> [WallpaperVariant.Request] {
        guard let settings, settings.liveWallpaperEnabled else { return [] }
        let assignments = settings.liveWallpaperAssignments
        let panels = WallpaperFolder.screens.compactMap { screen -> PixelSize? in
            guard let key = WallpaperFolder.key(of: screen),
                assignments.choice(forDisplay: key)?.wallpaperID == entry.wallpaper.id
            else { return nil }
            return WallpaperFolder.panelSize(of: screen)
        }
        return WallpaperVariant.needed(
            source: entry.pixelSize, kind: entry.wallpaper.kind, setting: settings.liveWallpaperPlaybackSize,
            panels: panels, economy: settings.liveWallpaperEconomy)
    }

    private func run(_ job: Job) async {
        guard let entry = index.entries[job.id] else { return }
        let id = job.id
        optimizing[id] = 0
        defer { optimizing[id] = nil }
        let reporter = ProgressReporter { [weak self] fraction in self?.optimizing[id] = fraction }
        switch job {
        case .clean:
            guard entry.needsCleaning else { return }
            await runCleaning(entry)
        case .optimize:
            guard entry.needsOptimization, !entry.needsCleaning else { return }
            do {
                let result = try await VideoOptimizer.optimize(fileNamed: entry.fileName) { reporter.report($0) }
                // Removed while it was converted: the new file has nothing pointing to it.
                guard index.entries[id] != nil else {
                    if result != nil { Self.removeFile(named: entry.fileName) }
                    return
                }
                let bytes = result == nil ? nil : Self.byteCount(of: entry)
                change { $0.markOptimized(id, byteCount: bytes, width: result?.width, height: result?.height) }
            } catch {
                // The original is left as it was, and is not tried again.
                Self.log.error("Could not optimize: \(error.localizedDescription, privacy: .public)")
                change { $0.markOptimized(id) }
            }
        case .variants:
            guard !entry.needsCleaning else { return }
            await makeVariants(of: entry, progress: reporter)
        }
    }

    private func makeVariants(of entry: LibraryIndex.Entry, progress reporter: ProgressReporter) async {
        let id = entry.wallpaper.id
        var made = false
        func attempt(_ key: String, _ make: () async throws -> String?) async {
            guard !failedVariants.contains(key) else { return }
            do {
                guard let name = try await make() else { return }
                // Removed while the copy was made: the copy has nothing pointing to it.
                guard index.entries[id] != nil else {
                    Self.removeFile(named: name)
                    return
                }
                guard index.entries[id]?.variants?.contains(name) != true else { return }
                var updated = index.entries[id] ?? entry
                updated.variants = (updated.variants ?? []) + [name]
                let bytes = Self.byteCount(of: updated)
                change { $0.markVariant(id, name: name, byteCount: bytes) }
                made = true
            } catch {
                // The display goes on with the file itself, and this copy is not tried again for now.
                failedVariants.insert(key)
                Self.log.error(
                    "Could not make \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        for request in variantRequests(for: entry) {
            let size = request.size
            let label = WallpaperVariant.name(for: entry.fileName, size: size, economy: request.economy)
            switch entry.wallpaper.kind {
            case .video:
                await attempt(label) {
                    try await VideoOptimizer.makeVariant(
                        fileNamed: entry.fileName, size: size, economy: request.economy
                    ) { reporter.report($0) }
                }
                // The desktop picture under the video, its still, the same size.
                if let size, let still = entry.stillName {
                    await attempt(WallpaperVariant.name(for: still, size: size, economy: false)) {
                        try await PictureVariant.make(fileNamed: still, size: size)
                    }
                }
            case .picture:
                guard let size else { continue }
                await attempt(label) { try await PictureVariant.make(fileNamed: entry.fileName, size: size) }
            }
        }
        // The player and the desktop picture move to the copies, a video from the same moment.
        if made { ProcessEvents.post(.settingsChanged) }
    }

    private func runCleaning(_ entry: LibraryIndex.Entry) async {
        let id = entry.wallpaper.id
        do {
            let files = try await WallpaperImporter.reclean(entry)
            var updated = entry
            updated.fileName = files.fileName
            updated.stillName = files.stillName
            change {
                $0.markCleaned(
                    id, fileName: files.fileName, stillName: files.stillName, byteCount: Self.byteCount(of: updated))
            }
            if files.fileName != entry.fileName {
                // A picture became PNG: the displays and the system's desktop picture move to it, then the old goes.
                settings?.liveWallpaperAssignments.renameFiles(
                    of: id, fileName: files.fileName, stillName: files.stillName)
                if let old = WallpaperFolder.file(named: entry.fileName) {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            thumbnails.forget(id)
            ProcessEvents.post(.settingsChanged)
            prepare(id)
        } catch let failure as WallpaperImporter.Failure where failure.problem != .couldNotCheck {
            // The file is not what a wallpaper may be, as a new file like it would not get in: it leaves the library.
            Self.log.error("Removed a wallpaper the cleaner refused: \(id, privacy: .public)")
            removedProblems.append(Self.describe(failure, file: entry.wallpaper.title))
            remove(id)
        } catch {
            // The cleaner itself could not finish, which says nothing sure about the file: it is tried again next time.
            Self.log.error("Could not clean \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func byteCount(of entry: LibraryIndex.Entry) -> Int64 {
        entry.fileNames.reduce(Int64(0)) { $0 + WallpaperImporter.byteCount(of: WallpaperFolder.file(named: $1)) }
    }

    var downloadedBytes: Int64 {
        DownloadLimit.usedBytes(index.stored(inUse: settings?.liveWallpaperAssignments.usedIDs ?? []))
    }

    var clearableCount: Int {
        DownloadLimit.clearable(index.stored(inUse: settings?.liveWallpaperAssignments.usedIDs ?? [])).count
    }

    /// Keeps downloads within the chosen limit, oldest first.
    private static func removeFile(named name: String) {
        if let url = WallpaperFolder.file(named: name) { try? FileManager.default.removeItem(at: url) }
    }

    func trimDownloads(keeping kept: String? = nil) {
        var inUse = settings?.liveWallpaperAssignments.usedIDs ?? []
        if let kept { inUse.insert(kept) }
        for id in DownloadLimit.toRemove(index.stored(inUse: inUse), limit: settings?.liveWallpaperDownloadLimit) {
            remove(id)
        }
    }

    func clearDownloads() {
        let inUse = settings?.liveWallpaperAssignments.usedIDs ?? []
        for id in DownloadLimit.clearable(index.stored(inUse: inUse)) { remove(id) }
    }

    func showInFinder(_ id: String) {
        guard let name = index.entries[id]?.fileName, let url = WallpaperFolder.file(named: name) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openBrowser(at address: URL) {
        let browser =
            self.browser
            ?? WallpaperBrowserController(
                library: self,
                onIdle: { [weak self] in
                    self?.browser = nil
                    if self?.isBusy == false { self?.onIdle?() }
                })
        self.browser = browser
        browser.show(address)
    }

    private func change(_ edit: (inout LibraryIndex) -> Void) {
        // Another process may have written in the meantime, such as a test adding a file.
        var latest = WallpaperFolder.readIndex()
        edit(&latest)
        do {
            try WallpaperFolder.write(latest)
        } catch {
            Self.log.error("Could not save the library: \(error.localizedDescription, privacy: .public)")
        }
        index = latest
    }

    static func describe(_ error: Error, file: String) -> String {
        guard let failure = error as? WallpaperImporter.Failure else {
            return String(localized: "“\(file)” could not be added: \(error.localizedDescription)")
        }
        switch failure.problem {
        case .unsupported:
            return String(localized: "“\(file)” is not a video or picture this Mac can show.")
        case .protected:
            return String(localized: "“\(file)” is protected and plays only in the app it came from.")
        case .unplayable:
            return String(localized: "“\(file)” could not be played. It may be damaged.")
        case .needsSoftwareDecoding(let codec):
            return String(
                localized:
                    "“\(file)” uses \(codec), which this Mac decodes only with its processor. As a wallpaper it would use a lot of power."
            )
        case .tooShort:
            return String(localized: "“\(file)” is shorter than a second.")
        case .tooLarge:
            return String(localized: "“\(file)” is larger than 8K, which no Mac screen needs.")
        case .tooSmall:
            return String(localized: "“\(file)” is too small for a desktop picture.")
        case .couldNotCheck:
            return String(localized: "“\(file)” could not be checked safely, so it was not added.")
        }
    }
}

/// Passes an optimization's progress to the main thread in whole percents, not once a frame.
///
/// `@unchecked Sendable`: `last` is read and written only under `lock`.
nonisolated final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    private let update: @MainActor (Double) -> Void

    init(update: @escaping @MainActor (Double) -> Void) {
        self.update = update
    }

    func report(_ fraction: Double) {
        let percent = Int(fraction * 100)
        lock.lock()
        let isNew = percent != last
        last = percent
        lock.unlock()
        guard isNew else { return }
        let update = self.update
        Task { @MainActor in update(Double(percent) / 100) }
    }
}

/// Thumbnails for the grid, decoded off the main thread at the size a tile shows them, and kept within a budget so a
/// large library does not keep every picture decoded.
final class ThumbnailCache {
    /// A tile is at most about 200 points wide, twice that on a Retina display.
    nonisolated static let pixelWidth = 400
    private let cache = NSCache<NSString, NSImage>()

    init() {
        // About a hundred tiles' worth of 400×250 pictures.
        cache.totalCostLimit = 40_000_000
    }

    func cached(_ id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    /// Decodes the thumbnail, making it again from the wallpaper if the caches were emptied.
    func load(_ entry: LibraryIndex.Entry) async -> NSImage? {
        if let image = cached(entry.wallpaper.id) { return image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let url = WallpaperImporter.remakeThumbnail(for: entry),
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.pixelWidth,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: .zero)
        cache.setObject(image, forKey: entry.wallpaper.id as NSString, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    func forget(_ id: String) {
        cache.removeObject(forKey: id as NSString)
    }
}
