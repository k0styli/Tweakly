import AppKit
import IOKit.ps
import notify

/// What the whole Mac is doing that decides whether wallpapers move: sleep, the lock screen, the power source, Low
/// Power Mode and heat. Every one of these is an event, so nothing here polls.
@MainActor
final class SystemConditions {
    private nonisolated static let screenLocked = "com.apple.screenIsLocked"
    private nonisolated static let screenUnlocked = "com.apple.screenIsUnlocked"

    private(set) var isSystemAsleep = false
    private(set) var areScreensAsleep = false
    private(set) var isScreenLocked = SystemConditions.readLocked()
    private(set) var isOnBattery = SystemConditions.readOnBattery()
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var isHot = SystemConditions.readHot()

    var onChange: (() -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerToken: Int32 = 0
    private var isObservingLock = false

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        watch(workspace, NSWorkspace.didWakeNotification) { conditions in
            conditions.isSystemAsleep = false
            // Anything may have changed while asleep, and some of it sends nothing on waking.
            conditions.isOnBattery = Self.readOnBattery()
            conditions.isScreenLocked = Self.readLocked()
        }
        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.areScreensAsleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { $0.areScreensAsleep = false }
        // Fast user switching: another person's session is in front.
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isScreenLocked = true }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isScreenLocked = Self.readLocked() }
        watch(.default, .NSProcessInfoPowerStateDidChange) {
            $0.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        watch(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.isHot = Self.readHot() }
        observeLock()
        // Only the switch between the adapter and the battery, not every change of charge.
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let onBattery = Self.readOnBattery()
                guard onBattery != self.isOnBattery else { return }
                self.isOnBattery = onBattery
                self.onChange?()
            }
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        if powerToken != 0 {
            notify_cancel(powerToken)
            powerToken = 0
        }
        if isObservingLock {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque())
            isObservingLock = false
        }
    }

    private func watch(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ change: @escaping @MainActor (SystemConditions) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.onChange?()
            }
        }
        observers.append((center, observer))
    }

    /// AppKit holds back distributed notices while an app is not active, which this process never is, so these are
    /// asked for at once.
    private func observeLock() {
        let center = CFNotificationCenterGetDistributedCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [Self.screenLocked, Self.screenUnlocked] {
            CFNotificationCenterAddObserver(
                center, me,
                { _, observer, name, _, _ in
                    guard let observer else { return }
                    let locked = name?.rawValue as String? == SystemConditions.screenLocked
                    // The distributed center delivers on the main thread.
                    MainActor.assumeIsolated {
                        Unmanaged<SystemConditions>.fromOpaque(observer).takeUnretainedValue().lockChanged(to: locked)
                    }
                }, name as CFString, nil, .deliverImmediately)
        }
        isObservingLock = true
    }

    private func lockChanged(to locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
        onChange?()
    }

    /// The session's own record, read only when no notice can be had: at start and after waking.
    private static func readLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?[kCGSessionOnConsoleKey] as? Bool == false { return true }
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private static func readHot() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}
