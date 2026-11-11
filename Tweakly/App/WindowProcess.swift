import AppKit
import notify
import os

/// The main window runs in its own short-lived process, started from this same executable.
///
/// SwiftUI keeps its memory after a window closes: measured on macOS 27.2, the agent stayed at 44.7 MB
/// after one visit to the window, against 19 MB before it. A process that exits gives all of it back,
/// so the menu bar agent, which runs for days, never pays for a window it showed once.
enum WindowProcess {
    private static let flag = "--window"
    private static let openOnLaunchFlag = "--open-window"
    /// The same process shows the task manager, which then comes up first and alone.
    private static let taskManagerFlag = "--task-manager"
    private static let volumeMixerFlag = "--volume-mixer"

    static var isWindowProcess: Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static var shouldOpenOnLaunch: Bool { ProcessInfo.processInfo.arguments.contains(openOnLaunchFlag) }
    static var opensTaskManagerFirst: Bool { ProcessInfo.processInfo.arguments.contains(taskManagerFlag) }
    static var opensVolumeMixerFirst: Bool { ProcessInfo.processInfo.arguments.contains(volumeMixerFlag) }

    /// How long after asking an existing window process to show itself to check that it was not exiting.
    private static let exitCheckDelay: TimeInterval = 0.5

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "process")
    private static var isLaunching = false
    /// What was asked for while the window process was starting, such as the task manager's shortcut right after
    /// Open Tweakly, passed on once it runs.
    private static var askedWhileLaunching: ProcessEvents.Event?
    private static var isRelaunching = false

    /// Brings the window forward, starting its process if needed.
    static func open() {
        open(.showWindow, launchArguments: [])
    }

    /// Brings the task manager forward, in the window's process, starting that if needed.
    static func openTaskManager() {
        open(.showTaskManager, launchArguments: [taskManagerFlag])
    }

    /// Brings the window forward on the volume mixer's page.
    static func openVolumeMixer() {
        open(.showVolumeMixer, launchArguments: [volumeMixerFlag])
    }

    private static func open(_ event: ProcessEvents.Event, launchArguments: [String]) {
        guard let running = runningWindowApp else {
            if isLaunching { askedWhileLaunching = event }
            launch(launchArguments)
            return
        }
        if QuietScreen.mayActivate {
            NSApp.activate()
            running.activate(from: .current)
        }
        // Activating alone would not bring back a minimized window.
        ProcessEvents.post(event)
        DispatchQueue.main.asyncAfter(deadline: .now() + exitCheckDelay) {
            if running.isTerminated { launch(launchArguments) }
        }
    }

    /// Starts a window process without looking for an existing one, which may be on its way out.
    static func launch(_ extraArguments: [String] = []) {
        guard !isLaunching else { return }
        isLaunching = true
        if QuietScreen.mayActivate { NSApp.activate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = QuietScreen.mayActivate
        // The agent's language is the app's own list, so the window is told its language to differ from it.
        configuration.arguments =
            [flag] + extraArguments + ["-AppleLanguages", "(\(AppSettings.savedWindowLanguage.localization))"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        log.error("Could not open the window: \(error.localizedDescription, privacy: .public)")
                    }
                    // A new process only gets focus if the active app hands it over. Otherwise the window can
                    // open inactive, with its first click lost and Cmd-W going to whichever app was in front.
                    #if TWEAKLY_AUTOMATION
                        quietWindowApp = app
                    #endif
                    if let app, QuietScreen.mayActivate {
                        NSApp.yieldActivation(to: app)
                        app.activate(from: .current)
                    }
                    isLaunching = false
                    if let asked = askedWhileLaunching {
                        askedWhileLaunching = nil
                        // Once it listens: launched is not yet finished launching.
                        DispatchQueue.main.asyncAfter(deadline: .now() + exitCheckDelay) { ProcessEvents.post(asked) }
                    }
                }
            }
        }
    }

    /// Restarts everything, so a new language applies to both processes. The old agent only goes away
    /// once its replacement has started, so a failed launch does not cost the menu bar items.
    static func relaunchAll() {
        guard !isRelaunching else { return }
        isRelaunching = true
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current && $0.bundleURL == Bundle.main.bundleURL }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [openOnLaunchFlag]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        log.error("Could not restart: \(error.localizedDescription, privacy: .public)")
                        isRelaunching = false
                        return
                    }
                    previous.forEach { $0.terminate() }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// Another agent started earlier from this same copy of the app. When two start together, the one started first
    /// stays, so exactly one survives. Copies elsewhere are left alone.
    static var olderAgent: NSRunningApplication? {
        let current = NSRunningApplication.current
        // The window is a regular app and the wallpaper process a background one; only an agent is an accessory.
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0 != current && !$0.isTerminated && $0.activationPolicy == .accessory
                && $0.bundleURL == Bundle.main.bundleURL && isOlder($0, than: current)
        }
    }

    /// By the time each started, as process numbers wrap around on a Mac that has been up for days; by the number
    /// only when the two started at the same moment.
    private static func isOlder(_ app: NSRunningApplication, than other: NSRunningApplication) -> Bool {
        // A process started other than through Launch Services, from a shell say, has no date to compare.
        guard let started = app.launchDate, let otherStarted = other.launchDate, started != otherStarted else {
            return app.processIdentifier < other.processIdentifier
        }
        return started < otherStarted
    }

    /// The agent never takes the regular activation policy, which tells the two apart.
    private static var runningWindowApp: NSRunningApplication? {
        windowApps.first { $0 != NSRunningApplication.current }
    }

    /// Another window process that started earlier. The gap before a new process counts as a window app
    /// lets a quick second request start one more, and two start at once only here, where one can give way.
    static var olderWindowApp: NSRunningApplication? {
        windowApps.first { $0 != NSRunningApplication.current && isOlder($0, than: .current) }
    }

    private static var windowApps: [NSRunningApplication] {
        #if TWEAKLY_AUTOMATION
            // A quiet test copy's window stays an accessory, so the agent goes by the one it started.
            if QuietScreen.isActive { return [quietWindowApp].compactMap { $0 }.filter { !$0.isTerminated } }
        #endif
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleURL == Bundle.main.bundleURL
        }
    }

    #if TWEAKLY_AUTOMATION
        private static var quietWindowApp: NSRunningApplication?
    #endif
}

/// Signals between the agent and the window process. Preferences themselves travel through
/// `UserDefaults`, which both processes share; these only say that it is time to act on them.
enum ProcessEvents {
    enum Event: String {
        case settingsChanged = "me.tweakly.Tweakly.settings-changed"
        case quitAll = "me.tweakly.Tweakly.quit-all"
        case showWindow = "me.tweakly.Tweakly.show-window"
        case showTaskManager = "me.tweakly.Tweakly.show-task-manager"
        case shortcutRecording = "me.tweakly.Tweakly.shortcut-recording"
        case simpleLookChanged = "me.tweakly.Tweakly.simple-look-changed"
        case fanSettingsChanged = "me.tweakly.Tweakly.fan-settings-changed"
        /// Live wallpaper turned itself off, which the window has to show.
        case liveWallpaperStopped = "me.tweakly.Tweakly.live-wallpaper-stopped"
        case showVolumeMixer = "me.tweakly.Tweakly.show-volume-mixer"
        /// The Finder menu turned itself off, which the window has to show.
        case finderMenuStopped = "me.tweakly.Tweakly.finder-menu-stopped"
        /// An app's volume, mute or output changed, see `AudioRuleStore`.
        case audioRulesChanged = "me.tweakly.Tweakly.audio-rules-changed"
        /// The process that plays apps' sound found it may or may not record it, see `AudioProcess`.
        case volumeMixerStateChanged = "me.tweakly.Tweakly.volume-mixer-state-changed"
    }

    /// A plain notify name reaches every process on the Mac: quitting would close other users' copies and
    /// any other copy of the app, and anything could send it. This prefix limits it to this user, and the
    /// suffix to this copy of the app.
    private static func name(of event: Event) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Bundle.main.bundleURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "user.uid.\(getuid()).\(event.rawValue).\(String(hash, radix: 16))"
    }

    static func post(_ event: Event) {
        notify_post(name(of: event))
    }

    /// Keep the returned token registered for as long as the handler should run.
    static func observe(_ event: Event, handler: @escaping @MainActor () -> Void) -> Int32 {
        var token: Int32 = 0
        let status = notify_register_dispatch(name(of: event), &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        if status != NOTIFY_STATUS_OK {
            Logger(subsystem: "me.tweakly.Tweakly", category: "process")
                .error("Could not listen for \(event.rawValue, privacy: .public): \(status, privacy: .public)")
        }
        return token
    }

    /// Quits the agent and the window, whichever process asks.
    static func quitEverything() {
        post(.quitAll)
    }
}

/// The application delegate of the window process, which lives exactly as long as its window.
final class WindowAppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let feed = OverviewFeed()
    private var window: MainWindowController?
    private var eventTokens: [Int32] = []
    private var shownDockIcon = AppTheme.system
    private var isWindowClosed = false

    /// Quit from the Dock comes as an Apple event, and has to mean what Quit in the menu means.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the process becomes a regular app, so that its tile never appears in the wrong look.
        applyLook()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    private func applyLook() {
        NSApp.appearance = settings.appTheme.appearance
        guard settings.dockIconTheme != shownDockIcon else { return }
        shownDockIcon = settings.dockIconTheme
        switch settings.dockIconTheme {
        // Back to what the system would show, whichever style is chosen there.
        case .system: NSApp.applicationIconImage = nil
        // The catalog's flat image of the icon is its light version.
        case .light: NSApp.applicationIconImage = NSImage(named: "AppIcon")
        case .dark: NSApp.applicationIconImage = Bundle.main.image(forResource: "DockIconDark")
        }
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        ProcessEvents.quitEverything()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.onChange = { [weak self] in
            self?.applyLook()
            ProcessEvents.post(.settingsChanged)
            if let settings = self?.settings { TweaklyTips.update(settings) }
        }
        eventTokens = [
            ProcessEvents.observe(.quitAll) { NSApp.terminate(nil) },
            ProcessEvents.observe(.showWindow) { [weak self] in self?.window?.showWindow() },
            ProcessEvents.observe(.showTaskManager) { [weak self] in
                self?.window?.showTaskManager()
                TweaklyTips.taskManagerOpenedFromOutside()
            },
            ProcessEvents.observe(.showVolumeMixer) { [weak self] in self?.window?.showWindow(page: .volumeMixer) },
            ProcessEvents.observe(.simpleLookChanged) { [weak self] in self?.settings.reloadSimpleLook() },
            ProcessEvents.observe(.fanSettingsChanged) { [weak self] in self?.settings.reloadFanSettings() },
            ProcessEvents.observe(.liveWallpaperStopped) { [weak self] in self?.settings.reloadLiveWallpaper() },
            ProcessEvents.observe(.finderMenuStopped) { [weak self] in self?.settings.reloadFinderMenu() },
        ]
        TweaklyTips.configure(settings: settings)
        let controller = MainWindowController(settings: settings, feed: feed) { [weak self] in
            self?.isWindowClosed = true
            self?.terminateIfNothingOpen()
        }
        // Whichever way it comes back, the shortcut, the menu's Settings or About too, the process has a window again
        // and must not leave once the browser or a download is done.
        controller.onShow = { [weak self] in self?.isWindowClosed = false }
        controller.wallpapers.settings = settings
        // The wallpaper browser has a window of its own, which may outlive this one while it downloads.
        controller.wallpapers.onIdle = { [weak self] in self?.terminateIfNothingOpen() }
        controller.wallpapers.onShowLibrary = { [weak self] in self?.window?.show(page: .liveWallpaper) }
        window = controller
        NSApp.mainMenu = AppMenu.make(target: controller)
        let startsWithTaskManager = WindowProcess.opensTaskManagerFirst
        if startsWithTaskManager {
            controller.showTaskManager()
            TweaklyTips.taskManagerOpenedFromOutside()
        } else if WindowProcess.opensVolumeMixerFirst {
            controller.showWindow(page: .volumeMixer)
        } else {
            controller.show(page: nil)
            controller.offerWelcome()
        }
        // Only now does this process count as a window app, for the other one to see too.
        DispatchQueue.main.async {
            if WindowProcess.olderWindowApp != nil {
                let asked: ProcessEvents.Event =
                    startsWithTaskManager
                    ? .showTaskManager : WindowProcess.opensVolumeMixerFirst ? .showVolumeMixer : .showWindow
                ProcessEvents.post(asked)
                NSApp.terminate(nil)
            }
        }
        #if TWEAKLY_AUTOMATION
            Automation.shared.startInWindowProcess(window: controller, settings: settings)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show(page: nil)
        return false
    }

    /// The process lives as long as its windows: the main one, and the wallpaper browser with its downloads, and until
    /// a video being optimized is done.
    private func terminateIfNothingOpen() {
        guard isWindowClosed, window?.wallpapers.isBusy != true else { return }
        NSApp.terminate(nil)
    }
}
