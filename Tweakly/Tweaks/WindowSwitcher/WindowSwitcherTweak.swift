import AppKit
import WindowSwitcherCore
import os

/// Command-Tab with a tile for every window. While on, it holds two event taps and a few observers, and does nothing
/// else: the list of windows is read when Command-Tab is pressed, and everything built for the panel is released when it
/// closes. Pictures of windows live in `WindowPictureStore`, shared with the Dock's previews.
final class WindowSwitcherTweak {
    /// The panel is a passing thing, so normally it leaves most of the screen in view.
    static let panelWidthShare: CGFloat = 0.9
    static let panelHeightShare: CGFloat = 0.62
    static let panelMaximumHeightShare: CGFloat = 0.88
    private static let commandWatchInterval: TimeInterval = 0.5
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "switcher")

    /// One press of Command-Tab, from the first Tab until Command is released.
    private final class Session {
        var items: [SwitcherItem]
        var selected: Int
        var panel: SwitcherPanelController?
        var capture: WindowPictureStore.Request?
        var buildWork: DispatchWorkItem?
        var showWork: DispatchWorkItem?
        var layout: SwitcherLayout?
        /// Kept by window, so they survive the tiles being laid out again after an app quits.
        var pictures: [CGWindowID: SwitcherPicture] = [:]
        var captured: Set<CGWindowID> = []
        var isShown = false
        var pictureScale: CGFloat = 2
        /// Whether the first item is the window in front, which is where the panel then appears.
        let firstIsCurrent: Bool

        init(items: [SwitcherItem], selected: Int, firstIsCurrent: Bool) {
            self.items = items
            self.selected = selected
            self.firstIsCurrent = firstIsCurrent
        }
    }

    /// Read as each press needs it, so a change shows from the next one.
    var tuning = SwitcherTuning() {
        didSet {
            // Only when the previews go off: the settings come again with every change on any page, and the pictures are
            // the Dock's too.
            if !tuning.showsPreviews, oldValue.showsPreviews { pictures.forgetEverything() }
        }
    }

    private let pictures: WindowPictureStore

    private var tap: SwitcherEventTap?
    private var session: Session?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityChanges: AccessibilityChanges?
    private var recency = WindowRecency()
    /// What each open window is, as asking the apps again on every press would wait on them for nothing.
    private var windowKinds: [CGWindowID: WindowKind] = [:]
    private var frontApp: pid_t?
    /// The switch this tweak just asked for, whose own notice must not be taken for a person's click elsewhere.
    private var expectedActivation: (pid: pid_t, window: CGWindowID)?
    /// When the switcher last switched to a window, which may take a move to another Space.
    private var lastSwitch: ContinuousClock.Instant?
    /// Runs only while the panel is on screen. See `watchCommandKey`.
    private var commandWatch: Timer?

    #if TWEAKLY_AUTOMATION
        private struct Timing {
            var began = ContinuousClock.Instant.now
            var listed = Duration.zero
            var shown = Duration.zero
            var firstPicture = Duration.zero
            var lastPicture = Duration.zero
            var pictures = 0
            var build = Duration.zero
            var selectMax = Duration.zero
            var pictureMain = Duration.zero
        }
        private var timing = Timing()
        private var lastCommit = "none"
        /// Opened by a command rather than by keys, so Command being up says nothing.
        private var isOpenWithoutKeys = false
    #endif

    init(pictures: WindowPictureStore) {
        self.pictures = pictures
    }

    /// Brings the taps in line with the tweak being on and Accessibility allowed.
    func update() {
        if observers.isEmpty {
            observeSystem()
            frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if AXIsProcessTrusted() {
            startTap()
        } else {
            stopTap()
            pictures.forgetEverything()
        }
    }

    /// Leaves nothing running, so the object can be released. The pictures stay with their store, which the Dock's
    /// previews may still be using.
    func stop() {
        stopTap()
        recency = WindowRecency()
        windowKinds = [:]
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        accessibilityChanges = nil
    }

    private func startTap() {
        guard tap == nil else { return }
        #if TWEAKLY_AUTOMATION
            // A test copy that only looks at the panel leaves Command-Tab to the copy in use.
            if UserDefaults.standard.bool(forKey: "switcherWithoutTap") { return }
        #endif
        let tap = SwitcherEventTap { [weak self] command in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(command) }
            }
        }
        if tap.start() {
            self.tap = tap
        } else {
            Self.log.error("Staying off: no event tap, though Accessibility reads as allowed")
        }
    }

    private func stopTap() {
        cancelSession()
        tap?.stop()
        tap = nil
    }

    private func observeSystem() {
        func watch(
            _ center: NotificationCenter, _ name: Notification.Name,
            _ action: @escaping @MainActor @Sendable (WindowSwitcherTweak) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification) { $0.cancelSession() }
        watch(workspace, NSWorkspace.didWakeNotification) {
            $0.tap?.ensureEnabled()
            $0.update()
        }
        watch(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceChanged() }
        watch(workspace, NSWorkspace.didActivateApplicationNotification) { $0.appActivated() }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.cancelSession() }
        watch(.default, NSApplication.didChangeScreenParametersNotification) { $0.cancelSession() }
        // Access can be taken away while the app runs. The taps must go at once, since a tap left behind by a
        // revoked permission is a known way to get input stuck across the whole system.
        accessibilityChanges = AccessibilityChanges { [weak self] in self?.update() }
    }

    /// The one thing kept up to date between sessions, as nothing else can tell which window was used before the
    /// current one once they are on different Spaces. It costs one window list per change of app.
    private func appActivated() {
        guard isListening else { return }
        // The system's notice about Accessibility going away is not documented, and a tap must not outlive the permission.
        guard AXIsProcessTrusted() else {
            update()
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != frontApp else { return }
        let fronts = WindowCatalog.frontWindows(of: Set([pid, frontApp].compactMap { $0 }))
        // What the app being left had in front is the window just used.
        if let frontApp, let left = fronts[frontApp] { recency.markUsed(left) }
        if let expected = expectedActivation, expected.pid == pid {
            recency.markUsed(expected.window)
        } else if let window = fronts[pid] {
            recency.markUsed(window)
        }
        expectedActivation = nil
        frontApp = pid
    }

    /// Without Accessibility there are no taps and no sessions, so a list of windows would be read for nothing.
    private var isListening: Bool {
        #if TWEAKLY_AUTOMATION
            if UserDefaults.standard.bool(forKey: "switcherWithoutTap") { return true }
        #endif
        return tap != nil
    }

    private func handle(_ command: SwitcherCommand) {
        switch command {
        case .begin(let backward): begin(backward: backward)
        case .next: move { SwitcherSelection.next(after: $0, count: $1) }
        case .previous: move { SwitcherSelection.previous(before: $0, count: $1) }
        case .move(let direction): arrow(direction)
        case .commit: commit()
        case .cancel: endSession()
        case .quitSelected: quitSelected()
        case .hideSelected: hideSelected()
        }
    }

    private func begin(backward: Bool) {
        // Should access have gone without any notice, this is where it comes to light.
        guard AXIsProcessTrusted() else {
            Self.log.notice("Accessibility access is gone, so handing Command-Tab back to the system")
            stopTap()
            return
        }
        endSession()
        #if TWEAKLY_AUTOMATION
            timing = Timing()
        #endif
        // The delays count from the press, not from the end of listing the windows, which takes a few milliseconds
        // and on the first press after launch about 80.
        let pressed = DispatchTime.now()
        let (items, firstIsCurrent) = WindowCatalog.snapshot(recency: &recency, kinds: &windowKinds, tuning: tuning)
        #if TWEAKLY_AUTOMATION
            timing.listed = timing.began.duration(to: .now)
        #endif
        guard !items.isEmpty else {
            tap?.endSession()
            return
        }
        let session = Session(
            items: items,
            selected: SwitcherSelection.initial(count: items.count, firstIsCurrent: firstIsCurrent, backward: backward),
            firstIsCurrent: firstIsCurrent)
        self.session = session
        session.buildWork = schedule(at: pressed + tuning.buildDelay) { $0.buildPanel() }
        session.showWork = schedule(at: pressed + tuning.panelDelay) { $0.showPanel() }
    }

    private func schedule(at deadline: DispatchTime, _ action: @escaping @MainActor (WindowSwitcherTweak) -> Void)
        -> DispatchWorkItem
    {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
        return work
    }

    /// A Space that moves under an open panel leaves it listing the wrong windows, so the session ends. The exception is
    /// the move the switcher itself asked for: a switch to a window on another Space finishes its move after the switch,
    /// which can be after the next press began, and ending that session lost the person's next switch. The session lists
    /// windows by number, which the move leaves valid.
    private func spaceChanged() {
        // Only the one move the switch asked for, used up whether or not a panel is showing by now: a second one in
        // that time is someone else's.
        let isOwnMove = lastSwitch.map { $0.duration(to: .now) < Self.ownSpaceMove } ?? false
        lastSwitch = nil
        // With no panel there is nothing to end, and the tap may be starting one whose news is on its way here.
        guard session != nil, !isOwnMove else { return }
        cancelSession()
    }

    /// Longer than the switch to a window on another Space takes to move there, AX work and animation included.
    private static let ownSpaceMove: Duration = .seconds(1)

    private func move(_ step: (Int, Int) -> Int) {
        guard let session else { return }
        // A second Tab means the person is choosing, so there is no reason to keep them waiting for the panel.
        showPanelThenSelect { step(session.selected, shownCount(of: session)) }
    }

    private func arrow(_ direction: SwitcherLayout.Direction) {
        guard let session else { return }
        showPanelThenSelect { session.layout?.neighbour(of: session.selected, in: direction) }
    }

    /// The panel shown by a key that also moves the selection tells VoiceOver once, about where the selection ends
    /// up, rather than starting on the window it is leaving.
    private func showPanelThenSelect(_ target: () -> Int?) {
        guard let session else { return }
        let wasShown = session.isShown
        showPanel(announcing: false)
        let before = session.selected
        if let index = target() { select(index) }
        if !wasShown, session.isShown, session.selected == before { session.panel?.announceSelection() }
    }

    private func select(_ index: Int) {
        #if TWEAKLY_AUTOMATION
            let started = ContinuousClock.Instant.now
            defer { timing.selectMax = max(timing.selectMax, started.duration(to: .now)) }
        #endif
        // The mouse reports every move within a tile, and each would cost an announcement to VoiceOver.
        guard session?.selected != index else { return }
        session?.selected = index
        session?.panel?.select(index)
    }

    private func shownCount(of session: Session) -> Int {
        session.layout?.tileFrames.count ?? session.items.count
    }

    /// Builds the panel without showing it, which a press that ends now will never need to know about.
    private func buildPanel() {
        guard let session, session.panel == nil,
            let screen = screen(for: session.items, firstIsCurrent: session.firstIsCurrent)
        else { return }
        #if TWEAKLY_AUTOMATION
            let started = ContinuousClock.Instant.now
            defer { timing.build = started.duration(to: .now) }
        #endif
        session.buildWork?.cancel()
        session.buildWork = nil
        let visible = screen.visibleFrame.size
        var metrics = SwitcherLayout.Metrics()
        metrics.fitsBackgroundToRows = tuning.fitsBackgroundToRows
        metrics.maximumTileHeight = CGFloat(tuning.largestTileHeight)
        let layout = SwitcherLayout(
            aspects: session.items.map(\.aspect),
            available: CGSize(
                width: visible.width * Self.panelWidthShare, height: visible.height * Self.panelHeightShare),
            overflow: CGSize(
                width: visible.width * Self.panelWidthShare, height: visible.height * Self.panelMaximumHeightShare),
            metrics: metrics)
        session.layout = layout
        session.pictureScale = screen.backingScaleFactor
        session.selected = min(session.selected, max(layout.tileFrames.count - 1, 0))

        let capturing = canCapture
        let panel = SwitcherPanelController(
            tiles: session.items.map {
                WindowTile(
                    icon: $0.app.icon, label: $0.appName, accessibilityLabel: $0.accessibilityLabel,
                    hasWindow: $0.window != nil)
            },
            layout: layout, selected: session.selected, screen: screen, willHavePictures: capturing)
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.tap?.endSession()
            self?.commit()
        }
        session.panel = panel
        guard capturing else {
            // The app can lose the permission while it runs, and then nothing taken with it should stay. Previews
            // turned off here only are no reason: the Dock's previews share these pictures.
            if !pictures.mayCapture { pictures.forgetEverything() }
            return
        }
        pictures.forgetClosedWindows()
        // What is known goes in now, so it is there from the panel's first frame.
        var kept: [(index: Int, picture: SwitcherKeptPicture)] = []
        for (index, item) in session.items.prefix(layout.tileFrames.count).enumerated() {
            guard let id = item.window?.id else { continue }
            if let picture = session.pictures[id] ?? pictures.sharp[id] {
                session.pictures[id] = picture
                panel.setPicture(picture, at: index, animated: false)
            } else if let picture = pictures.kept[id] {
                kept.append((index, picture))
            }
        }
        // About a millisecond to unpack each, and thirty one after another would hold up the panel's first frame.
        let images = SwitcherKeptPicture.unpack(kept.map(\.picture))
        for (slot, image) in zip(kept, images) {
            guard let image else { continue }
            panel.setKeptImage(image, labelBackdropBrightness: slot.picture.labelBackdropBrightness, at: slot.index)
        }
    }

    private func showPanel(announcing: Bool = true) {
        guard let session else { return }
        session.showWork?.cancel()
        session.showWork = nil
        buildPanel()
        guard !session.isShown, let panel = session.panel, let layout = session.layout else { return }
        session.isShown = true
        panel.show(announcing: announcing)
        watchCommandKey()
        #if TWEAKLY_AUTOMATION
            timing.shown = timing.began.duration(to: .now)
        #endif
        capturePictures(for: session, layout: layout)
    }

    /// The panel closes when Command is released, which the tap reports as a command. A cancelled session and a new press can
    /// cross on their way here, and then that command never comes, nothing else would ever close the panel, and it floats
    /// above everything. So what the tap knows about Command is looked at, only while the panel is on screen.
    private func watchCommandKey() {
        #if TWEAKLY_AUTOMATION
            if isOpenWithoutKeys { return }
        #endif
        guard tap != nil, commandWatch == nil else { return }
        let timer = Timer(timeInterval: Self.commandWatchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCommandKey() }
        }
        timer.tolerance = Self.commandWatchInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        commandWatch = timer
    }

    private func checkCommandKey() {
        guard let tap, !tap.isCommandDown else { return }
        Self.log.notice("Command is up but the panel was still open, so going where it points")
        tap.endSession()
        commit()
    }

    /// Where the window in front is, as the system's switcher also appears with the person's attention. When the app in
    /// front has no window in the list, the first item is only the window used last, which may be on another display,
    /// so the pointer says where the person is.
    private func screen(for items: [SwitcherItem], firstIsCurrent: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        if firstIsCurrent, let frame = items.first?.window?.frame, let primary = screens.first {
            // Window server coordinates start at the top left of the primary screen.
            let center = NSPoint(x: frame.midX, y: primary.frame.height - frame.midY)
            if let screen = screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens.first
    }

    private var canCapture: Bool {
        #if TWEAKLY_AUTOMATION
            if Self.noPicturesForTesting { return false }
        #endif
        return tuning.showsPreviews && pictures.mayCapture
    }

    private func capturePictures(for session: Session, layout: SwitcherLayout) {
        var requests: [(index: Int, request: WindowThumbnailer.Request)] = []
        for (index, frame) in layout.tileFrames.enumerated() {
            guard let window = session.items[index].window, !session.captured.contains(window.id) else { continue }
            let size = SwitcherLayout.thumbnailPixelSize(
                window: window.frame.size, tile: frame.size, scale: session.pictureScale)
            if index > 0, let known = session.pictures[window.id],
                known.image.width >= size.width || known.image.height >= size.height,
                known.takenAt.duration(to: .now) < .seconds(tuning.retakeAfterSeconds)
            {
                continue
            }
            requests.append((index, .init(window: window.id, width: size.width, height: size.height)))
        }
        // Without the permission the tiles keep their icons: switching still works, and the page says why.
        guard canCapture, !requests.isEmpty else { return }
        // The selected tile first, since that is the one being looked at.
        requests.sort { abs($0.index - session.selected) < abs($1.index - session.selected) }
        session.capture = pictures.capture(requests.map(\.request)) { [weak self, weak session] id, picture in
            guard let self else { return }
            #if TWEAKLY_AUTOMATION
                let started = ContinuousClock.Instant.now
                let picture = Self.losePicturesForTesting ? nil : picture
            #endif
            guard let session, self.session === session else { return }
            // Found by window, since the tiles may have moved if an app quit while this was on its way.
            let index = session.items.firstIndex { $0.window?.id == id }
            guard let picture else {
                if let index { session.panel?.showIcon(at: index) }
                return
            }
            session.pictures[id] = picture
            session.captured.insert(id)
            if let index { session.panel?.setPicture(picture, at: index, animated: true) }
            #if TWEAKLY_AUTOMATION
                if self.timing.pictures == 0 { self.timing.firstPicture = self.timing.began.duration(to: .now) }
                self.timing.pictures += 1
                self.timing.pictureMain += started.duration(to: .now)
                self.timing.lastPicture = self.timing.began.duration(to: .now)
            #endif
        }
    }

    private func commit() {
        guard let session else { return }
        let item = session.items.indices.contains(session.selected) ? session.items[session.selected] : nil
        // Releasing the panel's views takes a moment, which the switch itself should not have to wait for.
        defer { endSession() }
        guard let item, !item.app.isTerminated else { return }
        #if TWEAKLY_AUTOMATION
            lastCommit = WindowCatalog.onlyExecutablesForTesting != nil ? item.accessibilityLabel : item.appName
        #endif
        if let window = item.window?.id {
            recency.markUsed(window)
            expectedActivation = (item.app.processIdentifier, window)
        }
        // A window off screen is on another Space or minimized, and only going to it can move the Space.
        lastSwitch = item.window.map { !$0.isOnScreen } == true ? .now : nil
        WindowActivator.activate(
            WindowActivator.Target(
                pid: item.app.processIdentifier, window: item.window?.id, title: item.window?.title ?? "",
                frame: item.window?.frame ?? .zero, bundleURL: item.app.bundleURL, isHidden: item.app.isHidden))
    }

    private func quitSelected() {
        guard let session, session.items.indices.contains(session.selected) else { return }
        showPanel()
        let app = session.items[session.selected].app
        guard WindowFilter.canBeQuit(bundleID: app.bundleIdentifier) else { return }
        app.terminate()
        session.items.removeAll { $0.app == app }
        reloadPanel(for: session)
    }

    private func hideSelected() {
        guard let session, session.items.indices.contains(session.selected) else { return }
        showPanel()
        session.items[session.selected].app.hide()
    }

    private func reloadPanel(for session: Session) {
        guard !session.items.isEmpty else {
            cancelSession()
            return
        }
        if let capture = session.capture { pictures.cancel(capture) }
        session.capture = nil
        session.panel?.close()
        session.panel = nil
        session.layout = nil
        session.isShown = false
        session.selected = min(session.selected, session.items.count - 1)
        showPanel()
    }

    private func cancelSession() {
        tap?.endSession()
        endSession()
    }

    /// Everything the session held goes here: panel, views, icons and pictures.
    private func endSession() {
        commandWatch?.invalidate()
        commandWatch = nil
        #if TWEAKLY_AUTOMATION
            isOpenWithoutKeys = false
        #endif
        guard let session else { return }
        session.buildWork?.cancel()
        session.showWork?.cancel()
        if let capture = session.capture { pictures.cancel(capture) }
        session.panel?.close()
        pictures.panelClosed(tookPictures: !session.captured.isEmpty)
        self.session = nil
    }

    #if TWEAKLY_AUTOMATION
        /// Stands in for a missing Screen Recording permission, which a test cannot take away.
        static var noPicturesForTesting = false
        /// Stands in for windows that give no picture, which cannot be arranged on demand.
        static var losePicturesForTesting = false

        func forgetPicturesForTesting(andKept: Bool) {
            if andKept { pictures.forgetEverything() } else { pictures.forgetSharpPictures() }
        }

        /// As a press does, so the panel's delays can be seen at work without touching the keyboard.
        func beginForTesting() {
            begin(backward: false)
            isOpenWithoutKeys = true
        }

        func openForTesting() {
            begin(backward: false)
            isOpenWithoutKeys = true
            showPanel()
        }

        /// Takes the key state from under an open panel, which is where a lost report or a crossed cancel leaves it.
        func loseKeyStateForTesting() {
            tap?.endSession()
        }

        func closeForTesting() {
            endSession()
        }

        /// JSON for a test to read. Titles only when the test has limited the list to its own windows.
        var automationDescription: String {
            let showsTitles = WindowCatalog.onlyExecutablesForTesting != nil
            func ms(_ duration: Duration) -> Double { Double(duration / .microseconds(100)).rounded() / 10 }
            let items: [[String: Any]] = (session?.items ?? []).map { item in
                [
                    "app": item.appName, "title": showsTitles ? item.window?.title ?? "" : "",
                    "window": item.window != nil,
                    "picture": item.window.map { session?.pictures[$0.id] != nil } ?? false,
                    "kept": item.window.map { pictures.kept[$0.id] != nil } ?? false,
                ]
            }
            let panelFrame = session?.panel?.frame ?? .zero
            let object: [String: Any] = [
                "tap": tap != nil, "session": session != nil, "shown": session?.isShown ?? false,
                "selected": session?.selected ?? -1, "lastCommit": lastCommit, "items": items,
                "rows": session?.layout?.rows.map(\.count) ?? [], "tileHeight": session?.layout?.tileHeight ?? 0,
                "tiles": session?.layout?.tileFrames.count ?? 0,
                "tileWidths": session?.layout?.tileFrames.map(\.width) ?? [],
                "pictureSizes": (session?.items ?? []).map { item -> [Int] in
                    guard let id = item.window?.id, let picture = session?.pictures[id] else { return [] }
                    return [picture.image.width, picture.image.height]
                },
                "windowSizes": (session?.items ?? []).map { item -> [Int] in
                    guard let frame = item.window?.frame else { return [] }
                    return [Int(frame.width), Int(frame.height)]
                },
                "tileFrames": session?.layout?.tileFrames.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "backgrounds": session?.layout?.backgroundFrames.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "panel": [panelFrame.minX, panelFrame.minY, panelFrame.width, panelFrame.height],
                "listedMs": ms(timing.listed), "shownMs": ms(timing.shown), "firstPictureMs": ms(timing.firstPicture),
                "lastPictureMs": ms(timing.lastPicture),
                "pictures": timing.pictures, "buildMs": ms(timing.build), "selectMaxMs": ms(timing.selectMax),
                "pictureMainMs": ms(timing.pictureMain), "recentPictures": pictures.sharp.count,
                "tuning": [
                    "panelDelay": tuning.panelDelayMilliseconds, "largestTile": tuning.largestTileHeight,
                    "capturesAtOnce": tuning.capturesAtOnce, "retakeAfter": tuning.retakeAfterSeconds,
                    "keepSharp": tuning.keepSharpPicturesSeconds, "savesCompressed": tuning.savesCompressedPictures,
                    "quality": tuning.compressionQuality,
                ],
                "keptPictures": pictures.kept.count,
                "keptKB": pictures.kept.values.reduce(0) { $0 + $1.jpeg.count } / 1024,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
