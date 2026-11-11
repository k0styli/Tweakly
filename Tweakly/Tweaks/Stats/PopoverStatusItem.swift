import AppKit
import SystemMetrics

/// What a popover under a menu bar item shows.
enum StatsPopover: Equatable {
    case details(MetricKind)
    /// The simple view for these metrics.
    case simple([MetricKind], SimpleViewLook)

    func shows(_ kind: MetricKind) -> Bool {
        switch self {
        case .details(let shown): shown == kind
        case .simple(let shown, _): shown.contains(kind)
        }
    }
}

/// A stats menu bar item, which opens its popover through its owner's callbacks.
class PopoverStatusItem: MenuBarPopoverItem {
    /// macOS 27 adds 8 points on each side of an item by itself, and more than that only looks like empty space.
    static var horizontalPadding: CGFloat {
        if #available(macOS 27.0, *) { 0 } else { 5 }
    }

    /// What a click on this item opens.
    var popover: StatsPopover
    private let onOpen: (PopoverStatusItem) -> Void
    private let onToggle: (PopoverStatusItem) -> Void
    private let onDismiss: (PopoverStatusItem) -> Void

    /// False while nobody can see this item: behind the notch, in an auto-hidden menu bar, or under a
    /// full-screen app. Only trusted where it has been checked, because wrongly saying false would freeze
    /// the value, while wrongly saying true only costs a little sampling. That rules out several displays:
    /// each menu bar has its own room, and one window's state cannot speak for the others.
    var isOnScreen: Bool {
        #if TWEAKLY_AUTOMATION
            // A crowded menu bar would otherwise make every measurement read as if nothing were running.
            if UserDefaults.standard.bool(forKey: "ignoreOcclusion") { return true }
        #endif
        guard #available(macOS 27.0, *), NSScreen.screens.count == 1 else { return true }
        return item.button?.window?.occlusionState.contains(.visible) ?? true
    }

    init(
        length: CGFloat,
        autosaveName: String,
        popover: StatsPopover,
        onOpen: @escaping (PopoverStatusItem) -> Void,
        onToggle: @escaping (PopoverStatusItem) -> Void,
        onDismiss: @escaping (PopoverStatusItem) -> Void
    ) {
        self.popover = popover
        self.onOpen = onOpen
        self.onToggle = onToggle
        self.onDismiss = onDismiss
        super.init(length: length, autosaveName: autosaveName)
    }

    override func sessionDidBegin() {
        onOpen(self)
    }

    override func clicked() {
        onToggle(self)
    }

    override func sessionDidEnd() {
        onDismiss(self)
    }
}
