import Testing

@testable import WindowSwitcherCore

@Suite struct WindowPictureShelfTests {
    private typealias Shelf = WindowPictureShelf<String, String>

    private func shelf(with windows: [UInt32]) -> Shelf {
        var shelf = Shelf()
        for window in windows { shelf.store("sharp \(window)", kept: "kept \(window)", of: window, takenIn: shelf.era) }
        return shelf
    }

    @Test func aWarningAboutMemoryLeavesTheCompressedCopies() {
        var shelf = shelf(with: [1, 2, 3])
        shelf.memoryIsShort(.warning)
        #expect(shelf.sharp.isEmpty)
        #expect(shelf.kept == [1: "kept 1", 2: "kept 2", 3: "kept 3"])
    }

    @Test func criticalPressureTakesEverything() {
        var shelf = shelf(with: [1, 2])
        shelf.memoryIsShort(.critical)
        #expect(shelf.sharp.isEmpty)
        #expect(shelf.kept.isEmpty)
    }

    @Test func theCopiesOutliveTheSharpPicturesTimeAndSleep() {
        var shelf = shelf(with: [1, 2])
        shelf.forgetSharp()
        #expect(shelf.sharp.isEmpty)
        #expect(shelf.kept.count == 2)
    }

    @Test func aWindowStillOpenKeepsItsPictures() {
        // A minimized window or one on another Space is still in the window server's full list.
        var shelf = shelf(with: [1, 2, 3])
        shelf.keepOnly([1, 3, 9])
        #expect(Set(shelf.sharp.keys) == [1, 3])
        #expect(Set(shelf.kept.keys) == [1, 3])
    }

    @Test func aPictureBegunBeforeAWarningKeepsOnlyItsCopy() {
        var shelf = Shelf()
        let began = shelf.era
        shelf.memoryIsShort(.warning)
        shelf.store("sharp", kept: "kept", of: 7, takenIn: began)
        #expect(shelf.sharp[7] == nil)
        #expect(shelf.kept[7] == "kept")
        // The next capture is in the new era and is kept whole.
        shelf.store("sharp", kept: "kept", of: 8, takenIn: shelf.era)
        #expect(shelf.sharp[8] == "sharp")
    }

    @Test func aPictureBegunBeforeEverythingWentAddsNothing() {
        var shelf = Shelf()
        let began = shelf.era
        shelf.forgetEverything()
        shelf.store("sharp", kept: "kept", of: 7, takenIn: began)
        #expect(shelf.sharp.isEmpty)
        #expect(shelf.kept.isEmpty)
    }

    @Test func aCopyBegunBeforeCopiesWereTurnedOffIsNotKept() {
        var shelf = shelf(with: [1])
        let began = shelf.era
        shelf.forgetKept()
        shelf.store("sharp", kept: "kept", of: 2, takenIn: began)
        #expect(shelf.kept.isEmpty)
        #expect(shelf.sharp.count == 2)
    }

    @Test func aNewerPictureReplacesTheOldOne() {
        var shelf = shelf(with: [1])
        shelf.store("sharp new", kept: "kept new", of: 1, takenIn: shelf.era)
        shelf.store("sharp newer", kept: nil, of: 1, takenIn: shelf.era)
        #expect(shelf.sharp[1] == "sharp newer")
        #expect(shelf.kept[1] == "kept new")
    }
}
