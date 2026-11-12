import AVFoundation
import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Live wallpapers, laid out as System Settings › Wallpaper: what each display shows now, then the library to choose
/// from, then the sites to find more on. Search, filters and adding a file sit in the toolbar.
struct LiveWallpaperPageView: View {
    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
    private static let wallpaperSettings = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"

    @Bindable var settings: AppSettings
    @Bindable var library: WallpaperLibraryModel
    /// Command-F, which goes to the page's own field.
    let searchRequests: Int
    @FocusState private var isSearchFocused: Bool
    @State private var displays = DisplayInfo.connected()
    @State private var selectedDisplay: String?
    @State private var isChoosingFiles = false
    @State private var isShowingOptions = false
    @State private var isAskingAddress = false
    @State private var typedAddress = ""
    @State private var renaming: String?
    @State private var newTitle = ""
    @State private var restoredDefault = UserDefaults.standard.bool(forKey: DesktopPicture.restoredDefaultKey)

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.liveWallpaper.symbol, title: Text("Live Wallpaper"),
                    detail: Text("Videos and pictures on the desktop. A video stops whenever nobody can see it."),
                    isOn: isEnabled)
            }
            if let reason = settings.liveWallpaperStopReason, !settings.liveWallpaperEnabled {
                Section {
                    WarningRow(text: Text(Self.describe(reason)))
                }
            }
            if restoredDefault, !settings.liveWallpaperEnabled {
                restoredSection
            }
            currentSection
            playbackSection
            librarySection
            sitesSection
                .sectionActions {
                    Button("Options…") { isShowingOptions = true }
                }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                filterMenu
                Button {
                    isChoosingFiles = true
                } label: {
                    Label("Add Wallpaper", systemImage: "plus")
                }
                .help("Add a video or picture from this Mac")
            }
        }
        .searchable(text: $library.filter.query, placement: .toolbar, prompt: Text("Search Wallpapers"))
        .searchFocused($isSearchFocused)
        .onChange(of: searchRequests) { isSearchFocused = true }
        .fileImporter(
            isPresented: $isChoosingFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.importFiles(urls)
            return true
        }
        .sheet(isPresented: $isShowingOptions) {
            LiveWallpaperOptionsSheet(settings: settings, library: library)
        }
        .alert("Open a Site", isPresented: $isAskingAddress) {
            TextField("example.com", text: $typedAddress)
            Button("Open") {
                if let url = WallpaperSite.url(fromTyped: typedAddress) { library.openBrowser(at: url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the address of a site with wallpapers.")
        }
        .alert("Rename Wallpaper", isPresented: isRenaming) {
            TextField("Name", text: $newTitle)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Some Files Were Not Added", isPresented: hasImportProblems) {
            Button("OK") { library.importProblems = [] }
        } message: {
            Text(library.importProblems.joined(separator: "\n\n"))
        }
        .alert("Removed from the Library", isPresented: hasRemovedProblems) {
            Button("OK") { library.removedProblems = [] }
        } message: {
            Text(library.removedProblems.joined(separator: "\n\n"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in
            displays = DisplayInfo.connected()
            library.playbackChanged()
        }
        .onAppear {
            // The agent or the player may have turned the tweak off or changed the displays' wallpapers while another
            // page showed, and the library asks the settings which copies the displays need.
            settings.reloadLiveWallpaper()
            library.settings = settings
            library.reload()
        }
    }

    // MARK: Sections

    /// What the chosen display shows now, laid out as the top of Wallpaper in System Settings: the picture on the left,
    /// and beside it rows of what it is, how it covers the screen with its heart and menu, and the pause switch.
    private var currentSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                WallpaperThumbnail(entry: currentEntry, library: library, playsOnHover: true)
                    .frame(width: Self.currentWidth)
                    // As tall as the rows beside it, cropped to fill, as the system's own picture is.
                    .frame(maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    Divider()
                    if let entry = currentEntry {
                        fitRow(entry)
                        Divider()
                    }
                    pauseRow
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if displays.count > 1 {
                Toggle(isOn: sameOnAll) {
                    Text("Same on All Displays")
                }
                if !settings.liveWallpaperAssignments.sameOnAll {
                    Picker("Display", selection: displayBinding) {
                        ForEach(displays) { display in
                            Text(display.name).tag(display.key)
                        }
                    }
                }
            }
        }
    }

    private static let currentWidth: CGFloat = 196
    /// The space above and below each of the rows beside the picture, as a form's own rows have.
    private static let rowPadding: CGFloat = 7

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let entry = currentEntry {
                // One line: a long file name cut at the end rather than wrapped, and shown in full
                // on hover.
                Text(entry.wallpaper.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.wallpaper.title)
                Text(Self.summary(of: entry.wallpaper))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No Wallpaper Chosen")
                    .font(.headline)
                Text("Choose one from the library below, or add your own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Self.rowPadding)
    }

    /// How the wallpaper covers the screen, as the system's popup on the right, then its heart and menu. All three are
    /// borderless, as the controls in the rows of System Settings › Wallpaper are.
    private func fitRow(_ entry: LibraryIndex.Entry) -> some View {
        let id = entry.wallpaper.id
        let isFavourite = library.isFavourite(id)
        return HStack(spacing: 10) {
            Text("Fit")
            Spacer(minLength: 8)
            Picker("Fit", selection: fit) {
                ForEach(VideoFit.allCases, id: \.self) { fit in
                    Text(Self.title(of: fit)).tag(fit)
                }
            }
            .labelsHidden()
            .fixedSize()
            // Off means grey, as on the other pages; choosing a wallpaper below turns it back on.
            .disabled(!settings.liveWallpaperEnabled)
            Button {
                library.setFavourite(id, !isFavourite)
            } label: {
                Label(
                    isFavourite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavourite ? "heart.fill" : "heart"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(isFavourite ? "Remove from Favorites" : "Add to Favorites")
            Menu {
                Button("Rename…") {
                    newTitle = entry.wallpaper.title
                    renaming = id
                }
                Button("Show in Finder") { library.showInFinder(id) }
                if let page = entry.wallpaper.pageURL {
                    Button("Open Its Page") { library.openBrowser(at: page) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this wallpaper")
        }
        .padding(.vertical, Self.rowPadding)
    }

    private var pauseRow: some View {
        Toggle(isOn: $settings.liveWallpaperPauseRules.whenHidden) {
            Text("Pause in Full Screen")
            Text(
                "The video resumes from the same frame."
            )
        }
        .disabled(!settings.liveWallpaperEnabled)
        .padding(.top, Self.rowPadding)
    }

    /// How heavily wallpapers play: the size, with no larger than the display as the default, and economy mode, as the
    /// system's decoder costs most and follows the frame size and
    /// rate. Measured on a 4K video, its decoder held 199 MB at 3840×2160 and 104 MB at a MacBook Air's panel, and 179
    /// against 284 MB at 30 and 60 frames a second. A group of its own: beside the picture it made
    /// the rows so tall that the picture turned square.
    private var playbackSection: some View {
        Section {
            Picker(selection: $settings.liveWallpaperPlaybackSize) {
                Text(Self.title(of: PlaybackSize.display)).tag(PlaybackSize.display)
                Divider()
                ForEach([PlaybackSize.fullHD, .quadHD, .ultraHD], id: \.self) { size in
                    Text(Self.title(of: size)).tag(size)
                }
                Divider()
                Text(Self.title(of: PlaybackSize.original)).tag(PlaybackSize.original)
            } label: {
                Text("Resolution")
                Text("Larger videos and pictures shrink to use less memory.")
            }
            .disabled(!settings.liveWallpaperEnabled)
            .onChange(of: settings.liveWallpaperPlaybackSize) { library.playbackChanged() }
            Toggle(isOn: $settings.liveWallpaperEconomy) {
                Text("Economy Mode")
                Text(
                    "Up to 30 frames a second: less load on the processor and memory."
                )
            }
            .disabled(!settings.liveWallpaperEnabled)
            .onChange(of: settings.liveWallpaperEconomy) { library.playbackChanged() }
        }
    }

    private var librarySection: some View {
        Section {
            if library.importsInProgress > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding…").foregroundStyle(.secondary)
                }
            }
            if library.all.isEmpty {
                Text("No wallpapers yet. Find them on a site below, or add your own videos and pictures.")
                    .foregroundStyle(.secondary)
            } else if library.shown.isEmpty {
                Text("No wallpapers match the search and filters.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Self.columns, spacing: 14) {
                addTile
                ForEach(library.shown, id: \.wallpaper.id) { entry in
                    tile(entry)
                }
            }
            .padding(.vertical, 4)
        } header: {
            SectionTitle(
                title: Text("Library"),
                detail: Text("Downloaded and added wallpapers. Click one to put it on the desktop."))
        }
    }

    /// First in the grid, where it never moves: the shape of a wallpaper with a plus, as a tile of its own.
    private var addTile: some View {
        LookChoice(title: String(localized: "Add…"), isSelected: false, keepsToOneLine: true) {
            isChoosingFiles = true
        } preview: {
            // Clear space of a wallpaper's shape takes the width it is given, so the tile is as tall as the others.
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.title)
                        .fontWeight(.light)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
        .help("Add a video or picture from this Mac. Files can also be dropped on this page.")
        .accessibilityLabel(Text("Add Wallpaper…"))
    }

    private func tile(_ entry: LibraryIndex.Entry) -> some View {
        let id = entry.wallpaper.id
        return LookChoice(
            title: entry.wallpaper.title, isSelected: currentEntry?.wallpaper.id == id, keepsToOneLine: true
        ) {
            choose(id)
        } preview: {
            WallpaperThumbnail(entry: entry, library: library, playsOnHover: true)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    if let fraction = library.optimizing[id] {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                            .padding(8)
                            .help("Making the video lighter to play: \(Int(fraction * 100))%")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if library.isFavourite(id) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
        }
        .help(Self.summary(of: entry.wallpaper))
        .contextMenu {
            Button("Set as Wallpaper") { choose(id) }
            if library.isFavourite(id) {
                Button("Remove from Favorites") { library.setFavourite(id, false) }
            } else {
                Button("Add to Favorites") { library.setFavourite(id, true) }
            }
            Button("Rename…") {
                newTitle = entry.wallpaper.title
                renaming = id
            }
            Divider()
            Button("Show in Finder") { library.showInFinder(id) }
            if let page = entry.wallpaper.pageURL {
                Button("Open Its Page") { library.openBrowser(at: page) }
            }
            Divider()
            Button("Delete", role: .destructive) { library.remove(id) }
        }
        .accessibilityAction(named: Text(library.isFavourite(id) ? "Remove from Favorites" : "Add to Favorites")) {
            library.setFavourite(id, !library.isFavourite(id))
        }
    }

    /// The chosen sites, each opening in the app's own browser.
    private var sitesSection: some View {
        Section {
            ForEach(WallpaperSite.builtIn) { site in
                LinkRow(
                    symbol: site.offers.contains(.video) ? "play.rectangle" : "photo", title: Text(site.name),
                    detail: Text(Self.describe(site)), action: { library.openBrowser(at: site.address) }
                ) {
                    EmptyView()
                }
            }
            LinkRow(symbol: "globe", title: Text("Other Site…"), action: { isAskingAddress = true }) {
                EmptyView()
            }
        } header: {
            SectionTitle(
                title: Text("Find Wallpapers"),
                detail: Text(
                    "Opens the site in a browser window. You download wallpapers yourself, under the site’s own terms, for your own desktop; videos and pictures go into the library."
                ))
        }
    }

    private var restoredSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Open Wallpaper Settings…") {
                        if let url = URL(string: Self.wallpaperSettings) { NSWorkspace.shared.open(url) }
                    }
                    Button {
                        UserDefaults.standard.removeObject(forKey: DesktopPicture.restoredDefaultKey)
                        restoredDefault = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss"))
                }
            } label: {
                Text("Your Earlier Wallpaper")
                Text(
                    "The system’s own wallpaper is back. If you had an Aerial or a rotating one before, choose it again in Wallpaper settings."
                )
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $library.filter.collection) {
                Text("All Wallpapers").tag(WallpaperCollection.all)
                Text("Favorites").tag(WallpaperCollection.favourites)
                Text("Downloaded").tag(WallpaperCollection.downloaded)
                Text("Added by Me").tag(WallpaperCollection.imported)
            }
            .pickerStyle(.inline)
            Picker("Kind", selection: $library.filter.kind) {
                Text("Videos and Pictures").tag(Wallpaper.Kind?.none)
                Text("Videos").tag(Wallpaper.Kind?.some(.video))
                Text("Pictures").tag(Wallpaper.Kind?.some(.picture))
            }
            .pickerStyle(.menu)
            Picker("Resolution", selection: $library.filter.minimumResolution) {
                Text("Any").tag(Resolution.low)
                Text("Full HD and Higher").tag(Resolution.fullHD)
                Text("1440p and Higher").tag(Resolution.quadHD)
                Text("4K and Higher").tag(Resolution.ultraHD)
            }
            .pickerStyle(.menu)
            Menu("Shape") {
                ForEach(AspectRatio.allCases, id: \.self) { aspect in
                    Toggle(Self.title(of: aspect), isOn: shows(aspect))
                }
            }
            if !library.sites.isEmpty {
                Picker("Site", selection: $library.filter.site) {
                    Text("Any Site").tag(String?.none)
                    ForEach(library.sites, id: \.self) { site in
                        Text(site).tag(String?.some(site))
                    }
                }
                .pickerStyle(.menu)
            }
            Divider()
            Button("Reset Filters") {
                library.filter = WallpaperFilter(query: library.filter.query)
            }
            .disabled(!library.filter.narrows && library.filter.collection == .all)
        } label: {
            Label(
                "Filter",
                systemImage: library.filter.narrows || library.filter.collection != .all
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Show only some wallpapers")
    }

    // MARK: State

    private var displayKey: String? {
        selectedDisplay ?? displays.first?.key
    }

    private var currentEntry: LibraryIndex.Entry? {
        guard let displayKey, let choice = settings.liveWallpaperAssignments.choice(forDisplay: displayKey) else {
            return nil
        }
        return library.entry(choice.wallpaperID)
    }

    private func choose(_ id: String) {
        guard let displayKey else { return }
        library.choose(id, forDisplay: displayKey)
        restoredDefault = false
    }

    /// Turning it off may give the system's default picture back, which the agent notes a moment later.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.liveWallpaperEnabled },
            set: { isOn in
                settings.liveWallpaperEnabled = isOn
                if isOn {
                    settings.liveWallpaperStopReason = nil
                    UserDefaults.standard.removeObject(forKey: DesktopPicture.restoredDefaultKey)
                    restoredDefault = false
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        restoredDefault = UserDefaults.standard.bool(forKey: DesktopPicture.restoredDefaultKey)
                    }
                }
            })
    }

    private var fit: Binding<VideoFit> {
        Binding(
            get: {
                displayKey.flatMap { settings.liveWallpaperAssignments.choice(forDisplay: $0)?.fit } ?? .fill
            },
            set: { newFit in
                guard let displayKey else { return }
                settings.liveWallpaperAssignments.setFit(newFit, forDisplay: displayKey)
            })
    }

    private var sameOnAll: Binding<Bool> {
        Binding(
            get: { settings.liveWallpaperAssignments.sameOnAll },
            set: { same in
                var assignments = settings.liveWallpaperAssignments
                assignments.setSameOnAll(same, displays: displays.map(\.key))
                settings.liveWallpaperAssignments = assignments
            })
    }

    private var displayBinding: Binding<String> {
        Binding(get: { displayKey ?? "" }, set: { selectedDisplay = $0 })
    }

    private func shows(_ aspect: AspectRatio) -> Binding<Bool> {
        Binding(
            get: { library.filter.aspects.contains(aspect) },
            set: { isOn in
                if isOn {
                    library.filter.aspects.insert(aspect)
                } else {
                    library.filter.aspects.remove(aspect)
                }
            })
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var hasImportProblems: Binding<Bool> {
        Binding(get: { !library.importProblems.isEmpty }, set: { if !$0 { library.importProblems = [] } })
    }

    /// Wallpapers from before the safety check that did not pass it, and left the library.
    private var hasRemovedProblems: Binding<Bool> {
        Binding(get: { !library.removedProblems.isEmpty }, set: { if !$0 { library.removedProblems = [] } })
    }

    // MARK: Words

    static func describe(_ reason: LiveWallpaperStopReason) -> String {
        switch reason {
        case .fileMissing(let title):
            String(
                localized: "Turned off: the file of “\(title)” is gone. Choose another wallpaper and turn it back on.")
        case .unplayable(let title):
            String(
                localized: "Turned off: “\(title)” could not be played. Choose another wallpaper and turn it back on.")
        case .stoppedUnexpectedly:
            String(localized: "Turned off after the player stopped unexpectedly twice. Turn it on to try again.")
        }
    }

    private static func describe(_ site: WallpaperSite) -> String {
        switch site.id {
        case "moewalls": String(localized: "Live wallpapers from anime and games")
        case "motionbgs": String(localized: "Live wallpapers from games, films and anime")
        case "pexels", "pixabay": String(localized: "Free videos: nature, cities, abstract")
        case "mixkit": String(localized: "Free short videos")
        default: String(localized: "Pictures")
        }
    }

    static func summary(of wallpaper: Wallpaper) -> String {
        var parts = [wallpaper.kind == .video ? String(localized: "Video") : String(localized: "Picture")]
        parts.append("\(wallpaper.width)×\(wallpaper.height)")
        if wallpaper.kind == .video, wallpaper.duration > 0 {
            parts.append(Duration.seconds(wallpaper.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
        }
        if let site = wallpaper.site { parts.append(site) }
        return parts.joined(separator: " · ")
    }

    private static func title(of size: PlaybackSize) -> String {
        switch size {
        case .display: String(localized: "Same as Display")
        case .fullHD: String(localized: "Full HD (1080p)")
        case .quadHD: String(localized: "2K (1440p)")
        case .ultraHD: String(localized: "4K (2160p)")
        case .original: String(localized: "Original", comment: "Resolution of a wallpaper as its file came")
        }
    }

    private static func title(of fit: VideoFit) -> String {
        switch fit {
        case .fill: String(localized: "Fill Screen")
        case .fit: String(localized: "Fit to Screen")
        case .stretch: String(localized: "Stretch to Fill Screen")
        }
    }

    private static func title(of aspect: AspectRatio) -> String {
        switch aspect {
        case .standard: String(localized: "Standard (16:9, 16:10)")
        case .wide: String(localized: "Wide (21:9)")
        case .superWide: String(localized: "Super Wide (32:9)")
        case .portrait: String(localized: "Portrait")
        case .square: String(localized: "Square")
        }
    }
}

/// A display, as the page names it.
struct DisplayInfo: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }

    static func connected() -> [DisplayInfo] {
        WallpaperFolder.screens.compactMap { screen in
            WallpaperFolder.key(of: screen).map { DisplayInfo(key: $0, name: screen.localizedName) }
        }
    }
}

/// A row that says what went wrong, with the system's warning symbol.
private struct WarningRow: View {
    let text: Text

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
        }
    }
}

/// A wallpaper's still picture, with its video playing over it while the pointer rests on it.
struct WallpaperThumbnail: View {
    /// Long enough that moving across the grid does not start every video on the way.
    private static let hoverDelay: Duration = .milliseconds(350)

    let entry: LibraryIndex.Entry?
    let library: WallpaperLibraryModel
    let playsOnHover: Bool
    @State private var isPlaying = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var loaded: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From the cache at once when it is there, so a tile seen before never flashes empty.
    private var image: NSImage? {
        loaded ?? entry.flatMap { library.thumbnails.cached($0.wallpaper.id) }
    }

    var body: some View {
        // The rectangle takes the size it is offered, and the picture fills it without changing that size.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if isPlaying, let entry, entry.wallpaper.kind == .video,
                    let url = WallpaperFolder.file(named: entry.fileName)
                {
                    HoverVideo(url: url)
                }
            }
            .clipped()
            .contentShape(.rect)
            // Decoded off the main thread, so a large library opens and scrolls without waiting for its pictures.
            // Again once the cleaner has written the wallpaper anew, with its thumbnail.
            .task(id: entry.map { "\($0.wallpaper.id) \($0.fileName) \($0.needsCleaning)" }) {
                guard let entry, library.thumbnails.cached(entry.wallpaper.id) == nil else { return }
                loaded = await library.thumbnails.load(entry)
            }
            .onHover { inside in
                // A file from before the safety check is not played here until the cleaner has written it anew.
                guard playsOnHover, !reduceMotion, entry?.wallpaper.kind == .video, entry?.needsCleaning == false
                else { return }
                hoverTask?.cancel()
                if inside {
                    hoverTask = Task {
                        try? await Task.sleep(for: Self.hoverDelay)
                        if !Task.isCancelled { isPlaying = true }
                    }
                } else {
                    isPlaying = false
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                isPlaying = false
            }
    }
}

/// A silent looping video in a layer, for as long as the view exists.
private struct HoverVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HoverVideoView {
        HoverVideoView(url: url)
    }

    func updateNSView(_ view: HoverVideoView, context: Context) {}

    static func dismantleNSView(_ view: HoverVideoView, coordinator: ()) {
        view.stop()
    }
}

///
/// It plays only while its window can be seen. A window minimized, sent to another Space or closed with the pointer
/// still on a tile gets no hover change, and the original, 4K perhaps, would go on decoding for nobody: so the player
/// lets go of the file there, and takes it again when the window is back.
private final class HoverVideoView: NSView {
    private let url: URL
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private let player = AVQueuePlayer()
    private var windowObservers: [NSObjectProtocol] = []
    private var isStopped = false

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                windowObservers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        let closing = name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.followWindow(closing: closing) }
                    })
            }
        }
        followWindow(closing: false)
    }

    private func followWindow(closing: Bool) {
        guard !isStopped else { return }
        if !closing, let window, window.occlusionState.contains(.visible) {
            guard looper == nil else { return }
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            player.play()
        } else {
            release()
        }
    }

    private func release() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
    }

    func stop() {
        isStopped = true
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        release()
    }
}

/// The rarer settings: when a video pauses beyond being unseen, and how much room downloads may take.
private struct LiveWallpaperOptionsSheet: View {
    @Bindable var settings: AppSettings
    let library: WallpaperLibraryModel
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingBrowsingData = false

    var body: some View {
        DetailsSheet(height: 540) {
            Section {
                Toggle(isOn: $settings.liveWallpaperPauseRules.onBattery) {
                    Text("Pause on Battery Power")
                }
                Toggle(isOn: $settings.liveWallpaperPauseRules.inLowPowerMode) {
                    Text("Pause in Low Power Mode")
                }
                Toggle(isOn: $settings.liveWallpaperPauseRules.whenHot) {
                    Text("Pause When the Mac Is Hot")
                    Text("When the system starts slowing the Mac down to cool it.")
                }
            } header: {
                SectionTitle(
                    title: Text("Pause"),
                    detail: Text("A video always stops while the screen is locked or the display sleeps."))
            }
            Section {
                Picker("Keep Downloads Up To", selection: $settings.liveWallpaperDownloadLimit) {
                    ForEach(DownloadLimit.choices, id: \.self) { limit in
                        Text(Self.title(of: limit)).tag(limit)
                    }
                }
                .onChange(of: settings.liveWallpaperDownloadLimit) { library.trimDownloads() }
                LabeledContent {
                    Button("Remove Downloads…") { isConfirmingRemoval = true }
                        .disabled(library.clearableCount == 0)
                } label: {
                    // Without the word "Zero", as every size in the app reads.
                    Text("Downloaded: \(Format.fileSize(UInt64(max(library.downloadedBytes, 0))))")
                    Text("Favorites, files you added and what is on a display stay.")
                }
            } header: {
                SectionTitle(
                    title: Text("Storage"),
                    detail: Text("The wallpapers used longest ago go first when downloads reach the limit."))
            }
            Section {
                LabeledContent {
                    Button("Clear…") { isConfirmingBrowsingData = true }
                } label: {
                    Text("Browsing Data")
                    Text("Sign-ins, cookies and the cache of the sites.")
                }
            }
        }
        .confirmationDialog(
            "Remove \(library.clearableCount) downloaded wallpapers?", isPresented: $isConfirmingRemoval
        ) {
            Button("Remove", role: .destructive) { library.clearDownloads() }
        } message: {
            Text("They can be downloaded again from their sites.")
        }
        .confirmationDialog("Clear browsing data?", isPresented: $isConfirmingBrowsingData) {
            Button("Clear", role: .destructive) {
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
                ) {}
            }
        } message: {
            Text("You will be signed out of the sites in the wallpaper browser.")
        }
    }

    private static func title(of limit: Int64?) -> String {
        guard let limit else { return String(localized: "No Limit") }
        return Format.fileSize(UInt64(max(limit, 0)))
    }
}
