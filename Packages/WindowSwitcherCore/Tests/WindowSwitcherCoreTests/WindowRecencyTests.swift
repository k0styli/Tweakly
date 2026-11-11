import CoreGraphics
import Testing

@testable import WindowSwitcherCore

@Suite struct WindowRecencyTests {
    private let a: Int32 = 1
    private let b: Int32 = 2

    private func window(_ id: UInt32, _ owner: Int32, on: Bool = true) -> WindowRecord {
        WindowRecord(
            id: id, ownerPID: owner, title: "W", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isOnScreen: on)
    }

    private func ids(_ windows: [WindowRecord]) -> [UInt32] { windows.map(\.id) }

    @Test func startsFromTheWindowServersOrder() {
        var recency = WindowRecency()
        let result = recency.order([window(3, a), window(1, b), window(2, a, on: false)], front: 3) { _ in false }
        #expect(ids(result) == [3, 1, 2])
        #expect(recency.recent == [3, 1, 2])
    }

    @Test func goingBackAndForthBetweenAppsSkipsTheirOtherWindows() {
        // Activating an app brings all its windows forward, so window 11 lands right behind 10 and above 20.
        var recency = WindowRecency()
        recency.markUsed(11)
        recency.markUsed(20)
        recency.markUsed(10)
        let result = recency.order([window(10, a), window(11, a), window(20, b)], front: 10) { _ in false }
        #expect(ids(result) == [10, 20, 11])
    }

    @Test func aWindowOnAnotherSpaceKeepsItsPlace() {
        var recency = WindowRecency()
        recency.markUsed(3)
        recency.markUsed(2)
        recency.markUsed(1)
        let result = recency.order([window(1, a), window(3, b), window(2, b, on: false)], front: 1) { _ in false }
        #expect(ids(result) == [1, 2, 3])
    }

    @Test func aClickBetweenWindowsOfOneAppIsPickedUp() {
        // No event reports it, so the window in front says it.
        var recency = WindowRecency()
        recency.markUsed(20)
        recency.markUsed(10)
        let result = recency.order([window(11, a), window(10, a), window(20, b)], front: 11) { _ in false }
        #expect(ids(result)[0] == 11)
        #expect(ids(result)[1] == 10)
    }

    @Test func severalClicksWithinAnAppFollowItsOrder() {
        var recency = WindowRecency()
        for id: UInt32 in [13, 20, 12, 11] { recency.markUsed(id) }
        // Now 13 is in front, then 12, then 11, and 20 of the other app last.
        let result = recency.order([window(13, a), window(12, a), window(11, a), window(20, b)], front: 13) { _ in false
        }
        #expect(ids(result) == [13, 12, 11, 20])
    }

    @Test func aMinimizedWindowGoesLastAndIsNotThePreviousOne() {
        var recency = WindowRecency()
        recency.markUsed(2)
        recency.markUsed(1)
        recency.markUsed(9)
        let minimized = window(9, a, on: false)
        let result = recency.order([window(1, a), window(2, b), minimized], front: 1) { $0.id == 9 }
        #expect(ids(result) == [1, 2, 9])
    }

    @Test func closedWindowsAreForgotten() {
        var recency = WindowRecency()
        recency.markUsed(2)
        recency.markUsed(1)
        _ = recency.order([window(1, a)], front: 1) { _ in false }
        #expect(recency.recent == [1])
    }

    @Test func aNewWindowComesRightBehindWhatIsAboveIt() {
        var recency = WindowRecency()
        recency.markUsed(2)
        recency.markUsed(1)
        let result = recency.order([window(1, a), window(5, b), window(2, b)], front: 1) { _ in false }
        #expect(ids(result) == [1, 5, 2])
    }

    @Test func nothingInFrontKeepsTheOrder() {
        // An app with no window is in front, such as Finder over the desktop.
        var recency = WindowRecency()
        recency.markUsed(2)
        recency.markUsed(1)
        let result = recency.order([window(2, b), window(1, a)], front: nil) { _ in false }
        #expect(ids(result) == [1, 2])
    }

    @Test func aWindowUsedAgainMovesToTheFront() {
        var recency = WindowRecency()
        for id: UInt32 in [1, 2, 3, 1] { recency.markUsed(id) }
        #expect(recency.recent == [1, 3, 2])
    }

    @Test func eachWindowIsAskedOnceWhetherItWasSetAside() {
        var recency = WindowRecency()
        let windows = (1...5).map { WindowRecord(id: $0, ownerPID: 1, title: "", frame: .zero, isOnScreen: false) }
        var asked: [UInt32] = []
        let ordered = recency.order(windows, front: nil) { window in
            asked.append(window.id)
            return window.id == 2
        }
        #expect(asked.sorted() == [1, 2, 3, 4, 5])
        #expect(ordered.last?.id == 2)
    }

    @Test func whatIsRememberedDoesNotGrowWithoutAPress() {
        var recency = WindowRecency()
        for window in 0..<1000 { recency.markUsed(UInt32(window)) }
        #expect(recency.recent.count == 256)
        #expect(recency.recent.first == 999)
    }
}
