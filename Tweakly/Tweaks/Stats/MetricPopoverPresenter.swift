import AppKit
import SystemMetrics

/// Shows one popover at a time beneath its menu bar item: one metric's details, or the simple view's rings.
final class MetricPopoverPresenter {
    private let onChange: () -> Void
    private let popover = MenuBarPopover()
    private var lastClosed: (popover: StatsPopover, time: TimeInterval)?

    private(set) var current: StatsPopover?
    var fanActions: FanQuickActions?

    #if TWEAKLY_AUTOMATION
        var contentView: NSView? { popover.controller?.view }
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
