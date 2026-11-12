import AppKit
import SystemMetrics

/// One metric in the menu bar. Opens its details through the owner's callbacks.
final class MetricStatusItem: PopoverStatusItem {
    /// How far a label can reach past its item before the item's window cuts it off.
    static var overflowRoom: CGFloat {
        if #available(macOS 27.0, *) { 8 } else { horizontalPadding }
    }

    let kind: MetricKind
    private let label = StatusLabelView(frame: .zero)
    private var options: StatusLabelOptions
    private var value: MenuValue = .unavailable
    private var history = StatusLabelHistory()
    private var content: StatusLabelContent?

    init(
        kind: MetricKind,
        options: StatusLabelOptions,
        onOpen: @escaping (PopoverStatusItem) -> Void,
        onToggle: @escaping (PopoverStatusItem) -> Void,
        onDismiss: @escaping (PopoverStatusItem) -> Void
    ) {
        self.kind = kind
        self.options = options
        super.init(
            length: NSStatusItem.variableLength, autosaveName: "tweakly.\(kind.rawValue)", popover: .details(kind),
            onOpen: onOpen, onToggle: onToggle, onDismiss: onDismiss)
        if let button = item.button {
            // Constraints rather than a frame, because the button's bounds only settle after the system
            // has placed the item, and an inset of a still empty rectangle would be a null one.
            label.translatesAutoresizingMaskIntoConstraints = false
            label.overflowRoom = Self.overflowRoom
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.horizontalPadding),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.horizontalPadding),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        applyLength()
        refresh()
    }

    func show(_ newValue: MenuValue) {
        if options.style.usesHistory {
            history.record(newValue)
        } else if newValue == value {
            return
        }
        value = newValue
        refresh()
    }

    func setOptions(_ newOptions: StatusLabelOptions) {
        guard newOptions != options else { return }
        options = newOptions
        if !options.style.usesHistory { history = StatusLabelHistory() }
        applyLength()
        refresh()
    }

    /// Starts its chart again from the next reading.
    func forgetHistory() {
        history = StatusLabelHistory()
    }

    /// Low Power Mode changes how the battery looks without changing its charge.
    func powerStateChanged() {
        refresh()
    }

    /// The item keeps one width whatever it shows, so its neighbours never move. A change of `length` goes through
    /// the system's layout of the whole menu bar, at about 300M instructions a time against 0.3M for redrawing a label.
    private func applyLength() {
        let length = Self.length(of: kind, options: options)
        if length != item.length { setLength(length) }
    }

    static func length(of kind: MetricKind, options: StatusLabelOptions) -> CGFloat {
        let reference = StatusLabelContent.make(kind: kind, value: kind.widthReferenceValue, options: options)
        return StatusLabelRenderer.width(of: reference) + horizontalPadding * 2
    }

    private func setLength(_ length: CGFloat) {
        item.length = length
        #if TWEAKLY_AUTOMATION
            lengthChanges += 1
        #endif
    }

    private func refresh() {
        let content = StatusLabelContent.make(
            kind: kind, value: value, options: options, history: history,
            isLowPower: kind == .battery && ProcessInfo.processInfo.isLowPowerModeEnabled)
        let hadSameText = self.content?.accessibilityText == content.accessibilityText
        self.content = content
        label.show(content)
        if !hadSameText { item.button?.setAccessibilityLabel(content.accessibilityText) }
    }

    #if TWEAKLY_AUTOMATION
        private(set) var lengthChanges = 0
        var labelDescription: String { "\(label.automationDescription) lengthChanges=\(lengthChanges)" }
    #endif
}
