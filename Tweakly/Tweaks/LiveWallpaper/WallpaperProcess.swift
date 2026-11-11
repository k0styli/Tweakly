import AppKit
import LiveWallpaperCore
import notify
import os

/// Live wallpapers play in a process of their own, started by the agent from this same executable while the tweak is
/// on, and ended when it goes off. The agent never loads the video stack, so it costs nothing after the tweak is turned
/// off, and a damaged file can take down only this process.
enum WallpaperProcess {
    static let flag = "--wallpaper"

    static var isWallpaperProcess: Bool { ProcessInfo.processInfo.arguments.contains(flag) }
}

/// The application delegate of the wallpaper process.
final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    private let conditions = SystemConditions()
    private var displays: [String: DisplayWallpaper] = [:]
    private var rules = PauseRules()
    private var eventTokens: [Int32] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var parentWatch: DispatchSourceProcess?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The agent tells its own kind apart by this, and never mistakes this process for an older agent.
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchParent()
        handleTermination()
        eventTokens = [
            ProcessEvents.observe(.quitAll) { NSApp.terminate(nil) },
            ProcessEvents.observe(.settingsChanged) { [weak self] in self?.reload() },
        ]
        let center = NotificationCenter.default
        let screens = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        observers = [(center, screens)]
        conditions.onChange = { [weak self] in self?.evaluate() }
        conditions.start()
        reload()
        #if TWEAKLY_AUTOMATION
            listenForStateRequests()
        #endif
    }

    #if TWEAKLY_AUTOMATION
        /// Writes what each display is doing when asked, for tests: notify `<automation name>.wallpaper` and read
        /// `/tmp/tweakly-wallpaper-state[-<channel>].json`.
        private func listenForStateRequests() {
            let channel = UserDefaults.standard.string(forKey: "automationChannel")
            let name = "me.tweakly.Tweakly.automation" + (channel.map { ".\($0)" } ?? "") + ".wallpaper"
            let path = "/tmp/tweakly-wallpaper-state" + (channel.map { "-\($0)" } ?? "") + ".json"
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let rows: [[String: Any]] = self.displays.values.map {
                        [
                            "display": $0.key, "mode": String(describing: $0.mode), "visible": $0.isVisible,
                            "file": $0.choice.fileName, "fit": $0.choice.fit.rawValue, "hasPlayer": $0.hasPlayer,
                            "seconds": $0.playedSeconds, "playing": $0.playingFile, "economy": $0.isEconomy,
                            "size": $0.size.map { "\($0.width)x\($0.height)" } ?? "",
                        ]
                    }
                    let object: [String: Any] = [
                        "displays": rows, "locked": self.conditions.isScreenLocked,
                        "battery": self.conditions.isOnBattery, "lowPower": self.conditions.isLowPowerMode,
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        displays.values.forEach { $0.close() }
        displays = [:]
        conditions.stop()
    }

    /// The agent ends this process when the tweak goes off. If the agent itself goes, so does this, and the next agent
    /// starts its own.
    private func watchParent() {
        let parent = getppid()
        guard parent > 1 else {
            NSApp.terminate(nil)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        parentWatch = source
        // The agent may have gone between the question and the watch, which would then never fire: a new agent would
        // start a second of these, and two players would decode at once.
        if getppid() != parent { NSApp.terminate(nil) }
    }

    /// The agent asks with SIGTERM, which would otherwise end the process without closing the windows.
    private func handleTermination() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Brings the windows in line with the settings and the displays connected now.
    private func reload() {
        let saved = AppSettings.savedLiveWallpaper()
        rules = saved.rules
        guard saved.enabled else {
            NSApp.terminate(nil)
            return
        }
        let entries = WallpaperFolder.readIndex().entries
        var seen = Set<String>()
        for screen in WallpaperFolder.screens {
            // A picture is the system's desktop picture alone, which the agent sets.
            guard let key = WallpaperFolder.key(of: screen), let choice = saved.assignments.choice(forDisplay: key),
                choice.kind == .video
            else { continue }
            seen.insert(key)
            let title = entries[choice.wallpaperID]?.wallpaper.title ?? choice.fileName
            let size = entries[choice.wallpaperID].flatMap {
                WallpaperSizing.size(
                    of: $0.pixelSize, setting: saved.size, panel: WallpaperFolder.panelSize(of: screen))
            }
            if let display = displays[key] {
                display.place(on: screen)
                display.update(choice: choice, title: title, isEconomy: saved.economy, size: size)
            } else {
                let display = DisplayWallpaper(
                    key: key, screen: screen, choice: choice, title: title, isEconomy: saved.economy, size: size)
                display.onVisibilityChange = { [weak self] in self?.evaluate() }
                display.onFailure = { [weak self] display, reason in self?.failed(display, reason) }
                displays[key] = display
            }
        }
        for (key, display) in displays where !seen.contains(key) {
            display.close()
            displays[key] = nil
        }
        evaluate()
    }

    /// Every change that matters arrives as an event, so this runs only then.
    private func evaluate() {
        for display in displays.values {
            let situation = PlaybackSituation(
                isVisible: display.isVisible, isDisplayAsleep: conditions.areScreensAsleep,
                isScreenLocked: conditions.isScreenLocked, isSystemAsleep: conditions.isSystemAsleep,
                isOnBattery: conditions.isOnBattery, isLowPowerMode: conditions.isLowPowerMode,
                isHot: conditions.isHot)
            let mode = PlaybackPolicy.mode(for: situation, rules: rules)
            if mode != display.mode { display.apply(mode) }
        }
    }

    /// The tweak goes off with the reason for its page, and the video that failed is taken off its displays so that
    /// turning it back on does not fail the same way.
    private func failed(_ display: DisplayWallpaper, _ reason: LiveWallpaperStopReason) {
        Self.log.error("Turning live wallpaper off: \(String(describing: reason), privacy: .public)")
        AppSettings.stopLiveWallpaper(because: reason, removing: display.choice.wallpaperID)
        ProcessEvents.post(.liveWallpaperStopped)
        NSApp.terminate(nil)
    }
}
