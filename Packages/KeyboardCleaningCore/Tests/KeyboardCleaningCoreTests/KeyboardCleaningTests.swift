import Testing

@testable import KeyboardCleaningCore

@Suite struct CleaningClockTests {
    @Test func endsAfterTheChosenTime() {
        let clock = CleaningClock(now: 100, seconds: 60)
        #expect(clock.remaining(now: 100) == 60)
        #expect(!clock.isOver(now: 159))
        #expect(clock.isOver(now: 160))
    }

    @Test func remainingNeverGoesBelowZero() {
        #expect(CleaningClock(now: 0, seconds: 10).remaining(now: 500) == 0)
    }

    @Test func addingTimeMovesTheEnd() {
        var clock = CleaningClock(now: 100, seconds: 60)
        clock.add(seconds: 60, now: 110)
        #expect(clock.endsAt == 220)
    }

    @Test func noAmountOfAddingMakesItEndless() {
        var clock = CleaningClock(now: 0, seconds: 60)
        for _ in 0..<10_000 { clock.add(seconds: 60, now: 0) }
        #expect(clock.remaining(now: 0) == CleaningClock.longestRemaining)
    }

    @Test func aHugeStartIsCappedToo() {
        #expect(CleaningClock(now: 0, seconds: 1_000_000).remaining(now: 0) == CleaningClock.longestRemaining)
    }

    @Test func everyLengthFitsWithinTheLimit() {
        for length in CleaningLength.allCases {
            #expect(length.seconds <= CleaningClock.longestRemaining)
            #expect(length.seconds > 0)
        }
    }

    @Test func textReadsAsMinutesAndSeconds() {
        #expect(CleaningClock.text(remaining: 60) == "1:00")
        #expect(CleaningClock.text(remaining: 65) == "1:05")
        #expect(CleaningClock.text(remaining: 9) == "0:09")
    }

    @Test func textRoundsUpSoItNeverShowsZeroEarly() {
        #expect(CleaningClock.text(remaining: 0.2) == "0:01")
        #expect(CleaningClock.text(remaining: 59.5) == "1:00")
        #expect(CleaningClock.text(remaining: 0) == "0:00")
    }
}

@Suite struct UnlockChordTests {
    @Test func holdingBothForLongEnoughUnlocks() {
        var chord = UnlockChord()
        chord.update(leftHeld: true, rightHeld: true, now: 10)
        #expect(!chord.isComplete(now: 12.9))
        #expect(chord.isComplete(now: 13))
    }

    @Test func oneKeyAloneDoesNothing() {
        var chord = UnlockChord()
        chord.update(leftHeld: true, rightHeld: false, now: 10)
        #expect(!chord.isComplete(now: 100))
        chord.update(leftHeld: false, rightHeld: true, now: 100)
        #expect(!chord.isComplete(now: 200))
    }

    @Test func nothingHeldDoesNothing() {
        #expect(!UnlockChord().isComplete(now: 100))
    }

    @Test func releasingEitherStartsOver() {
        var chord = UnlockChord()
        chord.update(leftHeld: true, rightHeld: true, now: 10)
        chord.update(leftHeld: true, rightHeld: false, now: 12)
        #expect(!chord.isComplete(now: 20))
        chord.update(leftHeld: true, rightHeld: true, now: 20)
        #expect(!chord.isComplete(now: 22.9))
        #expect(chord.isComplete(now: 23))
    }

    @Test func otherEventsWhileHoldingDoNotRestartIt() {
        var chord = UnlockChord()
        chord.update(leftHeld: true, rightHeld: true, now: 10)
        chord.update(leftHeld: true, rightHeld: true, now: 12)
        #expect(chord.isComplete(now: 13))
    }
}

@Suite struct DeviceModifiersTests {
    @Test func tellsTheTwoCommandKeysApart() {
        // As seen in real events: the left Command key sets 0x08 and the right one 0x10, on top of the general bit.
        let left = DeviceModifiers(flags: 0x10_0108)
        #expect(left.leftCommandHeld && !left.rightCommandHeld)
        let right = DeviceModifiers(flags: 0x10_0110)
        #expect(!right.leftCommandHeld && right.rightCommandHeld)
        let both = DeviceModifiers(flags: 0x10_0118)
        #expect(both.leftCommandHeld && both.rightCommandHeld)
    }

    @Test func noCommandKey() {
        let none = DeviceModifiers(flags: 0x100)
        #expect(!none.leftCommandHeld && !none.rightCommandHeld)
    }
}
