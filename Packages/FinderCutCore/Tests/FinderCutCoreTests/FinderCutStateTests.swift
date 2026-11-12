import Testing

@testable import FinderCutCore

@Suite struct FinderFocusTests {
    @Test func textPlacesAreText() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(FinderFocus(role: role) == .text)
        }
    }

    @Test func fileViewsAreFiles() {
        for role in ["AXOutline", "AXList", "AXBrowser", "AXScrollArea", "AXGroup", "AXTable"] {
            #expect(FinderFocus(role: role) == .files)
        }
    }

    @Test func nothingNamedCountsAsFiles() {
        #expect(FinderFocus(role: nil) == .files)
    }
}

@Suite struct FinderCutStateTests {
    @Test func cuttingInTextIsLeftToTheText() {
        #expect(FinderCutState().actionForCut(focus: .text) == .forward)
    }

    @Test func cuttingFilesCopiesThem() {
        #expect(FinderCutState().actionForCut(focus: .files) == .copyFiles)
    }

    @Test func nothingIsPendingUntilFilesWereCopied() {
        var state = FinderCutState()
        #expect(!state.isPending(change: 5))
        #expect(state.actionForPaste(focus: .files, change: 5) == .forward)
        state.filesCopied(change: 5)
        #expect(state.isPending(change: 5))
    }

    @Test func pastingAfterACutMoves() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        #expect(state.actionForPaste(focus: .files, change: 5) == .moveFiles)
    }

    @Test func aSecondPasteDoesNotMoveAgain() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        _ = state.actionForPaste(focus: .files, change: 5)
        state.finishedMoving()
        #expect(state.actionForPaste(focus: .files, change: 5) == .forward)
        #expect(!state.isPending(change: 5))
    }

    /// A press held a moment too long repeats. To Finder that is a paste of files already moved, which it duplicates.
    @Test func thePressThatMovedThemIsIgnoredUntilThePasteboardIsEmpty() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        #expect(state.actionForPaste(focus: .files, change: 5) == .moveFiles)
        #expect(state.holdsPaste(change: 5))
        #expect(!state.isPending(change: 5))
        #expect(state.actionForPaste(focus: .files, change: 5) == .ignore)
        state.finishedMoving()
        #expect(!state.holdsPaste(change: 5))
    }

    @Test func somethingCopiedRightAfterTheMoveIsAnOrdinaryPaste() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        _ = state.actionForPaste(focus: .files, change: 5)
        #expect(state.actionForPaste(focus: .files, change: 6) == .forward)
    }

    @Test func copyingSomethingElseTurnsItIntoAnOrdinaryPaste() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        #expect(!state.isPending(change: 6))
        #expect(state.actionForPaste(focus: .files, change: 6) == .forward)
        #expect(!state.isPending(change: 5))
    }

    @Test func pastingIntoTextLeavesTheCutWaiting() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        #expect(state.actionForPaste(focus: .text, change: 5) == .forward)
        #expect(state.isPending(change: 5))
        #expect(state.actionForPaste(focus: .files, change: 5) == .moveFiles)
    }

    @Test func cancellingReportsWhetherThereWasACut() {
        var state = FinderCutState()
        let withNothing = state.cancel(focus: .files, change: 5)
        #expect(!withNothing)
        state.filesCopied(change: 5)
        let withACut = state.cancel(focus: .files, change: 5)
        #expect(withACut)
        #expect(!state.isPending(change: 5))
        #expect(state.actionForPaste(focus: .files, change: 5) == .forward)
    }

    @Test func cancellingAfterSomethingElseWasCopiedCancelsNothing() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        let cancelled = state.cancel(focus: .files, change: 6)
        #expect(!cancelled)
    }

    /// Escape there only leaves the name being edited, or a panel over Finder.
    @Test func escapeInTextLeavesTheCutWaiting() {
        var state = FinderCutState()
        state.filesCopied(change: 5)
        let cancelled = state.cancel(focus: .text, change: 5)
        #expect(!cancelled)
        #expect(state.isPending(change: 5))
    }
}

@Suite struct FinderEscapeTests {
    @Test func inAWindowOfFilesEscapeCancels() {
        #expect(FinderEscape.isAboutFiles(focusRole: "AXOutline", windowSubrole: "AXStandardWindow"))
    }

    @Test func onTheDesktopEscapeCancels() {
        // Finder with only the desktop has no focused window.
        #expect(FinderEscape.isAboutFiles(focusRole: "AXGroup", windowSubrole: nil))
    }

    @Test func quickLookAndOtherPanelsOnlyClose() {
        #expect(!FinderEscape.isAboutFiles(focusRole: "AXGroup", windowSubrole: "AXQuickLookPreviewPanel"))
        #expect(!FinderEscape.isAboutFiles(focusRole: "AXButton", windowSubrole: "AXDialog"))
        #expect(!FinderEscape.isAboutFiles(focusRole: nil, windowSubrole: "AXFloatingWindow"))
    }

    @Test func anOpenMenuOnlyCloses() {
        #expect(!FinderEscape.isAboutFiles(focusRole: "AXMenu", windowSubrole: "AXStandardWindow"))
        #expect(!FinderEscape.isAboutFiles(focusRole: "AXMenuItem", windowSubrole: nil))
    }
}
