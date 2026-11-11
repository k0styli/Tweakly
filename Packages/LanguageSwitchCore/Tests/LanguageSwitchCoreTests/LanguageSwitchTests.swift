import Testing

@testable import LanguageSwitchCore

@Suite struct FnTapTests {
    /// Fn down and up with the modifiers otherwise up, and other input at the given times.
    private func press(_ tap: inout FnTap, at time: Double, for held: Double = 0.1, input: [Double] = []) -> Bool {
        let isTapOnPress = tap.modifiersChanged(fn: true, others: false, at: time)
        #expect(!isTapOnPress)
        for moment in input { tap.otherInput(at: moment) }
        return tap.modifiersChanged(fn: false, others: false, at: time + held)
    }

    @Test func aQuickPressOnItsOwnIsATap() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10)
        #expect(isTap)
    }

    @Test func holdingFnIsNotATap() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, for: FnTap.longestPress + 0.01)
        #expect(!isTap)
    }

    @Test func aKeyWhileFnIsDownMakesAShortcut() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, input: [10.05])
        #expect(!isTap)
    }

    @Test func aKeyThatWentDownBeforeFnDoesNotCount() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, input: [9.99])
        #expect(isTap)
    }

    @Test func inputSetOffByTheReleaseDoesNotCount() {
        var tap = FnTap()
        // The globe key's own press comes a fraction of a millisecond after Fn comes up, and may be seen first.
        let isTap = press(&tap, at: 10, for: 0.1, input: [10.1003])
        #expect(isTap)
    }

    @Test func inputJustBeforeTheReleaseCounts() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, for: 0.1, input: [10.099])
        #expect(!isTap)
    }

    @Test func aKeyBeforeTheReleaseStillCountsWithTheGlobeKeyAfterIt() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, for: 0.1, input: [10.1003, 10.05])
        #expect(!isTap)
    }

    @Test func inputWithoutFnHeldIsForgotten() {
        var tap = FnTap()
        tap.otherInput(at: 9)
        let isTap = press(&tap, at: 10)
        #expect(isTap)
    }

    @Test func thePressIsTimedFromItsOwnStart() {
        var tap = FnTap()
        _ = press(&tap, at: 10, for: 1)
        let isTap = press(&tap, at: 20, for: 0.2)
        #expect(isTap)
    }

    @Test func aShortcutDoesNotSpoilTheNextPress() {
        var tap = FnTap()
        _ = press(&tap, at: 10, input: [10.05])
        let isTap = press(&tap, at: 11)
        #expect(isTap)
    }

    @Test func fnWithAModifierAlreadyHeldIsAShortcut() {
        var tap = FnTap()
        _ = tap.modifiersChanged(fn: true, others: true, at: 10)
        let isTap = tap.modifiersChanged(fn: false, others: false, at: 10.1)
        #expect(!isTap)
    }

    @Test func aModifierPressedMeanwhileSpoilsTheTap() {
        var tap = FnTap()
        _ = tap.modifiersChanged(fn: true, others: false, at: 10)
        _ = tap.modifiersChanged(fn: true, others: true, at: 10.05)
        _ = tap.modifiersChanged(fn: true, others: false, at: 10.08)
        let isTap = tap.modifiersChanged(fn: false, others: false, at: 10.1)
        #expect(!isTap)
    }

    @Test func fnReleasedBeforeTheOtherModifierIsAShortcut() {
        var tap = FnTap()
        _ = tap.modifiersChanged(fn: true, others: false, at: 10)
        let isTap = tap.modifiersChanged(fn: false, others: true, at: 10.1)
        #expect(!isTap)
    }

    @Test func aSpoiledPressDoesNotSpoilTheNext() {
        var tap = FnTap()
        _ = tap.modifiersChanged(fn: true, others: true, at: 10)
        _ = tap.modifiersChanged(fn: false, others: false, at: 10.1)
        let isTap = press(&tap, at: 11)
        #expect(isTap)
    }

    @Test func otherModifiersAloneDoNothing() {
        var tap = FnTap()
        let isFirstTap = tap.modifiersChanged(fn: false, others: true, at: 10)
        let isSecondTap = tap.modifiersChanged(fn: false, others: false, at: 10.1)
        #expect(!isFirstTap)
        #expect(!isSecondTap)
    }

    @Test func aClockGoingBackIsNotATap() {
        var tap = FnTap()
        let isTap = press(&tap, at: 10, for: -1)
        #expect(!isTap)
    }

    @Test func resetForgetsAPressUnderWay() {
        var tap = FnTap()
        _ = tap.modifiersChanged(fn: true, others: false, at: 10)
        #expect(tap.isPressed)
        tap.reset()
        #expect(!tap.isPressed)
        let isTap = tap.modifiersChanged(fn: false, others: false, at: 10.1)
        #expect(!isTap)
    }
}

@Suite struct InputSourceChoiceTests {
    private let english = "com.apple.keylayout.ABC"
    private let russian = "com.apple.keylayout.RussianWin"
    private let german = "com.apple.keylayout.German"

    @Test func twoSourcesTakeTurns() {
        let available = [english, russian]
        #expect(InputSourceChoice.next(current: english, previous: nil, available: available) == russian)
        #expect(InputSourceChoice.next(current: russian, previous: english, available: available) == english)
    }

    @Test func theOneUsedBeforeComesFirst() {
        let available = [english, russian, german]
        #expect(InputSourceChoice.next(current: german, previous: english, available: available) == english)
    }

    @Test func withoutAPreviousOneTheListGoesOnAndWraps() {
        let available = [english, russian, german]
        #expect(InputSourceChoice.next(current: russian, previous: nil, available: available) == german)
        #expect(InputSourceChoice.next(current: german, previous: nil, available: available) == english)
    }

    @Test func aRemovedPreviousOneIsSkipped() {
        let available = [english, russian]
        #expect(InputSourceChoice.next(current: english, previous: german, available: available) == russian)
    }

    @Test func oneSourceHasNothingToSwitchTo() {
        #expect(InputSourceChoice.next(current: english, previous: russian, available: [english]) == nil)
        #expect(InputSourceChoice.next(current: english, previous: nil, available: []) == nil)
    }

    @Test func anUnlistedCurrentOneStillSwitches() {
        let available = [english, russian]
        #expect(InputSourceChoice.next(current: german, previous: nil, available: available) == english)
        #expect(InputSourceChoice.next(current: nil, previous: russian, available: available) == russian)
    }
}

@Suite struct InputSourceHistoryTests {
    @Test func aChangeKeepsTheOneBefore() {
        var history = InputSourceHistory(current: "a")
        history.selected("b")
        #expect(history.current == "b")
        #expect(history.previous == "a")
    }

    @Test func theSameOneAgainChangesNothing() {
        var history = InputSourceHistory(current: "a")
        history.selected("b")
        history.selected("b")
        #expect(history.previous == "a")
    }

    @Test func onlyTheLastTwoAreKept() {
        var history = InputSourceHistory(current: "a")
        history.selected("b")
        history.selected("c")
        #expect(history.current == "c")
        #expect(history.previous == "b")
    }
}
