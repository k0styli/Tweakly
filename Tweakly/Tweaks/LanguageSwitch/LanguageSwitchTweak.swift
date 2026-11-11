import AppKit
import Carbon
import LanguageSwitchCore
import os

/// A short press of Fn on its own turns on the previous input source at once, without the system's menu.
///
/// While on, it holds two listening event taps on a thread of their own and a few observers, and does nothing between
/// presses: typing never wakes this process, see `FnKeyTap`. FnLangSwitch heard every key
/// press and every key release instead. The input source is selected on the main thread.
final class LanguageSwitchTweak {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "language-switch")

    private var tap: FnKeyTap?
    private var history = InputSourceHistory(current: nil)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityChanges: AccessibilityChanges?

    #if TWEAKLY_AUTOMATION
        private var switches = 0
        private var lastDecision = "none"
        private var lastSwitchMicroseconds = 0
    #endif

    /// Brings the taps in line with the tweak being on and Accessibility allowed.
    func update() {
        if observers.isEmpty { observeSystem() }
        if AXIsProcessTrusted() {
            startTap()
        } else {
            stopTap()
        }
    }

    /// Leaves nothing running, so the object can be released.
    func stop() {
        stopTap()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        accessibilityChanges = nil
    }

    private func startTap() {
        guard tap == nil else { return }
        let tap = FnKeyTap { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.switchToPrevious() }
            }
        }
        guard tap.start() else {
            Self.log.error("Staying off: no event tap, though Accessibility reads as allowed")
            return
        }
        self.tap = tap
        history = InputSourceHistory(current: InputSources.currentIdentifier)
        // The first list in a process takes about 15 ms to load, which would otherwise fall on the first press.
        _ = InputSources.selectable()
        observeInputSources()
    }

    private func stopTap() {
        guard let tap else { return }
        tap.stop()
        self.tap = nil
        stopObservingInputSources()
    }

    private func observeSystem() {
        func watch(
            _ center: NotificationCenter, _ name: Notification.Name,
            _ action: @escaping @MainActor @Sendable (LanguageSwitchTweak) -> Void
        ) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // A press under way when the Mac went to sleep will not get its release.
        watch(workspace, NSWorkspace.willSleepNotification) { $0.tap?.reset() }
        watch(workspace, NSWorkspace.didWakeNotification) { tweak in
            tweak.tap?.reset()
            tweak.update()
        }
        // A tap must not outlive the permission it was created with.
        accessibilityChanges = AccessibilityChanges { [weak self] in self?.update() }
    }

    /// Whoever changes the input source, the one before it is the one a tap goes back to. AppKit holds back distributed
    /// notices while an app is not active, which this agent never is, so this one is asked for at once.
    private func observeInputSources() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                // The distributed center delivers on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<LanguageSwitchTweak>.fromOpaque(observer).takeUnretainedValue().inputSourceChanged()
                }
            }, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
    }

    private func stopObservingInputSources() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged), nil)
    }

    private func inputSourceChanged() {
        guard let current = InputSources.currentIdentifier else { return }
        history.selected(current)
    }

    private func switchToPrevious() {
        guard tap != nil else { return }
        // The system's notice about Accessibility going away is not documented, so this checks too.
        guard AXIsProcessTrusted() else {
            note("no access")
            update()
            return
        }
        #if TWEAKLY_AUTOMATION
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            defer { lastSwitchMicroseconds = Int((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1000) }
        #endif
        let sources = InputSources.selectable()
        let identifiers = sources.map { InputSources.identifier(of: $0) }
        let current = InputSources.currentIdentifier
        // A notice may have been missed, such as while the tap was off.
        if let current { history.selected(current) }
        guard
            let target = InputSourceChoice.next(
                current: current, previous: history.previous, available: identifiers.compactMap { $0 }),
            let index = identifiers.firstIndex(of: target)
        else {
            note("nothing to switch to")
            return
        }
        note(InputSources.select(sources[index]) ? "switched" : "refused")
    }

    private func note(_ decision: String) {
        #if TWEAKLY_AUTOMATION
            lastDecision = decision
            if decision == "switched" { switches += 1 }
        #endif
    }

    #if TWEAKLY_AUTOMATION
        var automationDescription: String {
            let object: [String: Any] = [
                "listening": tap != nil, "switches": switches, "lastDecision": lastDecision,
                "lastRelease": tap?.lastRelease ?? "", "lastSwitchMicroseconds": lastSwitchMicroseconds,
                "current": InputSources.currentIdentifier ?? "", "previous": history.previous ?? "",
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
