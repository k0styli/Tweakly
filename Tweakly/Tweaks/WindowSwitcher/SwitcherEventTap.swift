import AppKit
import Synchronization
import WindowSwitcherCore
import os

/// Takes Command-Tab away from the system while the tweak is on.
///
/// Two taps, so that typing costs nothing: one sees only modifier changes, and it turns on the other, which sees
/// keys, only while Command is held. Nothing disables the system's own shortcut, so should this object or the
/// whole app stop, the system's Command-Tab simply works again.
///
/// Every key press made with Command held waits for the key tap's callback, so the taps have a thread of their
/// own, which a busy main thread cannot hold up, and the callback only updates `state` and queues the command.
///
/// `@unchecked Sendable`: the tap references are written once, by `start()` before the thread starts, and only read
/// after that. `runLoop` is written by the thread before it signals `start()`, which waits for that before going on.
/// `state` and `isCommandHeld` are protected by their mutexes. One object serves one start and one stop.
nonisolated final class SwitcherEventTap: @unchecked Sendable {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "switcher")

    private let onCommand: @Sendable (SwitcherCommand) -> Void
    private let state = Mutex(SwitcherKeyState())
    private let isCommandHeld = Mutex(false)
    private var modifierTap: CFMachPort?
    private var keyTap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(onCommand: @escaping @Sendable (SwitcherCommand) -> Void) {
        self.onCommand = onCommand
    }

    /// Returns false if the system refuses, which means Accessibility access is missing.
    func start() -> Bool {
        let info = Unmanaged.passUnretained(self).toOpaque()
        let keys = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        let modifiers = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard
            let keyTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keys,
                callback: switcherKeyCallback, userInfo: info)
        else {
            Self.log.error("The system refused an event tap")
            return false
        }
        guard
            let modifierTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: modifiers,
                callback: switcherModifierCallback, userInfo: info)
                ?? CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: modifiers, callback: switcherModifierCallback, userInfo: info)
        else {
            // The key tap is born enabled, and one that no run loop serves would hold up every key until the system
            // gave up on it.
            CFMachPortInvalidate(keyTap)
            Self.log.error("The system refused an event tap")
            return false
        }
        self.keyTap = keyTap
        self.modifierTap = modifierTap
        let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        isCommandHeld.withLock { $0 = held }
        CGEvent.tapEnable(tap: keyTap, enable: held)

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            for tap in [self.keyTap, self.modifierTap].compactMap({ $0 }) {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "me.tweakly.Tweakly.switcher-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        for tap in [keyTap, modifierTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// For a session that ended without the keyboard, such as by a click on a tile.
    func endSession() {
        state.withLock { $0.endSession() }
    }

    /// As the keys last said. The flags of the whole session would not do: a tool that remaps keys by rewriting events can
    /// make Command held in the events while the session says it is not, and the panel would close by itself.
    var isCommandDown: Bool {
        isCommandHeld.withLock { $0 }
    }

    /// After sleep the system may have turned a tap off without saying so.
    func ensureEnabled() {
        guard let modifierTap, !CGEvent.tapIsEnabled(tap: modifierTap) else { return }
        CGEvent.tapEnable(tap: modifierTap, enable: true)
        // Command may have gone up while nothing was listening: held, the key tap would stay on and wake for every key
        // pressed anywhere until Command was next pressed. Looked at on the taps' own thread, in turn with the events.
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            noteCommand(held: CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand))
        }
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            let flags = event.flags
            let modifiers = SwitcherKeyState.Modifiers(
                command: flags.contains(.maskCommand), shift: flags.contains(.maskShift),
                other: flags.contains(.maskControl) || flags.contains(.maskAlternate))
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let decision = state.withLock { $0.keyDown(code: code, modifiers: modifiers, isRepeat: isRepeat) }
            if let command = decision.command { onCommand(command) }
            return decision.swallow ? nil : Unmanaged.passUnretained(event)
        case .keyUp:
            return state.withLock { $0.keyUp() }.swallow ? nil : Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout:
            // Only the timeout counts. Turning this tap off between key presses also reports a disabled tap.
            if isCommandHeld.withLock({ $0 }), let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    fileprivate func handleModifiers(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            noteCommand(held: event.flags.contains(.maskCommand))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let modifierTap { CGEvent.tapEnable(tap: modifierTap, enable: true) }
            // Command may have gone up while nothing was listening, and no event will say so now.
            noteCommand(held: CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand))
        default:
            break
        }
    }

    private func noteCommand(held: Bool) {
        let changed = isCommandHeld.withLock { current in
            defer { current = held }
            return current != held
        }
        guard changed else { return }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: held) }
        if let command = state.withLock({ $0.commandChanged(held: held) }) { onCommand(command) }
    }
}

private nonisolated func switcherKeyCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SwitcherEventTap>.fromOpaque(info).takeUnretainedValue().handleKey(type: type, event: event)
}

private nonisolated func switcherModifierCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let info {
        Unmanaged<SwitcherEventTap>.fromOpaque(info).takeUnretainedValue().handleModifiers(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
