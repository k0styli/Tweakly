import AppKit
import Carbon
import LanguageSwitchCore
import Synchronization
import os

/// Tells a tap of Fn from Fn held for a shortcut.
///
/// Two listening taps, so that typing costs nothing: one sees only modifier changes, a few a minute, and it turns on
/// the other, which sees keys, clicks and media keys, only while Fn is held, as the switcher does with Command. The
/// system's own records of key presses would have spared the second tap, but neither will do: the time of the last key
/// press comes rounded to half a second, and the count of them lags by up to 0.4 s (macOS 27.2).
///
/// The taps have a thread of their own, so the key tap is on within a millisecond of Fn going down even when the main
/// thread is busy. The press is judged by the events' own times, which are nanoseconds of `CLOCK_UPTIME_RAW`.
///
/// `@unchecked Sendable`: the tap references are written once, by `start()` before the thread starts, and only read
/// after that. `runLoop` is written by the thread before it signals `start()`, which waits for that before going on.
/// `state` is protected by its mutex. One object serves one start and one stop.
nonisolated final class FnKeyTap: @unchecked Sendable {
    private struct State {
        var press = FnTap()
        var isKeyTapOn = false
        #if TWEAKLY_AUTOMATION
            var lastRelease = "none"
        #endif
    }

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "language-switch")
    /// `NSEvent.EventType.systemDefined`, which has no name in `CGEventType`: the volume, brightness and playback keys,
    /// and with them every click. Fn itself sends none.
    private static let systemDefinedType: UInt32 = 14
    private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    /// The globe key itself. Keyboards that print 🌐︎ on Fn send a press of it a fraction of a millisecond after Fn
    /// comes up, even with the key set to do nothing (macOS 27.2, MacBook Air M2). It is part of the tap, not another key.
    private static let globeKeyCode: Int64 = 179

    private let onTap: @Sendable () -> Void
    private let state = Mutex(State())
    private var modifierTap: CFMachPort?
    private var keyTap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(onTap: @escaping @Sendable () -> Void) {
        self.onTap = onTap
    }

    /// Returns false if the system refuses, which means Accessibility access is missing.
    func start() -> Bool {
        let info = Unmanaged.passUnretained(self).toOpaque()
        let modifiers = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let others = [
            CGEventType.keyDown.rawValue, CGEventType.leftMouseDown.rawValue, CGEventType.rightMouseDown.rawValue,
            CGEventType.otherMouseDown.rawValue, Self.systemDefinedType,
        ].reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1 }
        // At the tail, so what is seen is what apps get, after any tool that remaps keys has had its say.
        guard
            let modifierTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: modifiers,
                callback: fnModifierCallback, userInfo: info)
        else {
            Self.log.error("The system refused an event tap")
            return false
        }
        guard
            let keyTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: others,
                callback: fnKeyCallback, userInfo: info)
        else {
            CFMachPortInvalidate(modifierTap)
            Self.log.error("The system refused an event tap")
            return false
        }
        CGEvent.tapEnable(tap: keyTap, enable: false)
        self.modifierTap = modifierTap
        self.keyTap = keyTap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            for tap in [self.modifierTap, self.keyTap].compactMap({ $0 }) {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "me.tweakly.Tweakly.fn-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        for tap in [modifierTap, keyTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Forgets a press under way, whose release may never come, as across sleep. After sleep the system may also have
    /// turned the modifier tap off without saying so.
    func reset() {
        state.withLock { state in
            state.press.reset()
            state.isKeyTapOn = false
        }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
        if let modifierTap, !CGEvent.tapIsEnabled(tap: modifierTap) {
            CGEvent.tapEnable(tap: modifierTap, enable: true)
        }
    }

    #if TWEAKLY_AUTOMATION
        var lastRelease: String {
            state.withLock { $0.lastRelease }
        }
    #endif

    fileprivate func handleModifiers(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            // Only the Fn key itself says whether Fn went down or up. Arrow and function keys carry the Fn flag too,
            // and a modifier pressed while one of them is held must not look like a press of Fn.
            let isFnKey = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function)
            let others = !flags.isDisjoint(with: Self.otherModifiers)
            let time = Self.seconds(of: event)
            let (isTap, keyTapChange) = state.withLock { state -> (Bool, Bool?) in
                let wasPressed = state.press.isPressed
                let fn = isFnKey ? flags.contains(.maskSecondaryFn) : wasPressed
                let isTap = state.press.modifiersChanged(fn: fn, others: others, at: time)
                #if TWEAKLY_AUTOMATION
                    if wasPressed, !state.press.isPressed { state.lastRelease = isTap ? "tap" : "not a tap" }
                #endif
                let wanted = state.press.isPressed
                defer { state.isKeyTapOn = wanted }
                return (isTap, state.isKeyTapOn == wanted ? nil : wanted)
            }
            if let keyTapChange, let keyTap { CGEvent.tapEnable(tap: keyTap, enable: keyTapChange) }
            if isTap { onTap() }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reset()
        default:
            break
        }
    }

    fileprivate func handleKey(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            // Only the timeout counts. Turning this tap off after each press also reports a disabled tap.
            if state.withLock({ $0.isKeyTapOn }), let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
        case .tapDisabledByUserInput:
            break
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == Self.globeKeyCode:
            break
        default:
            let time = Self.seconds(of: event)
            state.withLock { $0.press.otherInput(at: time) }
        }
    }

    /// An event made without a time, as a posted one can be, happened now.
    private static func seconds(of event: CGEvent) -> Double {
        let nanoseconds = event.timestamp == 0 ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : event.timestamp
        return Double(nanoseconds) / 1_000_000_000
    }
}

private nonisolated func fnModifierCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let info {
        Unmanaged<FnKeyTap>.fromOpaque(info).takeUnretainedValue().handleModifiers(type: type, event: event)
    }
    // A listening tap's return value is ignored, so the event goes back untouched.
    return Unmanaged.passUnretained(event)
}

private nonisolated func fnKeyCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let info {
        Unmanaged<FnKeyTap>.fromOpaque(info).takeUnretainedValue().handleKey(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
