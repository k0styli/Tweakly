import CoreGraphics
import Testing

@testable import WindowSwitcherCore

@Suite struct WindowFilterTests {
    private let app: Int32 = 100
    private let full = CGRect(x: 0, y: 40, width: 1200, height: 800)

    private func window(
        _ id: UInt32, title: String = "A", frame: CGRect? = nil, on: Bool = true, owner: Int32? = nil, layer: Int = 0,
        alpha: Double = 1
    ) -> WindowRecord {
        WindowRecord(
            id: id, ownerPID: owner ?? app, title: title, frame: frame ?? full, layer: layer, alpha: alpha,
            isOnScreen: on)
    }

    private func filter(
        onScreen: [WindowRecord] = [], all: [WindowRecord] = [], spaces: @escaping (UInt32) -> Int? = { _ in 1 }
    ) -> [UInt32] {
        WindowFilter.switchable(onScreen: onScreen, all: all, regularApps: [app], spaceCount: spaces).map(\.id)
    }

    /// Measured from a full-screen Chrome on macOS 27.2: the window, its tabs, its toolbar, and what holds them together.
    private let chromeWindow = CGRect(x: 0, y: 121, width: 1470, height: 835)
    private let chromeTabs = CGRect(x: 0, y: 33, width: 1470, height: 41)
    private let chromeHolder = CGRect(x: 0, y: 33, width: 1470, height: 124)

    private func visible(_ windows: [WindowRecord], listed: Bool?) -> [UInt32] {
        WindowFilter.switchable(
            onScreen: windows, all: [], regularApps: [app], spaceCount: { _ in 1 },
            kind: { _ in listed.map { $0 ? .standard : .notListed } }
        ).map(\.id)
    }

    @Test func aFullScreenBrowsersStripsAreNotWindows() {
        let windows = [
            window(1, title: "Page", frame: chromeWindow),
            window(2, title: "", frame: chromeHolder),
            // Taller than the smallest window, as a toolbar with a bookmarks bar is, and listed by Accessibility.
            window(3, title: "", frame: CGRect(x: 0, y: 74, width: 1470, height: 80)),
            window(4, title: "", frame: chromeTabs),
        ]
        for listed in [true, false, nil] { #expect(visible(windows, listed: listed) == [1]) }
    }

    @Test func stripsAreToldApartWithoutTitles() {
        // Titles need Screen Recording, so without it the window itself has none either.
        let windows = [window(1, title: "", frame: chromeWindow), window(2, title: "", frame: chromeHolder)]
        #expect(visible(windows, listed: true) == [1])
    }

    @Test func aShortWindowThatIsNotAStripStays() {
        let main = window(1, title: "Main", frame: chromeWindow)
        // Apart from the window.
        let apart = window(2, title: "", frame: CGRect(x: 0, y: 980, width: 1470, height: 124))
        #expect(visible([main, apart], listed: true) == [1, 2])
        // Narrower.
        let narrow = window(3, title: "", frame: CGRect(x: 100, y: 33, width: 900, height: 88))
        #expect(visible([main, narrow], listed: true) == [1, 3])
        // Has a title.
        let titled = window(4, title: "Tools", frame: chromeHolder)
        #expect(visible([main, titled], listed: nil) == [1, 4])
        // Not much shorter than the window.
        let tall = window(5, title: "", frame: CGRect(x: 0, y: 33, width: 1470, height: 400))
        #expect(visible([main, tall], listed: true) == [1, 5])
        // Another app's.
        let other = window(6, title: "", frame: chromeHolder, owner: 200)
        let filtered = WindowFilter.switchable(
            onScreen: [main, other], all: [], regularApps: [app, 200], spaceCount: { _ in 1 }, kind: { _ in .standard })
        #expect(filtered.map(\.id) == [1, 6])
    }

    @Test func windowsOnScreenKeepTheirOrderFrontToBack() {
        #expect(filter(onScreen: [window(3), window(1), window(2)]) == [3, 1, 2])
    }

    @Test func windowsOutOfSightComeAfterThoseOnScreen() {
        let hidden = window(9, on: false)
        #expect(filter(onScreen: [window(1)], all: [hidden, window(1)]) == [1, 9])
    }

    @Test func aWindowOnBothListsAppearsOnce() {
        #expect(filter(onScreen: [window(1)], all: [window(1), window(1, on: false)]) == [1])
    }

    @Test func standInsOfEveryAppAreLeftOut() {
        // What macOS 27.2 reports: untitled bars and small squares that belong to no Space.
        let bar = window(5, title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 33), on: false)
        let square = window(6, title: "", frame: CGRect(x: 0, y: 0, width: 64, height: 64), on: false)
        let untitled = window(7, title: "", on: false)
        #expect(filter(all: [bar, square, untitled]) { _ in 0 } == [])
    }

    @Test func untitledWindowOutOfSightIsLeftOutUnlessConfirmed() {
        // Seen on macOS 27.2: untitled strips of an app, on a Space.
        let untitled = window(5, title: "", on: false)
        func result(_ listed: Bool?) -> [UInt32] {
            WindowFilter.switchable(
                onScreen: [], all: [untitled], regularApps: [app], spaceCount: { _ in 1 },
                kind: { _ in listed.map { $0 ? .standard : .notListed } }
            ).map(\.id)
        }
        #expect(result(nil) == [])
        #expect(result(false) == [])
        #expect(result(true) == [5])
    }

    @Test func aStripOfAnAppOnAnotherSpaceIsTooThinToBeAWindow() {
        let strip = window(5, title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 32), on: false)
        let result = WindowFilter.switchable(
            onScreen: [], all: [strip], regularApps: [app], spaceCount: { _ in 1 }, kind: { _ in .standard })
        #expect(result.isEmpty)
    }

    @Test func aSheetInsideItsWindowIsLeftOut() {
        let parent = window(1)
        let sheet = window(2, title: "Save", frame: CGRect(x: 300, y: 80, width: 300, height: 160))
        let result = WindowFilter.switchable(
            onScreen: [sheet, parent], all: [], regularApps: [app], spaceCount: { _ in 1 },
            kind: { $0.id == 1 ? .standard : .notListed })
        #expect(result.map(\.id) == [1])
    }

    @Test func accessibilityNamesWhatAWindowIs() {
        #expect(WindowKind(role: "AXWindow", subrole: "AXStandardWindow") == .standard)
        #expect(WindowKind(role: "AXWindow", subrole: "AXDialog") == .dialog)
        #expect(WindowKind(role: "AXWindow", subrole: "AXUnknown") == .unusual)
        #expect(WindowKind(role: "AXWindow", subrole: "AXFloatingWindow") == .unusual)
        #expect(WindowKind(role: "AXWindow", subrole: nil) == .unusual)
        // Measured: Firefox's downloads popup, and Finder's desktop.
        #expect(WindowKind(role: "AXPopover", subrole: "AXUnknown") == .part)
        #expect(WindowKind(role: "AXScrollArea", subrole: nil) == .part)
    }

    /// Frames below were measured on real windows of these apps, next to their main windows.
    private let browser = CGRect(x: 22, y: 55, width: 1200, height: 789)

    private func judged(_ other: WindowRecord, _ kind: WindowKind?) -> [UInt32] {
        let main = window(1, title: "Page", frame: browser)
        return WindowFilter.switchable(
            onScreen: [other, main], all: [], regularApps: [app], spaceCount: { _ in 1 },
            kind: { $0.id == 1 ? .standard : kind }
        ).map(\.id)
    }

    @Test func firefoxsDownloadsPopupGetsNoTile() {
        let popup = window(2, title: "", frame: CGRect(x: 753, y: 113, width: 483, height: 109))
        #expect(judged(popup, .part) == [1])
        // Listed under another role, so not even a title helps it.
        let titled = window(2, title: "Downloads", frame: CGRect(x: 1300, y: 100, width: 483, height: 109))
        #expect(judged(titled, .part) == [1])
    }

    @Test func chromesNoticeAndFindBarGetNoTile() {
        let notice = window(2, title: "", frame: CGRect(x: 300, y: 300, width: 649, height: 70))
        #expect(judged(notice, .unusual) == [1])
        let findBar = window(2, title: "", frame: CGRect(x: 100, y: 120, width: 1038, height: 178))
        #expect(judged(findBar, .unusual) == [1])
    }

    @Test func aNoticeOutsideItsWindowGetsNoTile() {
        // Telegram's, which stands apart from the window.
        let notice = window(2, title: "", frame: CGRect(x: 1300, y: 900, width: 350, height: 70))
        #expect(judged(notice, .unusual) == [1])
    }

    @Test func aRealWindowOfAnUnusualKindKeepsItsTile() {
        // Games and Steam, by other people's reports: titled, with their own title bar.
        let titled = window(2, title: "Friends", frame: CGRect(x: 1300, y: 100, width: 300, height: 600))
        #expect(judged(titled, .unusual) == [2, 1])
        // Firefox's full-screen video, by the same reports: no title, and the size of the screen.
        let video = window(2, title: "", frame: CGRect(x: 1300, y: 0, width: 1470, height: 956))
        #expect(judged(video, .unusual) == [2, 1])
    }

    @Test func anUnusualWindowInsideAnotherIsAPartOfIt() {
        let bubble = window(2, title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(judged(bubble, .unusual) == [1])
        let titled = window(2, title: "Extension", frame: CGRect(x: 100, y: 100, width: 400, height: 500))
        #expect(judged(titled, .unusual) == [1])
    }

    @Test func aTitledDialogKeepsItsTileAndAnUntitledOneDoesNot() {
        let settings = window(2, title: "Settings", frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        #expect(judged(settings, .dialog) == [2, 1])
        let bubble = window(2, title: "", frame: CGRect(x: 100, y: 100, width: 246, height: 381))
        #expect(judged(bubble, .dialog) == [1])
    }

    @Test func aTitledWindowAnAppForgotToListKeepsItsTile() {
        let forgotten = window(2, title: "Tool", frame: CGRect(x: 1300, y: 100, width: 300, height: 400))
        #expect(judged(forgotten, .notListed) == [2, 1])
    }

    @Test func aStandardWindowKeepsItsTileWhateverItsSizeAndTitle() {
        let small = window(2, title: "", frame: CGRect(x: 100, y: 100, width: 230, height: 300))
        #expect(judged(small, .standard) == [2, 1])
    }

    @Test func withoutAnAnswerOnlyWhatLooksLikeNothingElseGoes() {
        // A titled window stays even inside another, as it may be real, and so does an app's biggest window.
        let titled = window(2, title: "Tool", frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        #expect(judged(titled, nil) == [2, 1])
        let notice = window(2, title: "", frame: CGRect(x: 1300, y: 900, width: 350, height: 70))
        #expect(judged(notice, nil) == [1])
        let only = window(5, title: "", frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let alone = WindowFilter.switchable(
            onScreen: [only], all: [], regularApps: [app], spaceCount: { _ in 1 }, kind: { _ in nil })
        #expect(alone.map(\.id) == [5])
    }

    @Test func anUntitledPopoverIsLeftOut() {
        let parent = window(1)
        let popover = window(2, title: "", frame: CGRect(x: 1190, y: 80, width: 226, height: 146))
        let result = WindowFilter.switchable(
            onScreen: [popover, parent], all: [], regularApps: [app], spaceCount: { _ in 1 },
            kind: { $0.id == 1 ? .standard : .notListed })
        #expect(result.map(\.id) == [1])
    }

    @Test func aWindowThatCannotBeCheckedIsKept() {
        // An app that does not answer Accessibility must not lose its windows.
        let parent = window(1)
        let inner = window(2, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        let result = WindowFilter.switchable(
            onScreen: [inner, parent], all: [], regularApps: [app], spaceCount: { _ in 1 }, kind: { _ in nil })
        #expect(result.map(\.id) == [2, 1])
    }

    @Test func beingOverAnotherAppsWindowMeansNothing() {
        let big = window(1)
        let small = window(2, frame: CGRect(x: 100, y: 100, width: 300, height: 200), owner: 200)
        let result = WindowFilter.switchable(
            onScreen: [small, big], all: [], regularApps: [app, 200], spaceCount: { _ in 1 },
            kind: { $0.id == 1 ? .standard : .unusual })
        #expect(result.map(\.id) == [2, 1])
    }

    @Test func backgroundTabIsLeftOutAndAnotherSpaceIsKept() {
        let tab = window(5, title: "Tab", on: false)
        let otherSpace = window(6, title: "Elsewhere", on: false)
        #expect(filter(all: [tab, otherSpace]) { $0 == 5 ? 0 : 1 } == [6])
    }

    @Test func withoutTheSpacesCallOnlyWindowsOnScreenRemain() {
        #expect(filter(onScreen: [window(1)], all: [window(1), window(2, on: false)]) { _ in nil } == [1])
    }

    @Test func otherLayersOwnersAndInvisibleWindowsAreLeftOut() {
        let menu = window(1, layer: 101)
        let agent = window(2, owner: 200)
        let clear = window(3, alpha: 0)
        let tiny = window(4, frame: CGRect(x: 0, y: 0, width: 40, height: 400))
        #expect(filter(onScreen: [menu, agent, clear, tiny]) == [])
    }
}

@Suite struct AppsWithoutWindowsTests {
    @Test func finderGetsNoTileWithoutAWindow() {
        #expect(!WindowFilter.getsTileWithoutWindows(bundleID: "com.apple.finder"))
    }

    @Test func finderIsNotAskedToQuit() {
        #expect(!WindowFilter.canBeQuit(bundleID: "com.apple.finder"))
        #expect(WindowFilter.canBeQuit(bundleID: "com.apple.Safari"))
    }

    @Test func otherAppsStayWithinReach() {
        #expect(WindowFilter.getsTileWithoutWindows(bundleID: "com.apple.Safari"))
        #expect(WindowFilter.getsTileWithoutWindows(bundleID: nil))
    }
}

@Suite struct WindowMatcherTests {
    private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let b = CGRect(x: 40, y: 40, width: 800, height: 600)

    @Test func matchesTitleAndFrame() {
        let candidates = [(title: "A", frame: a), (title: "A", frame: b), (title: "B", frame: a)]
        #expect(WindowMatcher.bestIndex(title: "A", frame: b, among: candidates) == 1)
    }

    @Test func aChangedTitleStillMatchesByFrame() {
        #expect(WindowMatcher.bestIndex(title: "Old", frame: a, among: [(title: "New", frame: a)]) == 0)
    }

    @Test func aMovedWindowStillMatchesByTitle() {
        #expect(WindowMatcher.bestIndex(title: "A", frame: b, among: [(title: "A", frame: a)]) == 0)
    }

    @Test func doesNotGuessBetweenEqualCandidates() {
        let same = [(title: "A", frame: a), (title: "A", frame: a)]
        #expect(WindowMatcher.bestIndex(title: "A", frame: a, among: same) == nil)
    }

    @Test func anEmptyTitleAloneMatchesNothing() {
        #expect(WindowMatcher.bestIndex(title: "", frame: b, among: [(title: "", frame: a)]) == nil)
    }
}
