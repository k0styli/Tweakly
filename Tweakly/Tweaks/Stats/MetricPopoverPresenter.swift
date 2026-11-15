import AppKit
import SystemMetrics

/// Shows one popover at a time beneath its menu bar item: one metric's details, or the simple view's rings.
final class MetricPopoverPresenter {
    private let onChange: () -> Void
    private let popover = MenuBarPopover()
    private var lastClosed: (popover: StatsPopover, time: TimeInterval)?
    /// The question before ending an app or a process, while it is up.
    private var endQuestion: EndProcessQuestion?

    private(set) var current: StatsPopover?
    var fanActions: FanQuickActions?

    #if TWEAKLY_AUTOMATION
        var contentView: NSView? { popover.controller?.view }
        /// Milliseconds from the popover's content loading to its first figures, for checking it never shows empty.
        var firstFiguresDelay: Double? { (popover.controller as? MetricDetailViewController)?.firstFiguresDelay }
        var processList: ProcessListView? { (popover.controller as? MetricDetailViewController)?.processList }
    #endif

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Handles a click on systems where the app itself manages the item's open state.
    func toggle(for item: PopoverStatusItem) {
        if current == item.popover {
            close()
            return
        }
        if let lastClosed, lastClosed.popover == item.popover,
            ProcessInfo.processInfo.systemUptime - lastClosed.time < MenuBarPopover.reopenGuard
        {
            return
        }
        show(for: item)
    }

    /// Does nothing if this item's details are already showing. macOS 27 begins an expanded-interface
    /// session by itself as soon as a popover appears under a status item, so this gets called twice.
    func show(for item: PopoverStatusItem) {
        guard current != item.popover else { return }
        close()
        let shown = item.popover
        let controller = MetricDetailViewController(popover: shown, fanActions: fanActions)
        controller.onEndProcess = { [weak self] entry in self?.askToEnd(entry) }
        // Set first: macOS 27 may begin the item's session, and ask for this again, while the popover appears.
        current = shown
        // The controller keeps its preferred size up to date, which the popover follows by itself.
        let didShow = popover.show(
            controller, under: item, setsSizeFirst: false,
            fittingSize: { [weak controller] in controller?.fittingContentSize ?? .zero }
        ) { [weak self] in
            self?.didClose(shown)
        }
        guard didShow else {
            current = nil
            return
        }
        onChange()
    }

    func updateAppearance() {
        popover.updateAppearance()
    }

    /// The system ended the session for this item.
    func dismiss(for item: PopoverStatusItem) {
        if current == item.popover { close() }
    }

    func close() {
        popover.close()
    }

    /// The task manager's question, in a window of its own: the popover closes first, as it would at any click outside
    /// it, and the window stays up however long the person takes to answer.
    private func askToEnd(_ entry: ProcessEntry) {
        close()
        endQuestion?.close()
        let question = EndProcessQuestion(entry: entry) { [weak self] in self?.endQuestion = nil }
        endQuestion = question
        question.show()
    }

    func deliver(_ update: MetricUpdate) {
        (popover.controller as? MetricDetailViewController)?.update(update)
    }

    /// The whole view hierarchy is gone by now, so a closed popover costs nothing to keep around.
    private func didClose(_ shown: StatsPopover) {
        lastClosed = (shown, ProcessInfo.processInfo.systemUptime)
        current = nil
        onChange()
    }
}

/// A real `NSAlert` with the task manager's question about one row of a popover's list. Shown as a window rather than run
/// modally, so the agent's menu bar items go on updating while it is up, as the Finder menu's alert does.
private final class EndProcessQuestion: NSObject {
    private let entry: ProcessEntry
    private let alert: NSAlert
    private let onClose: () -> Void
    private var resignObserver: NSObjectProtocol?

    init(entry: ProcessEntry, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        // A row that can be ended is the person's app, which quits by its own command, or the person's own processes, so
        // nothing of another user's gets a signal from here.
        // loginwindow is the person's own process and an app of its own, and ending it logs them out.
        let logsOut = ["WindowServer", "loginwindow"].contains(entry.name)
        alert = ProcessActions.question(
            name: entry.name, processCount: entry.processCount, logsOut: logsOut, isSystem: false, force: false)
        super.init()
        let actions: [Selector] = [#selector(endTask), #selector(forceQuit), #selector(close)]
        for (button, action) in zip(alert.buttons, actions) {
            button.target = self
            button.action = action
        }
        alert.layout()
        alert.window.appearance = AppSettings.savedTheme.appearance
    }

    func show() {
        // The agent has no Dock icon to find the question by again, so going to another app cancels it, as a click
        // outside the popover would have.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        if QuietScreen.mayActivate { NSApp.activate() }
        alert.window.center()
        #if TWEAKLY_AUTOMATION
            // A test copy keeps it on its own display, out of sight.
            QuietScreen.place(alert.window)
        #endif
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func endTask() {
        ProcessActions.end(entry, force: false)
        close()
    }

    @objc private func forceQuit() {
        ProcessActions.end(entry, force: true)
        close()
    }

    @objc func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        alert.window.orderOut(nil)
        // The agent came forward only for the question: the keyboard goes back to the app the person was using, unless
        // another window of the agent is still up.
        let window = alert.window
        let othersShow = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeKey }
        if NSApp.isActive, !othersShow { NSApp.deactivate() }
        onClose()
    }
}
