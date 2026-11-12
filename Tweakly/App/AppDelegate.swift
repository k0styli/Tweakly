import AppKit
import SystemMetrics

/// The application delegate of the menu bar agent, the process that stays running.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusMenu = AppStatusMenu()
    private static let olderAgentGracePeriod: TimeInterval = 1
    /// How long a restart waits for the agent it replaces, which is told to quit once this one runs.
    private static let replacedAgentWait: TimeInterval = 5

    private let settings = AppSettings()
    private lazy var stats = StatsTweak(settings: settings, statusMenu: statusMenu)
    /// Exists only while the tweak is on, so a tweak that is off costs nothing.
    private var windowSwitcher: WindowSwitcherTweak?
    private var dock: DockTweak?
    private var mouse: MouseTweak?
    /// Shared by the two above while either is on.
    private var windowPictures: WindowPictureStore?
    private var finderCut: FinderCutTweak?
    private var finderMenu: FinderMenuTweak?
    /// Nil until the settings are first applied, so starting up never touches the system's setting for the extension.
    private var finderMenuWasEnabled: Bool?
    private var languageSwitch: LanguageSwitchTweak?
    private var taskManager: TaskManagerTweak?
    private var liveWallpaper: LiveWallpaperTweak?
    private var volumeMixer: VolumeMixerTweak?
    private var appItem: NSStatusItem?
    private var eventTokens: [Int32] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A restart for a new language replaces the old agent on purpose. It waits for that one to go, so the two never
        // hold the wallpaper, the apps' sound or the shortcuts at once, and the old one's putting back the desktop
        // picture as it quits does not undo this one's.
        if WindowProcess.shouldOpenOnLaunch {
            startAfterReplacedAgent(deadline: Date.now.addingTimeInterval(Self.replacedAgentWait))
            return
        }
        guard WindowProcess.olderAgent != nil else {
            start()
            return
        }
        // That agent may just be on its way out, in which case this one should simply take over.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.olderAgentGracePeriod) { [weak self] in
            if WindowProcess.olderAgent != nil {
                // Two agents would mean every menu bar item twice.
                NSApp.terminate(nil)
            } else {
                self?.start()
            }
        }
    }

    /// Checked a few times a second for a few seconds after a restart, and never otherwise.
    private func startAfterReplacedAgent(deadline: Date) {
        guard WindowProcess.olderAgent != nil, Date.now < deadline else {
            start()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startAfterReplacedAgent(deadline: deadline)
        }
    }

    private func start() {
        settings.publishAgentLanguage()
        settings.onChange = { [weak self] in self?.settingsChanged() }
        eventTokens = [
            ProcessEvents.observe(.settingsChanged) { [weak self] in
                self?.settings.reload()
                self?.settingsChanged()
            },
            ProcessEvents.observe(.quitAll) { NSApp.terminate(nil) },
            // The settings page takes the keys while it records a new shortcut.
            ProcessEvents.observe(.shortcutRecording) { [weak self] in self?.taskManager?.pause() },
            // The process that plays turned the tweak off, and has left by itself.
            ProcessEvents.observe(.liveWallpaperStopped) { [weak self] in
                self?.settings.reload()
                self?.settingsChanged()
            },
        ]
        settingsChanged()
        if WindowProcess.shouldOpenOnLaunch {
            WindowProcess.launch()
        } else if settings.isFirstLaunch || !settings.showsAnythingInMenuBar {
            WindowProcess.open()
        }
        #if TWEAKLY_AUTOMATION
            Automation.shared.startInAgent(
                stats: stats, settings: settings, windowSwitcher: { [weak self] in self?.windowSwitcher },
                dock: { [weak self] in self?.dock }, mouse: { [weak self] in self?.mouse },
                finderCut: { [weak self] in self?.finderCut },
                finderMenu: { [weak self] in self?.finderMenu },
                languageSwitch: { [weak self] in self?.languageSwitch },
                volumeMixer: { [weak self] in self?.volumeMixer })
        #endif
    }

    /// Launching an already running copy, or clicking it in Finder, is how people get back to the
    /// window when every menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowProcess.open()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func settingsChanged() {
        // The simple view's item and this one are the same gear under one name, so one goes before the other appears.
        let wantsAppItem = settings.showAppIcon && !settings.simpleViewEnabled
        if !wantsAppItem { removeAppItem() }
        stats.settingsChanged()
        if wantsAppItem { addAppItem() }
        updateWindowSwitcher()
        updateDock()
        updateWindowPictures()
        updateMouse()
        updateFinderCut()
        updateFinderMenu()
        updateLanguageSwitch()
        updateTaskManager()
        updateLiveWallpaper()
        updateVolumeMixer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The mouse goes back to the system's settings, which are what it will have without Tweakly.
        mouse?.stop()
        liveWallpaper?.stop()
        volumeMixer?.stop()
    }

    private func updateVolumeMixer() {
        guard settings.volumeMixerEnabled else {
            volumeMixer?.stop()
            volumeMixer = nil
            return
        }
        if volumeMixer == nil { volumeMixer = VolumeMixerTweak(statusMenu: statusMenu) }
        volumeMixer?.update(
            showsInput: settings.volumeMixerShowsInput, scrolls: settings.volumeMixerScrolls,
            boosts: settings.volumeMixerBoosts)
    }

    private func updateLiveWallpaper() {
        guard settings.liveWallpaperEnabled else {
            liveWallpaper?.stop()
            liveWallpaper = nil
            // A display that was away when the tweak went off gets its own picture back once it is here.
            if DesktopPicture.hasRemembered { DesktopPicture.restoreAll(on: WallpaperFolder.screens) }
            return
        }
        if liveWallpaper == nil {
            let tweak = LiveWallpaperTweak()
            tweak.onStopped = { [weak self] in
                self?.settings.reload()
                self?.settingsChanged()
            }
            liveWallpaper = tweak
        }
        liveWallpaper?.update(
            assignments: settings.liveWallpaperAssignments, playbackSize: settings.liveWallpaperPlaybackSize)
    }

    private func updateTaskManager() {
        guard settings.taskManagerEnabled else {
            taskManager?.stop()
            taskManager = nil
            return
        }
        if taskManager == nil { taskManager = TaskManagerTweak() }
        taskManager?.update(shortcut: settings.taskManagerShortcut)
    }

    private func updateLanguageSwitch() {
        guard settings.languageSwitchEnabled else {
            languageSwitch?.stop()
            languageSwitch = nil
            return
        }
        if languageSwitch == nil { languageSwitch = LanguageSwitchTweak() }
        languageSwitch?.update()
    }

    private func updateFinderCut() {
        guard settings.finderCutEnabled else {
            finderCut?.stop()
            finderCut = nil
            return
        }
        if finderCut == nil { finderCut = FinderCutTweak() }
        finderCut?.update(showsConfirmation: settings.finderCutShowsConfirmation)
    }

    private func updateFinderMenu() {
        let isOn = settings.finderMenuEnabled
        // Only the switch changing turns the extension on or off, so someone who turns it off in System Settings is not
        // overruled at the next launch. Off, Finder lets its process go, and the tweak costs nothing.
        if let wasOn = finderMenuWasEnabled, wasOn != isOn { FinderExtension.setEnabled(isOn) }
        finderMenuWasEnabled = isOn
        guard isOn else {
            finderMenu?.stop()
            finderMenu = nil
            return
        }
        if finderMenu == nil {
            let tweak = FinderMenuTweak()
            tweak.onStopped = { [weak self] reason in
                guard let self else { return }
                // The name is taken by another copy of this app, whose menu is the same extension: switching that off
                // would take Finder's menu from the copy that works.
                if reason == .nameTaken { finderMenuWasEnabled = false }
                // Off first, so the reason arriving does not start it again.
                settings.finderMenuEnabled = false
                settings.finderMenuStopReason = reason
                ProcessEvents.post(.finderMenuStopped)
            }
            finderMenu = tweak
            if settings.finderMenuStopReason != nil { settings.finderMenuStopReason = nil }
        }
        finderMenu?.update(items: settings.finderMenuItems)
    }

    private func updateWindowSwitcher() {
        guard settings.windowSwitcherEnabled else {
            windowSwitcher?.stop()
            windowSwitcher = nil
            return
        }
        if windowSwitcher == nil { windowSwitcher = WindowSwitcherTweak(pictures: sharedWindowPictures()) }
        windowSwitcher?.tuning = settings.switcherTuning
        windowSwitcher?.update()
    }

    private func updateDock() {
        guard settings.dockEnabled else {
            dock?.stop()
            dock = nil
            return
        }
        if dock == nil { dock = DockTweak(pictures: sharedWindowPictures()) }
        dock?.tuning = settings.dockTuning
        dock?.update()
    }

    private func updateMouse() {
        #if TWEAKLY_AUTOMATION
            // A test copy showing made-up data draws the mouse's page switched on, but must never change the mouse.
            let isOn = settings.mouseEnabled && !DemoData.isOn
        #else
            let isOn = settings.mouseEnabled
        #endif
        guard isOn else {
            mouse?.stop()
            mouse = nil
            // A run that ended without stopping the tweak may have left its values on the mice.
            MouseDevices.restoreLeftovers()
            return
        }
        if mouse == nil { mouse = MouseTweak() }
        mouse?.update(settings.mouseSettings)
    }

    private func sharedWindowPictures() -> WindowPictureStore {
        if let windowPictures { return windowPictures }
        let store = WindowPictureStore()
        store.tuning = settings.switcherTuning
        windowPictures = store
        return store
    }

    /// The pictures follow the switcher's settings even while only the Dock uses them, and go once neither does.
    private func updateWindowPictures() {
        guard windowSwitcher != nil || dock != nil else {
            windowPictures?.stop()
            windowPictures = nil
            return
        }
        windowPictures?.tuning = settings.switcherTuning
        windowPictures?.refreshPermission()
    }

    private func removeAppItem() {
        if let appItem { NSStatusBar.system.removeStatusItem(appItem) }
        appItem = nil
    }

    private func addAppItem() {
        guard appItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "tweakly.app"
        item.button?.image = NSImage(named: "MenuBarIcon")
        item.button?.setAccessibilityLabel("Tweakly")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        appItem = item
    }

    /// Built on demand, so the menu takes no memory until someone opens it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu.fill(menu)
    }
}
