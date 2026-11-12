import Observation
import SwiftUI
import SystemMetrics
import TipKit

enum MainPage: Hashable, Identifiable {
    case home
    case simpleView
    case metric(MetricKind)
    case windowSwitcher
    case dock
    case mouse
    case finderCut
    case finderMenu
    case keyboardCleaning
    case languageSwitch
    case liveWallpaper
    case taskManager
    case uninstaller
    case volumeMixer
    case settings
    case permissions
    case about

    #if TWEAKLY_AUTOMATION
        /// The automation commands name pages by their identifier.
        init?(rawValue: String) {
            switch rawValue {
            case "home": self = .home
            case "simpleView": self = .simpleView
            case "windowSwitcher": self = .windowSwitcher
            case "dock": self = .dock
            case "mouse": self = .mouse
            case "finderCut": self = .finderCut
            case "finderMenu": self = .finderMenu
            case "keyboardCleaning": self = .keyboardCleaning
            case "languageSwitch": self = .languageSwitch
            case "liveWallpaper": self = .liveWallpaper
            case "taskManager": self = .taskManager
            case "uninstaller": self = .uninstaller
            case "volumeMixer": self = .volumeMixer
            case "settings": self = .settings
            case "permissions": self = .permissions
            case "about": self = .about
            default:
                guard let kind = MetricKind(rawValue: rawValue) else { return nil }
                self = .metric(kind)
            }
        }
    #endif

    var id: String {
        switch self {
        case .home: "home"
        case .simpleView: "simpleView"
        case .metric(let kind): kind.rawValue
        case .windowSwitcher: "windowSwitcher"
        case .dock: "dock"
        case .mouse: "mouse"
        case .finderCut: "finderCut"
        case .finderMenu: "finderMenu"
        case .keyboardCleaning: "keyboardCleaning"
        case .languageSwitch: "languageSwitch"
        case .liveWallpaper: "liveWallpaper"
        case .taskManager: "taskManager"
        case .uninstaller: "uninstaller"
        case .volumeMixer: "volumeMixer"
        case .settings: "settings"
        case .permissions: "permissions"
        case .about: "about"
        }
    }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .simpleView: String(localized: "Simple View")
        case .metric(let kind): kind.pageTitle
        case .windowSwitcher: String(localized: "Window Switcher")
        case .dock: String(localized: "Dock Previews")
        case .mouse: String(localized: "Mouse")
        case .finderCut: String(localized: "Cut in Finder")
        case .finderMenu: String(localized: "Finder Menu")
        case .keyboardCleaning: String(localized: "Keyboard Cleaning")
        case .languageSwitch: String(localized: "Language Switch")
        case .liveWallpaper: String(localized: "Live Wallpaper")
        case .taskManager: String(localized: "Task Manager")
        case .uninstaller: String(localized: "App Uninstaller")
        case .volumeMixer: String(localized: "Volume Mixer")
        case .settings: String(localized: "Settings")
        case .permissions: String(localized: "Permissions")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .simpleView: "gauge.with.dots.needle.67percent"
        case .metric(let kind): kind.symbol
        case .windowSwitcher: "macwindow.on.rectangle"
        case .dock: "dock.rectangle"
        case .mouse: "computermouse"
        case .finderCut: "scissors"
        case .finderMenu: "contextualmenu.and.cursorarrow"
        case .keyboardCleaning: "keyboard"
        case .languageSwitch: "globe"
        case .liveWallpaper: "play.rectangle.on.rectangle"
        case .taskManager: "waveform.path.ecg.rectangle"
        case .uninstaller: "trash"
        case .volumeMixer: "slider.vertical.3"
        case .settings: "gearshape"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// What people might type to find this page: its title and the settings on it.
    private var searchTerms: [String] {
        switch self {
        case .home:
            [
                String(localized: "This Mac"), String(localized: "Chip"), String(localized: "Model"),
                String(localized: "Working the Hardest"),
            ]
        case .simpleView:
            [
                String(localized: "How to Show"), String(localized: "Rings"), String(localized: "List"),
                String(localized: "What to Show"), String(localized: "Show in Menu Bar"), String(localized: "Icon"),
                String(localized: "Icon Mode"), String(localized: "Fill with the Load"),
                String(localized: "Draw an Icon with AI"), "ChatGPT", "Claude", "SVG",
                "GIF",
            ]
        case .metric(let kind):
            [
                kind.title, kind.shortTitle, kind.menuBarDescription, String(localized: "Show in Menu Bar"),
                String(localized: "Style"), String(localized: "Name alignment"), String(localized: "Update every"),
            ] + kind.menuBarStyles.map(\.title)
                + (kind == .fans
                    ? [String(localized: "Profile"), String(localized: "Curve"), String(localized: "Fan Helper")] : [])
        case .windowSwitcher:
            [
                "Cmd-Tab", "Command-Tab", String(localized: "Accessibility"), String(localized: "Screen Recording"),
                String(localized: "Fit Background to Rows"), String(localized: "Panel Delay"),
                String(localized: "Tile Size"), String(localized: "Window Previews"),
                String(localized: "Windows on Other Desktops"), String(localized: "Minimized and Hidden Windows"),
                String(localized: "Apps with No Open Windows"), String(localized: "Captures at Once"),
                String(localized: "Picture Refresh"), String(localized: "Keep Sharp Pictures"),
                String(localized: "Save Compressed Pictures"), String(localized: "Compression Quality"),
                String(localized: "Advanced…"), String(localized: "Permissions"),
            ]
        case .dock:
            [
                "Dock", String(localized: "Window Previews"), String(localized: "Show Previews on Hover"),
                String(localized: "Delay"), String(localized: "Tile Size"), String(localized: "Click on the Icon"),
                String(localized: "Minimize"), String(localized: "Hide"), String(localized: "Accessibility"),
                String(localized: "Screen Recording"),
            ]
        case .mouse:
            [
                String(localized: "Pointer Acceleration"), String(localized: "Pointer Speed"),
                String(localized: "Scroll Direction"), String(localized: "Scroll Acceleration"),
                String(localized: "Lines per Notch"), String(localized: "Smooth Scrolling"),
                String(localized: "Side Buttons"), String(localized: "Back and Forward Everywhere"), "DPI",
            ]
        case .finderCut:
            [
                "Cmd-X", "Command-X", "Cmd-V", "Command-V", "Finder", String(localized: "Move"),
                String(localized: "Accessibility"), String(localized: "Permissions"), String(localized: "Keys"),
                String(localized: "Show Confirmation"),
            ]
        case .finderMenu:
            [
                "Finder", String(localized: "Shortcut Menu"), String(localized: "Right Click"),
                String(localized: "New File"), String(localized: "Copy Path"), String(localized: "Open in Terminal"),
                "Terminal", String(localized: "Finder Extension"), String(localized: "Items"),
            ]
        case .keyboardCleaning:
            [
                String(localized: "Start Cleaning"), String(localized: "Turn Back On After"),
                String(localized: "How to Turn It Back On"), String(localized: "Accessibility"),
                String(localized: "Permissions"),
            ]
        case .languageSwitch:
            [
                "Fn", "Globe", "🌐", String(localized: "Switch Language with Fn"),
                String(localized: "Input Source"), String(localized: "Keyboard Layout"),
                String(localized: "Previous Input Source"), String(localized: "Show Language at the Cursor"),
                String(localized: "Accessibility"), String(localized: "Permissions"), String(localized: "Keys"),
            ]
        case .liveWallpaper:
            [
                String(localized: "Wallpaper"), String(localized: "Desktop Picture"), String(localized: "Video"),
                String(localized: "Library"), String(localized: "Find Wallpapers"), String(localized: "Fill Screen"),
                String(localized: "Same on All Displays"), String(localized: "Pause in Full Screen"),
                String(localized: "Economy Mode"), String(localized: "Resolution"), "Full HD", "1080p", "1440p", "4K",
                String(localized: "Pause on Battery Power"),
                String(localized: "Pause in Low Power Mode"), String(localized: "Keep Downloads Up To"),
                "MoeWalls", "MotionBGs", "Pexels", "Pixabay", "Mixkit", "Wallhaven",
            ]
        case .taskManager:
            [
                "Ctrl-Shift-Esc", "Control-Shift-Escape", "Activity Monitor", String(localized: "Processes"),
                String(localized: "Performance"), String(localized: "End Task"), String(localized: "Force Quit"),
                String(localized: "Keyboard Shortcut"), String(localized: "Open Task Manager"),
                String(localized: "Keys"),
            ]
        case .uninstaller:
            [
                String(localized: "Uninstall…"), String(localized: "Reset…"), String(localized: "Move to Trash"),
                String(localized: "Data"), String(localized: "Cache"), String(localized: "Settings"),
                String(localized: "Background Item"), String(localized: "Full Disk Access…"), "App Store",
                String(localized: "Duplicate"), "Intel", "Uninstall", "Delete", "Remove", "Leftovers", "App Cleaner",
            ]
        case .volumeMixer:
            [
                String(localized: "Sound"), String(localized: "Volume"), String(localized: "Output"),
                String(localized: "Input"), String(localized: "Apps"), String(localized: "Muted"),
                String(localized: "Show the Microphone"), String(localized: "Boost Up to 200 %"),
                String(localized: "Scroll Over the Icon"), String(localized: "System Audio Recording"),
                "AirPods", "Bluetooth",
            ]
        case .settings:
            [
                String(localized: "Open at Login"), String(localized: "Show Tweakly Icon in Menu Bar"),
                String(localized: "Language"), String(localized: "Main Window"), String(localized: "Popovers"),
                String(localized: "Menu Bar Labels"), String(localized: "Appearance"), String(localized: "App Theme"),
                String(localized: "Dock Icon"),
            ]
        case .permissions:
            [
                String(localized: "Privacy & Security"), String(localized: "Accessibility"),
                String(localized: "Screen & System Audio Recording"), String(localized: "System Audio Recording Only"),
                String(localized: "Full Disk Access"), String(localized: "Files & Folders"),
                String(localized: "Login Items & Extensions"), String(localized: "Open at Login"),
                String(localized: "Finder Extension"), String(localized: "Tweakly Helper"),
                String(localized: "Administrator Rights"),
            ]
        case .about:
            ["Tweakly", String(localized: "Version"), String(localized: "Build"), String(localized: "Quit Tweakly")]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title] + searchTerms).contains { $0.localizedStandardContains(query) }
    }
}

@Observable final class MainRouter {
    /// Whether any of the window can be seen, for pages that have to keep asking the system about something.
    var isWindowVisible = true
    private(set) var page: MainPage = .home {
        didSet { onVisibilityNeeded?() }
    }
    private var pagesBehind: [MainPage] = []
    private var pagesAhead: [MainPage] = []

    var canGoBack: Bool { !pagesBehind.isEmpty }
    var canGoForward: Bool { !pagesAhead.isEmpty }

    func open(_ newPage: MainPage) {
        guard newPage != page else { return }
        pagesBehind.append(page)
        pagesAhead = []
        page = newPage
    }

    func goBack() {
        guard let previous = pagesBehind.popLast() else { return }
        pagesAhead.append(page)
        page = previous
    }

    func goForward() {
        guard let next = pagesAhead.popLast() else { return }
        pagesBehind.append(page)
        page = next
    }

    @ObservationIgnored var onVisibilityNeeded: (() -> Void)?
    /// Hidden as a whole or shown, as in Finder: macOS has no sidebar that folds down to its icons.
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var isSidebarHidden: Bool { sidebarVisibility == .detailOnly }
    var query = ""
    /// Raised to move the keyboard to the search field.
    var searchRequests = 0
    /// Raised to move the keyboard to a page's own search field in the toolbar: the task manager's or the
    /// uninstaller's.
    var toolbarSearchRequests = 0
    /// The welcome sheet, on first opening the window and from Help.
    var isWelcomeShown = false
    var welcomeStep: WelcomeStep = .features
    /// How tall a sheet can be in the window, kept up to date while one is shown.
    var windowContentHeight: CGFloat = 600
}

struct MainView: View {
    /// Fixed and as wide as in System Settings on macOS 27.2, whose search field then has the same length as ours.
    /// Wide enough for the longest page title in any language.
    private static let sidebarWidth: CGFloat = 271

    @Bindable var router: MainRouter
    let settings: AppSettings
    let data: StatsLiveData
    let cleaning: KeyboardCleaningController
    let taskManager: TaskManagerModel
    let uninstaller: UninstallerModel
    let wallpapers: WallpaperLibraryModel
    let access: SystemAccess

    var body: some View {
        // The sidebar hides with the system's own button, as in Finder, so the task manager can have the whole window.
        NavigationSplitView(columnVisibility: $router.sidebarVisibility) {
            Sidebar(
                router: router,
                taskManagerTip: settings.taskManagerEnabled
                    ? TaskManagerShortcutTip(shortcut: settings.taskManagerShortcut.displayText) : nil
            )
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            switch router.page {
            case .home:
                HomeView(
                    data: data, settings: settings, open: router.open)
            case .simpleView:
                SimpleViewPageView(settings: settings)
            case .metric(let kind):
                MetricPageView(
                    kind: kind, settings: settings, open: router.open, isWindowVisible: router.isWindowVisible
                )
                // Each metric's page starts from its own state, rather than inheriting the last one's.
                .id(kind)
            case .windowSwitcher:
                WindowSwitcherPageView(settings: settings)
            case .dock:
                DockPageView(settings: settings)
            case .mouse:
                MousePageView(settings: settings)
            case .finderCut:
                FinderCutPageView(settings: settings)
            case .finderMenu:
                FinderMenuPageView(settings: settings)
            case .keyboardCleaning:
                KeyboardCleaningPageView(settings: settings, cleaning: cleaning)
            case .languageSwitch:
                LanguageSwitchPageView(settings: settings)
            case .liveWallpaper:
                LiveWallpaperPageView(
                    settings: settings, library: wallpapers, searchRequests: router.toolbarSearchRequests)
            case .volumeMixer:
                VolumeMixerPageView(settings: settings)
            case .taskManager:
                TaskManagerPageView(
                    model: taskManager, settings: settings, searchRequests: router.toolbarSearchRequests)
            case .uninstaller:
                UninstallerPageView(
                    model: uninstaller,
                    searchRequests: router.toolbarSearchRequests)
            case .settings:
                SettingsView(settings: settings)
            case .permissions:
                PermissionsPageView(access: access, settings: settings)
            case .about:
                AboutView()
            }
        }
        .navigationTitle(router.page.title)
        .environment(access)
        .environment(router)
        .sheet(isPresented: $router.isWelcomeShown) {
            WelcomeView(router: router, settings: settings)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // The system's own pair of back and forward buttons, as in System Settings.
                ControlGroup {
                    Button(action: router.goBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!router.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    Button(action: router.goForward) {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!router.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                }
                .controlGroupStyle(.navigation)
            }
        }
    }
}

private struct Sidebar: View {
    /// A group of pages under a heading.
    private struct PageGroup {
        let title: String
        let pages: [MainPage]
    }

    /// Grouped by what each page is: the desktop, tools that are opened and used, as
    /// Activity Monitor is in Utilities, what the menu bar shows, tweaks that change how macOS itself behaves, and the
    /// app itself. The desktop and the tools come first, right under Home.
    private static var groups: [PageGroup] {
        [
            PageGroup(
                title: String(localized: "Desktop", comment: "Sidebar heading above Live Wallpaper"),
                pages: [.liveWallpaper]),
            PageGroup(
                title: String(localized: "Utilities", comment: "Sidebar heading, as the Utilities folder of macOS"),
                pages: [.taskManager, .uninstaller, .volumeMixer, .keyboardCleaning]),
            PageGroup(
                title: String(localized: "Statistics"),
                pages: [.simpleView] + MetricKind.available.map(MainPage.metric)),
            PageGroup(
                title: String(localized: "Tweaks"),
                pages: [.windowSwitcher, .dock, .mouse, .finderCut, .finderMenu, .languageSwitch]),
            PageGroup(title: String(localized: "Other"), pages: [.settings, .permissions, .about]),
        ]
    }

    @Bindable var router: MainRouter
    /// Beside the task manager, until its shortcut has been used.
    let taskManagerTip: TaskManagerShortcutTip?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let query = router.query
        let showsHome = MainPage.home.matches(query)
        let groups = Self.groups.compactMap { group in
            let pages = group.pages.filter { $0.matches(query) }
            return pages.isEmpty ? nil : PageGroup(title: group.title, pages: pages)
        }
        List(selection: selection) {
            if showsHome { row(.home) }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.pages) { row($0) }
                } header: {
                    Text(group.title)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !showsHome && groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $router.query, placement: .sidebar, prompt: Text("Search"))
        .searchFocused($isSearchFocused)
        .onChange(of: router.searchRequests) { isSearchFocused = true }
    }

    /// `.monochrome` is the system's own way of keeping sidebar icons from taking the accent colour.
    private func row(_ page: MainPage) -> some View {
        Label {
            Text(page.title)
        } icon: {
            // The battery is much wider than the other symbols, and would crowd its title at full size.
            Image(systemName: page.symbol)
                .imageScale(page == .metric(.battery) ? .small : .medium)
        }
        .listItemTint(.monochrome)
        .popoverTip(page == .taskManager ? taskManagerTip : nil, arrowEdge: .leading)
        .tag(page)
    }

    /// A sidebar selection can be cleared by the list, but a page must always be showing.
    private var selection: Binding<MainPage?> {
        Binding(
            get: { router.page },
            set: { if let page = $0 { router.open(page) } }
        )
    }
}
