import AppKit
import WindowSwitcherCore
import os

/// Previews of an app's windows over its Dock icon, and a click on the icon of the app in front putting it away, as on a
/// Windows taskbar. While on and the pointer is elsewhere it holds an Accessibility observer on the Dock, an event tap
/// that is off and a few notices, and does nothing: the Dock says when the pointer comes onto an icon. Pictures of
/// windows come from `WindowPictureStore`, shared with Command-Tab.
final class DockTweak {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "dock")
    /// Kept while windows come and go, and dropped whole past this, rather than checked against every open window.
    private static let mostKinds = 512

    var tuning = DockTuning() {
        didSet {
            guard !tuning.showsPanel, oldValue.showsPanel else { return }
            dismiss()
            panelWindow?.orderOut(nil)
            panelWindow = nil
        }
    }

    /// The panel up now and what it was built from.
    private final class Shown {
        let app: NSRunningApplication
        let items: [SwitcherItem]
        let panel: DockPreviewPanel
        var capture: WindowPictureStore.Request?
        var tookPictures = false

        init(app: NSRunningApplication, items: [SwitcherItem], panel: DockPreviewPanel) {
            self.app = app
            self.items = items
            self.panel = panel
        }
    }

    /// The button went down on an icon. Whether that was a click is known when it comes up.
    private struct Press {
        let location: CGPoint
        let seconds: TimeInterval
        let app: NSRunningApplication
        let wasFrontmost: Bool
        let hadWindowInSight: Bool
    }

    private let pictures: WindowPictureStore
    private var watcher: DockWatcher?
    /// Made when watching starts and kept until it stops, so a panel never waits for a window to be made.
    private var panelWindow: DockPreviewWindow?
    private var tap: DockClickTap?
    private var hover = DockHover()
    private var showTimer: DispatchWorkItem?
    private var hideTimer: DispatchWorkItem?
    private var shown: Shown?
    private var press: Press?
    /// What each window is, as asking the app on every hover would wait on it for nothing.
    private var kinds: [CGWindowID: WindowKind] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityChanges: AccessibilityChanges?

    init(pictures: WindowPictureStore) {
        self.pictures = pictures
    }

    /// Brings the observer and the tap in line with the tweak being on and Accessibility allowed.
    func update() {
        if observers.isEmpty { observeSystem() }
        #if TWEAKLY_AUTOMATION
            // A test copy on its own display has no Accessibility and no Dock, and shows panels on command.
            if QuietScreen.isActive {
                prepareWindow()
                return
            }
        #endif
        if AXIsProcessTrusted() {
            startWatching()
        } else {
            stopWatching()
        }
    }

    /// Leaves nothing running, so the object can be released. The pictures stay with their store.
    func stop() {
        stopWatching()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        accessibilityChanges = nil
        kinds = [:]
    }

    private func startWatching() {
        #if TWEAKLY_AUTOMATION
            // A test copy on its own display must not answer the real pointer on the Dock.
            if QuietScreen.isActive { return }
        #endif
        if watcher == nil {
            let watcher = DockWatcher()
            watcher.onChange = { [weak self] icon in self?.pointerMoved(to: icon) }
            watcher.start()
            self.watcher = watcher
        }
        // Only the click on the icon is wanted without previews, which needs no window.
        if tuning.showsPanel { prepareWindow() }
        if tap == nil {
            let tap = DockClickTap { [weak self] press in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.pressed(press) }
                }
            }
            if tap.start() { self.tap = tap }
        }
    }

    /// The panel's window, made and warmed up ahead of the first hover.
    private func prepareWindow() {
        guard panelWindow == nil else { return }
        let window = DockPreviewWindow.make()
        panelWindow = window
        // Not at once: the tweak may be starting with the app, which has better things to do in its first second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
            MainActor.assumeIsolated {
                if window?.isVisible == false { window?.warmUp() }
            }
        }
    }

    private func stopWatching() {
        dismiss()
        panelWindow?.orderOut(nil)
        panelWindow = nil
        watcher?.stop()
        watcher = nil
        tap?.stop()
        tap = nil
        press = nil
    }

    private func observeSystem() {
        func watch(
            _ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (DockTweak) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification) { $0.dismiss() }
        watch(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.dismiss() }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.dismiss() }
        watch(workspace, NSWorkspace.didTerminateApplicationNotification) { tweak in
            if tweak.shown?.app.isTerminated == true { tweak.dismiss() }
        }
        watch(.default, NSApplication.didChangeScreenParametersNotification) { $0.dismiss() }
        // A tap or an observer must not outlive the permission.
        accessibilityChanges = AccessibilityChanges { [weak self] in self?.update() }
    }

    // MARK: The pointer

    private func pointerMoved(to icon: DockIcon?) {
        // Clicks matter only on the Dock, so the tap listens only while the pointer is there.
        tap?.setEnabled(icon != nil)
        let app = tuning.showsPanel ? icon?.app : nil
        perform(hover.pointerOnDock(app: app?.processIdentifier, onIcon: icon != nil))
    }

    private func perform(_ actions: [DockHover.Action]) {
        for action in actions {
            switch action {
            case .show(let pid): show(pid)
            case .hide: closePanel()
            case .startShowTimer:
                showTimer?.cancel()
                // Without a delay the panel covers the Dock's bubble in the same moment, never a turn of the loop later.
                if tuning.delay == 0 {
                    perform(hover.showTimerFired())
                } else {
                    showTimer = schedule(after: tuning.delay) { $0.perform($0.hover.showTimerFired()) }
                }
            case .stopShowTimer:
                showTimer?.cancel()
                showTimer = nil
            case .startHideTimer:
                hideTimer?.cancel()
                hideTimer = schedule(after: DockTuning.fadeDelay) { $0.fadeOut() }
            case .stopHideTimer:
                hideTimer?.cancel()
                hideTimer = nil
                stopFading()
            }
        }
    }

    /// Counts fades, so that one stopped half way does not hide the panel when its animation ends anyway.
    private var fade = 0

    private func fadeOut() {
        hideTimer = nil
        guard let window = panelWindow, window.isVisible else {
            perform(hover.hideTimerFired())
            return
        }
        fade += 1
        let current = fade
        window.fade(to: 0, duration: DockTuning.fadeDuration) { [weak self] in
            guard let self, self.fade == current else { return }
            self.perform(self.hover.hideTimerFired())
            window.fade(to: 1, duration: 0)
        }
    }

    /// The pointer came back in time: the panel returns to full strength at once, as the Dock's bubble does.
    private func stopFading() {
        fade += 1
        panelWindow?.fade(to: 1, duration: 0)
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor (DockTweak) -> Void)
        -> DispatchWorkItem
    {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func dismiss() {
        perform(hover.dismiss())
        closePanel()
    }

    // MARK: The panel

    private func show(_ pid: pid_t) {
        guard let icon = currentIcon, let app = icon.app, app.processIdentifier == pid else {
            hover.nothingToShow()
            closePanel()
            return
        }
        if kinds.count > Self.mostKinds { kinds = [:] }
        let items = WindowCatalog.windows(of: app, kinds: &kinds)
        guard !items.isEmpty, let screen = Self.screen(containing: icon.dock) else {
            hover.nothingToShow()
            closePanel()
            return
        }
        present(items, of: app, icon: icon.frame, dock: icon.dock, on: screen)
    }

    private func present(
        _ items: [SwitcherItem], of app: NSRunningApplication, icon: CGRect, dock: CGRect, on screen: NSScreen
    ) {
        closePanel(keepingWindow: true)
        let visible = screen.visibleFrame
        let edge = DockGeometry.edge(ofDock: dock, on: screen.frame)
        let room = DockGeometry.room(for: edge, visible: visible)
        let metrics = tuning.layoutMetrics
        let layout = SwitcherLayout(
            aspects: items.map(\.aspect), available: room.available, overflow: room.overflow, metrics: metrics)
        guard !layout.tileFrames.isEmpty else {
            hover.nothingToShow()
            panelWindow?.orderOut(nil)
            return
        }
        let origin = DockGeometry.panelOrigin(size: layout.panelSize, icon: icon, edge: edge, visible: visible)
        let tailOffset = DockGeometry.tailOffset(
            icon: icon, panel: CGRect(origin: origin, size: layout.panelSize), edge: edge,
            cornerRadius: metrics.cornerRadius)
        let capturing = canCapture
        let listed = Array(items.prefix(layout.tileFrames.count))
        let appIcon = app.icon
        let window = panelWindow ?? DockPreviewWindow.make()
        panelWindow = window
        stopFading()
        let panel = DockPreviewPanel(
            in: window,
            tiles: listed.map { item in
                let title = item.window?.title ?? ""
                return WindowTile(
                    icon: appIcon, label: title.isEmpty ? item.appName : title,
                    accessibilityLabel: item.accessibilityLabel, hasWindow: true)
            },
            layout: layout, metrics: metrics, origin: origin, edge: edge, tailOffset: tailOffset,
            scale: screen.backingScaleFactor, willHavePictures: capturing)
        let shown = Shown(app: app, items: listed, panel: panel)
        panel.onClick = { [weak self] index in self?.choose(index) }
        panel.onPointerInside = { [weak self] inside in
            guard let self else { return }
            self.perform(self.hover.pointerInPanel(inside))
        }
        self.shown = shown
        if capturing { fillPictures(of: shown, layout: layout, scale: screen.backingScaleFactor) }
        panel.show()
    }

    /// What is known goes in at once, so it is there from the panel's first frame; the rest is taken, along with any
    /// picture old enough to have changed. A window Command-Tab took in the last seconds is not taken again.
    private func fillPictures(of shown: Shown, layout: SwitcherLayout, scale: CGFloat) {
        pictures.forgetClosedWindows()
        let retakeAfter = Duration.seconds(pictures.tuning.retakeAfterSeconds)
        var kept: [(index: Int, picture: SwitcherKeptPicture)] = []
        var requests: [WindowThumbnailer.Request] = []
        for (index, item) in shown.items.enumerated() {
            guard let window = item.window else { continue }
            let size = SwitcherLayout.thumbnailPixelSize(
                window: window.frame.size, tile: layout.tileFrames[index].size, scale: scale)
            if let picture = pictures.sharp[window.id] {
                shown.panel.setPicture(picture, at: index, animated: false)
                let isFresh = picture.takenAt.duration(to: .now) < retakeAfter
                let isLargeEnough = picture.image.width >= size.width || picture.image.height >= size.height
                if isFresh, isLargeEnough { continue }
            } else if let copy = pictures.kept[window.id] {
                kept.append((index, copy))
            }
            requests.append(.init(window: window.id, width: size.width, height: size.height))
        }
        let images = SwitcherKeptPicture.unpack(kept.map(\.picture))
        for (slot, image) in zip(kept, images) {
            guard let image else { continue }
            shown.panel.setKeptImage(
                image, labelBackdropBrightness: slot.picture.labelBackdropBrightness, at: slot.index)
        }
        guard !requests.isEmpty else { return }
        shown.capture = pictures.capture(requests) { [weak self, weak shown] id, picture in
            guard let self, let shown, self.shown === shown,
                let index = shown.items.firstIndex(where: { $0.window?.id == id })
            else { return }
            if let picture {
                shown.tookPictures = true
                shown.panel.setPicture(picture, at: index, animated: true)
            } else {
                shown.panel.showIcon(at: index)
            }
        }
    }

    /// - Parameter keepingWindow: another app's panel replaces this one at once, in the same window.
    private func closePanel(keepingWindow: Bool = false) {
        guard let shown else { return }
        if let capture = shown.capture { pictures.cancel(capture) }
        shown.panel.close(keepingWindow: keepingWindow)
        pictures.panelClosed(tookPictures: shown.tookPictures)
        self.shown = nil
    }

    private func choose(_ index: Int) {
        guard let shown, shown.items.indices.contains(index), let window = shown.items[index].window else { return }
        let app = shown.app
        dismiss()
        WindowActivator.activate(
            WindowActivator.Target(
                pid: app.processIdentifier, window: window.id, title: window.title, frame: window.frame,
                bundleURL: app.bundleURL, isHidden: app.isHidden))
    }

    /// Without the permission the tiles keep their icons and titles, which still lead to each window.
    private var canCapture: Bool {
        #if TWEAKLY_AUTOMATION
            if WindowSwitcherTweak.noPicturesForTesting { return false }
        #endif
        return pictures.mayCapture
    }

    private static func screen(containing dock: CGRect) -> NSScreen? {
        let center = CGPoint(x: dock.midX, y: dock.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    // MARK: The click

    private func pressed(_ event: DockClickTap.Press) {
        let point = Self.appKitPoint(event.location)
        guard event.isDown else {
            finishClick(at: event)
            return
        }
        press = nil
        // A click in the panel is the panel's own.
        if let shown, shown.panel.frame.contains(point) { return }
        // Whatever the button went down on, the panel has done its part, and the icon's menu must not open under it.
        dismiss()
        guard !event.opensMenu else { return }
        guard let icon = watcher?.current, icon.frame.contains(point), let app = icon.app,
            tuning.clickAction != .nothing
        else { return }
        press = Press(
            location: event.location, seconds: event.seconds, app: app,
            wasFrontmost: NSWorkspace.shared.frontmostApplication == app,
            hadWindowInSight: WindowCatalog.hasWindowInSight(of: app.processIdentifier))
    }

    private func finishClick(at event: DockClickTap.Press) {
        guard let down = press else { return }
        press = nil
        guard !down.app.isTerminated,
            DockClick.isClick(from: down.location, to: event.location, after: event.seconds - down.seconds)
        else { return }
        switch DockClick.action(
            tuning.clickAction, appWasFrontmost: down.wasFrontmost, hasWindowsInSight: down.hadWindowInSight)
        {
        case .nothing: break
        case .minimize: WindowActivator.minimizeWindows(of: down.app.processIdentifier)
        case .hide: down.app.hide()
        }
    }

    /// The window server measures from the top left of the main screen, AppKit from its bottom left.
    private static func appKitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    // MARK: Tests

    #if TWEAKLY_AUTOMATION
        /// The icon a test points at, standing in for the Dock under a pointer, which a test copy must not use.
        private var testIcon: DockIcon?
        private var currentIcon: DockIcon? { watcher?.current ?? testIcon }
    #else
        private var currentIcon: DockIcon? { watcher?.current }
    #endif

    #if TWEAKLY_AUTOMATION
        /// As if the pointer came onto the icon of the app with this executable, in a row at the bottom of the screen
        /// the test copy lives on. Nil, as if it left the Dock.
        func hoverForTesting(executable: String?, at position: Int = 0) {
            guard let executable else {
                testIcon = nil
                pointerMoved(to: nil)
                return
            }
            let app = NSWorkspace.shared.runningApplications.first {
                $0.executableURL?.lastPathComponent == executable && $0.activationPolicy != .prohibited
            }
            let screen = QuietScreen.screen ?? NSScreen.main
            let frame = screen?.frame ?? .zero
            let dock = CGRect(x: frame.midX - 400, y: frame.minY + 10, width: 800, height: 84)
            let icon = CGRect(x: dock.minX + 8 + CGFloat(position) * 68, y: frame.minY + 5, width: 68, height: 84)
            testIcon = DockIcon(app: app, frame: icon, dock: dock)
            pointerMoved(to: testIcon)
        }

        func pointerInPanelForTesting(_ inside: Bool) {
            perform(hover.pointerInPanel(inside))
        }

        func chooseForTesting(_ index: Int) {
            choose(index)
        }

        /// JSON for a test to read: only numbers and states, and titles never.
        var automationDescription: String {
            let object: [String: Any] = [
                "watching": watcher != nil, "tap": tap != nil, "hovered": hover.hovered.map(Int.init) ?? -1,
                "shown": hover.shown.map(Int.init) ?? -1, "pending": hover.pending.map(Int.init) ?? -1,
                "inPanel": hover.isInPanel, "window": shown?.panel.windowNumber ?? 0,
                "panel": shown.map {
                    [$0.panel.frame.minX, $0.panel.frame.minY, $0.panel.frame.width, $0.panel.frame.height]
                } ?? [],
                "tiles": shown?.items.count ?? 0,
                "pictures": shown.map { shown in shown.items.filter { pictures.sharp[$0.window?.id ?? 0] != nil }.count
                } ?? 0,
                "sharp": pictures.sharp.count, "kept": pictures.kept.count,
                "tuning": [
                    "showsPanel": tuning.showsPanel, "delay": tuning.delayMilliseconds,
                    "tile": tuning.largestTileHeight, "click": tuning.clickAction.rawValue,
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
