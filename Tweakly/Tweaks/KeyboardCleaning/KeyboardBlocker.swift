import AppKit
import KeyboardCleaningCore
import Synchronization
import SystemMetrics
import os

/// Swallows every key press for a limited time.
///
/// Everything that ends the block lives here, on a thread of its own, and none of it needs the rest of the app: the
/// time limit and the Command keys work even if the main thread hangs and the screen stops responding. If this process
/// dies for any reason, the system removes the tap with it. Nothing is saved anywhere, so a restart cannot bring the
/// block back.
///
/// `@unchecked Sendable`: `tap` and `runLoop` are written by `start()` and by the thread before it signals `start()`,
/// which waits for that, and only read after. `state` is protected by its mutex.
nonisolated final class KeyboardBlocker: @unchecked Sendable {
    enum Ending: Sendable {
        case timeUp
        case commandKeys
        case accessLost
    }

    private struct State {
        var clock: CleaningClock
        var chord = UnlockChord()
        #if TWEAKLY_AUTOMATION
            /// Only a test reads it: the count left the screen in 0017.
            var presses = 0
        #endif
        var isOver = false
    }

    /// Often enough for the Command keys to feel immediate. It runs only while the keyboard is off.
    private static let checkInterval: TimeInterval = 0.1
    /// `NSEvent.EventType.systemDefined`, which has no name in `CGEventType`.
    private static let systemDefinedType: UInt32 = 14
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "keyboard-cleaning")

    /// Seconds that go on through sleep and that moving the clock does not touch. The main thread ends the block on the way to
    /// sleep, but this must not count on it: with that thread hung, a clock stopped by sleep would leave a Mac waking up to a
    /// login screen with the keyboard off for all the time that was left.
    private static var now: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private let state: Mutex<State>
    private let onEnd: @Sendable (Ending) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(seconds: Double, onEnd: @escaping @Sendable (Ending) -> Void) {
        state = Mutex(State(clock: CleaningClock(now: Self.now, seconds: seconds)))
        self.onEnd = onEnd
    }

    /// Returns false if the system refuses, in which case the keyboard simply stays on.
    func start() -> Bool {
        let events: [UInt32] = [
            CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
            Self.systemDefinedType,
        ]
        let mask = events.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1 }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: keyboardBlockerCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.error("The system refused an event tap")
            return false
        }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            if let tap = self.tap {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            }
            let timer = CFRunLoopTimerCreateWithHandler(
                nil, CFAbsoluteTimeGetCurrent() + Self.checkInterval, Self.checkInterval, 0, 0
            ) { [self] _ in
                check()
            }
            CFRunLoopTimerSetTolerance(timer, Self.checkInterval * 0.2)
            CFRunLoopAddTimer(loop, timer, .commonModes)
            ready.signal()
            CFRunLoopRun()
            // The run loop would keep the timer, the timer this object, and this object the run loop, for good.
            CFRunLoopTimerInvalidate(timer)
        }
        thread.name = "me.tweakly.Tweakly.keyboard-blocker"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    /// Lets the keyboard go. Safe to call at any time and more than once.
    func stop() {
        guard
            state.withLock({ state in
                defer { state.isOver = true }
                return !state.isOver
            })
        else { return }
        release()
    }

    func addTime(seconds: Double) {
        state.withLock { $0.clock.add(seconds: seconds, now: Self.now) }
    }

    var remaining: Double {
        state.withLock { $0.clock.remaining(now: Self.now) }
    }

    #if TWEAKLY_AUTOMATION
        var presses: Int {
            state.withLock { $0.presses }
        }
    #endif

    private func release() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    private func end(_ ending: Ending) {
        guard
            state.withLock({ state in
                defer { state.isOver = true }
                return !state.isOver
            })
        else { return }
        release()
        onEnd(ending)
    }

    private func check() {
        let now = Self.now
        let (timeUp, chordDone, over) = state.withLock {
            ($0.clock.isOver(now: now), $0.chord.isComplete(now: now), $0.isOver)
        }
        guard !over else { return }
        if timeUp {
            end(.timeUp)
        } else if chordDone {
            end(.commandKeys)
        } else if !AXIsProcessTrusted() {
            // A tap left behind by a revoked permission is a known way to get input stuck.
            end(.accessLost)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let now = Self.now
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turned the tap off, and it stays off if the time is up anyway.
            let isOver = state.withLock { $0.isOver || $0.clock.isOver(now: now) }
            if !isOver, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown, .keyUp, .flagsChanged:
            // The first key after the limit gets through, even if the timer above somehow did not run.
            let isOver = state.withLock { state -> Bool in
                if state.isOver || state.clock.isOver(now: now) { return true }
                #if TWEAKLY_AUTOMATION
                    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        state.presses += 1
                    }
                #endif
                if type == .flagsChanged {
                    let modifiers = DeviceModifiers(flags: event.flags.rawValue)
                    state.chord.update(
                        leftHeld: modifiers.leftCommandHeld, rightHeld: modifiers.rightCommandHeld, now: now)
                }
                return false
            }
            return isOver ? pass : nil
        default:
            guard type.rawValue == Self.systemDefinedType else { return pass }
            // Only the volume, brightness and playback keys. Other subtypes, such as those of the power button, are
            // left alone. This is not asked through `NSEvent`, which crashes on this thread, see the function.
            let isAuxiliaryKey = SystemDefinedEvent.subtype(of: event) == SystemDefinedEvent.auxiliaryKeysSubtype
            guard isAuxiliaryKey, !state.withLock({ $0.isOver }) else { return pass }
            return nil
        }
    }
}

private nonisolated func keyboardBlockerCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardBlocker>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
}
