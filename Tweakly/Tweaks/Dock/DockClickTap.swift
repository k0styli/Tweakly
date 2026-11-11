import AppKit
import os

/// Hears the left button go down and up, only while the pointer is on the Dock: the tap is off the rest of the time and
/// costs nothing. It only listens, so no click anywhere waits for it, and the Dock still gets every click as before.
///
/// `@unchecked Sendable`: `tap` is written once by `start()` before the thread starts and only read after that;
/// `runLoop` is written by the thread before it signals `start()`, which waits for that. One object serves one start
/// and one stop.
nonisolated final class DockClickTap: @unchecked Sendable {
    struct Press: Sendable {
        let isDown: Bool
        /// The secondary button, or the primary with Control: the icon's menu.
        let opensMenu: Bool
        /// In the window server's coordinates, from the top left of the main screen.
        let location: CGPoint
        let seconds: TimeInterval
    }

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "dock")

    private let onPress: @Sendable (Press) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(onPress: @escaping @Sendable (Press) -> Void) {
        self.onPress = onPress
    }

    /// Returns false if the system refuses, which means Accessibility access is missing. The tap starts off.
    func start() -> Bool {
        let mask = CGEventMask(
            1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
                | 1 << CGEventType.rightMouseDown.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: dockClickCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.error("The system refused an event tap")
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            if let tap = self.tap { CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "me.tweakly.Tweakly.dock-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func setEnabled(_ enabled: Bool) {
        guard let tap, CGEvent.tapIsEnabled(tap: tap) != enabled else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown:
            onPress(
                Press(
                    isDown: type != .leftMouseUp,
                    opensMenu: type == .rightMouseDown || event.flags.contains(.maskControl),
                    location: event.location, seconds: TimeInterval(event.timestamp) / 1_000_000_000))
        default:
            // A listening tap that is turned off by the system is simply off: the next hover turns it on again.
            break
        }
    }
}

private nonisolated func dockClickCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let info { Unmanaged<DockClickTap>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
