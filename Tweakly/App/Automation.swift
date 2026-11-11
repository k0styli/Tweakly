#if TWEAKLY_AUTOMATION
    import AppKit
    import AudioMixerCore
    import CustomIconCore
    import FanControlCore
    import FinderMenuCore
    import LiveWallpaperCore
    import MouseCore
    import SwiftUI
    import SystemMetrics
    import TaskManagerCore
    import WindowSwitcherCore
    import notify

    /// Drives the app without a mouse, so UI paths and their cost can be measured from a script.
    /// Compiled only into builds made with `TWEAKLY_AUTOMATION`, never into a shipping build.
    ///
    /// Write a command to `/tmp/tweakly-automation`, then run `notifyutil -p me.tweakly.Tweakly.automation`.
    /// A copy with `automationChannel` set in its defaults listens on `/tmp/tweakly-automation-<channel>` and
    /// `me.tweakly.Tweakly.automation.<channel>` instead, so other sessions' test copies do not act on its commands.
    final class Automation {
        static let shared = Automation()
        private static let channel = UserDefaults.standard.string(forKey: "automationChannel")
        private static let commandFile = channel.map { "/tmp/tweakly-automation-\($0)" } ?? "/tmp/tweakly-automation"
        private static let notifyName =
            channel.map { "me.tweakly.Tweakly.automation.\($0)" }
            ?? "me.tweakly.Tweakly.automation"
        private var token: Int32 = 0
        private var stats: StatsTweak?
        private var settings: AppSettings?
        private var window: MainWindowController?
        private var windowSettings: AppSettings?
        private var taskManager: TaskManagerModel? { window?.taskManager }
        private var uninstaller: UninstallerModel? { window?.uninstaller }
        private var windowSwitcher: (() -> WindowSwitcherTweak?)?
        private var dock: (() -> DockTweak?)?
        private var mouse: (() -> MouseTweak?)?
        private var finderCut: (() -> FinderCutTweak?)?
        private var finderMenu: (() -> FinderMenuTweak?)?
        private var languageSwitch: (() -> LanguageSwitchTweak?)?
        private var volumeMixer: (() -> VolumeMixerTweak?)?
        /// Stands in for a small screen, which cannot be attached from a script.
        private(set) var popoverHeightLimit: CGFloat?

        func startInAgent(
            stats: StatsTweak, settings: AppSettings, windowSwitcher: @escaping () -> WindowSwitcherTweak?,
            dock: @escaping () -> DockTweak?, mouse: @escaping () -> MouseTweak?,
            finderCut: @escaping () -> FinderCutTweak?,
            finderMenu: @escaping () -> FinderMenuTweak?,
            languageSwitch: @escaping () -> LanguageSwitchTweak?,
            volumeMixer: @escaping () -> VolumeMixerTweak?
        ) {
            self.stats = stats
            self.settings = settings
            self.windowSwitcher = windowSwitcher
            self.dock = dock
            self.mouse = mouse
            self.finderCut = finderCut
            self.finderMenu = finderMenu
            self.languageSwitch = languageSwitch
            self.volumeMixer = volumeMixer
            register()
        }

        func startInWindowProcess(window: MainWindowController, settings: AppSettings) {
            self.window = window
            windowSettings = settings
            register()
        }

        private func register() {
            notify_register_dispatch(Self.notifyName, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runCommands() }
            }
        }

        private func rowID(_ bundleID: String) -> String? {
            uninstaller?.rows.first { $0.app.identity.bundleID == bundleID }?.id
        }

        private func planForTesting(_ plan: RemovalPlan) -> String {
            var lines = [
                "app \(plan.app.name) mode \(plan.mode) searching \(plan.isSearching) working \(plan.isWorking) running \(plan.isRunning)"
                    + " password \(plan.needsPassword) unreadable \(plan.hasUnreadableData)"
                    + " copy \(plan.otherCopy ?? "-") size \(plan.checkedSize) problem \(plan.problem ?? "-")"
            ]
            for item in plan.items {
                lines.append(
                    "  [\(item.isChecked ? "x" : " ")] \(item.leftover.category) \(item.leftover.path)"
                        + " \(item.leftover.size ?? -1)\(item.leftover.needsAdministrator ? " admin" : "")")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        private func runCommands() {
            guard let text = try? String(contentsOfFile: Self.commandFile, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                run(line.split(separator: " ").map(String.init))
            }
        }

        private func run(_ words: [String]) {
            guard let command = words.first else { return }
            let argument = words.count > 1 ? words[1] : ""
            switch command {
            case "open-details":
                if let kind = MetricKind(rawValue: argument) { stats?.openDetails(for: kind) }
            case "open-simple":
                stats?.openSimple()
            case "mixer-open":
                // Only the agent; quiet.py's `shot --open mixer-open` says where its item sits first.
                volumeMixer?()?.openPopover()
            case "mixer-close":
                volumeMixer?()?.closePopover()
            case "mixer-enabled":
                guard stats != nil, let settings else { return }
                settings.volumeMixerEnabled = argument == "1"
            case "mixer-rule":
                // The agent alone: <bundle ID> <volume> <muted 0|1> [output UID], as the popover's controls set it.
                guard stats != nil else { return }
                let parts = Array(words.dropFirst())
                guard parts.count >= 3, let volume = Double(parts[1]) else { return }
                AudioRuleStore.update(parts[0]) {
                    $0.volume = volume
                    $0.isMuted = parts[2] == "1"
                    $0.outputUID = parts.count > 3 ? parts[3] : nil
                }
            case "mixer-reset":
                guard stats != nil else { return }
                AudioRuleStore.save(AudioRuleBook())
            case "mixer-state":
                // The agent alone: what the popover would show, without opening it.
                guard stats != nil else { return }
                let output = AudioSystem.defaultDevice(input: false)
                let apps = AudioAppGrouping.apps(clients: AudioSystem.clients(), owner: AudioSystem.owner(of:))
                let object: [String: Any] = [
                    "enabled": settings?.volumeMixerEnabled ?? false,
                    "output": output.flatMap(AudioSystem.uid(of:)) ?? "",
                    "volume": output.flatMap { AudioSystem.volume(of: $0, input: false) } ?? -1,
                    "muted": output.flatMap { AudioSystem.isMuted($0, input: false) } ?? false,
                    "outputs": AudioSystem.devices(input: false).map {
                        ["name": $0.name, "uid": $0.uid, "kind": $0.kind.rawValue]
                    },
                    "inputs": AudioSystem.devices(input: true).map { ["name": $0.name, "kind": $0.kind.rawValue] },
                    "apps": apps.map {
                        ["id": $0.id, "name": $0.owner.name, "playing": $0.isPlaying, "objects": $0.objectIDs.count]
                    },
                    "rules": AudioRuleStore.load().rules.mapValues {
                        ["volume": $0.volume, "muted": $0.isMuted, "output": $0.outputUID ?? ""]
                    },
                    "permitted": AudioRuleStore.isPermitted,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                try? data.write(to: URL(fileURLWithPath: argument))
            case "close-details":
                stats?.closeDetails()
                volumeMixer?()?.closePopover()
            case "icon-import":
                // Only the agent, or both processes would add it. The window's code, for testing without the window.
                guard stats != nil else { return }
                if let manifest = try? IconImporter.add(fileAt: URL(fileURLWithPath: argument)) {
                    settings?.simpleViewIconOwnColours = manifest.hasColours
                    settings?.simpleViewIcon = manifest.id
                }
            case "icon-gear":
                (settings ?? windowSettings)?.simpleViewIcon = nil
            case "icon-own-colours":
                (settings ?? windowSettings)?.simpleViewIconOwnColours = argument == "1"
            case "icon-motion":
                if let mode = IconMotionMode(rawValue: argument) { settings?.iconMotion.mode = mode }
            case "fan-install":
                // Only the window, which is where a person presses this.
                if windowSettings != nil, let error = FanHelperInstaller.install() { NSLog("fan helper: %@", error) }
            case "fan-uninstall":
                if windowSettings != nil, let error = FanHelperInstaller.uninstall() { NSLog("fan helper: %@", error) }
            case "fan-emergency":
                if let settings = settings ?? windowSettings, let degrees = Double(argument) {
                    settings.fanSettings.tuning.emergencyTemperature = degrees
                    settings.fanSettings.tuning = settings.fanSettings.tuning.validated
                }
            case "fan-mode":
                // system, fixed <percent>, curve <preset>, profile <name>, separate or battery.
                guard let settings = settings ?? windowSettings else { return }
                var fans = settings.fanSettings
                switch argument {
                case "fixed":
                    fans.adapter.shared.mode = .fixed
                    fans.adapter.shared.fixedPercent = words.count > 2 ? Double(words[2]) ?? 50 : 50
                case "curve":
                    fans.adapter.shared.mode = .curve
                    fans.adapter.shared.curve =
                        (words.count > 2 ? FanPreset(rawValue: words[2]) : nil)?.curve ?? FanPreset.balanced.curve
                case "profile":
                    if words.count > 2, let profile = FanProfile(rawValue: words[2]) { fans.adapter = profile.plan }
                case "separate":
                    fans.adapter.isLinked = false
                    fans.adapter.separate = [fans.adapter.shared, fans.adapter.shared]
                case "battery":
                    fans.battery = fans.adapter
                default:
                    fans.adapter.shared.mode = .system
                }
                settings.fanSettings = fans
            case "icon-fill":
                settings?.iconMotion.fills = argument == "1"
            case "icon-speeds":
                // Loop, idle, busy.
                let numbers = words.dropFirst().compactMap(Double.init)
                if numbers.count == 3 {
                    settings?.iconMotion.loopSpeed = numbers[0]
                    settings?.iconMotion.idleSpeed = numbers[1]
                    settings?.iconMotion.busySpeed = numbers[2]
                }
            case "icon-load":
                if let percent = Int(argument) { stats?.feedIconLoad(of: .cpu, value: .percent(percent)) }
            case "app-theme":
                if let theme = AppTheme(rawValue: argument) { windowSettings?.appTheme = theme }
            case "dock-icon":
                if let theme = AppTheme(rawValue: argument) { windowSettings?.dockIconTheme = theme }
            case "snapshot-app-icon":
                // What the Dock is given, for when the Dock itself is hidden.
                if windowSettings != nil, let data = NSApp.applicationIconImage.tiffRepresentation,
                    let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                {
                    try? png.write(to: URL(fileURLWithPath: argument))
                }
            case "languages":
                // The window, the popovers and the menu bar.
                let chosen = words.dropFirst().compactMap(AppLanguage.init(rawValue:))
                if chosen.count == 3, let windowSettings {
                    windowSettings.windowLanguage = chosen[0]
                    windowSettings.language = chosen[1]
                    windowSettings.menuBarLanguage = chosen[2]
                }
            case "simple-look":
                if let look = SimpleViewLook(rawValue: argument) { (settings ?? windowSettings)?.simpleViewLook = look }
            case "simple-view":
                (settings ?? windowSettings)?.simpleViewEnabled = argument == "1"
            case "simple-view-metrics":
                (settings ?? windowSettings)?.simpleViewMetrics = Set(
                    argument.split(separator: ",").compactMap { MetricKind(rawValue: String($0)) })
            case "open-window":
                if stats != nil { WindowProcess.open() }
                window?.show(page: MainPage(rawValue: argument))
            case "close-window":
                window?.closeWindow()
            case "welcome":
                // `welcome`, `welcome how` for its second step, `welcome close`.
                if argument == "close" {
                    window?.closeWelcomeForTesting()
                } else {
                    window?.showWelcomeForTesting(step: argument == "how" ? .howItWorks : .features)
                }
            case "window-search":
                window?.search(for: argument)
            case "window-size":
                if let width = Double(argument), words.count > 2, let height = Double(words[2]) {
                    window?.resize(width: width, height: height)
                }
            case "window-metrics":
                windowSettings?.enabledMetrics = Set(
                    argument.split(separator: ",").compactMap { MetricKind(rawValue: String($0)) })
            case "relaunch":
                if windowSettings != nil { WindowProcess.relaunchAll() }
            case "quit-all":
                if windowSettings != nil { ProcessEvents.quitEverything() }
            case "window-front":
                window?.bringToFrontForMeasuring()
            case "window-page":
                if let page = MainPage(rawValue: argument) { window?.openPageForMeasuring(page) }
            case "window-visible":
                if let state = window?.visibilityForTesting {
                    try? state.write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "window-toggle-sidebar":
                if let title = window?.toggleSidebarForTesting() {
                    try? (title + "\n").write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "window-hide":
                window?.hideForTesting()
            case "window-scroll":
                if let points = Double(argument) { window?.scrollForTesting(to: points) }
            case "window-move":
                if let x = Double(argument), words.count > 2, let y = Double(words[2]) {
                    window?.moveForMeasuring(x: x, y: y)
                }
            case "bench-labels":
                LabelBenchmark.run(to: argument)
            case "memory-relief":
                malloc_zone_pressure_relief(nil, 0)
            case "show-value":
                // Lasts until the next real value arrives, which is long enough for a snapshot at a slow interval.
                if let kind = MetricKind(rawValue: argument), words.count > 2, let number = Double(words[2]),
                    number.isFinite, abs(number) < 1e12
                {
                    let value: MenuValue =
                        kind == .network
                        ? .rates(
                            up: CompactRate(bytesPerSecond: number), down: CompactRate(bytesPerSecond: number))
                        : .percent(Int(number))
                    stats?.item(for: kind)?.show(value)
                }
            case "stress-ticks":
                stressTicks(remaining: Int(argument) ?? 0, step: 0)
            case "metrics":
                settings?.enabledMetrics = Set(
                    argument.split(separator: ",").compactMap { MetricKind(rawValue: String($0)) })
            case "style":
                if let style = MenuBarStyle(rawValue: argument) {
                    for kind in MetricKind.allCases { settings?.appearances[kind]?.style = style }
                }
            case "interval":
                if let value = Double(argument), let interval = UpdateInterval(rawValue: value) {
                    for kind in MetricKind.allCases { settings?.appearances[kind]?.interval = interval }
                }
            case "status":
                guard let state = stats?.automationDescription else { return }
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "dump-details":
                if let view = stats?.detailContentView {
                    var lines: [String] = ["fitting=\(view.fittingSize) frame=\(view.frame)"]
                    Self.describe(view, depth: 0, into: &lines)
                    try? lines.joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "post-sleep":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "post-wake":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            case "post-screen-sleep":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            case "post-screen-wake":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            case "limit-popover":
                popoverHeightLimit = Double(argument).map { CGFloat($0) }
            case "press-concealed":
                if let view = stats?.detailContentView { Self.concealedRow(in: view)?.pressForAutomation() }
            case "snapshot-details":
                if let view = stats?.detailContentView { Self.snapshotLayers(view, to: argument) }
            case "snapshot-labels":
                Self.sheetScale = Self.scale(words)
                Self.snapshotLabels(to: argument)
            case "snapshot-row":
                Self.snapshotRows(to: argument)
            case "site-labels":
                Self.siteLabels(to: argument)
            case "snapshot-battery":
                Self.sheetScale = Self.scale(words)
                Self.snapshotBattery(to: argument)
            case "audit-labels":
                Self.auditLabels(toDirectory: argument)
            case "caption-align":
                if let alignment = CaptionAlignment(rawValue: argument) {
                    for kind in MetricKind.allCases { settings?.appearances[kind]?.alignment = alignment }
                }
            case "battery-style":
                if let style = BatteryBarStyle(rawValue: argument) { settings?.batteryStyle = style }
            case "task-open":
                if stats != nil { WindowProcess.openTaskManager() }
            case "task-search":
                taskManager?.query = words.dropFirst().joined(separator: " ")
            case "task-sort":
                if let column = TaskColumn(rawValue: argument) {
                    taskManager?.processes.sortForTesting(column, ascending: words.count > 2 && words[2] == "up")
                }
            case "task-column":
                if let column = TaskColumn(rawValue: argument) { taskManager?.toggle(column) }
            case "task-expand":
                taskManager?.processes.expandForTesting(name: words.dropFirst().joined(separator: " "))
            case "task-select":
                taskManager?.processes.selectForTesting(name: words.dropFirst().joined(separator: " "))
            case "task-info":
                taskManager?.showInfo()
            case "task-header":
                try? taskManager?.processes.headerForTesting.write(toFile: argument, atomically: true, encoding: .utf8)
            case "task-scroll":
                if let row = Int(argument) { taskManager?.processes.scrollForTesting(toRow: row) }
            case "uninstaller-reload":
                uninstaller?.reload()
            case "uninstaller-state":
                try? uninstaller?.stateForTesting.write(toFile: argument, atomically: true, encoding: .utf8)
            case "uninstaller-search":
                uninstaller?.query = words.dropFirst().joined(separator: " ")
            case "uninstaller-select":
                // By bundle id, which has no spaces, unlike most app paths.
                if let row = uninstaller?.rows.first(where: { $0.app.identity.bundleID == argument }) {
                    uninstaller?.selection = row.id
                }
            case "uninstaller-open":
                uninstaller?.begin(words.count > 2 && words[2] == "reset" ? .reset : .uninstall, for: rowID(argument))
            case "uninstaller-uncheck":
                // The item whose path ends with the argument stays.
                if let plan = uninstaller?.plan, let index = plan.items.firstIndex(where: { $0.id.hasSuffix(argument) })
                {
                    plan.items[index].isChecked = false
                }
            case "uninstaller-sheet-select":
                // The item whose path ends with the argument, as a click in the sheet's list would.
                if let plan = uninstaller?.plan { plan.selection = plan.items.first { $0.id.hasSuffix(argument) }?.id }
            case "uninstaller-geometry":
                let text =
                    (uninstaller?.table.geometryForTesting ?? "") + "sheet\n"
                    + (uninstaller?.sheetTable?.geometryForTesting ?? "")
                try? text.write(toFile: argument, atomically: true, encoding: .utf8)
            case "uninstaller-plan":
                try? uninstaller?.plan.map(planForTesting)?.write(toFile: argument, atomically: true, encoding: .utf8)
            case "uninstaller-carry-out":
                // Only the test apps a run makes for itself, so a mistyped command can never remove a real app.
                if let plan = uninstaller?.plan,
                    plan.app.identity.bundleID.hasPrefix("me.tweakly.Tweakly-uninstall-test")
                {
                    uninstaller?.carryOut(plan)
                }
            case "uninstaller-close":
                uninstaller?.plan = nil
            case "uninstaller-drop":
                // Apps dropped on the page, as a drag from Finder brings them: the same check, then the page.
                let urls = words.dropFirst().joined(separator: " ").split(separator: "|").map {
                    URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
                }
                uninstaller?.open(droppedApps: urls.filter(AppCatalog.mayList(dropped:)))
            case "hotkeys-selftest":
                try? GlobalHotKeys.selfTest().write(toFile: argument, atomically: true, encoding: .utf8)
            case "task-scroll-bench":
                // task-scroll-bench <file> <seconds> <points a second>
                let seconds = words.count > 2 ? Double(words[2]) ?? 10 : 10
                let speed = words.count > 3 ? Double(words[3]) ?? 1500 : 1500
                taskManager?.processes.scrollBenchForTesting(seconds: seconds, speed: speed, to: argument)
            case "task-anchor-check":
                let seconds = words.count > 2 ? Double(words[2]) ?? 10 : 10
                taskManager?.processes.anchorCheckForTesting(seconds: seconds, to: argument)
            case "task-offer-helper":
                taskManager?.offerHelper()
            case "task-shortcut":
                taskManager?.isShowingShortcut = argument != "0"
            case "task-end":
                taskManager?.endTask(force: argument == "force")
            case "task-dismiss":
                // Closes whatever sheet or popover the page shows, as Cancel would.
                if let window = NSApp.windows.first(where: { $0.attachedSheet != nil }),
                    let sheet = window.attachedSheet
                {
                    let response: NSApplication.ModalResponse =
                        switch argument {
                        case "first": .alertFirstButtonReturn
                        case "second": .alertSecondButtonReturn
                        default: .cancel
                        }
                    window.endSheet(sheet, returnCode: response)
                }
            case "task-interval":
                if let seconds = Double(argument) { taskManager?.interval = seconds }
            case "task-state":
                if let processes = taskManager?.processes, processes.isViewLoaded {
                    try? processes.stateForTesting.write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "task-timing":
                if windowSettings != nil {
                    try? TaskManagerTiming.shared.report().write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "task-enabled":
                (settings ?? windowSettings)?.taskManagerEnabled = argument == "1"
            case "snapshot-window":
                if let view = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })?
                    .contentView
                {
                    Self.snapshot(view, to: argument)
                }
            case "mouse-enabled":
                (settings ?? windowSettings)?.mouseEnabled = argument == "1"
            case "mouse-settings":
                // A JSON object of MouseSettings, all on one line.
                let json = words.dropFirst().joined(separator: " ")
                guard let target = settings ?? windowSettings,
                    let value = try? JSONDecoder().decode(MouseSettings.self, from: Data(json.utf8))
                else { return }
                target.mouseSettings = value.validated
            case "mouse-state":
                guard let mouse else { return }
                let state = mouse()?.automationDescription ?? "off\n"
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "dock-enabled":
                (settings ?? windowSettings)?.dockEnabled = argument == "1"
            case "dock-tuning":
                // Shows the panel 0|1, delay in ms, largest tile, click action: nothing, minimize or hide.
                guard words.count > 4, let target = settings ?? windowSettings else { return }
                var tuning = target.dockTuning
                tuning.showsPanel = words[1] == "1"
                tuning.delayMilliseconds = Int(words[2]) ?? tuning.delayMilliseconds
                tuning.largestTileHeight = Int(words[3]) ?? tuning.largestTileHeight
                tuning.clickAction = DockTuning.ClickAction(rawValue: words[4]) ?? tuning.clickAction
                target.dockTuning = tuning.validated
            case "dock-hover":
                // The agent alone: the executable whose icon the pointer comes onto, at a place in the row, or none.
                guard stats != nil else { return }
                let position = words.count > 2 ? Int(words[2]) ?? 0 : 0
                dock?()?.hoverForTesting(executable: argument == "none" ? nil : argument, at: position)
            case "dock-pointer-in-panel":
                dock?()?.pointerInPanelForTesting(argument == "1")
            case "dock-choose":
                dock?()?.chooseForTesting(Int(argument) ?? 0)
            case "dock-state":
                guard let dock else { return }
                let state = dock()?.automationDescription ?? "off\n"
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "switcher-enabled":
                (settings ?? windowSettings)?.windowSwitcherEnabled = argument == "1"
            case "switcher-fit-background":
                (settings ?? windowSettings)?.switcherTuning.fitsBackgroundToRows = argument == "1"
            case "window-tuning-captures":
                // Only the window process, as the page would, so the change has to reach the agent to be seen.
                windowSettings?.switcherTuning.capturesAtOnce = Int(argument) ?? 4
            case "window-tuning-shows":
                // Other desktops, minimized, apps without windows, each 1 or 0.
                guard words.count > 3 else { return }
                windowSettings?.switcherTuning.showsWindowsOnOtherDesktops = words[1] == "1"
                windowSettings?.switcherTuning.showsMinimizedWindows = words[2] == "1"
                windowSettings?.switcherTuning.showsAppsWithoutWindows = words[3] == "1"
            case "window-catalog":
                // Only the window process, so no agent has to hold the switcher for this. Only numbers come out.
                guard let tuning = windowSettings?.switcherTuning else { return }
                var recency = WindowRecency()
                var kinds: [CGWindowID: WindowKind] = [:]
                let items = WindowCatalog.snapshot(recency: &recency, kinds: &kinds, tuning: tuning).items
                let windows = items.filter { $0.window != nil }.count
                let outOfSight = items.filter { $0.window?.isOnScreen == false }.count
                try? "windows \(windows) outOfSight \(outOfSight) apps \(items.count - windows)\n".write(
                    toFile: argument, atomically: true, encoding: .utf8)
            case "switcher-saves-compressed":
                (settings ?? windowSettings)?.switcherTuning.savesCompressedPictures = argument == "1"
            case "switcher-begin":
                windowSwitcher?()?.beginForTesting()
            case "switcher-demo":
                // The agent alone: the real panel with tiles from a manifest file, on the test display only, and where
                // it ended up written to a second file. `close` takes it away. See DemoPanels.
                guard stats != nil else { return }
                if argument == "close" {
                    DemoPanels.shared.closeSwitcher()
                } else {
                    DemoPanels.shared.showSwitcher(manifestAt: argument, state: words.count > 2 ? words[2] : nil)
                }
            case "dock-demo":
                // The same for the Dock's panel, over a drawn row of icons at the bottom of the test display.
                guard stats != nil else { return }
                if argument == "close" {
                    DemoPanels.shared.closeDock()
                } else {
                    DemoPanels.shared.showDock(manifestAt: argument, state: words.count > 2 ? words[2] : nil)
                }
            case "switcher-only":
                WindowCatalog.onlyExecutablesForTesting =
                    argument.isEmpty
                    ? nil
                    : Set(argument.split(separator: ",").map { $0.replacingOccurrences(of: "+", with: " ") })
            case "keyboard-clean-start":
                window?.keyboardCleaning.start(seconds: Double(argument) ?? 30)
            case "keyboard-clean-state":
                if let state = window?.keyboardCleaning.automationDescription {
                    try? state.write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "keyboard-clean-preview":
                window?.keyboardCleaning.previewForTesting(
                    seconds: Double(argument) ?? 2, passwordWarning: words.contains("warning"),
                    dims: !words.contains("nodim"))
            case "keyboard-clean-hang":
                window?.keyboardCleaning.hangMainThreadForTesting(seconds: Double(argument) ?? 1)
            case "finder-cut-enabled":
                (settings ?? windowSettings)?.finderCutEnabled = argument == "1"
            case "finder-cut-state":
                guard let finderCut else { return }
                let state = finderCut()?.automationDescription ?? "{}\n"
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "finder-menu-enabled":
                (settings ?? windowSettings)?.finderMenuEnabled = argument == "1"
            case "finder-menu-items":
                (settings ?? windowSettings)?.finderMenuItems = FinderMenuItems(rawValue: UInt32(argument) ?? 0)
            case "finder-menu-new", "finder-menu-terminal":
                // The agent alone, as if the extension had asked: a folder or item, which may contain spaces.
                guard let tweak = finderMenu?() else { return }
                let path = words.dropFirst().joined(separator: " ")
                if command == "finder-menu-terminal" {
                    tweak.perform(.openInTerminal(path: path))
                } else if let name = NewFileName(base: "untitled file", pathExtension: "txt") {
                    tweak.perform(.newFile(folder: path, name: name))
                }
            case "finder-menu-state":
                guard let finderMenu else { return }
                let tweak = finderMenu()
                let object: [String: Any] = [
                    "listening": tweak?.isListening ?? false, "lastAction": tweak?.lastAction ?? "none",
                    "extensionEnabled": FinderExtension.isEnabled,
                    "stopReason": settings?.finderMenuStopReason?.rawValue ?? "",
                ]
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                try? data.write(to: URL(filePath: argument))
            case "language-switch-enabled":
                (settings ?? windowSettings)?.languageSwitchEnabled = argument == "1"
            case "language-switch-state":
                guard let languageSwitch else { return }
                let state = languageSwitch()?.automationDescription ?? "{}\n"
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "switcher-bench":
                guard windowSwitcher != nil else { return }
                try? WindowCatalog.benchForTesting(rounds: 30).write(
                    toFile: argument, atomically: true, encoding: .utf8)
            case "switcher-lose-pictures":
                WindowSwitcherTweak.losePicturesForTesting = argument == "1"
            case "switcher-forget-pictures":
                windowSwitcher?()?.forgetPicturesForTesting(andKept: argument == "all")
            case "switcher-open":
                windowSwitcher?()?.openForTesting()
            case "switcher-close":
                windowSwitcher?()?.closeForTesting()
            case "switcher-lose-key-state":
                windowSwitcher?()?.loseKeyStateForTesting()
            case "switcher-no-pictures":
                WindowSwitcherTweak.noPicturesForTesting = argument == "1"
            case "switcher-state":
                // Only the agent answers, or a window process would overwrite the answer.
                guard let windowSwitcher else { return }
                let state = windowSwitcher()?.automationDescription ?? "off\n"
                try? state.write(toFile: argument, atomically: true, encoding: .utf8)
            case "appearance":
                NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
            case "quiet-item":
                // x y width height of this copy's item on the quiet display's menu bar, from the top left.
                let numbers = words.dropFirst().compactMap(Double.init)
                if numbers.count == 4 {
                    QuietScreen.setItemFrame(
                        topLeft: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
                }
            case "wallpaper-add":
                // Only the agent: adds the file as the window does and shows it on every display.
                guard stats != nil, let settings else { return }
                let path = words.dropFirst().joined(separator: " ")
                Task { @MainActor in
                    do {
                        let entry = try await WallpaperImporter.importFile(at: URL(fileURLWithPath: path))
                        var index = WallpaperFolder.readIndex()
                        index.store(entry)
                        try WallpaperFolder.write(index)
                        var assignments = settings.liveWallpaperAssignments
                        assignments.sameOnAll = true
                        assignments.shared = index.choice(
                            for: entry.wallpaper.id, fit: assignments.shared?.fit ?? .fill)
                        settings.liveWallpaperAssignments = assignments
                        settings.liveWallpaperStopReason = nil
                        settings.liveWallpaperEnabled = true
                        ProcessEvents.post(.settingsChanged)
                    } catch {
                        NSLog("wallpaper-add: %@", String(describing: error))
                    }
                }
            case "wallpaper-browser":
                // Only the window: opens the wallpaper browser at a site's address.
                if let window, let url = URL(string: argument) { window.wallpapers.openBrowser(at: url) }
            case "wallpaper-import":
                // Only the window, as files dropped on its page together: paths separated by " | ".
                let paths = words.dropFirst().joined(separator: " ").components(separatedBy: " | ")
                window?.wallpapers.importFiles(paths.map { URL(fileURLWithPath: $0) })
            case "wallpaper-library":
                // Only the window: every entry, and the problems the page would show.
                guard let window else { return }
                let model = window.wallpapers
                model.reload()
                let rows: [[String: Any]] = model.all.map {
                    [
                        "title": $0.wallpaper.title, "kind": $0.wallpaper.kind.rawValue, "file": $0.fileName,
                        "still": $0.stillName ?? "", "cleaned": $0.cleaned ?? false,
                    ]
                }
                let object: [String: Any] = [
                    "entries": rows, "importProblems": model.importProblems,
                    "removedProblems": model.removedProblems, "importing": model.importsInProgress,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                try? data.write(to: URL(fileURLWithPath: argument))
            case "media-probe":
                // The cleaner tries what its sandbox must forbid; what happened goes to the file.
                guard window != nil else { return }
                Task { @MainActor in
                    let result = await MediaCleanerClient.probeSandbox()
                    try? result.write(toFile: argument, atomically: true, encoding: .utf8)
                }
            case "wallpaper-economy":
                // Only the window, as its page does: 1 or 0, then the copies the displays need are made.
                guard let window, let windowSettings else { return }
                windowSettings.liveWallpaperEconomy = argument == "1"
                window.wallpapers.settings = windowSettings
                window.wallpapers.playbackChanged()
            case "wallpaper-size":
                // Only the window, as its page does: display, 1080p, 1440p, 2160p or original.
                guard let window, let windowSettings, let size = PlaybackSize(rawValue: argument) else { return }
                windowSettings.liveWallpaperPlaybackSize = size
                window.wallpapers.settings = windowSettings
                window.wallpapers.playbackChanged()
            case "wallpaper-filter":
                // kind video|picture|any, then collection all|favourites|downloaded|imported.
                guard let window else { return }
                window.wallpapers.filter.kind = Wallpaper.Kind(rawValue: argument)
                if words.count > 2, let collection = WallpaperCollection(rawValue: words[2]) {
                    window.wallpapers.filter.collection = collection
                }
            case "wallpaper-downloads":
                guard let window else { return }
                let rows =
                    window.wallpapers.browserDownloads.map { "\($0.name)\t\($0.state)\t\($0.libraryID ?? "")" }
                    + ["--- optimizing \(window.wallpapers.optimizing)", "--- navigation"]
                    + window.wallpapers.browserLog
                try? (rows.joined(separator: "\n") + "\n").write(toFile: argument, atomically: true, encoding: .utf8)
            case "wallpaper-script":
                // JavaScript for the browser's page, such as a click on a site's download button.
                window?.wallpapers.runBrowserScript(words.dropFirst().joined(separator: " "))
            case "wallpaper-search":
                window?.wallpapers.filter.query = words.dropFirst().joined(separator: " ")
            case "wallpaper-close-browser":
                window?.wallpapers.closeBrowser()
            case "wallpaper-favourite":
                // Only the window: marks the newest wallpaper whose title holds the argument.
                guard let window else { return }
                let part = words.dropFirst().joined(separator: " ")
                if let entry = window.wallpapers.all.first(where: { $0.wallpaper.title.contains(part) }) {
                    window.wallpapers.setFavourite(entry.wallpaper.id, true)
                }
            case "wallpaper-reload":
                // What the agent changed for a test, which the window would otherwise only learn on its next visit.
                windowSettings?.reloadLiveWallpaper()
                window?.wallpapers.reload()
            case "wallpaper-choose":
                // Only the agent: puts a wallpaper already in the library on every display, without the video stack
                // that adding a file loads. The argument is a part of its title.
                guard stats != nil, let settings else { return }
                let part = words.dropFirst().joined(separator: " ")
                let index = WallpaperFolder.readIndex()
                guard let entry = index.newestFirst.first(where: { $0.wallpaper.title.contains(part) }) else { return }
                var assignments = settings.liveWallpaperAssignments
                assignments.sameOnAll = true
                assignments.shared = index.choice(for: entry.wallpaper.id, fit: assignments.shared?.fit ?? .fill)
                settings.liveWallpaperAssignments = assignments
                settings.liveWallpaperEnabled = true
                ProcessEvents.post(.settingsChanged)
            case "wallpaper-enabled":
                guard stats != nil, let settings else { return }
                settings.liveWallpaperEnabled = argument == "1"
                ProcessEvents.post(.settingsChanged)
            case "wallpaper-fit":
                guard stats != nil, let settings, let fit = VideoFit(rawValue: argument) else { return }
                settings.liveWallpaperAssignments.shared?.fit = fit
                ProcessEvents.post(.settingsChanged)
            case "wallpaper-rule":
                // hidden, battery, lowpower or hot, then 1 or 0.
                guard stats != nil, let settings, words.count > 2 else { return }
                let isOn = words[2] == "1"
                switch argument {
                case "hidden": settings.liveWallpaperPauseRules.whenHidden = isOn
                case "battery": settings.liveWallpaperPauseRules.onBattery = isOn
                case "lowpower": settings.liveWallpaperPauseRules.inLowPowerMode = isOn
                case "hot": settings.liveWallpaperPauseRules.whenHot = isOn
                default: return
                }
                ProcessEvents.post(.settingsChanged)
            case "wallpaper-state":
                guard stats != nil, let settings else { return }
                settings.reloadLiveWallpaper()
                let object: [String: Any] = [
                    "enabled": settings.liveWallpaperEnabled,
                    "stopReason": settings.liveWallpaperStopReason.map { String(describing: $0) } ?? "",
                    "shared": settings.liveWallpaperAssignments.shared?.fileName ?? "",
                    "fit": settings.liveWallpaperAssignments.shared?.fit.rawValue ?? "",
                    "stored": WallpaperFolder.readIndex().entries.keys.sorted(),
                ]
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                try? data.write(to: URL(fileURLWithPath: argument))
            case "windows":
                // Both processes hear every command, so each answers in a file of its own.
                let role = stats != nil ? "agent" : "window"
                try? Self.windowList().write(toFile: "\(argument).\(role).json", atomically: true, encoding: .utf8)
            default:
                break
            }
        }

        /// Puts values through every item as fast as the main thread allows, one run loop turn each, so that a
        /// day of updates takes seconds and whatever each update leaves behind shows up in the footprint.
        private func stressTicks(remaining: Int, step: Int) {
            guard remaining > 0 else { return }
            autoreleasepool {
                for item in stats?.shownItems ?? [] {
                    item.show(Self.stressValue(for: item.kind, step: step))
                }
                CATransaction.flush()
            }
            DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
                MainActor.assumeIsolated { self?.stressTicks(remaining: remaining - 1, step: step + 1) }
            }
        }

        private static func stressValue(for kind: MetricKind, step: Int) -> MenuValue {
            // Stays within two digits, so the width stays put and this does not measure the system's layout.
            let percent = 10 + (step * 7) % 89
            switch kind {
            case .network:
                return .rates(
                    up: CompactRate(bytesPerSecond: Double(100_000 + step % 800 * 1_000)),
                    down: CompactRate(bytesPerSecond: Double(100_000 + (step * 3) % 800 * 1_000)))
            case .battery:
                return .battery(percent: percent, isCharging: false)
            default:
                return .percent(percent)
            }
        }

        /// Every window of this process, with its frame in screen coordinates from the top left of the main display,
        /// as screencapture and CGWindowList count them.
        private static func windowList() -> String {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let rows: [[String: Any]] = NSApp.windows.map { window in
                let frame = window.frame
                return [
                    "number": window.windowNumber, "class": String(describing: type(of: window)),
                    "visible": window.isVisible, "key": window.isKeyWindow, "level": window.level.rawValue,
                    "occlusionVisible": window.occlusionState.contains(.visible),
                    "screen": window.screen?.localizedName ?? "",
                    "appearance": window.effectiveAppearance.name.rawValue,
                    "frame": [frame.minX, mainHeight - frame.maxY, frame.width, frame.height],
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        private static func concealedRow(in view: NSView) -> ConcealedRow? {
            if let row = view as? ConcealedRow { return row }
            for child in view.subviews {
                if let row = concealedRow(in: child) { return row }
            }
            return nil
        }

        private static func describe(_ view: NSView, depth: Int, into lines: inout [String]) {
            guard depth < 7 else { return }
            let indent = String(repeating: "  ", count: depth)
            let text = (view as? NSTextField)?.stringValue ?? ""
            lines.append(
                "\(indent)\(type(of: view)) y=\(view.frame.minY) h=\(view.frame.height) hidden=\(view.isHidden) \(text)"
            )
            view.subviews.forEach { describe($0, depth: depth + 1, into: &lines) }
        }

        /// Includes content that lives in custom layers, which the display-based snapshot below misses.
        private static func snapshotLayers(_ view: NSView, to path: String) {
            view.wantsLayer = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let layer = view.layer, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else { return }
            layer.render(in: context.cgContext)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        private static func snapshot(_ view: NSView, to path: String) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        private static var sheetScale: CGFloat = 3

        /// The sheet's scale from a command, 3 unless it is a sensible number.
        private static func scale(_ words: [String]) -> CGFloat {
            guard words.count > 2, let scale = Double(words[2]), scale.isFinite, scale > 0, scale <= 8 else { return 3 }
            return scale
        }
        private static let sheetRowHeight: CGFloat = 26
        private static let sheetTitleWidth: CGFloat = 150
        private static let sheetGap: CGFloat = 16
        private static let sheetMargin: CGFloat = 12

        private struct SheetRow {
            let title: String
            let items: [StatusLabelContent]
        }

        private static func tinted(_ image: CGImage, _ color: CGColor) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.draw(image, in: rect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color)
            context.fill(rect)
            return context.makeImage()
        }

        /// Draws rows of real labels as the menu bar would, on a dark bar and then a light one.
        private static func writeSheet(_ rows: [SheetRow], to path: String) {
            let appearances: [(NSAppearance.Name, NSColor, NSColor)] = [
                (.darkAqua, NSColor(white: 0.1, alpha: 1), .white),
                (.aqua, NSColor(white: 0.92, alpha: 1), .black),
            ]
            let rowWidth =
                rows.map { row in
                    row.items.reduce(sheetTitleWidth) { $0 + StatusLabelRenderer.width(of: $1) + sheetGap }
                }.max() ?? 0
            let width = rowWidth + sheetMargin * 2
            let panelHeight = CGFloat(rows.count) * sheetRowHeight + sheetMargin
            let height = panelHeight * CGFloat(appearances.count)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width * sheetScale), pixelsHigh: Int(height * sheetScale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            let cg = context.cgContext
            cg.scaleBy(x: sheetScale, y: sheetScale)
            for (panel, (name, background, tint)) in appearances.enumerated() {
                let top = height - panelHeight * CGFloat(panel)
                cg.setFillColor(background.cgColor)
                cg.fill(CGRect(x: 0, y: top - panelHeight, width: width, height: panelHeight))
                let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
                for (index, row) in rows.enumerated() {
                    let y = top - CGFloat(index + 1) * sheetRowHeight
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSAttributedString(
                        string: row.title,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: tint.withAlphaComponent(0.6),
                        ]
                    ).draw(at: NSPoint(x: sheetMargin, y: y + 7))
                    NSGraphicsContext.restoreGraphicsState()
                    var x = sheetMargin + sheetTitleWidth
                    for item in row.items {
                        var accent: CGColor?
                        appearance.performAsCurrentDrawingAppearance { accent = item.accent?.color.cgColor }
                        let size = CGSize(width: StatusLabelRenderer.width(of: item), height: 22)
                        let bitmaps = StatusLabelRenderer.render(
                            item, size: size, scale: sheetScale, accentColor: accent)
                        let rect = CGRect(x: x, y: y + 2, width: size.width, height: size.height)
                        if let mask = bitmaps.mask, let image = tinted(mask, tint.cgColor) { cg.draw(image, in: rect) }
                        if let colored = bitmaps.colored { cg.draw(colored, in: rect) }
                        x += size.width + sheetGap
                    }
                }
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        private static func sampleRow(_ title: String, _ options: StatusLabelOptions) -> SheetRow {
            let kinds: [MetricKind] = [.cpu, .gpu, .memory, .disk, .network]
            return SheetRow(title: title, items: kinds.map { StatusLabelSample.content(kind: $0, options: options) })
        }

        /// The site's pictures of labels, on a clear background in the menu bar's ink, for a light bar and a dark one:
        /// each style as a strip of the five sample labels, four pixels to a point, and each metric's label for the
        /// made-up Mac's figures (see DemoData), six pixels to a point, which the site hangs its panels from.
        private static func siteLabels(to directory: String) {
            let sampleKinds: [MetricKind] = [.cpu, .gpu, .memory, .disk, .network]
            let metricKinds: [MetricKind] = [.cpu, .gpu, .memory, .disk, .network, .battery]
            let themes: [(String, NSAppearance.Name, NSColor)] = [
                ("light", .aqua, .black), ("dark", .darkAqua, .white),
            ]
            for (theme, name, ink) in themes {
                let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
                for style in MenuBarStyle.allCases {
                    let options = StatusLabelOptions(style: style, alignment: .center, batteryStyle: .number)
                    let items = sampleKinds.map { StatusLabelSample.content(kind: $0, options: options) }
                    writeStrip(
                        items, scale: 4, appearance: appearance, ink: ink,
                        to: "\(directory)/style-\(style.rawValue)-\(theme).png")
                }
                let options = StatusLabelOptions(style: .stacked, alignment: .left, batteryStyle: .number)
                for kind in metricKinds {
                    let item = StatusLabelContent.make(
                        kind: kind, value: DemoData.menuValue(of: kind), options: options)
                    writeStrip(
                        [item], scale: 6, appearance: appearance, ink: ink,
                        to: "\(directory)/label-\(kind.rawValue)-\(theme).png")
                }
            }
        }

        /// Labels side by side, as far apart as the menu bar puts its items, on nothing.
        private static func writeStrip(
            _ items: [StatusLabelContent], scale: CGFloat, appearance: NSAppearance, ink: NSColor, to path: String
        ) {
            let gap: CGFloat = 16
            let height: CGFloat = 22
            let widths = items.map { StatusLabelRenderer.width(of: $0) }
            let width = widths.reduce(0, +) + gap * CGFloat(max(items.count - 1, 0))
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: Int((width * scale).rounded(.up)), height: Int(height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.scaleBy(x: scale, y: scale)
            var x: CGFloat = 0
            for (item, itemWidth) in zip(items, widths) {
                var accent: CGColor?
                appearance.performAsCurrentDrawingAppearance { accent = item.accent?.color.cgColor }
                let size = CGSize(width: itemWidth, height: height)
                let bitmaps = StatusLabelRenderer.render(item, size: size, scale: scale, accentColor: accent)
                let rect = CGRect(origin: CGPoint(x: x, y: 0), size: size)
                if let mask = bitmaps.mask, let image = tinted(mask, ink.cgColor) { context.draw(image, in: rect) }
                if let colored = bitmaps.colored { context.draw(colored, in: rect) }
                x += itemWidth + gap
            }
            guard let image = context.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        /// Renders every style for every metric, as they would look at real size.
        private static func snapshotLabels(to path: String) {
            var rows: [SheetRow] = []
            for style in MenuBarStyle.allCases {
                if style.usesCaption {
                    for alignment in CaptionAlignment.allCases {
                        rows.append(
                            sampleRow(
                                "\(style.title) · \(alignment.title)",
                                StatusLabelOptions(style: style, alignment: alignment, batteryStyle: .number)))
                    }
                } else {
                    rows.append(
                        sampleRow(
                            style.title, StatusLabelOptions(style: style, alignment: .center, batteryStyle: .number)))
                }
            }
            rows += valueRows()
            writeSheet(rows, to: path)
        }

        /// Every style over the values that change a label's shape: one to three digits, each unit of a rate.
        private static func valueRows() -> [SheetRow] {
            let percents = [0, 7, 58, 100].map { MenuValue.percent($0) }
            let rates = [(0.0, 0.0), (34_000, 1_240_000), (2_500_000, 87_000), (345_000_000, 12_300_000_000)]
                .map { MenuValue.rates(up: CompactRate(bytesPerSecond: $0.0), down: CompactRate(bytesPerSecond: $0.1)) }
            return MenuBarStyle.allCases.flatMap { style -> [SheetRow] in
                CaptionAlignment.allCases.map { alignment in
                    let options = StatusLabelOptions(style: style, alignment: alignment, batteryStyle: .sameAsOthers)
                    var history = StatusLabelHistory()
                    let percentItems = percents.map { value -> StatusLabelContent in
                        history.record(value)
                        history.record(.percent(40))
                        return StatusLabelContent.make(kind: .cpu, value: value, options: options, history: history)
                    }
                    var rateHistory = StatusLabelHistory()
                    let rateItems = rates.map { value -> StatusLabelContent in
                        rateHistory.record(value)
                        return StatusLabelContent.make(
                            kind: .network, value: value, options: options, history: rateHistory)
                    }
                    return SheetRow(title: "\(style.rawValue) \(alignment.rawValue)", items: percentItems + rateItems)
                }
            }
        }

        /// Draws all the items side by side as the menu bar places them, over values that change a label's shape, and
        /// writes down the gap between each pair of neighbours. A crowded menu bar hides most of them from a photo.
        private static func snapshotRows(to path: String) {
            let scale: CGFloat = 2
            let systemGap: CGFloat = 16
            let order: [MetricKind] = [.cpu, .gpu, .memory, .disk, .network, .battery]
            func rate(_ bytes: Double) -> MenuValue {
                .rates(up: CompactRate(bytesPerSecond: bytes / 8), down: CompactRate(bytesPerSecond: bytes))
            }
            func values(_ cpu: Int, _ gpu: Int, _ memory: Int, _ disk: Int, _ net: Double, _ battery: Int)
                -> [MetricKind:
                MenuValue]
            {
                [
                    .cpu: .percent(cpu), .gpu: .percent(gpu), .memory: .percent(memory), .disk: .percent(disk),
                    .network: rate(net), .battery: .battery(percent: battery, isCharging: false),
                ]
            }
            let scenarios: [(String, [MetricKind: MenuValue])] = [
                ("calm", values(7, 3, 85, 65, 12_000, 94)),
                ("working", values(23, 14, 85, 65, 340_000, 94)),
                ("busy", values(58, 47, 91, 65, 12_000_000, 94)),
                ("mixed", values(100, 7, 85, 9, 880_000_000, 8)),
                ("all full", values(100, 100, 100, 100, 880_000_000, 100)),
            ]
            let looks: [(String, StatusLabelOptions)] = [
                ("name left", StatusLabelOptions(style: .stacked, alignment: .left, batteryStyle: .number)),
                ("name centre", StatusLabelOptions(style: .stacked, alignment: .center, batteryStyle: .number)),
                ("name right", StatusLabelOptions(style: .stacked, alignment: .right, batteryStyle: .number)),
                ("icon + value", StatusLabelOptions(style: .icon, alignment: .left, batteryStyle: .number)),
                ("value only", StatusLabelOptions(style: .value, alignment: .left, batteryStyle: .number)),
            ]
            let rowHeight: CGFloat = 26
            let titleWidth: CGFloat = 150
            let width: CGFloat = 560
            let height = rowHeight * CGFloat(looks.count * scenarios.count) + 8
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var report = ""
            var row = 0
            for (lookName, options) in looks {
                for (scenarioName, scenario) in scenarios {
                    row += 1
                    let y = height - CGFloat(row) * rowHeight
                    let title = "\(lookName), \(scenarioName)"
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSAttributedString(
                        string: title,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 9),
                            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                        ]
                    ).draw(at: NSPoint(x: 8, y: y + 7))
                    NSGraphicsContext.restoreGraphicsState()
                    var x = titleWidth
                    var previousRight: CGFloat?
                    var gaps: [String] = []
                    for kind in order {
                        guard let value = scenario[kind] else { continue }
                        let content = StatusLabelContent.make(kind: kind, value: value, options: options)
                        let length = MetricStatusItem.length(of: kind, options: options)
                        let frame = StatusLabelView.canvasFrame(
                            for: content, in: CGSize(width: length, height: 22),
                            overflowRoom: MetricStatusItem.overflowRoom)
                        var accent: CGColor?
                        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                            accent = content.accent?.color.cgColor
                        }
                        let bitmaps = StatusLabelRenderer.render(
                            content, size: frame.size, scale: scale, accentColor: accent)
                        let rect = CGRect(x: x + frame.minX, y: y + 2, width: frame.width, height: frame.height)
                        if let mask = bitmaps.mask, let image = tinted(mask, CGColor(gray: 1, alpha: 1)) {
                            cg.draw(image, in: rect)
                        }
                        if let colored = bitmaps.colored { cg.draw(colored, in: rect) }
                        if let previousRight { gaps.append(String(format: "%.0f", rect.minX - previousRight)) }
                        previousRight = rect.maxX
                        x += length + systemGap
                    }
                    report += "\(title): gaps \(gaps.joined(separator: " "))\n"
                }
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            try? report.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }

        /// Renders every battery style in every state.
        private static func snapshotBattery(to path: String) {
            let states: [(percent: Int, charging: Bool, plugged: Bool, lowPower: Bool)] = [
                (100, false, false, false), (62, false, false, false), (45, false, false, false),
                (15, false, false, false), (8, false, false, false),
                (62, true, true, false), (28, true, true, false), (99, true, true, false), (15, true, true, false),
                (8, true, true, false), (100, false, true, false), (62, false, true, false),
                (100, false, false, true), (62, false, false, true), (15, false, false, true), (62, true, true, true),
                (99, true, true, true),
            ]
            let styles = BatteryBarStyle.allCases.filter { $0 != .sameAsOthers }
            let rows = [true, false].flatMap { colors in
                styles.map { style in
                    SheetRow(
                        title: style.title + (colors ? "" : " · белая"),
                        items: states.map {
                            StatusLabelContent.make(
                                kind: .battery,
                                value: .battery(percent: $0.percent, isCharging: $0.charging, isPluggedIn: $0.plugged),
                                options: StatusLabelOptions(
                                    style: .stacked, alignment: .center, batteryStyle: style,
                                    colorsBatteryWhileCharging: colors),
                                isLowPower: $0.lowPower)
                        })
                }
            }
            writeSheet(rows, to: path)
        }

        /// Reports where each style's ink lies at the screen's scales, and writes an enlarged sheet to judge its edges.
        private static func auditLabels(toDirectory directory: String) {
            var report = ""
            var rows: [(String, [CGImage])] = []
            for scale in [CGFloat(2), 1] {
                report += "=== scale \(Int(scale))x, canvas middle row \(Double(22 * scale - 1) / 2)\n"
                for style in MenuBarStyle.allCases {
                    let options = StatusLabelOptions(style: style, alignment: .center, batteryStyle: .number)
                    var images: [CGImage] = []
                    for item in sampleRow(style.title, options).items {
                        let size = CGSize(width: StatusLabelRenderer.width(of: item), height: 22)
                        let bitmaps = StatusLabelRenderer.render(item, size: size, scale: scale, accentColor: nil)
                        guard let mask = bitmaps.mask, let ink = inkRows(mask) else { continue }
                        report += String(
                            format: "%-14@ w %3.0f  rows %2d...%-2d  middle %4.1f  side %d/%d\n",
                            style.rawValue as NSString, size.width, ink.top, ink.bottom,
                            Double(ink.top + ink.bottom) / 2, ink.left, mask.width - 1 - ink.right)
                        if scale == 2 { images.append(mask) }
                    }
                    if scale == 2 { rows.append((style.title, images)) }
                }
            }
            try? report.write(toFile: directory + "/audit.txt", atomically: true, encoding: .utf8)
            let factor = 5
            let height = rows.count * (44 * factor + 10)
            let width = (rows.map { $0.1.reduce(0) { $0 + $1.width + 16 } }.max() ?? 0) * factor
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.interpolationQuality = .none
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, row) in rows.enumerated() {
                var x = 8 * factor
                let y = height - (index + 1) * (44 * factor + 10)
                for mask in row.1 {
                    if let image = tinted(mask, CGColor(gray: 1, alpha: 1)) {
                        context.draw(
                            image, in: CGRect(x: x, y: y, width: mask.width * factor, height: mask.height * factor))
                    }
                    x += (mask.width + 16) * factor
                }
            }
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory + "/audit.png"))
            }
        }

        /// The extent of a bitmap's ink in pixels, counting rows from the top.
        private static func inkRows(_ image: CGImage) -> (top: Int, bottom: Int, left: Int, right: Int)? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let data = context.data
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var top = image.height
            var bottom = -1
            var left = image.width
            var right = -1
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 64 {
                    top = min(top, y)
                    bottom = max(bottom, y)
                    left = min(left, x)
                    right = max(right, x)
                }
            }
            return bottom >= 0 ? (top, bottom, left, right) : nil
        }
    }

    /// What one menu bar update costs at each step, for every style. Each step runs many times over changing
    /// values and reports instructions and CPU time per call, which are far steadier than a CPU percentage.
    enum LabelBenchmark {
        private static let rounds = 400

        private static func instructions() -> UInt64 {
            // The kernel brings a running thread's counters up to date when it switches away from it.
            usleep(1_000)
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? info.ri_instructions : 0
        }

        private static func measure(_ body: (Int) -> Void) -> (instructions: Double, microseconds: Double) {
            let startInstructions = instructions()
            let startTime = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for round in 0..<rounds {
                autoreleasepool { body(round) }
            }
            let time = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- startTime
            let spent = instructions() &- startInstructions
            return (Double(spent) / Double(rounds), Double(time) / 1_000 / Double(rounds))
        }

        private static func value(kind: MetricKind, round: Int) -> MenuValue {
            let percent = 10 + (round * 7) % 89
            switch kind {
            case .network:
                return .rates(
                    up: CompactRate(bytesPerSecond: Double(2_000 + (round * 13) % 900) * 1_000),
                    down: CompactRate(bytesPerSecond: Double(100 + (round * 37) % 900) * 1_000))
            case .battery:
                return .battery(percent: percent, isCharging: false)
            default:
                return .percent(percent)
            }
        }

        static func run(to path: String) {
            var report = "style\tkind\tmake_ki\twidth_ki\trender_ki\ttotal_ki\ttotal_us\n"
            let cases: [(String, MetricKind, StatusLabelOptions)] =
                MenuBarStyle.allCases.flatMap { style -> [(String, MetricKind, StatusLabelOptions)] in
                    let options = StatusLabelOptions(style: style, alignment: .left, batteryStyle: .sameAsOthers)
                    return [(style.rawValue, .cpu, options), (style.rawValue, .network, options)]
                }
                + [BatteryBarStyle.glyph, .number, .side].map { style in
                    (
                        "battery-\(style.rawValue)", .battery,
                        StatusLabelOptions(style: .stacked, alignment: .left, batteryStyle: style)
                    )
                }
            for (name, kind, options) in cases {
                var history = StatusLabelHistory()
                let contents = (0..<rounds).map { round -> StatusLabelContent in
                    let value = value(kind: kind, round: round)
                    if options.style.usesHistory { history.record(value) }
                    return StatusLabelContent.make(kind: kind, value: value, options: options, history: history)
                }
                var replay = StatusLabelHistory()
                let make = measure { round in
                    let value = value(kind: kind, round: round)
                    if options.style.usesHistory { replay.record(value) }
                    _ = StatusLabelContent.make(kind: kind, value: value, options: options, history: replay)
                }
                let width = measure { round in _ = StatusLabelRenderer.width(of: contents[round]) }
                let widths = contents.map { StatusLabelRenderer.width(of: $0) }
                let render = measure { round in
                    let size = CGSize(width: widths[round], height: 22)
                    _ = StatusLabelRenderer.render(contents[round], size: size, scale: 2, accentColor: nil)
                }
                let total = make.instructions + width.instructions + render.instructions
                let time = make.microseconds + width.microseconds + render.microseconds
                report += String(
                    format: "%@\t%@\t%.0f\t%.0f\t%.0f\t%.0f\t%.1f\n", name as NSString, kind.rawValue as NSString,
                    make.instructions / 1_000, width.instructions / 1_000, render.instructions / 1_000,
                    total / 1_000, time)
            }
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif
