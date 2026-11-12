import AppKit
import Carbon
import FinderCutCore
import os

/// Command-X and Command-V for files in Finder, as in Windows.
///
/// Finder already moves files with Option-Command-V after Command-C, so this only changes which keys ask for it. The
/// shortcuts are registered only while Finder is in front, and Command-V and Escape only while a cut is waiting.
/// In any other app they are not this tweak's at all.
final class FinderCutTweak {
    private enum Key {
        static let cut = GlobalHotKeys.Shortcut(keyCode: kVK_ANSI_X, modifiers: cmdKey)
        static let paste = GlobalHotKeys.Shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey)
        static let cancel = GlobalHotKeys.Shortcut(keyCode: kVK_Escape, modifiers: 0)
    }

    private static let copyKey = kVK_ANSI_C
    /// How long Finder gets to put the files on the pasteboard. No event reports that, so it is checked this often,
    /// and only for this moment after Command-X.
    private static let copyCheckInterval: TimeInterval = 0.02
    private static let copyCheckAttempts = 30
    /// Finder reads the pasteboard when it gets the key. A second paste must not copy what was just moved, so the
    /// pasteboard is emptied after this, as Explorer does.
    private static let clearDelay: TimeInterval = 0.6
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "finder-cut")

    private lazy var hotKeys = GlobalHotKeys { [weak self] in self?.pressed($0) }
    private var state = FinderCutState()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityChanges: AccessibilityChanges?
    private var copyCheck: Timer?
    private var copyChecksLeft = 0
    private var changeBeforeCopy = 0
    private var confirmation: CutConfirmation?
    private var showsConfirmation = true

    #if TWEAKLY_AUTOMATION
        private var lastAction = "none"
    #endif

    /// Brings the shortcuts in line with the tweak being on, Accessibility allowed and what is in front.
    func update(showsConfirmation: Bool) {
        self.showsConfirmation = showsConfirmation
        if !showsConfirmation {
            confirmation?.close()
            confirmation = nil
        }
        if observers.isEmpty { observeSystem() }
        applyShortcuts()
    }

    /// Leaves nothing running, so the object can be released.
    func stop() {
        copyCheck?.invalidate()
        copyCheck = nil
        confirmation?.close()
        confirmation = nil
        hotKeys.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        accessibilityChanges = nil
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let activated = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShortcuts() }
        }
        observers.append((workspace, activated))
        // Without Accessibility the keys could not be passed on, and Command-X would stop working in text.
        accessibilityChanges = AccessibilityChanges { [weak self] in self?.applyShortcuts() }
    }

    private var finder: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == FinderCommands.bundleID
        else { return nil }
        return app
    }

    private var pasteboardChange: Int { NSPasteboard.general.changeCount }

    private func applyShortcuts() {
        let isActive = finder != nil && AXIsProcessTrusted()
        hotKeys.set(Key.cut, enabled: isActive)
        // Runs on every switch of apps, and asking the pasteboard is a round trip to its server.
        guard isActive else {
            hotKeys.set(Key.paste, enabled: false)
            hotKeys.set(Key.cancel, enabled: false)
            return
        }
        let change = pasteboardChange
        hotKeys.set(Key.paste, enabled: state.holdsPaste(change: change))
        hotKeys.set(Key.cancel, enabled: state.isPending(change: change))
    }

    private func pressed(_ shortcut: GlobalHotKeys.Shortcut) {
        guard let pid = finder?.processIdentifier else {
            applyShortcuts()
            return
        }
        guard AXIsProcessTrusted() else {
            Self.log.notice("Accessibility access is gone, so handing the keys back to Finder")
            applyShortcuts()
            return
        }
        switch shortcut {
        case Key.cut: cutPressed(pid: pid)
        case Key.paste: pastePressed(pid: pid)
        default: cancelPressed(pid: pid)
        }
    }

    private func cutPressed(pid: pid_t) {
        FinderCommands.readFocus(pid: pid) { [weak self] focus, owner in
            guard let self else { return }
            switch self.state.actionForCut(focus: focus) {
            case .forward:
                FinderCommands.pressKey(kVK_ANSI_X, flags: .maskCommand, pid: owner)
                self.note("forwarded cut")
            case .copyFiles:
                self.copyFiles(pid: pid)
            }
        }
    }

    private func copyFiles(pid: pid_t) {
        changeBeforeCopy = pasteboardChange
        copyChecksLeft = Self.copyCheckAttempts
        FinderCommands.pressKey(Self.copyKey, flags: .maskCommand, pid: pid)
        copyCheck?.invalidate()
        copyCheck = Timer.scheduledTimer(withTimeInterval: Self.copyCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCopy() }
        }
        copyCheck?.tolerance = Self.copyCheckInterval / 4
    }

    private func checkCopy() {
        copyChecksLeft -= 1
        if pasteboardChange != changeBeforeCopy {
            copyCheck?.invalidate()
            copyCheck = nil
            filesMayHaveBeenCopied()
        } else if copyChecksLeft <= 0 {
            // Nothing was selected. Finder has said so with its own beep.
            copyCheck?.invalidate()
            copyCheck = nil
            note("nothing to cut")
        }
    }

    private func filesMayHaveBeenCopied() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        guard !files.isEmpty else {
            note("copied, but no files")
            return
        }
        state.filesCopied(change: pasteboard.changeCount)
        applyShortcuts()
        note("cut \(files.count)")
        confirm(String(localized: "Cut: \(files.count)"), symbol: "scissors")
    }

    private func pastePressed(pid: pid_t) {
        FinderCommands.readFocus(pid: pid) { [weak self] focus, owner in
            guard let self else { return }
            let change = self.pasteboardChange
            switch self.state.actionForPaste(focus: focus, change: change) {
            case .forward:
                FinderCommands.pressKey(kVK_ANSI_V, flags: .maskCommand, pid: owner)
                self.note("forwarded paste")
            case .moveFiles:
                FinderCommands.pressKey(kVK_ANSI_V, flags: [.maskCommand, .maskAlternate], pid: pid)
                self.emptyPasteboard(ifStill: change, after: Self.clearDelay)
                self.note("moved")
            case .ignore:
                self.note("ignored a repeated paste")
            }
            self.applyShortcuts()
        }
    }

    private func cancelPressed(pid: pid_t) {
        FinderCommands.readEscape(pid: pid) { [weak self] focus, owner, aboutFiles in
            guard let self else { return }
            // Escape still means what it means there, such as leaving a name being edited or closing Quick Look.
            FinderCommands.pressKey(kVK_Escape, flags: [], pid: owner)
            // Closing Quick Look or a menu leaves the cut waiting, as it is not about the files.
            guard aboutFiles else {
                self.applyShortcuts()
                return
            }
            let change = self.pasteboardChange
            if self.state.cancel(focus: focus, change: change) {
                self.emptyPasteboard(ifStill: change, after: 0)
                self.note("cancelled")
                self.confirm(String(localized: "Cut canceled"), symbol: "xmark")
            }
            self.applyShortcuts()
        }
    }

    private func emptyPasteboard(ifStill change: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                let pasteboard = NSPasteboard.general
                if pasteboard.changeCount == change { pasteboard.clearContents() }
                self?.state.finishedMoving()
                self?.applyShortcuts()
            }
        }
    }

    private func confirm(_ text: String, symbol: String) {
        guard showsConfirmation else { return }
        if confirmation == nil { confirmation = CutConfirmation() }
        confirmation?.show(text, symbol: symbol)
    }

    private func note(_ action: String) {
        #if TWEAKLY_AUTOMATION
            lastAction = action
        #endif
    }

    #if TWEAKLY_AUTOMATION
        var automationDescription: String {
            let object: [String: Any] = [
                "finderInFront": finder != nil, "pending": state.isPending(change: pasteboardChange),
                "lastAction": lastAction,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    #endif
}
