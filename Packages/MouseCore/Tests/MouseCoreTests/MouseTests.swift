import Foundation
import Testing

@testable import MouseCore

@Suite struct MouseSettingsTests {
    @Test func theDefaultsAreWhatTheOwnerAskedFor() {
        let settings = MouseSettings()
        #expect(!settings.acceleration)
        #expect(settings.speed == 1)
        #expect(settings.scrollDirection == .standard)
        #expect(!settings.scrollAcceleration)
        #expect(settings.linesPerNotch == 3)
        #expect(!settings.smoothScrolling)
        #expect(!settings.sideButtonSwipes)
    }

    @Test func storedValuesAreBroughtWithinReach() {
        var settings = MouseSettings()
        settings.speed = 3
        settings.linesPerNotch = 40
        #expect(settings.validated.speed == 2.8)
        #expect(settings.validated.linesPerNotch == 10)
        settings.linesPerNotch = -2
        #expect(settings.validated.linesPerNotch == 1)
    }
}

@Suite struct PointerSpeedTests {
    @Test func aFasterPointerClaimsFewerCountsAnInch() {
        #expect(PointerSpeed.resolution(original: 400, speed: 1) == 400)
        #expect(PointerSpeed.resolution(original: 400, speed: 2) == 200)
        #expect(PointerSpeed.resolution(original: 400, speed: 0.5) == 800)
    }

    @Test func theResolutionStaysWhereTheSystemAcceptsIt() {
        #expect(PointerSpeed.resolution(original: 1600, speed: 0.25) == 1995)
        #expect(PointerSpeed.resolution(original: 20, speed: 4) == 10)
        #expect(PointerSpeed.resolution(original: 400, speed: 0) == 400)
    }
}

@Suite struct WheelScrollTests {
    @Test func theWheelIsTurnedBackOnlyWhenTheSystemDisagrees() {
        #expect(WheelScroll.flips(wanted: .standard, systemNatural: true))
        #expect(!WheelScroll.flips(wanted: .standard, systemNatural: false))
        #expect(WheelScroll.flips(wanted: .natural, systemNatural: false))
        #expect(!WheelScroll.flips(wanted: .natural, systemNatural: true))
    }

    @Test func notchesBecomeLines() {
        #expect(WheelScroll.lines(notches: 1, linesPerNotch: 3) == 3)
        #expect(WheelScroll.lines(notches: -2, linesPerNotch: 3) == -6)
    }
}

@Suite struct WheelNotchesTests {
    @Test func aSlowNotchIsANotchThoughTheSystemCallsItATenthOfALine() {
        var wheel = WheelNotches()
        #expect(wheel.notches(wholeLines: 1, lines: 0.1) == 1)
        #expect(wheel.notches(wholeLines: -1, lines: -0.1) == -1)
    }

    @Test func aWheelTheSystemSpeedsUpStillGivesOneNotchAnEvent() {
        var wheel = WheelNotches()
        // As measured on a DeathAdder turned quickly.
        let reported: [Int64] = [1, 3, 4, 5, 6, 7, 8]
        #expect(reported.map { wheel.notches(wholeLines: $0, lines: Double($0)) } == [1, 1, 1, 1, 1, 1, 1])
        #expect(wheel.notches(wholeLines: -5, lines: -5) == -1)
    }

    @Test func partsOfANotchAddUp() {
        var wheel = WheelNotches()
        #expect(wheel.notches(wholeLines: 0, lines: 0.4) == 0)
        #expect(wheel.notches(wholeLines: 0, lines: 0.4) == 0)
        #expect(wheel.notches(wholeLines: 0, lines: 0.4) == 1)
        #expect(abs(wheel.partial - 0.2) < 0.0001)
        #expect(wheel.notches(wholeLines: 1, lines: 0.1) == 1)
        #expect(wheel.partial == 0)
    }

    @Test func turningBackForgetsWhatWasGathered() {
        var wheel = WheelNotches()
        _ = wheel.notches(wholeLines: 0, lines: 0.8)
        #expect(wheel.notches(wholeLines: 0, lines: -0.5) == 0)
        #expect(wheel.partial == -0.5)
    }

    @Test func anAxisThatDidNotMoveGivesNothing() {
        var wheel = WheelNotches()
        _ = wheel.notches(wholeLines: 0, lines: 0.6)
        #expect(wheel.notches(wholeLines: 0, lines: 0) == 0)
        #expect(abs(wheel.partial - 0.6) < 0.0001)
    }
}

@Suite struct SmoothScrollTests {
    @Test func aNotchGlidesToExactlyItsDistance() {
        var glide = SmoothScroll()
        glide.add(lines: 3)
        var total = 0.0
        var frames = 0
        while glide.isGliding, frames < 200 {
            total += glide.step(seconds: 1.0 / 120)
            frames += 1
        }
        #expect(total == 48)
        // Settles within about a quarter of a second.
        #expect(frames < 40)
    }

    @Test func itStartsQuicklyAndSlowsDown() {
        var glide = SmoothScroll()
        glide.add(lines: 3)
        let first = glide.step(seconds: 1.0 / 60)
        let second = glide.step(seconds: 1.0 / 60)
        #expect(first > second)
        #expect(first > 10)
    }

    @Test func notchesInARowAddUpAndTurningBackStopsAtOnce() {
        var glide = SmoothScroll()
        glide.add(lines: 3)
        glide.add(lines: 3)
        #expect(glide.remaining == 96)
        glide.add(lines: -3)
        #expect(glide.remaining == -48)
    }
}

@Suite struct SideButtonTests {
    @Test func appsThatKnowTheButtonsGetThemAsTheyAre() {
        #expect(SideButtons.swipe(button: 3, bundleID: "com.google.Chrome", enabled: true) == nil)
        #expect(SideButtons.swipe(button: 3, bundleID: "com.valvesoftware.steam", enabled: true) == nil)
        #expect(SideButtons.swipe(button: 3, bundleID: nil, enabled: true) == nil)
    }

    @Test func appsThatDoNotGetTheSwipeWhenAskedFor() {
        #expect(SideButtons.swipe(button: 3, bundleID: "com.apple.Safari", enabled: true) == .back)
        #expect(SideButtons.swipe(button: 4, bundleID: "com.apple.finder", enabled: true) == .forward)
        #expect(SideButtons.swipe(button: 3, bundleID: "org.mozilla.firefox", enabled: true) == .back)
        #expect(SideButtons.swipe(button: 3, bundleID: "com.apple.Safari", enabled: false) == nil)
        #expect(SideButtons.swipe(button: 2, bundleID: "com.apple.Safari", enabled: true) == nil)
        #expect(SideButtons.swipe(button: 3, bundleID: "org.mozilla.firefoxbeta", enabled: true) == nil)
    }
}

@Suite struct MouseOriginalsTests {
    private let systems = MouseOriginals.Values(resolution: 400, linear: 0, acceleration: 45056)
    private let tweaklys = MouseOriginals.Values(resolution: 200, linear: 1, acceleration: 45056)

    @Test func theFirstReadingIsKept() {
        var originals = MouseOriginals()
        #expect(originals.original(of: 7, now: systems) == systems)
        #expect(originals.kept(for: 7) == systems)
    }

    @Test func afterACrashTheValuesFromBeforeWinOverTweaklysOwn() throws {
        var before = MouseOriginals()
        _ = before.original(of: 7, now: systems)
        // The agent dies with the speed set; the next one finds Tweakly's values on the mouse.
        var after = try JSONDecoder().decode(MouseOriginals.self, from: JSONEncoder().encode(before))
        #expect(after.original(of: 7, now: tweaklys) == systems)
    }

    @Test func aMousePutBackIsForgotten() {
        var originals = MouseOriginals()
        _ = originals.original(of: 7, now: systems)
        originals.forget(7)
        #expect(originals.isEmpty)
        #expect(originals.original(of: 7, now: tweaklys) == tweaklys)
    }

    @Test func miceUnpluggedSinceAreDropped() {
        var originals = MouseOriginals()
        _ = originals.original(of: 7, now: systems)
        _ = originals.original(of: 8, now: systems)
        originals.keepOnly([8])
        #expect(originals.kept(for: 7) == nil)
        #expect(originals.kept(for: 8) == systems)
    }
}
