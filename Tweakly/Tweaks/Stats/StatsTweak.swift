import AppKit
import FanControlCore
import SystemMetrics

/// The statistics feature: owns the menu bar items, details popover and sampling engine, and decides
/// what gets sampled. With no metric enabled and nothing on screen it holds no engine at all.
final class StatsTweak {
    /// Seconds between readings of the load an icon follows. Often enough to feel alive, since its speed changes
    /// gradually anyway, and this path is the default, so it has to fit the budget of an idle agent.
    private static let iconLoadInterval: TimeInterval = 3
    /// Seconds between readings for the fans. A temperature does not move faster than a fan can answer it.
    private static let fanInterval: TimeInterval = 3

    private let settings: AppSettings
    private let statusMenu: AppStatusMenu
    private var items: [MetricKind: MetricStatusItem] = [:]
    /// The simple view's one item, in place of all the others.
    private var simpleItem: SimpleStatusItem?
    private lazy var presenter = MetricPopoverPresenter { [weak self] in
        self?.detailsChanged()
    }
    private var engine: MetricsEngine?
    /// Exists only while something takes a fan from the system.
    private var fanDriver: FanDriver?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var rightClickMonitor: Any?
    private var isSystemAsleep = false
    private var isScreenAsleep = false
    private var isSessionInactive = false
    private var lastPlan = SamplingPlan()
    /// The battery's last reading, shown again when Low Power Mode changes its colour without changing its charge.
    private var lastBattery: MetricUpdate?
    private var voiceOverObservation: NSKeyValueObservation?

    init(settings: AppSettings, statusMenu: AppStatusMenu) {
        self.settings = settings
        self.statusMenu = statusMenu
        statusMenu.onChooseLook = { [weak self] look in
            self?.settings.simpleViewLook = look
            ProcessEvents.post(.simpleLookChanged)
        }
        statusMenu.onChooseFanProfile = { [weak self] in self?.chooseFans($0) }
    }

    /// Brings items, observers and the engine in line with the current settings.
    func settingsChanged() {
        presenter.fanActions = fanActions
        presenter.updateAppearance()
        reconcileItems()
        updateRightClickMonitor()
        applyPlan()
    }

    #if TWEAKLY_AUTOMATION
        /// Opens details the same way a click on the item does.
        func openDetails(for kind: MetricKind) {
            guard let item = items[kind] else { return }
            presenter.show(for: item)
        }

        func openSimple() {
            if let simpleItem { presenter.show(for: simpleItem) }
        }

        /// Stands in for a reading of the load, which a test cannot simply ask the Mac for.
        func feedIconLoad(of kind: MetricKind, value: MenuValue) {
            simpleItem?.noteLoad(of: kind, value: value)
        }

        func closeDetails() {
            presenter.close()
        }

        var detailContentView: NSView? { presenter.contentView }

        func item(for kind: MetricKind) -> MetricStatusItem? { items[kind] }
        var shownItems: [MetricStatusItem] { Array(items.values) }

        var automationDescription: String {
            let lines = items.values.sorted { $0.kind.rawValue < $1.kind.rawValue }.map { item in
                let window = item.button?.window
                return
                    "\(item.kind.rawValue): frame=\(window?.frame ?? .zero) visible=\(window?.isVisible ?? false) occlusion=\(window?.occlusionState.rawValue ?? 0) \(item.labelDescription)"
            }
            let view = presenter.contentView
            let levels = lastPlan.levels.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
            let state =
                "details=\(presenter.current.map { String(describing: $0) } ?? "none") bounds=\(view?.bounds ?? .zero)"
                + " simpleItem=\(simpleItem?.button?.window?.frame ?? .zero) engine=\(engine != nil)"
                + " \(simpleItem?.automationDescription ?? "")"
            return
                (lines + [
                    state,
                    "plan=\(levels) interval=\(lastPlan.menuIntervals.values.min() ?? 0) paused=\(lastPlan.isPaused)",
                    "asleep=\(isSystemAsleep) screen=\(isScreenAsleep) session=\(isSessionInactive) fans=\(fanDriver != nil)",
                ])
                .joined(separator: "\n") + "\n"
        }
    #endif

    private func reconcileItems() {
        // A metric the simple view shows gives up its own item for now, and a metric it does not show carries on. What
        // each metric's page says stays as it is, for when the simple view is turned off again.
        var wanted = settings.enabledMetrics.intersection(MetricKind.available)
        if settings.simpleViewEnabled { wanted.subtract(settings.simpleViewMetrics) }
        for (kind, item) in items where !wanted.contains(kind) {
            if presenter.current == .details(kind) { presenter.close() }
            item.remove()
            items[kind] = nil
        }
        // Newly created items appear to the left of existing ones, so creating them last-to-first
        // gives the natural CPU, GPU, Memory... reading order on first launch.
        for kind in MetricKind.allCases.reversed() where wanted.contains(kind) && items[kind] == nil {
            items[kind] = MetricStatusItem(
                kind: kind,
                options: labelOptions(for: kind),
                onOpen: { [weak self] in self?.presenter.show(for: $0) },
                onToggle: { [weak self] in self?.presenter.toggle(for: $0) },
                onDismiss: { [weak self] in self?.presenter.dismiss(for: $0) }
            )
        }
        for (kind, item) in items { item.setOptions(labelOptions(for: kind)) }
        // The engine may stay for the simple view's icon or the fans, but the labels' symbols and text are gone.
        if items.isEmpty { StatusLabelRenderer.releaseCaches() }
        reconcileSimpleItem()
    }

    private func reconcileSimpleItem() {
        guard settings.simpleViewEnabled else {
            if let simpleItem {
                if presenter.current == simpleItem.popover { presenter.close() }
                simpleItem.remove()
            }
            simpleItem = nil
            return
        }
        let popover = StatsPopover.simple(
            MetricKind.available.filter(settings.simpleViewMetrics.contains), settings.simpleViewLook)
        let item =
            simpleItem
            ?? SimpleStatusItem(
                popover: popover,
                onOpen: { [weak self] in self?.presenter.show(for: $0) },
                onToggle: { [weak self] in self?.presenter.toggle(for: $0) },
                onDismiss: { [weak self] in self?.presenter.dismiss(for: $0) }
            )
        simpleItem = item
        if item.popover != popover {
            if presenter.current == item.popover { presenter.close() }
            item.popover = popover
        }
        item.setIcon(id: settings.simpleViewIcon, usesOwnColours: settings.simpleViewIconOwnColours)
    }

    /// The menu that a popover's buttons used to stand in for. On macOS 27 a right click reaches the app and leaves the
    /// expanded-interface session alone, unlike a scroll, and nothing needs to listen until one comes.
    private func updateRightClickMonitor() {
        let isNeeded = !items.isEmpty || simpleItem != nil
        guard isNeeded != (rightClickMonitor != nil) else { return }
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        } else {
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                let isHandled = MainActor.assumeIsolated { self?.showMenu(for: event) == true }
                return isHandled ? nil : event
            }
        }
    }

    private func showMenu(for event: NSEvent) -> Bool {
        let all: [PopoverStatusItem] = Array(items.values) + (simpleItem.map { [$0] } ?? [])
        guard let item = all.first(where: { $0.button?.window === event.window && event.window != nil }),
            let button = item.button
        else { return false }
        presenter.close()
        let menu = NSMenu()
        // Only where the fans are shown, and only once there is a helper to carry the choice out.
        let showsFans = SystemInfo.hasFans && item.popover.shows(.fans) && FanHelperClient.isInstalled
        statusMenu.fill(
            menu, offersBatterySettings: item.popover == .details(.battery),
            simpleLook: item === simpleItem ? settings.simpleViewLook : nil,
            fanProfiles: showsFans ? settings.fanSettings.allProfiles : [], currentFanProfile: currentFanProfile)
        NSMenu.popUpContextMenu(menu, with: event, for: button)
        return true
    }

    private func labelOptions(for kind: MetricKind) -> StatusLabelOptions {
        let appearance = settings.appearance(of: kind)
        return StatusLabelOptions(
            style: appearance.style, alignment: appearance.alignment, batteryStyle: settings.batteryStyle,
            colorsBatteryWhileCharging: settings.colorsBatteryWhileCharging,
            fanShowsTemperature: settings.fansShowTemperature)
    }

    private func detailsChanged() {
        applyPlan()
    }

    private func applyPlan() {
        updateIconMotion()
        updateFanDriver()
        let plan = makePlan()
        // Items that are all out of sight still need the engine and its observers, to come back when they
        // reappear. Its plan is then empty, so it holds no timer and no sampler. So does an icon that plays by itself.
        // Fans given back for sleep count too, or nothing would hear the wake and they would never be taken again.
        let needsEngine = !items.isEmpty || presenter.current != nil || simpleItem?.isLive == true || wantsFans
        if needsEngine, engine == nil {
            startEngine()
        }
        if plan != lastPlan {
            // A chart in the menu bar after a sleep, or back from behind the notch, would draw what it showed before
            // right next to what comes now, as if moments apart.
            for (kind, item) in items
            where (lastPlan.isPaused && !plan.isPaused) || (lastPlan.levels[kind] == nil && plan.levels[kind] != nil) {
                item.forgetHistory()
            }
            lastPlan = plan
            engine?.apply(plan)
        }
        if !needsEngine, engine != nil {
            stopEngine()
        }
    }

    /// An icon nobody can see, or that the person has asked not to see moving, costs nothing at all.
    private func updateIconMotion() {
        guard let simpleItem else { return }
        let isAsleep = isSystemAsleep || isScreenAsleep || isSessionInactive
        simpleItem.setMotion(
            settings.iconMotion, isSeen: !isAsleep && simpleItem.isOnScreen,
            reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            isSlowed: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func makePlan() -> SamplingPlan {
        // A job left running with the screen off or locked still makes heat, so the fans are the one thing that goes on
        // unseen.
        if isUnseen, !isSystemAsleep, fanDriver != nil {
            return SamplingPlan(
                levels: [.fans: .menu], menuIntervals: [.fans: Self.fanInterval], kindsReportingEverySample: [.fans])
        }
        var levels: [MetricKind: SamplingLevel] = [:]
        // Sampling what nobody can see would be exactly the work this app promises not to do. A plain symbol shows no
        // value at all, and its value is only heard, by someone using VoiceOver.
        let hearsValues = NSWorkspace.shared.isVoiceOverEnabled
        for (kind, item) in items where item.isOnScreen && (hearsValues || showsValue(kind)) { levels[kind] = .menu }
        switch presenter.current {
        case .details(let kind): levels[kind] = .detail
        case .simple(let kinds, let look):
            // Rings need only one figure each, and a list also needs the parts and the temperature. The disk's ring
            // shows a whole percent, as its menu bar label does, which needs no count of what could be cleared.
            for kind in kinds { levels[kind] = look == .list ? .summary : kind == .disk ? .menu : .overview }
        case nil: break
        }
        // Low Power Mode slows everything down, because the person has asked the Mac to save energy.
        let slowdown: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1
        var intervals: [MetricKind: TimeInterval] = [:]
        var charts: Set<MetricKind> = []
        for kind in items.keys {
            let appearance = settings.appearance(of: kind)
            intervals[kind] = appearance.interval.rawValue * slowdown
            if appearance.style.usesHistory { charts.insert(kind) }
        }
        // Not slowed for Low Power Mode, as this is what keeps the Mac safe, and on every sample, as it follows temperature.
        if fanDriver != nil {
            if levels[.fans] == nil { levels[.fans] = .menu }
            intervals[.fans] = min(intervals[.fans] ?? .infinity, Self.fanInterval)
            charts.insert(.fans)
        }
        for kind in simpleItem?.loadKinds ?? [] {
            if levels[kind] == nil { levels[kind] = .menu }
            intervals[kind] = min(intervals[kind] ?? .infinity, Self.iconLoadInterval * slowdown)
            // The icon comes to a new load over several readings, and at a steady load they are all the same.
            charts.insert(kind)
        }
        return SamplingPlan(
            levels: levels,
            menuIntervals: intervals,
            isPaused: isSystemAsleep || isScreenAsleep || isSessionInactive,
            kindsReportingEverySample: charts
        )
    }

    /// Every style draws the value but the plain symbol, which for the battery still follows its charge.
    private func showsValue(_ kind: MetricKind) -> Bool {
        kind == .battery || settings.appearance(of: kind).style != .symbol
    }

    private func startEngine() {
        engine = MetricsEngine { [weak self] updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(updates) }
            }
        }
        lastPlan = SamplingPlan()
        observeSystem()
    }

    private func stopEngine() {
        engine = nil
        lastPlan = SamplingPlan()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        voiceOverObservation = nil
        lastBattery = nil
        // Nothing reports the next wake once the observers are gone.
        isSystemAsleep = false
        isScreenAsleep = false
        isSessionInactive = false
        StatusLabelRenderer.releaseCaches()
    }

    private func deliver(_ updates: [MetricUpdate]) {
        for update in updates {
            if update.kind == .battery { lastBattery = update }
            if !isUnseen { items[update.kind]?.show(update.menuValue) }
            if case .fans(let fans) = update { fanDriver?.follow(fans, settings: settings.fanSettings) }
            if presenter.current?.shows(update.kind) == true { presenter.deliver(update) }
        }
        simpleItem?.noteLoads(updates)
    }

    private func isItemWindow(_ window: NSWindow) -> Bool {
        simpleItem?.button?.window === window || items.values.contains { $0.button?.window === window }
    }

    private var wantsFans: Bool {
        #if TWEAKLY_AUTOMATION
            // The made-up fans of a test copy taking pictures are only drawn, never driven.
            if DemoData.isOn { return false }
        #endif
        return SystemInfo.hasFans && settings.fanSettings.takesFans
    }

    private var isUnseen: Bool { isScreenAsleep || isSessionInactive }

    /// An inactive session alone does not say someone else took over, as it may only be locked. Only another person at the
    /// console means this session is really not in charge.
    private var isAnotherUserActive: Bool {
        guard isSessionInactive else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?[kCGSessionOnConsoleKey] as? Bool == false
    }

    /// On the way to sleep the fans go back to the system, and they are taken again after waking. So too while another
    /// person is using the Mac, as this is one person's choice. A screen that is off or locked changes nothing.
    private func updateFanDriver() {
        let isWanted = wantsFans && !isSystemAsleep && !isAnotherUserActive
        if isWanted, fanDriver == nil {
            fanDriver = FanDriver()
        } else if !isWanted {
            fanDriver?.giveBack(because: isSystemAsleep ? "sleep" : wantsFans ? "another user" : "no longer wanted")
            fanDriver = nil
            FanDriverStatus.forget()
        }
    }

    private var fanActions: FanQuickActions {
        FanQuickActions(
            current: { [weak self] in self?.currentFanProfile },
            choose: { [weak self] in self?.chooseFans($0) },
            openWindow: { WindowProcess.open() },
            problem: { [weak self] in self?.fanDriver?.status.message })
    }

    /// The plan in force right now, as the choices in the menu bar act on what is running.
    private var isFanPlanForBattery: Bool {
        settings.fanSettings.battery != nil && FanDriver.isOnBattery
    }

    private var currentFanProfile: FanProfileChoice? {
        let fans = settings.fanSettings
        return fans.profile(of: fans.plan(onBattery: isFanPlanForBattery))
    }

    private func chooseFans(_ choice: FanProfileChoice) {
        var fans = settings.fanSettings
        guard let plan = fans.plan(of: choice) else { return }
        if isFanPlanForBattery { fans.battery = plan } else { fans.adapter = plan }
        settings.fanSettings = fans
        ProcessEvents.post(.fanSettingsChanged)
    }

    /// Nothing is visible while the system or display sleeps or another user is active, so sampling stops.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func watch(
            _ name: Notification.Name,
            center: NotificationCenter = workspace,
            _ change: @escaping @MainActor @Sendable (StatsTweak) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                    self.applyPlan()
                }
            }
            observers.append((center, observer))
        }
        watch(NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        watch(NSWorkspace.didWakeNotification) { $0.isSystemAsleep = false }
        watch(NSWorkspace.screensDidSleepNotification) { $0.isScreenAsleep = true }
        watch(NSWorkspace.screensDidWakeNotification) { $0.isScreenAsleep = false }
        watch(NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionInactive = true }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionInactive = false }
        watch(.NSProcessInfoPowerStateDidChange, center: .default) {
            $0.items[.battery]?.powerStateChanged()
            // The rings and the list colour the battery for Low Power Mode, which sends no battery reading of its own.
            if let battery = $0.lastBattery, $0.presenter.current?.shows(.battery) == true {
                $0.presenter.deliver(battery)
            }
        }
        // Only this tweak's own items: every popover, Dock preview and Command-Tab panel of the agent sends it too.
        let occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, self.isItemWindow(window) else { return }
                self.applyPlan()
            }
        }
        observers.append((.default, occlusion))
        watch(NSApplication.didChangeScreenParametersNotification, center: .default) { _ in }
        watch(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { _ in }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyPlan() } }
        }
    }
}
