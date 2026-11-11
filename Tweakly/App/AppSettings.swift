import AppKit
import CustomIconCore
import FanControlCore
import FinderMenuCore
import LiveWallpaperCore
import MouseCore
import Observation
import SystemMetrics
import TaskManagerCore
import WindowSwitcherCore

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case stacked, icon, value, symbol, filledSymbol, ring, ringValue, column, signal, line, bars, captionBar
    var id: String { rawValue }

    /// These draw recent readings, so they need one on every tick and not only on a change.
    var usesHistory: Bool { self == .line || self == .bars }
    var usesCaption: Bool { self == .stacked || self == .captionBar }
}

/// Where a label's name sits, relative to what is below it.
enum CaptionAlignment: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
}

/// The battery has styles of its own, because its charge reads best as the familiar icon.
enum BatteryBarStyle: String, CaseIterable, Identifiable {
    case glyph, number, side, sameAsOthers
    var id: String { rawValue }
}

enum UpdateInterval: Double, CaseIterable, Identifiable {
    case fast = 1
    case normal = 2
    case relaxed = 5
    var id: Double { rawValue }
}

/// How one metric looks and behaves in the menu bar.
struct MetricAppearance: Equatable {
    var style: MenuBarStyle
    var alignment: CaptionAlignment
    var interval: UpdateInterval
}

enum AppLanguage: String, CaseIterable, Identifiable {
    // Listed in the pickers in this order: English, then the other Latin and Cyrillic scripts, then the rest.
    case system, en, de, ru, ja
    case zhHans = "zh-Hans"
    var id: String { rawValue }

    /// The app's own translation this stands for. The system's list comes from where the system keeps it, because the
    /// list this process sees can be set to something else by another of these settings.
    var localization: String {
        guard self == .system else { return rawValue }
        let list =
            CFPreferencesCopyValue(
                "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost) as? [String] ?? []
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: list).first ?? "en"
    }

    /// Its strings, whichever language this process runs in.
    var bundle: Bundle {
        Bundle.main.url(forResource: localization, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main
    }

    /// What the menu bar's items say, in the same process as popovers that can speak another language. Looked up once,
    /// because a label asks on every update and this changes only with a restart.
    static let menuBarBundle = AppSettings.savedMenuBarLanguage.bundle
}

/// What the simple view's popover shows: one figure for each metric, or the main parts of each.
enum SimpleViewLook: String, CaseIterable, Identifiable {
    case rings, list
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rings: String(localized: "Rings")
        case .list: String(localized: "List")
        }
    }
}

/// As the system is, or light or dark regardless.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    /// Nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User preferences. Every change is saved at once and reported through `onChange`.
@Observable final class AppSettings {
    private enum Key {
        static let metrics = "enabledMetrics"
        static let style = "menuBarStyle"
        static let alignment = "captionAlignment"
        static let batteryStyle = "batteryStyle"
        static let batteryCharging = "colorsBatteryWhileCharging"
        static let interval = "updateInterval"
        static let appIcon = "showAppIcon"
        static let simpleView = "simpleViewEnabled"
        static let simpleViewMetrics = "simpleViewMetrics"
        static let fanSettings = "fanSettings"
        static let fansShowTemperature = "fansShowTemperature"
        static let simpleViewLook = "simpleViewLook"
        static let simpleViewIcon = "simpleViewIcon"
        static let simpleViewIconOwnColours = "simpleViewIconOwnColours"
        static let iconMotionMode = "iconMotionMode"
        static let iconLoopSpeed = "iconLoopSpeed"
        static let iconIdleSpeed = "iconIdleSpeed"
        static let iconBusySpeed = "iconBusySpeed"
        static let iconLoadSource = "iconLoadSource"
        static let iconFills = "iconFills"
        static let iconFillSource = "iconFillSource"
        static let windowSwitcher = "windowSwitcherEnabled"
        static let switcherFitsBackground = "switcherFitsBackground"
        static let switcherPanelDelay = "switcherPanelDelay"
        static let switcherTileHeight = "switcherTileHeight"
        static let switcherCapturesAtOnce = "switcherCapturesAtOnce"
        static let switcherRetakeAfter = "switcherRetakeAfter"
        static let switcherKeepSharp = "switcherKeepSharp"
        static let switcherSavesCompressed = "switcherSavesCompressed"
        static let switcherCompression = "switcherCompression"
        static let switcherShowsPreviews = "switcherShowsPreviews"
        static let switcherShowsOtherDesktops = "switcherShowsOtherDesktops"
        static let switcherShowsMinimized = "switcherShowsMinimized"
        static let switcherShowsWindowlessApps = "switcherShowsWindowlessApps"
        static let dock = "dockEnabled"
        static let mouse = "mouseEnabled"
        static let mouseSettings = "mouseSettings"
        static let dockShowsPanel = "dockShowsPanel"
        static let dockDelay = "dockDelay"
        static let dockTileHeight = "dockTileHeight"
        static let dockClickAction = "dockClickAction"
        static let finderCut = "finderCutEnabled"
        static let finderCutConfirmation = "finderCutShowsConfirmation"
        static let finderMenu = "finderMenuEnabled"
        static let finderMenuItems = "finderMenuItems"
        static let finderMenuStopReason = "finderMenuStopReason"
        static let keyboardCleaning = "keyboardCleaningSeconds"
        static let languageSwitch = "languageSwitchEnabled"
        static let volumeMixer = "volumeMixerEnabled"
        static let volumeMixerShowsInput = "volumeMixerShowsInput"
        static let volumeMixerScrolls = "volumeMixerScrolls"
        static let volumeMixerBoosts = "volumeMixerBoosts"
        static let taskManager = "taskManagerEnabled"
        static let taskManagerShortcut = "taskManagerShortcut"
        static let liveWallpaper = "liveWallpaperEnabled"
        static let liveWallpaperAssignments = "liveWallpaperAssignments"
        static let liveWallpaperPauseRules = "liveWallpaperPauseRules"
        static let liveWallpaperEconomy = "liveWallpaperEconomy"
        static let liveWallpaperPlaybackSize = "liveWallpaperPlaybackSize"
        static let liveWallpaperDownloadLimit = "liveWallpaperDownloadLimit"
        static let liveWallpaperStopReason = "liveWallpaperStopReason"
        static let launched = "hasLaunchedBefore"
        static let languages = "AppleLanguages"
        static let agentLanguage = "agentLanguage"
        static let windowLanguage = "windowLanguage"
        static let menuBarLanguage = "menuBarLanguage"
        static let agentMenuBarLanguage = "agentMenuBarLanguage"
        static let appTheme = "appTheme"
        static let dockIconTheme = "dockIconTheme"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var isReloading = false

    var enabledMetrics: Set<MetricKind> {
        didSet { saved { $0.set(enabledMetrics.map(\.rawValue), forKey: Key.metrics) } }
    }

    /// One entry for every metric, so nothing has to deal with a missing one.
    var appearances: [MetricKind: MetricAppearance] {
        didSet {
            saved { defaults in
                for (kind, appearance) in appearances {
                    defaults.set(appearance.style.rawValue, forKey: Self.key(Key.style, kind))
                    defaults.set(appearance.alignment.rawValue, forKey: Self.key(Key.alignment, kind))
                    defaults.set(appearance.interval.rawValue, forKey: Self.key(Key.interval, kind))
                }
            }
        }
    }

    var batteryStyle: BatteryBarStyle {
        didSet { saved { $0.set(batteryStyle.rawValue, forKey: Key.batteryStyle) } }
    }

    var colorsBatteryWhileCharging: Bool {
        didSet { saved { $0.set(colorsBatteryWhileCharging, forKey: Key.batteryCharging) } }
    }

    var showAppIcon: Bool {
        didSet { saved { $0.set(showAppIcon, forKey: Key.appIcon) } }
    }

    /// One item in the menu bar with rings behind it, in place of an item for each metric.
    var simpleViewEnabled: Bool {
        didSet {
            saved { defaults in
                defaults.set(simpleViewEnabled, forKey: Key.simpleView)
                // From now on a metric is in it or not by choice, and turning one on elsewhere does not add it.
                if simpleViewEnabled, defaults.object(forKey: Key.simpleViewMetrics) == nil {
                    defaults.set(simpleViewMetrics.map(\.rawValue), forKey: Key.simpleViewMetrics)
                }
            }
        }
    }

    /// What the fans should do. Until someone chooses, the system keeps them and nothing about them runs.
    var fanSettings: FanSettings {
        didSet { saved { $0.set(try? JSONEncoder().encode(fanSettings), forKey: Key.fanSettings) } }
    }

    /// Whether the fans' item in the menu bar shows how hot it is rather than how fast they spin.
    var fansShowTemperature: Bool {
        didSet { saved { $0.set(fansShowTemperature, forKey: Key.fansShowTemperature) } }
    }

    /// For what asks every second, and only has to know whether anything changed.
    static var savedFanSettingsData: Data? {
        UserDefaults.standard.data(forKey: Key.fanSettings)
    }

    var simpleViewLook: SimpleViewLook {
        didSet { saved { $0.set(simpleViewLook.rawValue, forKey: Key.simpleViewLook) } }
    }

    /// What the simple view shows. Separate from `enabledMetrics`, which comes back when it is turned off.
    var simpleViewMetrics: Set<MetricKind> {
        didSet { saved { $0.set(simpleViewMetrics.map(\.rawValue), forKey: Key.simpleViewMetrics) } }
    }

    /// An icon from the library in place of the gear, or nil for the gear.
    var simpleViewIcon: String? {
        didSet { saved { $0.set(simpleViewIcon, forKey: Key.simpleViewIcon) } }
    }

    /// Whether an icon with colours keeps them, rather than taking the menu bar's one colour as the system's do.
    var simpleViewIconOwnColours: Bool {
        didSet { saved { $0.set(simpleViewIconOwnColours, forKey: Key.simpleViewIconOwnColours) } }
    }

    var iconMotion: IconMotion {
        didSet { saved { Self.write(iconMotion, to: $0) } }
    }

    /// Off until someone turns it on, because it needs permissions that are only asked for at that moment.
    var windowSwitcherEnabled: Bool {
        didSet { saved { $0.set(windowSwitcherEnabled, forKey: Key.windowSwitcher) } }
    }

    /// Its defaults are what was chosen by measuring.
    var switcherTuning: SwitcherTuning {
        didSet { saved { Self.write(switcherTuning, to: $0) } }
    }

    /// Off until someone turns it on, because it needs permissions that are only asked for at that moment.
    var dockEnabled: Bool {
        didSet { saved { $0.set(dockEnabled, forKey: Key.dock) } }
    }

    var dockTuning: DockTuning {
        didSet { saved { Self.write(dockTuning, to: $0) } }
    }

    /// Off until someone turns it on: it changes how a familiar device behaves.
    var mouseEnabled: Bool {
        didSet { saved { $0.set(mouseEnabled, forKey: Key.mouse) } }
    }

    /// Stored whole, as one change to it is one choice.
    var mouseSettings: MouseSettings {
        didSet { saved { $0.set(try? JSONEncoder().encode(mouseSettings), forKey: Key.mouseSettings) } }
    }

    /// Off until someone turns it on, for the same reason, and because it changes what familiar keys do.
    var finderCutEnabled: Bool {
        didSet { saved { $0.set(finderCutEnabled, forKey: Key.finderCut) } }
    }

    var finderCutShowsConfirmation: Bool {
        didSet { saved { $0.set(finderCutShowsConfirmation, forKey: Key.finderCutConfirmation) } }
    }

    /// Off until someone turns it on, as it adds to Finder's menus and loads an extension into Finder.
    var finderMenuEnabled: Bool {
        didSet { saved { $0.set(finderMenuEnabled, forKey: Key.finderMenu) } }
    }

    /// All of them until someone takes one away.
    var finderMenuItems: FinderMenuItems {
        didSet { saved { $0.set(Int(finderMenuItems.rawValue), forKey: Key.finderMenuItems) } }
    }

    /// Why the agent turned the Finder menu off, until it is turned on again.
    var finderMenuStopReason: FinderMenuStopReason? {
        didSet { saved { $0.set(finderMenuStopReason?.rawValue, forKey: Key.finderMenuStopReason) } }
    }

    /// Only the length is kept. Whether the keyboard is off never is, so nothing can bring that back after a restart.
    var keyboardCleaningSeconds: Int {
        didSet { saved { $0.set(keyboardCleaningSeconds, forKey: Key.keyboardCleaning) } }
    }

    /// Off until someone turns it on, as it needs Accessibility and changes what a press of Fn does.
    var languageSwitchEnabled: Bool {
        didSet { saved { $0.set(languageSwitchEnabled, forKey: Key.languageSwitch) } }
    }

    /// The volume mixer's item in the menu bar, see `VolumeMixerTweak`. Each app's own volume is kept apart, in
    /// `AudioRuleStore`, as a slider writes it many times a second.
    var volumeMixerEnabled: Bool {
        didSet { saved { $0.set(volumeMixerEnabled, forKey: Key.volumeMixer) } }
    }

    /// The input device and its volume in the mixer's popover.
    var volumeMixerShowsInput: Bool {
        didSet { saved { $0.set(volumeMixerShowsInput, forKey: Key.volumeMixerShowsInput) } }
    }

    /// Scrolling over the mixer's item changes the volume, as on the keys.
    var volumeMixerScrolls: Bool {
        didSet { saved { $0.set(volumeMixerScrolls, forKey: Key.volumeMixerScrolls) } }
    }

    /// Apps' sliders reach twice their own volume.
    var volumeMixerBoosts: Bool {
        didSet { saved { $0.set(volumeMixerBoosts, forKey: Key.volumeMixerBoosts) } }
    }

    /// Whether a keyboard shortcut opens the task manager from any app. On from the start, as Windows has it: macOS gives
    /// the shortcut no meaning of its own, and holding it costs nothing.
    var taskManagerEnabled: Bool {
        didSet { saved { $0.set(taskManagerEnabled, forKey: Key.taskManager) } }
    }

    var taskManagerShortcut: KeyShortcut {
        didSet { saved { Self.write(taskManagerShortcut, to: $0) } }
    }

    /// Off until someone turns it on. While on, a process of its own plays the videos, see `LiveWallpaperTweak`.
    var liveWallpaperEnabled: Bool {
        didSet { saved { $0.set(liveWallpaperEnabled, forKey: Key.liveWallpaper) } }
    }

    /// Which video each display plays.
    var liveWallpaperAssignments: DisplayAssignments {
        didSet {
            saved { $0.set(try? JSONEncoder().encode(liveWallpaperAssignments), forKey: Key.liveWallpaperAssignments) }
        }
    }

    var liveWallpaperPauseRules: PauseRules {
        didSet {
            saved { $0.set(try? JSONEncoder().encode(liveWallpaperPauseRules), forKey: Key.liveWallpaperPauseRules) }
        }
    }

    /// Videos faster than 30 frames a second play from a copy with fewer frames, see `EconomyMode`. Off until someone
    /// turns it on.
    var liveWallpaperEconomy: Bool {
        didSet { saved { $0.set(liveWallpaperEconomy, forKey: Key.liveWallpaperEconomy) } }
    }

    /// How large wallpapers are shown: no larger than each display by default, see `PlaybackSize`.
    var liveWallpaperPlaybackSize: PlaybackSize {
        didSet { saved { $0.set(liveWallpaperPlaybackSize.rawValue, forKey: Key.liveWallpaperPlaybackSize) } }
    }

    /// How much downloaded videos may take, in bytes; nil for no limit. Added files never count.
    var liveWallpaperDownloadLimit: Int64? {
        didSet { saved { $0.set(liveWallpaperDownloadLimit ?? 0, forKey: Key.liveWallpaperDownloadLimit) } }
    }

    /// Why the tweak turned itself off, shown on its page until it is turned on again.
    var liveWallpaperStopReason: LiveWallpaperStopReason? {
        didSet {
            saved { $0.set(try? JSONEncoder().encode(liveWallpaperStopReason), forKey: Key.liveWallpaperStopReason) }
        }
    }

    /// With nothing there, the window is the only way back to the app.
    var showsAnythingInMenuBar: Bool {
        // Only what this Mac has, or preferences brought from another Mac could leave no item and no window at all.
        simpleViewEnabled || showAppIcon || volumeMixerEnabled
            || !enabledMetrics.isDisjoint(with: MetricKind.available)
    }

    func appearance(of kind: MetricKind) -> MetricAppearance {
        appearances[kind] ?? MetricAppearance(style: .stacked, alignment: .center, interval: .normal)
    }

    /// The popovers and everything else the agent shows. Kept as the app's own language list, because that is what the
    /// system reads as the agent starts, and it takes effect on the next launch for that reason.
    var language: AppLanguage {
        didSet {
            if language == .system {
                defaults.removeObject(forKey: Key.languages)
            } else {
                defaults.set([language.rawValue], forKey: Key.languages)
            }
        }
    }

    /// The language the running agent started with, to tell whether a restart is pending. The window
    /// process cannot go by its own start, because it starts anew with the language already changed.
    @ObservationIgnored let agentLanguage: AppLanguage

    /// The window's process is told this as it starts, so it applies the next time the window opens.
    var windowLanguage: AppLanguage {
        didSet { saved { $0.set(windowLanguage.rawValue, forKey: Key.windowLanguage) } }
    }

    /// The captions and units on the menu bar's items. The agent reads this once, as it starts.
    var menuBarLanguage: AppLanguage {
        didSet { saved { $0.set(menuBarLanguage.rawValue, forKey: Key.menuBarLanguage) } }
    }

    @ObservationIgnored let agentMenuBarLanguage: AppLanguage
    @ObservationIgnored let startedWindowLanguage: AppLanguage

    var needsRestartForLanguage: Bool {
        language != agentLanguage || menuBarLanguage != agentMenuBarLanguage || windowLanguage != startedWindowLanguage
    }

    /// The window and the popovers. The window switcher's panel goes by the wallpaper behind it instead.
    var appTheme: AppTheme {
        didSet { saved { $0.set(appTheme.rawValue, forKey: Key.appTheme) } }
    }

    /// Only the Dock's tile, which exists while the window is open. Finder and Spotlight stay with the system's choice,
    /// because changing the icon inside the app would break its signature and with it the permissions.
    var dockIconTheme: AppTheme {
        didSet { saved { $0.set(dockIconTheme.rawValue, forKey: Key.dockIconTheme) } }
    }

    static var savedMenuBarLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: Key.menuBarLanguage).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static var savedWindowLanguage: AppLanguage {
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.string(forKey: Key.windowLanguage).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// For what appears now and then in the agent, which has no need to hold on to this.
    static var savedTheme: AppTheme {
        UserDefaults.standard.string(forKey: Key.appTheme).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    let isFirstLaunch: Bool

    init() {
        isFirstLaunch = !defaults.bool(forKey: Key.launched)
        defaults.set(true, forKey: Key.launched)

        enabledMetrics = Self.readMetrics(defaults)
        appearances = Self.readAppearances(defaults)
        batteryStyle = Self.readBatteryStyle(defaults)
        colorsBatteryWhileCharging = Self.readBatteryCharging(defaults)
        showAppIcon = Self.readAppIcon(defaults)
        simpleViewEnabled = defaults.bool(forKey: Key.simpleView)
        simpleViewMetrics = Self.readSimpleViewMetrics(defaults)
        fanSettings = Self.readFanSettings(defaults)
        fansShowTemperature = defaults.bool(forKey: Key.fansShowTemperature)
        simpleViewLook = Self.readSimpleLook(defaults)
        simpleViewIcon = defaults.string(forKey: Key.simpleViewIcon)
        simpleViewIconOwnColours = defaults.bool(forKey: Key.simpleViewIconOwnColours)
        iconMotion = Self.readIconMotion(defaults)
        windowSwitcherEnabled = defaults.bool(forKey: Key.windowSwitcher)
        switcherTuning = Self.readSwitcherTuning(defaults)
        dockEnabled = defaults.bool(forKey: Key.dock)
        dockTuning = Self.readDockTuning(defaults)
        mouseEnabled = defaults.bool(forKey: Key.mouse)
        mouseSettings = (Self.readJSON(Key.mouseSettings, defaults) ?? MouseSettings()).validated
        finderCutEnabled = defaults.bool(forKey: Key.finderCut)
        finderCutShowsConfirmation = defaults.object(forKey: Key.finderCutConfirmation) as? Bool ?? true
        finderMenuEnabled = defaults.bool(forKey: Key.finderMenu)
        finderMenuItems = Self.readFinderMenuItems(defaults)
        finderMenuStopReason = defaults.string(forKey: Key.finderMenuStopReason).flatMap(FinderMenuStopReason.init)
        keyboardCleaningSeconds = defaults.object(forKey: Key.keyboardCleaning) as? Int ?? 60
        languageSwitchEnabled = defaults.bool(forKey: Key.languageSwitch)
        volumeMixerEnabled = defaults.bool(forKey: Key.volumeMixer)
        volumeMixerShowsInput = defaults.object(forKey: Key.volumeMixerShowsInput) as? Bool ?? true
        volumeMixerScrolls = defaults.object(forKey: Key.volumeMixerScrolls) as? Bool ?? true
        volumeMixerBoosts = defaults.bool(forKey: Key.volumeMixerBoosts)
        taskManagerEnabled = defaults.object(forKey: Key.taskManager) as? Bool ?? true
        taskManagerShortcut = Self.readShortcut(defaults)
        liveWallpaperEnabled = defaults.bool(forKey: Key.liveWallpaper)
        liveWallpaperAssignments = Self.readJSON(Key.liveWallpaperAssignments, defaults) ?? DisplayAssignments()
        liveWallpaperPauseRules = Self.readJSON(Key.liveWallpaperPauseRules, defaults) ?? PauseRules()
        liveWallpaperEconomy = defaults.bool(forKey: Key.liveWallpaperEconomy)
        liveWallpaperPlaybackSize = Self.readPlaybackSize(defaults)
        liveWallpaperDownloadLimit = Self.readDownloadLimit(defaults)
        liveWallpaperStopReason = Self.readJSON(Key.liveWallpaperStopReason, defaults)

        // Only this app's own domain counts; the merged value always contains the system's list.
        let own = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Key.languages] as? [String]
        let resolvedLanguage = own?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = resolvedLanguage
        agentLanguage =
            defaults.string(forKey: Key.agentLanguage).flatMap(AppLanguage.init(rawValue:)) ?? resolvedLanguage
        let resolvedWindowLanguage = Self.readLanguage(Key.windowLanguage, inheriting: resolvedLanguage, defaults)
        let resolvedMenuBarLanguage = Self.readLanguage(Key.menuBarLanguage, inheriting: resolvedLanguage, defaults)
        windowLanguage = resolvedWindowLanguage
        startedWindowLanguage = resolvedWindowLanguage
        menuBarLanguage = resolvedMenuBarLanguage
        agentMenuBarLanguage =
            defaults.string(forKey: Key.agentMenuBarLanguage).flatMap(AppLanguage.init(rawValue:))
            ?? resolvedMenuBarLanguage
        appTheme = Self.readTheme(Key.appTheme, defaults)
        dockIconTheme = Self.readTheme(Key.dockIconTheme, defaults)
    }

    /// Called by the agent as it starts.
    func publishAgentLanguage() {
        defaults.set(language.rawValue, forKey: Key.agentLanguage)
        defaults.set(menuBarLanguage.rawValue, forKey: Key.agentMenuBarLanguage)
        defaults.synchronize()
    }

    /// The popover can change this while the window shows it.
    func reloadFanSettings() {
        defaults.synchronize()
        isReloading = true
        defer { isReloading = false }
        fanSettings = Self.readFanSettings(defaults)
    }

    /// The process that plays can turn the tweak off, and the agent too, while the window shows it.
    func reloadLiveWallpaper() {
        defaults.synchronize()
        let wasReloading = isReloading
        isReloading = true
        defer { isReloading = wasReloading }
        liveWallpaperEnabled = defaults.bool(forKey: Key.liveWallpaper)
        liveWallpaperAssignments = Self.readJSON(Key.liveWallpaperAssignments, defaults) ?? DisplayAssignments()
        liveWallpaperPauseRules = Self.readJSON(Key.liveWallpaperPauseRules, defaults) ?? PauseRules()
        liveWallpaperEconomy = defaults.bool(forKey: Key.liveWallpaperEconomy)
        liveWallpaperPlaybackSize = Self.readPlaybackSize(defaults)
        liveWallpaperDownloadLimit = Self.readDownloadLimit(defaults)
        liveWallpaperStopReason = Self.readJSON(Key.liveWallpaperStopReason, defaults)
    }

    /// For the process that plays, which only reads. Fresh from the disk each time, as another process wrote it.
    static func savedLiveWallpaper() -> (
        enabled: Bool, assignments: DisplayAssignments, rules: PauseRules, economy: Bool, size: PlaybackSize
    ) {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        return (
            defaults.bool(forKey: Key.liveWallpaper),
            readJSON(Key.liveWallpaperAssignments, defaults) ?? DisplayAssignments(),
            readJSON(Key.liveWallpaperPauseRules, defaults) ?? PauseRules(),
            defaults.bool(forKey: Key.liveWallpaperEconomy),
            readPlaybackSize(defaults)
        )
    }

    private static func readPlaybackSize(_ defaults: UserDefaults) -> PlaybackSize {
        defaults.string(forKey: Key.liveWallpaperPlaybackSize).flatMap(PlaybackSize.init(rawValue:)) ?? .display
    }

    /// Turns the tweak off from a process that holds no settings object, keeping the reason for the page.
    static func stopLiveWallpaper(because reason: LiveWallpaperStopReason, removing wallpaperID: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        if let wallpaperID {
            var assignments: DisplayAssignments =
                readJSON(Key.liveWallpaperAssignments, defaults) ?? DisplayAssignments()
            assignments.remove(wallpaperID)
            defaults.set(try? JSONEncoder().encode(assignments), forKey: Key.liveWallpaperAssignments)
        }
        defaults.set(false, forKey: Key.liveWallpaper)
        defaults.set(try? JSONEncoder().encode(reason), forKey: Key.liveWallpaperStopReason)
        defaults.synchronize()
    }

    private static func readJSON<Value: Decodable>(_ key: String, _ defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    /// Zero on disk means no limit; nothing means the standard one.
    private static func readDownloadLimit(_ defaults: UserDefaults) -> Int64? {
        guard let number = defaults.object(forKey: Key.liveWallpaperDownloadLimit) as? NSNumber else {
            return DownloadLimit.standard
        }
        return number.int64Value > 0 ? number.int64Value : nil
    }

    /// The menu in the menu bar can change this while the window shows it.
    func reloadSimpleLook() {
        defaults.synchronize()
        isReloading = true
        defer { isReloading = false }
        simpleViewLook = Self.readSimpleLook(defaults)
    }

    /// Picks up changes made by the other process.
    func reload() {
        defaults.synchronize()
        isReloading = true
        defer { isReloading = false }
        enabledMetrics = Self.readMetrics(defaults)
        appearances = Self.readAppearances(defaults)
        batteryStyle = Self.readBatteryStyle(defaults)
        colorsBatteryWhileCharging = Self.readBatteryCharging(defaults)
        showAppIcon = Self.readAppIcon(defaults)
        simpleViewEnabled = defaults.bool(forKey: Key.simpleView)
        simpleViewMetrics = Self.readSimpleViewMetrics(defaults)
        fanSettings = Self.readFanSettings(defaults)
        fansShowTemperature = defaults.bool(forKey: Key.fansShowTemperature)
        simpleViewLook = Self.readSimpleLook(defaults)
        simpleViewIcon = defaults.string(forKey: Key.simpleViewIcon)
        simpleViewIconOwnColours = defaults.bool(forKey: Key.simpleViewIconOwnColours)
        iconMotion = Self.readIconMotion(defaults)
        windowSwitcherEnabled = defaults.bool(forKey: Key.windowSwitcher)
        switcherTuning = Self.readSwitcherTuning(defaults)
        dockEnabled = defaults.bool(forKey: Key.dock)
        dockTuning = Self.readDockTuning(defaults)
        mouseEnabled = defaults.bool(forKey: Key.mouse)
        mouseSettings = (Self.readJSON(Key.mouseSettings, defaults) ?? MouseSettings()).validated
        finderCutEnabled = defaults.bool(forKey: Key.finderCut)
        finderCutShowsConfirmation = defaults.object(forKey: Key.finderCutConfirmation) as? Bool ?? true
        finderMenuEnabled = defaults.bool(forKey: Key.finderMenu)
        finderMenuItems = Self.readFinderMenuItems(defaults)
        finderMenuStopReason = defaults.string(forKey: Key.finderMenuStopReason).flatMap(FinderMenuStopReason.init)
        keyboardCleaningSeconds = defaults.object(forKey: Key.keyboardCleaning) as? Int ?? 60
        languageSwitchEnabled = defaults.bool(forKey: Key.languageSwitch)
        volumeMixerEnabled = defaults.bool(forKey: Key.volumeMixer)
        volumeMixerShowsInput = defaults.object(forKey: Key.volumeMixerShowsInput) as? Bool ?? true
        volumeMixerScrolls = defaults.object(forKey: Key.volumeMixerScrolls) as? Bool ?? true
        volumeMixerBoosts = defaults.bool(forKey: Key.volumeMixerBoosts)
        taskManagerEnabled = defaults.object(forKey: Key.taskManager) as? Bool ?? true
        taskManagerShortcut = Self.readShortcut(defaults)
        reloadLiveWallpaper()
        windowLanguage = Self.readLanguage(Key.windowLanguage, inheriting: language, defaults)
        menuBarLanguage = Self.readLanguage(Key.menuBarLanguage, inheriting: language, defaults)
        appTheme = Self.readTheme(Key.appTheme, defaults)
        dockIconTheme = Self.readTheme(Key.dockIconTheme, defaults)
    }

    /// Someone who chose a language when there was only one keeps it everywhere. It is written down at once, so that
    /// from then on changing one of them leaves the others as they are.
    private static func readLanguage(
        _ key: String, inheriting language: AppLanguage, _ defaults: UserDefaults
    ) -> AppLanguage {
        if let saved = defaults.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) { return saved }
        defaults.set(language.rawValue, forKey: key)
        return language
    }

    private static func readFanSettings(_ defaults: UserDefaults) -> FanSettings {
        var settings =
            defaults.data(forKey: Key.fanSettings).flatMap { try? JSONDecoder().decode(FanSettings.self, from: $0) }
            ?? FanSettings()
        // The page shows these as they are, and a number far outside what makes sense would stop it.
        settings.tuning = settings.tuning.validated
        return settings
    }

    /// Kept as the key and its modifiers, the numbers the system's hot key call takes.
    private static func readShortcut(_ defaults: UserDefaults) -> KeyShortcut {
        guard let numbers = defaults.array(forKey: Key.taskManagerShortcut) as? [Int], numbers.count == 2 else {
            return .standard
        }
        // Only what the recorder could have saved: a damaged key code would stop the agent at every launch, and a key
        // without Control or Option would take a letter from every app.
        let shortcut = KeyShortcut(keyCode: numbers[0], modifiers: numbers[1])
        guard (0...127).contains(shortcut.keyCode), shortcut.problem() == nil else { return .standard }
        return shortcut
    }

    private static func write(_ shortcut: KeyShortcut, to defaults: UserDefaults) {
        if shortcut == .standard {
            defaults.removeObject(forKey: Key.taskManagerShortcut)
        } else {
            defaults.set([shortcut.keyCode, shortcut.modifiers], forKey: Key.taskManagerShortcut)
        }
    }

    private static func readSimpleLook(_ defaults: UserDefaults) -> SimpleViewLook {
        defaults.string(forKey: Key.simpleViewLook).flatMap(SimpleViewLook.init(rawValue:)) ?? .rings
    }

    private static func readTheme(_ key: String, _ defaults: UserDefaults) -> AppTheme {
        defaults.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    private func saved(_ write: (UserDefaults) -> Void) {
        guard !isReloading else { return }
        write(defaults)
        // The other process reads these right after being told about the change.
        defaults.synchronize()
        onChange?()
    }

    /// What the agent changed by itself, for the window to show.
    func reloadFinderMenu() {
        isReloading = true
        defer { isReloading = false }
        defaults.synchronize()
        finderMenuEnabled = defaults.bool(forKey: Key.finderMenu)
        finderMenuStopReason = defaults.string(forKey: Key.finderMenuStopReason).flatMap(FinderMenuStopReason.init)
    }

    private static func readFinderMenuItems(_ defaults: UserDefaults) -> FinderMenuItems {
        guard let saved = defaults.object(forKey: Key.finderMenuItems) as? Int, let raw = UInt32(exactly: saved) else {
            return .all
        }
        return FinderMenuItems(rawValue: raw).intersection(.all)
    }

    private static func readMetrics(_ defaults: UserDefaults) -> Set<MetricKind> {
        // Fans are for someone who wants them: most people would only see a number that is usually zero.
        guard let saved = defaults.stringArray(forKey: Key.metrics) else {
            return Set(MetricKind.available).subtracting([.fans])
        }
        return Set(saved.compactMap(MetricKind.init(rawValue:)))
    }

    /// Until someone chooses, it holds what the menu bar shows now, or everything if that is nothing.
    private static func readSimpleViewMetrics(_ defaults: UserDefaults) -> Set<MetricKind> {
        if let saved = defaults.stringArray(forKey: Key.simpleViewMetrics) {
            return Set(saved.compactMap(MetricKind.init(rawValue:)))
        }
        let shown = readMetrics(defaults)
        return shown.isEmpty ? Set(MetricKind.available).subtracting([.fans]) : shown
    }

    private static func readIconMotion(_ defaults: UserDefaults) -> IconMotion {
        var motion = IconMotion()
        func number(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }
        if let mode = defaults.string(forKey: Key.iconMotionMode).flatMap(IconMotionMode.init(rawValue:)) {
            motion.mode = mode
        }
        if let source = defaults.string(forKey: Key.iconLoadSource).flatMap(IconLoadSource.init(rawValue:)) {
            motion.source = source
        }
        motion.fills = defaults.bool(forKey: Key.iconFills)
        if let source = defaults.string(forKey: Key.iconFillSource).flatMap(IconLoadSource.init(rawValue:)) {
            motion.fillSource = source
        }
        if let speed = number(Key.iconLoopSpeed) { motion.loopSpeed = speed }
        if let speed = number(Key.iconIdleSpeed) { motion.idleSpeed = speed }
        if let speed = number(Key.iconBusySpeed) { motion.busySpeed = speed }
        return motion.validated
    }

    private static func write(_ motion: IconMotion, to defaults: UserDefaults) {
        defaults.set(motion.mode.rawValue, forKey: Key.iconMotionMode)
        defaults.set(motion.source.rawValue, forKey: Key.iconLoadSource)
        defaults.set(motion.fills, forKey: Key.iconFills)
        defaults.set(motion.fillSource.rawValue, forKey: Key.iconFillSource)
        defaults.set(motion.loopSpeed, forKey: Key.iconLoopSpeed)
        defaults.set(motion.idleSpeed, forKey: Key.iconIdleSpeed)
        defaults.set(motion.busySpeed, forKey: Key.iconBusySpeed)
    }

    private static func key(_ name: String, _ kind: MetricKind) -> String {
        "\(name).\(kind.rawValue)"
    }

    private static func readSwitcherTuning(_ defaults: UserDefaults) -> SwitcherTuning {
        func has(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
        var tuning = SwitcherTuning()
        if has(Key.switcherPanelDelay) {
            tuning.panelDelayMilliseconds = defaults.integer(forKey: Key.switcherPanelDelay)
        }
        if has(Key.switcherTileHeight) { tuning.largestTileHeight = defaults.integer(forKey: Key.switcherTileHeight) }
        if has(Key.switcherFitsBackground) {
            tuning.fitsBackgroundToRows = defaults.bool(forKey: Key.switcherFitsBackground)
        }
        if has(Key.switcherCapturesAtOnce) {
            tuning.capturesAtOnce = defaults.integer(forKey: Key.switcherCapturesAtOnce)
        }
        if has(Key.switcherRetakeAfter) {
            tuning.retakeAfterSeconds = defaults.integer(forKey: Key.switcherRetakeAfter)
        }
        if has(Key.switcherKeepSharp) {
            tuning.keepSharpPicturesSeconds = defaults.integer(forKey: Key.switcherKeepSharp)
        }
        if has(Key.switcherSavesCompressed) {
            tuning.savesCompressedPictures = defaults.bool(forKey: Key.switcherSavesCompressed)
        }
        if has(Key.switcherCompression) { tuning.compressionQuality = defaults.double(forKey: Key.switcherCompression) }
        if has(Key.switcherShowsPreviews) { tuning.showsPreviews = defaults.bool(forKey: Key.switcherShowsPreviews) }
        if has(Key.switcherShowsOtherDesktops) {
            tuning.showsWindowsOnOtherDesktops = defaults.bool(forKey: Key.switcherShowsOtherDesktops)
        }
        if has(Key.switcherShowsMinimized) {
            tuning.showsMinimizedWindows = defaults.bool(forKey: Key.switcherShowsMinimized)
        }
        if has(Key.switcherShowsWindowlessApps) {
            tuning.showsAppsWithoutWindows = defaults.bool(forKey: Key.switcherShowsWindowlessApps)
        }
        return tuning.validated
    }

    private static func readDockTuning(_ defaults: UserDefaults) -> DockTuning {
        var tuning = DockTuning()
        if let shows = defaults.object(forKey: Key.dockShowsPanel) as? Bool { tuning.showsPanel = shows }
        if let delay = defaults.object(forKey: Key.dockDelay) as? Int { tuning.delayMilliseconds = delay }
        if let height = defaults.object(forKey: Key.dockTileHeight) as? Int { tuning.largestTileHeight = height }
        if let action = defaults.string(forKey: Key.dockClickAction).flatMap(DockTuning.ClickAction.init(rawValue:)) {
            tuning.clickAction = action
        }
        return tuning.validated
    }

    /// As with the switcher, a value left at its default is not stored.
    private static func write(_ tuning: DockTuning, to defaults: UserDefaults) {
        let standard = DockTuning()
        func store<Value: Equatable>(_ value: Value, _ original: Value, _ key: String) {
            if value == original { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
        store(tuning.showsPanel, standard.showsPanel, Key.dockShowsPanel)
        store(tuning.delayMilliseconds, standard.delayMilliseconds, Key.dockDelay)
        store(tuning.largestTileHeight, standard.largestTileHeight, Key.dockTileHeight)
        store(tuning.clickAction.rawValue, standard.clickAction.rawValue, Key.dockClickAction)
    }

    /// A value left at its default is not stored, so that a better default later reaches everyone who never changed it.
    private static func write(_ tuning: SwitcherTuning, to defaults: UserDefaults) {
        let standard = SwitcherTuning()
        func store<Value: Equatable>(_ value: Value, _ original: Value, _ key: String) {
            if value == original { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
        store(tuning.panelDelayMilliseconds, standard.panelDelayMilliseconds, Key.switcherPanelDelay)
        store(tuning.largestTileHeight, standard.largestTileHeight, Key.switcherTileHeight)
        store(tuning.fitsBackgroundToRows, standard.fitsBackgroundToRows, Key.switcherFitsBackground)
        store(tuning.capturesAtOnce, standard.capturesAtOnce, Key.switcherCapturesAtOnce)
        store(tuning.retakeAfterSeconds, standard.retakeAfterSeconds, Key.switcherRetakeAfter)
        store(tuning.keepSharpPicturesSeconds, standard.keepSharpPicturesSeconds, Key.switcherKeepSharp)
        store(tuning.savesCompressedPictures, standard.savesCompressedPictures, Key.switcherSavesCompressed)
        store(tuning.compressionQuality, standard.compressionQuality, Key.switcherCompression)
        store(tuning.showsPreviews, standard.showsPreviews, Key.switcherShowsPreviews)
        store(
            tuning.showsWindowsOnOtherDesktops, standard.showsWindowsOnOtherDesktops, Key.switcherShowsOtherDesktops)
        store(tuning.showsMinimizedWindows, standard.showsMinimizedWindows, Key.switcherShowsMinimized)
        store(tuning.showsAppsWithoutWindows, standard.showsAppsWithoutWindows, Key.switcherShowsWindowlessApps)
    }

    private static func readAppearances(_ defaults: UserDefaults) -> [MetricKind: MetricAppearance] {
        var result: [MetricKind: MetricAppearance] = [:]
        for kind in MetricKind.allCases {
            let style = defaults.string(forKey: key(Key.style, kind))
            let alignment = defaults.string(forKey: key(Key.alignment, kind))
            result[kind] = MetricAppearance(
                style: style.flatMap(MenuBarStyle.init(rawValue:)) ?? .stacked,
                alignment: alignment.flatMap(CaptionAlignment.init(rawValue:)) ?? .center,
                interval: UpdateInterval(rawValue: defaults.double(forKey: key(Key.interval, kind))) ?? .normal
            )
        }
        return result
    }

    private static func readBatteryStyle(_ defaults: UserDefaults) -> BatteryBarStyle {
        defaults.string(forKey: Key.batteryStyle).flatMap(BatteryBarStyle.init(rawValue:)) ?? .number
    }

    private static func readBatteryCharging(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.batteryCharging) as? Bool ?? true
    }

    private static func readAppIcon(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Key.appIcon)
    }
}
