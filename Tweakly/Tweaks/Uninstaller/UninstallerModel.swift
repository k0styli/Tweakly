import AppKit
import Observation
import UninstallerCore
import os

#if TWEAKLY_AUTOMATION
    import SystemMetrics
#endif

/// The uninstaller page: every app with what it keeps in the Library, and the sheet that removes one. Everything is read
/// when the page first shows and again when an app folder changes while it shows. The window's process exits when the
/// window closes, so none of it costs anything afterwards.
@Observable final class UninstallerModel {
    nonisolated struct Row: Identifiable, Hashable {
        var app: InstalledApp
        /// Nil while the Library is being searched.
        var leftovers: [Leftover]?
        /// What the leftovers take, nil while they are measured.
        var dataSize: Int64?
        /// Some of its data is in a container, which is not read without Full Disk Access.
        var hasUnreadableData = false
        /// Another copy of the app, whose files are its too.
        var otherCopy: String?

        var id: String { app.id }
        var name: String { app.name }
        var kindTitle: String { UninstallerText.kind(of: app) }
        var sortDate: Date { app.lastOpened ?? .distantPast }
        var sortSize: Int64 { app.size ?? -1 }
        var sortData: Int64 { dataSize ?? -1 }
    }

    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    var query = ""
    var sort = AppSort.saved() {
        didSet { if sort != oldValue { sort.save() } }
    }
    var selection: Row.ID?
    /// The sheet, while it is open.
    var plan: RemovalPlan?
    /// A line about what was just moved to the Trash, in place of the totals for a while.
    private(set) var notice: String?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    /// The table, kept here so that its scroll and columns survive a visit to another page.
    @ObservationIgnored lazy var table = AppsTableController(model: self)
    #if TWEAKLY_AUTOMATION
        /// The sheet's list while it is open, for checking its layout.
        @ObservationIgnored weak var sheetTable: RemovalTableController?
    #endif
    @ObservationIgnored private var catalog = AppCatalog()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isVisible = false
    /// An app folder changed while the page was out of sight.
    @ObservationIgnored private var missedChange = false
    @ObservationIgnored private var droppedApps: [URL] = []
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    var visibleRows: [Row] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(query) }
        return sort.sorted(shown)
    }

    var selectedRow: Row? { rows.first { $0.id == selection } }

    /// Whether some app keeps data that only Full Disk Access shows.
    var needsFullDiskAccess: Bool { !hasFullDiskAccess && rows.contains(where: \.hasUnreadableData) }

    var status: String {
        if let notice { return notice }
        guard !rows.isEmpty else { return isLoading ? String(localized: "Looking for apps…") : "" }
        let size = rows.reduce(Int64(0)) { $0 + max($1.app.size ?? 0, 0) }
        let data = rows.reduce(Int64(0)) { $0 + ($1.dataSize ?? 0) }
        let apps = String(localized: "\(rows.count) apps, \(Format.fileSize(UInt64(size)))")
        guard data > 0 else { return apps }
        return apps + "   " + String(localized: "Their data \(Format.fileSize(UInt64(data)))")
    }

    func icon(for row: Row) -> NSImage { icon(forApp: row.id) }

    /// Asked of the system once for each app: the sheet's header is drawn again with every box ticked.
    func icon(forApp path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    // MARK: Loading

    /// Reads only while the page can be seen. The app folders are watched from the first look for as long as the window
    /// is open, which costs nothing between changes: an app installed or thrown away while the page is out of sight is
    /// read when it comes back, rather than offered for removal as it was.
    func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
        if watcher == nil, isVisible {
            let home = NSHomeDirectory()
            watcher = FolderWatcher(paths: ["/Applications", home + "/Applications"]) { [weak self] in
                guard let self else { return }
                if self.isVisible { self.reload() } else { self.missedChange = true }
            }
        }
        guard isVisible, !hasLoaded || missedChange else { return }
        missedChange = false
        reload()
    }

    func reload() {
        hasLoaded = true
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn {
                rows = Self.demoRows()
                isLoading = false
                return
            }
        #endif
        loadTask?.cancel()
        isLoading = true
        let home = NSHomeDirectory()
        let readsContainers = hasFullDiskAccess
        let extra = droppedApps
        loadTask = Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) { AppCatalog.read(home: home, extra: extra) }.value
            guard !Task.isCancelled, let self else { return }
            self.catalog = catalog
            let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = catalog.apps.map { app in
                var row = Row(app: app, otherCopy: catalog.otherCopy(of: app))
                // A row already searched keeps its files and figure until the new ones come, rather than blinking, and
                // so that the sheet opened meanwhile lists them.
                if let earlier = previous[app.id] {
                    row.leftovers = earlier.leftovers
                    row.dataSize = earlier.dataSize
                    row.hasUnreadableData = earlier.hasUnreadableData
                }
                return row
            }
            if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
            let found = await Task.detached(priority: .utility) {
                LeftoverScanner.scan(catalog, home: home, readsContainers: readsContainers)
            }.value
            guard !Task.isCancelled else { return }
            for index in rows.indices {
                let leftovers = found[rows[index].id] ?? []
                rows[index].leftovers = leftovers
                rows[index].hasUnreadableData =
                    !readsContainers && leftovers.contains { $0.place == .containers || $0.place == .groupContainers }
            }
            if let plan, plan.isSearching, let row = rows.first(where: { $0.id == plan.app.id }) {
                plan.found(row, readsContainers: readsContainers)
            }
            await measure(readsContainers: readsContainers)
            if !Task.isCancelled { isLoading = false }
        }
    }

    /// The biggest apps first, one app at a time, so the figures that matter most come first and the disk is not
    /// asked for everything at once.
    private func measure(readsContainers: Bool) async {
        let order = rows.sorted { $0.sortSize > $1.sortSize }.map(\.id)
        for id in order {
            guard !Task.isCancelled, let row = rows.first(where: { $0.id == id }) else { return }
            let leftovers = row.leftovers ?? []
            let needsAppSize = row.app.size == nil
            let path = row.id
            let (sizes, appSize) = await Task.detached(priority: .utility) {
                let sizes = OSAllocatedUnfairLock(initialState: [Int64?](repeating: nil, count: leftovers.count))
                DispatchQueue.concurrentPerform(iterations: leftovers.count) { index in
                    let size = LeftoverSizer.size(of: leftovers[index], readsContainers: readsContainers)
                    sizes.withLock { $0[index] = size }
                }
                return (sizes.withLock { $0 }, needsAppSize ? LeftoverSizer.size(of: path) : nil)
            }.value
            guard !Task.isCancelled, let index = rows.firstIndex(where: { $0.id == id }) else { return }
            var measured = leftovers
            for item in measured.indices { measured[item].size = sizes[item] }
            rows[index].leftovers = measured
            rows[index].dataSize = sizes.reduce(0) { $0 + ($1 ?? 0) }
            if let appSize { rows[index].app.size = appSize }
        }
    }

    /// An app dropped on the page: selected if it is listed, and added if it lives elsewhere.
    func open(droppedApps urls: [URL]) {
        let apps = urls.filter { $0.pathExtension == "app" }
        guard let first = apps.first else { return }
        selection = first.path
        guard !rows.contains(where: { $0.id == first.path }) else { return }
        droppedApps += apps.filter { !droppedApps.contains($0) }
        reload()
    }

    // MARK: Full Disk Access

    func refreshFullDiskAccess() {
        let granted = FullDiskAccess.isGranted
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        reload()
    }

    // MARK: Removing

    func begin(_ mode: RemovalPlan.Mode, for id: Row.ID? = nil) {
        guard let row = rows.first(where: { $0.id == (id ?? selection) }) else { return }
        selection = row.id
        plan = RemovalPlan(row: row, mode: mode, readsContainers: hasFullDiskAccess)
    }

    func reveal(_ id: Row.ID? = nil) {
        guard let path = id ?? selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func carryOut(_ plan: RemovalPlan) {
        guard !plan.isWorking else { return }
        plan.isWorking = true
        plan.problem = nil
        Task { [weak self] in
            let outcome = await AppRemover.remove(plan.checkedItems, of: plan.app)
            plan.isWorking = false
            guard !outcome.wasCancelled else { return }
            if let problem = outcome.problem {
                plan.problem = problem
                return
            }
            self?.reload()
            if outcome.failed.isEmpty {
                self?.plan = nil
                let size = outcome.moved.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                self?.show(notice: UninstallerText.done(plan.mode, name: plan.app.name, size: size))
            } else {
                plan.keepOnly(outcome.failed)
                plan.problem = UninstallerText.failed(count: outcome.failed.count)
            }
        }
    }

    private func show(notice: String) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    #if TWEAKLY_AUTOMATION
        /// Every app with its files, for checking the search without a screen.
        var stateForTesting: String {
            var lines: [String] = ["loading \(isLoading) fullDiskAccess \(hasFullDiskAccess) status \(status)"]
            for row in rows.sorted(by: { $0.name < $1.name }) {
                lines.append(
                    "\(row.name) | \(row.kindTitle) | \(row.app.size ?? -1) | data \(row.dataSize ?? -1)"
                        + (row.otherCopy.map { " | copy \($0)" } ?? ""))
                for item in (row.leftovers ?? []).sorted(by: Leftover.sheetOrder) {
                    lines.append(
                        "    \(item.place?.rawValue ?? "app") \(item.path) \(item.size ?? -1)"
                            + (item.needsAdministrator ? " admin" : "") + (item.job.map { " job \($0.domain)" } ?? ""))
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    #endif
}

/// One app on its way to the Trash, or only its data when it is reset: what goes, ticked or not, and how it went.
@Observable final class RemovalPlan: Identifiable {
    enum Mode {
        case uninstall
        /// Its data and settings go, the app stays and starts as new.
        case reset
    }

    struct Item: Identifiable, Hashable {
        var leftover: Leftover
        var isChecked = true
        var id: String { leftover.id }
    }

    let app: InstalledApp
    let mode: Mode
    var items: [Item]
    var selection: Item.ID?
    private(set) var otherCopy: String?
    private(set) var hasUnreadableData: Bool
    let isRunning: Bool
    /// The page is still searching the Library for this app, which an app folder that just changed sets going again.
    /// Nothing can go until it is done, or the app would go without its files.
    private(set) var isSearching: Bool
    var isWorking = false
    var problem: String?

    init(row: UninstallerModel.Row, mode: Mode, readsContainers: Bool) {
        app = row.app
        self.mode = mode
        otherCopy = row.otherCopy
        hasUnreadableData = row.hasUnreadableData
        isSearching = row.leftovers == nil
        items = Self.items(of: row, mode: mode)
        isRunning = !AppRemover.running(row.app).isEmpty
        measureMissing(readsContainers: readsContainers)
    }

    var checkedItems: [Leftover] { items.filter(\.isChecked).map(\.leftover) }
    var checkedSize: Int64 { checkedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var needsPassword: Bool { checkedItems.contains(where: \.needsAdministrator) }
    var canProceed: Bool { !isWorking && !isSearching && !checkedItems.isEmpty }

    /// The search the sheet waited for has ended. Boxes the person already cleared stay clear.
    func found(_ row: UninstallerModel.Row, readsContainers: Bool) {
        let cleared = Set(items.filter { !$0.isChecked }.map(\.id))
        items = Self.items(of: row, mode: mode).map { item in
            var item = item
            item.isChecked = !cleared.contains(item.id)
            return item
        }
        otherCopy = row.otherCopy
        hasUnreadableData = row.hasUnreadableData
        isSearching = false
        measureMissing(readsContainers: readsContainers)
    }

    private static func items(of row: UninstallerModel.Row, mode: Mode) -> [Item] {
        var leftovers = row.leftovers ?? []
        if mode == .uninstall {
            let bundle = Leftover(
                path: row.app.identity.path, place: nil, size: row.app.size,
                needsAdministrator: !LeftoverScanner.canMove(row.app.identity.path))
            leftovers.insert(bundle, at: 0)
        }
        return leftovers.sorted(by: Leftover.sheetOrder).map { Item(leftover: $0) }
    }

    func keepOnly(_ failed: [Leftover]) {
        let paths = Set(failed.map(\.path))
        items = items.filter { paths.contains($0.id) }
    }

    /// The sheet can open before the page has measured this app.
    private func measureMissing(readsContainers: Bool) {
        let missing = items.filter { $0.leftover.size == nil }.map(\.leftover)
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            let sizes = await Task.detached(priority: .userInitiated) {
                missing.map { LeftoverSizer.size(of: $0, readsContainers: readsContainers) }
            }.value
            guard let self else { return }
            for (leftover, size) in zip(missing, sizes) {
                if let index = items.firstIndex(where: { $0.id == leftover.id }) { items[index].leftover.size = size }
            }
        }
    }
}

/// Full Disk Access, which no prompt asks for: the person adds Tweakly in System Settings themselves.
enum FullDiskAccess {
    /// The database of privacy permissions opens only with Full Disk Access, and trying it asks nobody anything.
    static var isGranted: Bool {
        let file = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard file >= 0 else { return false }
        close(file)
        return true
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Tells when an app folder gains or loses an app, from the kernel, without reading it again and again. The calls come
/// a moment after the last change, as installing an app writes many times.
final class FolderWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(paths: [String], changed: @escaping @MainActor () -> Void) {
        for path in paths {
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.pending?.cancel()
                    let work = DispatchWorkItem { MainActor.assumeIsolated { changed() } }
                    self?.pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    isolated deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
    }
}

#if TWEAKLY_AUTOMATION
    extension UninstallerModel {
        /// Test copies with the `demoData` preference only, for pictures that will be published: widely used apps with
        /// made-up sizes, dates and data, instead of this Mac's own list. Only apps this Mac has are shown, as an icon
        /// comes from the app itself; nothing on disk is searched or measured.
        fileprivate static func demoRows() -> [Row] {
            let day: TimeInterval = 86_400
            let gigabyte: Int64 = 1_000_000_000
            let megabyte: Int64 = 1_000_000
            let apps: [(String, String, AppKind, Bool, TimeInterval, Int64, Int64)] = [
                ("Xcode", "com.apple.dt.Xcode", .appleSilicon, true, 1, 12_640 * megabyte, 3_180 * megabyte),
                ("Docker", "com.docker.docker", .appleSilicon, false, 6, 2_310 * megabyte, 1_420 * megabyte),
                ("Google Chrome", "com.google.Chrome", .universal, false, 0, 1_520 * megabyte, 864 * megabyte),
                ("Blender", "org.blenderfoundation.blender", .appleSilicon, false, 23, 1_080 * megabyte, 42 * megabyte),
                ("Visual Studio Code", "com.microsoft.VSCode", .appleSilicon, false, 2, 612 * megabyte, 486 * megabyte),
                ("Firefox", "org.mozilla.firefox", .universal, false, 4, 538 * megabyte, 312 * megabyte),
                ("Discord", "com.hnc.Discord", .universal, false, 9, 471 * megabyte, 228 * megabyte),
                ("Figma", "com.figma.Desktop", .appleSilicon, false, 15, 402 * megabyte, 96 * megabyte),
                ("Telegram", "ru.keepcoder.Telegram", .appleSilicon, true, 1, 288 * megabyte, 1 * gigabyte),
            ]
            let now = Date()
            return apps.compactMap { name, bundleID, kind, isAppStore, daysAgo, size, data in
                let path = "/Applications/\(name).app"
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                let app = InstalledApp(
                    identity: AppIdentity(path: path, bundleID: bundleID, names: [name]), name: name, kind: kind,
                    isAppStore: isAppStore, lastOpened: now.addingTimeInterval(-daysAgo * day - 3_600), size: size)
                // No list of files: the table then shows the figure as it is, without searching anything.
                var row = Row(app: app, otherCopy: nil)
                row.dataSize = data
                return row
            }
        }
    }
#endif
