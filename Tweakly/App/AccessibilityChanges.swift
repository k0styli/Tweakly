import Foundation

/// Hears that some app's Accessibility access changed, which macOS announces slightly before it takes effect, and calls
/// back once it has. AppKit holds back distributed notices while an app is not active, which the agent never is: a
/// permission given in System Settings would go unheard until something else woke the tweak, and one taken away would
/// leave its event tap in place. So this asks for them at once, as `SystemConditions` does for the screen lock.
final class AccessibilityChanges {
    private static let name = "com.apple.accessibility.api"
    private static let settleDelay: TimeInterval = 0.4

    private let onChange: () -> Void

    init(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                // The distributed center delivers on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<AccessibilityChanges>.fromOpaque(observer).takeUnretainedValue().changed()
                }
            }, Self.name as CFString, nil, .deliverImmediately)
    }

    isolated deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(Self.name as CFString), nil)
    }

    private func changed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
    }
}
