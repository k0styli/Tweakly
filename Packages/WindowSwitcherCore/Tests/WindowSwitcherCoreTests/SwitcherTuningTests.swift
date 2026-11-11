import Testing

@testable import WindowSwitcherCore

@Suite struct SwitcherTuningTests {
    @Test func theDefaultsAreTheMeasuredValues() {
        let tuning = SwitcherTuning()
        #expect(tuning.panelDelayMilliseconds == 130)
        #expect(tuning.largestTileHeight == 176)
        #expect(tuning.fitsBackgroundToRows == false)
        #expect(tuning.capturesAtOnce == 4)
        #expect(tuning.retakeAfterSeconds == 10)
        #expect(tuning.keepSharpPicturesSeconds == 60)
        #expect(tuning.savesCompressedPictures == true)
        #expect(tuning.compressionQuality == 0.85)
    }

    @Test func theDefaultsAreAmongTheChoices() {
        #expect(SwitcherTuning().validated == SwitcherTuning())
    }

    /// Preferences can hold anything, and this runs as the app starts, so that stopping here would stop every launch.
    @Test(arguments: [Int.min, Int.min + 1, -5_000_000, 5_000_000, Int.max])
    func anyNumberAtAllFallsOnAChoice(number: Int) {
        var tuning = SwitcherTuning()
        tuning.panelDelayMilliseconds = number
        tuning.largestTileHeight = number
        tuning.capturesAtOnce = number
        tuning.retakeAfterSeconds = number
        tuning.keepSharpPicturesSeconds = number
        let valid = tuning.validated
        #expect(SwitcherTuning.panelDelayChoices.contains(valid.panelDelayMilliseconds))
        #expect(SwitcherTuning.tileHeightChoices.contains(valid.largestTileHeight))
        #expect(SwitcherTuning.capturesAtOnceRange.contains(valid.capturesAtOnce))
        #expect(SwitcherTuning.retakeChoices.contains(valid.retakeAfterSeconds))
        #expect(SwitcherTuning.keepSharpChoices.contains(valid.keepSharpPicturesSeconds))
    }

    @Test func thePanelIsBuiltJustBeforeItShows() {
        var tuning = SwitcherTuning()
        #expect(abs(tuning.panelDelay - 0.13) < 0.001)
        #expect(abs(tuning.buildDelay - 0.08) < 0.001)
        tuning.panelDelayMilliseconds = 0
        #expect(tuning.panelDelay == 0)
        #expect(tuning.buildDelay == 0)
    }

    @Test func storedNonsenseLandsOnTheNearestChoice() {
        var tuning = SwitcherTuning()
        tuning.panelDelayMilliseconds = -40
        tuning.largestTileHeight = 9000
        tuning.capturesAtOnce = 99
        tuning.retakeAfterSeconds = 7
        tuning.keepSharpPicturesSeconds = 0
        tuning.compressionQuality = 5
        let valid = tuning.validated
        #expect(valid.panelDelayMilliseconds == 0)
        #expect(valid.largestTileHeight == 176)
        #expect(valid.capturesAtOnce == 10)
        #expect(valid.retakeAfterSeconds == 5)
        #expect(valid.keepSharpPicturesSeconds == 15)
        #expect(valid.compressionQuality == 0.95)

        tuning.capturesAtOnce = 0
        #expect(tuning.validated.capturesAtOnce == 1)
    }

    @Test func showsEveryWindowUntilToldOtherwise() {
        let tuning = SwitcherTuning()
        #expect(tuning.showsPreviews)
        #expect(tuning.showsAppsWithoutWindows)
        #expect(!tuning.filtersWindowsOutOfSight)
        for desktop in [true, false, nil] as [Bool?] {
            #expect(tuning.shows(isOnScreen: false, isOnCurrentDesktop: desktop))
        }
    }

    @Test func aWindowOnScreenAlwaysStays() {
        var tuning = SwitcherTuning()
        tuning.showsMinimizedWindows = false
        tuning.showsWindowsOnOtherDesktops = false
        #expect(tuning.filtersWindowsOutOfSight)
        #expect(tuning.shows(isOnScreen: true, isOnCurrentDesktop: nil))
        #expect(tuning.shows(isOnScreen: true, isOnCurrentDesktop: true))
    }

    @Test func eachChoiceLeavesOutOnlyItsOwnWindows() {
        var tuning = SwitcherTuning()
        tuning.showsMinimizedWindows = false
        #expect(!tuning.shows(isOnScreen: false, isOnCurrentDesktop: true))
        #expect(tuning.shows(isOnScreen: false, isOnCurrentDesktop: false))

        tuning = SwitcherTuning()
        tuning.showsWindowsOnOtherDesktops = false
        #expect(tuning.shows(isOnScreen: false, isOnCurrentDesktop: true))
        #expect(!tuning.shows(isOnScreen: false, isOnCurrentDesktop: false))
    }

    /// Without the private call, only windows on screen were listed to begin with, so there is nothing to judge.
    @Test func aWindowWhoseDesktopIsUnknownStays() {
        var tuning = SwitcherTuning()
        tuning.showsMinimizedWindows = false
        tuning.showsWindowsOnOtherDesktops = false
        #expect(tuning.shows(isOnScreen: false, isOnCurrentDesktop: nil))
    }
}
