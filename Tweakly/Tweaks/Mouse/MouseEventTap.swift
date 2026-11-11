import AppKit
import MouseCore
import Synchronization
import SystemMetrics
import os

/// The mouse's wheel and side buttons, changed on their way to apps. It sees nothing else: the pointer's movement never
/// passes through here, which is what keeps games and a mouse polled 8000 times a second free of any added latency.
///
/// Only a wheel's notches are changed; continuous scrolling, from a trackpad or a Magic Mouse, passes as it is. The
/// callback runs on a thread of its own and does a few arithmetic steps, so a busy main thread cannot hold scrolling up.
///
/// `@unchecked Sendable`: `tap` is written once by `start()` before the thread starts and only read after; `runLoop` is
/// written by the thread before it signals `start()`, which waits for that. The glide, its timer and `heldButtons` are
/// touched only on the tap's thread; what the main thread sets goes through the mutexes.
nonisolated final class MouseEventTap: @unchecked Sendable {
    struct Rules: Sendable, Equatable {
        var flipsWheel = false
        /// Lines for each notch, or nil to leave what the system sends, acceleration included.
        var linesPerNotch: Int?
        var smooth = false
        var sideButtonSwipes = false

        var changesAnything: Bool { flipsWheel || linesPerNotch != nil || smooth || sideButtonSwipes }
    }

    /// Marks the events this tap makes, so they pass through it untouched.
    private static let ownMark: Int64 = 0x5457_4B4C
    /// The points one line is worth in a wheel event the system makes, which apps scroll by.
    private static let pointsPerSystemLine: Double = 10
    /// A frame of the glide, a little shorter than the display's.
    private static let glideInterval: CFTimeInterval = 1.0 / 120
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "mouse")

    private let rules = Mutex(Rules())
    /// Apps by process, kept by the main thread, for the side buttons.
    private let bundleIDs = Mutex([pid_t: String]())
    /// Games, which get one event a notch as the wheel sends it: smooth or multiplied, a notch would switch weapons
    /// several times.
    private let games = Mutex(Set<pid_t>())
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var glideY = SmoothScroll()
    private var glideX = SmoothScroll()
    private var glideTimer: CFRunLoopTimer?
    private var lastGlideStep: CFAbsoluteTime = 0
    private var carryY: Double = 0
    private var carryX: Double = 0
    private var wheelY = WheelNotches()
    private var wheelX = WheelNotches()
    /// Buttons whose press became a swipe, whose release must not reach the app either.
    private var heldButtons: Set<Int64> = []

    /// Returns false if the system refuses, which means Accessibility access is missing.
    func start() -> Bool {
        let mask = CGEventMask(
            1 << CGEventType.scrollWheel.rawValue | 1 << CGEventType.otherMouseDown.rawValue
                | 1 << CGEventType.otherMouseUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: mouseTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.error("The system refused an event tap")
            return false
        }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            if let tap = self.tap { CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "me.tweakly.Tweakly.mouse-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        // Events stop coming through at once; the rest ends on the tap's thread, which owns the glide.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        guard let runLoop else { return }
        // Invalidating the tap here instead would leave the loop with no source, and it would return before running
        // this block, which would then hold `self` for good through the loop `self` holds.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            stopGliding()
            if let tap { CFMachPortInvalidate(tap) }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    func update(_ rules: Rules) {
        self.rules.withLock { $0 = rules }
        if let tap { CGEvent.tapEnable(tap: tap, enable: rules.changesAnything) }
    }

    func update(apps: [pid_t: String], games: Set<pid_t>) {
        bundleIDs.withLock { $0 = apps }
        self.games.withLock { $0 = games }
    }

    // MARK: Events, on the tap's thread

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .scrollWheel:
            return scrolled(event)
        case .otherMouseDown, .otherMouseUp:
            return pressed(event, isDown: type == .otherMouseDown)
        case .tapDisabledByTimeout:
            if let tap, rules.withLock({ $0.changesAnything }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func scrolled(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownMark,
            event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        else { return Unmanaged.passUnretained(event) }
        let rules = rules.withLock { $0 }
        let isGame = games.withLock { $0.contains(pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))) }
        let sign: Double = rules.flipsWheel ? -1 : 1
        guard !isGame, let linesPerNotch = rules.linesPerNotch else {
            if rules.flipsWheel { Self.flip(event) }
            return Unmanaged.passUnretained(event)
        }
        // One notch an event, however slow or fast the system judged it, in the direction wanted.
        let notchesY = wheelY.notches(
            wholeLines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1) * Int64(sign),
            lines: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * sign)
        let notchesX = wheelX.notches(
            wholeLines: event.getIntegerValueField(.scrollWheelEventDeltaAxis2) * Int64(sign),
            lines: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * sign)
        let linesY = WheelScroll.lines(notches: notchesY, linesPerNotch: linesPerNotch)
        let linesX = WheelScroll.lines(notches: notchesX, linesPerNotch: linesPerNotch)
        if rules.smooth {
            if linesY != 0 { glideY.add(lines: linesY) }
            if linesX != 0 { glideX.add(lines: linesX) }
            // A part of a notch, as some wheels send, moves nothing yet and needs no frames.
            if linesY != 0 || linesX != 0 { startGliding() }
            return nil
        }
        guard linesY != 0 || linesX != 0 else { return nil }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: linesY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: linesX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(linesY))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(linesX))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(linesY) * Self.pointsPerSystemLine)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(linesX) * Self.pointsPerSystemLine)
        return Unmanaged.passUnretained(event)
    }

    /// Made once, as the tap's thread flips every notch with them.
    private static let wholeFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
    private static let fractionFields: [CGEventField] = [
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventPointDeltaAxis2,
    ]

    private static func flip(_ event: CGEvent) {
        for field in wholeFields {
            event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
        }
        for field in fractionFields {
            event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
        }
    }

    private func pressed(_ event: CGEvent, isDown: Bool) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard isDown else {
            // The release of a press that became a swipe.
            return heldButtons.remove(button) == nil ? Unmanaged.passUnretained(event) : nil
        }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let enabled = rules.withLock { $0.sideButtonSwipes }
        guard let swipe = SideButtons.swipe(button: button, bundleID: bundleIDs.withLock({ $0[pid] }), enabled: enabled)
        else { return Unmanaged.passUnretained(event) }
        heldButtons.insert(button)
        NavigationSwipe.post(swipe == .back ? .back : .forward)
        return nil
    }

    // MARK: The glide, on the tap's thread

    private func startGliding() {
        guard glideTimer == nil, let runLoop else { return }
        lastGlideStep = CFAbsoluteTimeGetCurrent()
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent(), Self.glideInterval, 0, 0
        ) { [self] _ in glideFrame() }
        glideTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    private func glideFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        let seconds = now - lastGlideStep
        lastGlideStep = now
        carryY += glideY.step(seconds: seconds)
        carryX += glideX.step(seconds: seconds)
        let pointsY = Int32(carryY.rounded(.towardZero))
        let pointsX = Int32(carryX.rounded(.towardZero))
        carryY -= Double(pointsY)
        carryX -= Double(pointsX)
        if pointsY != 0 || pointsX != 0,
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: pointsY, wheel2: pointsX,
                wheel3: 0)
        {
            event.setIntegerValueField(.eventSourceUserData, value: Self.ownMark)
            event.post(tap: .cgSessionEventTap)
        }
        if !glideY.isGliding, !glideX.isGliding { stopGliding() }
    }

    private func stopGliding() {
        if let glideTimer { CFRunLoopTimerInvalidate(glideTimer) }
        glideTimer = nil
        glideY.stop()
        glideX.stop()
        carryY = 0
        carryX = 0
    }
}

private nonisolated func mouseTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseEventTap>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
}
