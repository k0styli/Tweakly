import AppKit
import Carbon
import KeyboardCleaningCore
import Observation

/// One cleaning of the keyboard, from the button on the page until the keyboard is back.
///
/// It lives in the window process, which is short-lived, so the agent running all day never holds any of this. Quitting
/// or killing that process gives the keyboard back too, because the system removes the tap with it.
@Observable final class KeyboardCleaningController {
    private static let extraTime: TimeInterval = 60
    private static let refreshInterval: TimeInterval = 1

    private(set) var isActive = false
    /// Set when the system refused, for the page to say so.
    private(set) var couldNotStart = false

    @ObservationIgnored private var blocker: KeyboardBlocker?
    @ObservationIgnored private var overlay: KeyboardCleaningOverlay?
    @ObservationIgnored private var keyboardState: KeyboardState?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var totalTime: Double = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    #if TWEAKLY_AUTOMATION
        @ObservationIgnored private var lastEnding = "none"
    #endif

    func start(seconds: Double) {
        guard !isActive else { return }
        let state = KeyboardState()
        let blocker = KeyboardBlocker(seconds: seconds) { [weak self] ending in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(ending: ending) }
            }
        }
        // The screen comes first, so that the keyboard is never off with no way shown to turn it back on.
        let overlay = KeyboardCleaningOverlay(
            onTurnOn: { [weak self] in self?.turnOn() }, onAddTime: { [weak self] in self?.addTime() })
        overlay.show()
        guard blocker.start() else {
            overlay.close()
            couldNotStart = true
            return
        }
        couldNotStart = false
        isActive = true
        self.blocker = blocker
        self.overlay = overlay
        keyboardState = state
        totalTime = seconds
        observeSystem()
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = Self.refreshInterval / 10
        // The common modes, so the countdown goes on while a button is being pressed.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// The button on the screen.
    func turnOn() {
        blocker?.stop()
        finish(ending: nil)
    }

    private func addTime() {
        blocker?.addTime(seconds: Self.extraTime)
        totalTime = blocker?.remaining ?? totalTime
        refresh()
    }

    private func refresh() {
        guard let blocker else { return }
        let remaining = blocker.remaining
        // The bar shows the share left, so time added fills it up again instead of running off its end.
        totalTime = max(totalTime, remaining)
        overlay?.update(remaining: remaining, total: totalTime, secureInputOn: IsSecureEventInputEnabled())
    }

    private func finish(ending: KeyboardBlocker.Ending?) {
        guard isActive else { return }
        #if TWEAKLY_AUTOMATION
            lastEnding = ending.map { "\($0)" } ?? "button"
        #endif
        isActive = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        overlay?.close()
        overlay = nil
        blocker = nil
        keyboardState?.restore()
        keyboardState = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Whatever takes the person away from this screen also ends the cleaning: they must never come back to a
    /// keyboard that does not work, least of all at the login screen.
    private func observeSystem() {
        func endOn(_ center: NotificationCenter, _ name: Notification.Name) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.turnOn() }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        endOn(workspace, NSWorkspace.willSleepNotification)
        endOn(workspace, NSWorkspace.screensDidSleepNotification)
        endOn(workspace, NSWorkspace.sessionDidResignActiveNotification)
        endOn(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        endOn(DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstart"))
        // The screens the overlay covers have changed.
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlay?.show()
                self?.refresh()
            }
        }
        observers.append((.default, screens))
    }

    #if TWEAKLY_AUTOMATION
        /// The screen alone, with the keyboard left on, to look at it while someone may be typing.
        func previewForTesting(seconds: Double, passwordWarning: Bool, dims: Bool = true) {
            let preview = KeyboardCleaningOverlay(onTurnOn: {}, onAddTime: {})
            preview.showForTesting(dims: dims)
            preview.update(remaining: 58, total: 60, secureInputOn: passwordWarning)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { preview.close() }
            }
        }

        func hangMainThreadForTesting(seconds: Double) {
            Thread.sleep(forTimeInterval: seconds)
        }

        var automationDescription: String {
            let frame = overlay?.buttonFrameOnScreen ?? .zero
            let add = overlay?.addButtonFrameOnScreen ?? .zero
            let object: [String: Any] = [
                "active": isActive, "couldNotStart": couldNotStart, "remaining": blocker?.remaining ?? 0,
                "presses": blocker?.presses ?? 0, "lastEnding": lastEnding,
                "button": [frame.minX, frame.minY, frame.width, frame.height],
                "addButton": [add.minX, add.minY, add.width, add.height],
                "secureInput": IsSecureEventInputEnabled(),
                "panels": overlay?.panelCount ?? 0,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
