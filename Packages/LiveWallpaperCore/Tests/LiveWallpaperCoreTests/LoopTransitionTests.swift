import Testing

@testable import LiveWallpaperCore

@Suite struct LoopTransitionTests {
    @Test func noneByDefaultTakesNoTime() {
        #expect(LoopTransition.none.length(forVideoOf: 30) == 0)
        #expect(!LoopTransition.none.revealsFirstFrame)
    }

    @Test func aShortLoopIsNotMostlyTransition() {
        #expect(LoopTransition.dissolve.length(forVideoOf: 30) == 1.2)
        #expect(LoopTransition.blur.length(forVideoOf: 3) == 1)
        #expect(LoopTransition.zoom.length(forVideoOf: 0) == 0)
        #expect(LoopTransition.wipe.length(forVideoOf: .nan) == 0)
    }

    /// Fade to Black is darkest at the loop; the others reach the first frame there.
    @Test func eachEndsWhereTheLoopNeedsIt() {
        for transition in LoopTransition.allCases where transition != .none {
            let lead = transition.lead(forLength: 1.4)
            #expect(lead == (transition == .fadeToBlack ? 0.7 : 1.4))
            #expect(transition.revealsFirstFrame == (transition != .fadeToBlack))
        }
    }

    @Test func reduceMotionTurnsMovementIntoADissolve() {
        #expect(LoopTransition.zoom.respectingReducedMotion(true) == .dissolve)
        #expect(LoopTransition.wipe.respectingReducedMotion(true) == .dissolve)
        #expect(LoopTransition.blur.respectingReducedMotion(true) == .blur)
        #expect(LoopTransition.zoom.respectingReducedMotion(false) == .zoom)
    }

    @Test func storedNamesStay() {
        #expect(LoopTransition.allCases.map(\.rawValue) == ["none", "dissolve", "blur", "zoom", "wipe", "fadeToBlack"])
    }
}
