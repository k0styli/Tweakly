import Testing

@testable import WindowSwitcherCore

@Suite struct SwitcherKeyStateTests {
    private let tab: Int64 = 0x30
    private let grave: Int64 = 0x32
    private let escape: Int64 = 0x35
    private let returnKey: Int64 = 0x24
    private let left: Int64 = 0x7B
    private let up: Int64 = 0x7E
    private let q: Int64 = 0x0C
    private let h: Int64 = 0x04
    private let letterA: Int64 = 0x00
    private let command = SwitcherKeyState.Modifiers(command: true)
    private let commandShift = SwitcherKeyState.Modifiers(command: true, shift: true)

    private func started() -> SwitcherKeyState {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: tab, modifiers: command)
        return state
    }

    @Test func commandTabStartsASessionAndIsSwallowed() {
        var state = SwitcherKeyState()
        let decision = state.keyDown(code: tab, modifiers: command)
        #expect(decision == .init(swallow: true, command: .begin(backward: false)))
        #expect(state.isSessionActive)
    }

    @Test func commandShiftTabStartsBackward() {
        var state = SwitcherKeyState()
        #expect(state.keyDown(code: tab, modifiers: commandShift).command == .begin(backward: true))
    }

    @Test func otherShortcutsPassThroughUntouched() {
        var state = SwitcherKeyState()
        #expect(state.keyDown(code: letterA, modifiers: command) == .init(swallow: false))
        #expect(state.keyDown(code: grave, modifiers: command) == .init(swallow: false))
        #expect(!state.isSessionActive)
    }

    @Test func tabWithoutCommandPassesThrough() {
        var state = SwitcherKeyState()
        #expect(state.keyDown(code: tab, modifiers: .init(command: false)) == .init(swallow: false))
    }

    @Test func commandTabWithControlOrOptionIsLeftAlone() {
        var state = SwitcherKeyState()
        #expect(state.keyDown(code: tab, modifiers: .init(command: true, other: true)) == .init(swallow: false))
    }

    @Test func keysDuringASessionMoveTheSelection() {
        var state = started()
        #expect(state.keyDown(code: tab, modifiers: command) == .init(swallow: true, command: .next))
        #expect(state.keyDown(code: tab, modifiers: commandShift).command == .previous)
        #expect(state.keyDown(code: grave, modifiers: command).command == .previous)
        #expect(state.keyDown(code: grave, modifiers: commandShift).command == .next)
        #expect(state.keyDown(code: left, modifiers: command).command == .move(.left))
        #expect(state.keyDown(code: up, modifiers: command).command == .move(.up))
    }

    @Test func quitAndHideAreAskedForDuringASession() {
        var state = started()
        #expect(state.keyDown(code: q, modifiers: command) == .init(swallow: true, command: .quitSelected))
        #expect(state.keyDown(code: h, modifiers: command) == .init(swallow: true, command: .hideSelected))
        #expect(state.isSessionActive)
    }

    @Test func otherKeysDuringASessionAreSwallowedAndDoNothing() {
        var state = started()
        #expect(state.keyDown(code: letterA, modifiers: command) == .init(swallow: true, command: nil))
    }

    @Test func escapeCancelsAndReturnCommits() {
        var state = started()
        #expect(state.keyDown(code: escape, modifiers: command).command == .cancel)
        #expect(!state.isSessionActive)
        state = started()
        #expect(state.keyDown(code: returnKey, modifiers: command).command == .commit)
        #expect(!state.isSessionActive)
    }

    @Test func releasingCommandCommits() {
        var state = started()
        #expect(state.commandChanged(held: false) == .commit)
        #expect(!state.isSessionActive)
    }

    @Test func modifierChangesOutsideASessionDoNothing() {
        var state = SwitcherKeyState()
        #expect(state.commandChanged(held: true) == nil)
        #expect(state.commandChanged(held: false) == nil)
    }

    @Test func holdingCommandDuringASessionDoesNotCommit() {
        var state = started()
        #expect(state.commandChanged(held: true) == nil)
        #expect(state.isSessionActive)
    }

    @Test func aLostCommandReleaseCannotKeepTheKeyboard() {
        var state = started()
        let decision = state.keyDown(code: letterA, modifiers: .init(command: false))
        #expect(decision == .init(swallow: false, command: .commit))
        #expect(!state.isSessionActive)
    }

    @Test func keyUpIsSwallowedOnlyDuringASession() {
        var state = SwitcherKeyState()
        #expect(state.keyUp() == .init(swallow: false))
        state = started()
        #expect(state.keyUp() == .init(swallow: true))
    }

    @Test func aSessionEndedElsewhereLetsTheNextTabStartAnother() {
        var state = started()
        state.endSession()
        #expect(state.keyDown(code: tab, modifiers: command).command == .begin(backward: false))
    }

    @Test func afterASessionEndsOrdinaryKeysPassThroughAgain() {
        var state = started()
        _ = state.keyDown(code: escape, modifiers: command)
        #expect(state.keyDown(code: letterA, modifiers: command) == .init(swallow: false))
    }

    /// Quitting moves the selection on, so a held Q went through the apps one after another.
    @Test func aHeldKeyQuitsOrHidesOnlyOnce() {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: 0x30, modifiers: .init(command: true))
        #expect(state.keyDown(code: 0x0C, modifiers: .init(command: true)).command == .quitSelected)
        let repeated = state.keyDown(code: 0x0C, modifiers: .init(command: true), isRepeat: true)
        #expect(repeated.command == nil)
        #expect(repeated.swallow)
        #expect(state.keyDown(code: 0x0C, modifiers: .init(command: true)).command == .quitSelected)
        #expect(state.keyDown(code: 0x04, modifiers: .init(command: true)).command == .hideSelected)
        #expect(state.keyDown(code: 0x04, modifiers: .init(command: true), isRepeat: true).command == nil)
    }

    @Test func aHeldTabGoesOnMoving() {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: 0x30, modifiers: .init(command: true))
        #expect(state.keyDown(code: 0x30, modifiers: .init(command: true), isRepeat: true).command == .next)
    }

    /// Held a little too long, it would reach the app just chosen as Command-Return, which sends a message in many of them.
    @Test(arguments: [Int64(0x24), 0x4C, 0x35])
    func theKeyThatEndsASessionDoesNotGoOnToTheNextApp(key: Int64) {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: 0x30, modifiers: .init(command: true))
        _ = state.keyDown(code: key, modifiers: .init(command: true))
        #expect(!state.isSessionActive)
        let repeated = state.keyDown(code: key, modifiers: .init(command: true), isRepeat: true)
        #expect(repeated.swallow)
        #expect(repeated.command == nil)
        // A new press is a new press.
        #expect(state.keyDown(code: key, modifiers: .init(command: true)).swallow == false)
    }

    @Test func anotherKeyEndsTheWatchForRepeats() {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: 0x30, modifiers: .init(command: true))
        _ = state.keyDown(code: 0x24, modifiers: .init(command: true))
        #expect(state.keyDown(code: 0x00, modifiers: .init(command: true)).swallow == false)
        #expect(state.keyDown(code: 0x24, modifiers: .init(command: true), isRepeat: true).swallow == false)
    }

    @Test func releasingCommandEndsTheWatchForRepeats() {
        var state = SwitcherKeyState()
        _ = state.keyDown(code: 0x30, modifiers: .init(command: true))
        _ = state.keyDown(code: 0x24, modifiers: .init(command: true))
        _ = state.commandChanged(held: false)
        _ = state.commandChanged(held: true)
        #expect(state.keyDown(code: 0x24, modifiers: .init(command: true), isRepeat: true).swallow == false)
    }
}
