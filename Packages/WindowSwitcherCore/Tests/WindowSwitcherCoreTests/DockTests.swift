import CoreGraphics
import Testing

@testable import WindowSwitcherCore

@Suite struct DockHoverTests {
    private let safari: Int32 = 10
    private let mail: Int32 = 20

    private func showing(_ app: Int32) -> DockHover {
        var hover = DockHover()
        _ = hover.pointerOnDock(app: app, onIcon: true)
        _ = hover.showTimerFired()
        return hover
    }

    @Test func anIconWaitsForTheDelayBeforeShowing() {
        var hover = DockHover()
        #expect(hover.pointerOnDock(app: safari, onIcon: true) == [.startShowTimer])
        #expect(hover.shown == nil)
        #expect(hover.showTimerFired() == [.show(safari)])
        #expect(hover.shown == safari)
    }

    @Test func passingOverAnIconOnTheWayShowsNothing() {
        var hover = DockHover()
        _ = hover.pointerOnDock(app: safari, onIcon: true)
        _ = hover.pointerOnDock(app: mail, onIcon: true)
        _ = hover.pointerOnDock(app: nil, onIcon: false)
        #expect(hover.showTimerFired().isEmpty)
        #expect(hover.shown == nil)
    }

    @Test func theTimerShowsOnlyTheAppStillUnderThePointer() {
        var hover = DockHover()
        _ = hover.pointerOnDock(app: safari, onIcon: true)
        _ = hover.pointerOnDock(app: mail, onIcon: true)
        #expect(hover.showTimerFired() == [.show(mail)])
    }

    @Test func movingAlongTheDockWithAPanelUpSwitchesAtOnce() {
        var hover = showing(safari)
        #expect(hover.pointerOnDock(app: mail, onIcon: true) == [.stopShowTimer, .stopHideTimer, .show(mail)])
        #expect(hover.shown == mail)
    }

    @Test func leavingTheDockGivesThePointerTimeToReachThePanel() {
        var hover = showing(safari)
        #expect(hover.pointerOnDock(app: nil, onIcon: false) == [.stopShowTimer, .startHideTimer])
        #expect(hover.pointerInPanel(true) == [.stopHideTimer])
        #expect(hover.hideTimerFired().isEmpty)
        #expect(hover.shown == safari)
    }

    @Test func thePanelGoesOnceThePointerIsInNeither() {
        var hover = showing(safari)
        _ = hover.pointerOnDock(app: nil, onIcon: false)
        #expect(hover.hideTimerFired() == [.hide])
        #expect(hover.shown == nil)
    }

    @Test func leavingThePanelBackToItsIconKeepsIt() {
        var hover = showing(safari)
        _ = hover.pointerOnDock(app: nil, onIcon: false)
        _ = hover.pointerInPanel(true)
        _ = hover.pointerOnDock(app: safari, onIcon: true)
        #expect(hover.pointerInPanel(false).isEmpty)
        #expect(hover.hideTimerFired().isEmpty)
        #expect(hover.shown == safari)
    }

    @Test func leavingThePanelForTheDesktopHidesIt() {
        var hover = showing(safari)
        _ = hover.pointerOnDock(app: nil, onIcon: false)
        _ = hover.pointerInPanel(true)
        #expect(hover.pointerInPanel(false) == [.startHideTimer])
        #expect(hover.hideTimerFired() == [.hide])
    }

    @Test func returningToTheIconInTimeKeepsThePanel() {
        var hover = showing(safari)
        _ = hover.pointerOnDock(app: nil, onIcon: false)
        #expect(hover.pointerOnDock(app: safari, onIcon: true) == [.stopShowTimer, .stopHideTimer])
        #expect(hover.hideTimerFired().isEmpty)
    }

    @Test func anIconOtherThanARunningAppHidesThePanelAtOnce() {
        var hover = showing(safari)
        // The Dock shows that icon's name straight away, so the panel must not still be fading over it.
        #expect(hover.pointerOnDock(app: nil, onIcon: true) == [.stopShowTimer, .stopHideTimer, .hide])
        #expect(hover.shown == nil)
        #expect(hover.pointerOnDock(app: mail, onIcon: true) == [.startShowTimer])
    }

    @Test func dismissingHidesAndForgetsWhatWasWaiting() {
        var hover = showing(safari)
        #expect(hover.dismiss() == [.stopShowTimer, .stopHideTimer, .hide])
        #expect(hover.shown == nil)
        var waiting = DockHover()
        _ = waiting.pointerOnDock(app: mail, onIcon: true)
        #expect(waiting.dismiss() == [.stopShowTimer, .stopHideTimer])
        #expect(waiting.showTimerFired().isEmpty)
    }

    @Test func anAppWithNothingToShowWaitsForTheDelayAgainNextTime() {
        var hover = showing(safari)
        hover.nothingToShow()
        #expect(hover.pointerOnDock(app: mail, onIcon: true) == [.startShowTimer])
    }
}

@Suite struct DockClickTests {
    @Test func aShortStillPressIsAClick() {
        #expect(DockClick.isClick(from: .zero, to: CGPoint(x: 3, y: 3), after: 0.2))
        #expect(!DockClick.isClick(from: .zero, to: CGPoint(x: 6, y: 0), after: 0.2))
        #expect(!DockClick.isClick(from: .zero, to: .zero, after: 0.8))
        #expect(!DockClick.isClick(from: .zero, to: .zero, after: -1))
    }

    @Test func onlyTheAppInFrontWithAWindowInSightIsPutAway() {
        #expect(DockClick.action(.minimize, appWasFrontmost: true, hasWindowsInSight: true) == .minimize)
        #expect(DockClick.action(.hide, appWasFrontmost: true, hasWindowsInSight: true) == .hide)
        #expect(DockClick.action(.minimize, appWasFrontmost: false, hasWindowsInSight: true) == .nothing)
        #expect(DockClick.action(.minimize, appWasFrontmost: true, hasWindowsInSight: false) == .nothing)
        #expect(DockClick.action(.nothing, appWasFrontmost: true, hasWindowsInSight: true) == .nothing)
    }
}

@Suite struct DockGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let visible = CGRect(x: 0, y: 94, width: 1470, height: 829)

    @Test func theEdgeComesFromTheShapeAndSideOfTheDock() {
        #expect(DockGeometry.edge(ofDock: CGRect(x: 168, y: 10, width: 1134, height: 84), on: screen) == .bottom)
        #expect(DockGeometry.edge(ofDock: CGRect(x: 0, y: 200, width: 84, height: 600), on: screen) == .left)
        #expect(DockGeometry.edge(ofDock: CGRect(x: 1386, y: 200, width: 84, height: 600), on: screen) == .right)
    }

    @Test func aBottomPanelSitsWhereTheDockShowsTheNameCentredOnTheIcon() {
        let icon = CGRect(x: 380, y: 5, width: 68, height: 84)
        let origin = DockGeometry.panelOrigin(
            size: CGSize(width: 300, height: 160), icon: icon, edge: .bottom, visible: visible)
        // Measured: the Dock's name bubble ends 9 pt above the icon's frame.
        #expect(origin == CGPoint(x: 264, y: 98))
    }

    @Test func theDropPointsAtTheIconButStaysOutOfTheCorners() {
        let panel = CGRect(x: 8, y: 98, width: 700, height: 160)
        let middle = CGRect(x: 300, y: 5, width: 68, height: 84)
        #expect(DockGeometry.tailOffset(icon: middle, panel: panel, edge: .bottom, cornerRadius: 32) == 326)
        let first = CGRect(x: 0, y: 5, width: 20, height: 84)
        #expect(DockGeometry.tailOffset(icon: first, panel: panel, edge: .bottom, cornerRadius: 32) == 32)
        let beyond = CGRect(x: 900, y: 5, width: 68, height: 84)
        #expect(DockGeometry.tailOffset(icon: beyond, panel: panel, edge: .bottom, cornerRadius: 32) == 668)
    }

    @Test func aPanelNearTheEndOfTheDockStaysOnTheScreen() {
        let dock = CGRect(x: 168, y: 10, width: 1134, height: 84)
        let first = CGRect(x: 176, y: 5, width: 68, height: 84)
        let last = CGRect(x: 1226, y: 5, width: 68, height: 84)
        let size = CGSize(width: 700, height: 160)
        #expect(DockGeometry.panelOrigin(size: size, icon: first, edge: .bottom, visible: visible).x == 8)
        // The screen's width, less the margin and the panel.
        let lastX = DockGeometry.panelOrigin(size: size, icon: last, edge: .bottom, visible: visible).x
        #expect(lastX == 762)
    }

    @Test func aSidePanelSitsBesideTheDock() {
        let left = CGRect(x: 0, y: 200, width: 84, height: 600)
        let icon = CGRect(x: 8, y: 500, width: 68, height: 68)
        let size = CGSize(width: 300, height: 200)
        let fullHeight = CGRect(x: 84, y: 0, width: 1386, height: 923)
        let origin = DockGeometry.panelOrigin(size: size, icon: icon, edge: .left, visible: fullHeight)
        #expect(origin == CGPoint(x: 85, y: 434))
        let right = CGRect(x: 1386, y: 200, width: 84, height: 600)
        let rightOrigin = DockGeometry.panelOrigin(
            size: size, icon: icon.offsetBy(dx: 1378, dy: 0), edge: .right, visible: fullHeight)
        // The icon's left side, less the gap and the panel.
        #expect(rightOrigin.x == 1077)
    }

    @Test func aPanelLargerThanTheRoomKeepsItsNearSide() {
        let dock = CGRect(x: 168, y: 10, width: 1134, height: 84)
        let icon = CGRect(x: 700, y: 5, width: 68, height: 84)
        let origin = DockGeometry.panelOrigin(
            size: CGSize(width: 2000, height: 160), icon: icon, edge: .bottom, visible: visible)
        #expect(origin.x == 8)
    }

    @Test func tuningKeepsEveryValueOnAChoice() {
        var tuning = DockTuning()
        tuning.delayMilliseconds = 333
        tuning.largestTileHeight = Int.max
        let validated = tuning.validated
        #expect(validated.delayMilliseconds == 400)
        #expect(DockTuning().delayMilliseconds == 0)
        #expect(validated.largestTileHeight == 160)
        #expect(DockTuning().layoutMetrics.cornerRadius - DockTuning().layoutMetrics.padding == 20)
    }
}
