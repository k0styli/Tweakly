import AppKit
import SystemMetrics

/// Finds the icon for a process. Lives only as long as the popover, so icons leave memory when it closes.
private final class ProcessIconProvider {
    private static let size = NSSize(width: 16, height: 16)
    private var icons: [String: NSImage] = [:]

    /// A helper shows the icon of the app it belongs to. Anything without an app gets the placeholder.
    func icon(for entry: ProcessEntry) -> NSImage {
        guard let path = entry.appBundlePath else { return ProcessPlaceholderIcon.image }
        if let known = icons[path] { return known }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = Self.size
        icons[path] = icon
        return icon
    }

}

/// A small rounded tile with a gear, for system daemons and command line tools, in the popovers and the task manager. It
/// draws on demand, so it follows light and dark mode.
enum ProcessPlaceholderIcon {
    private static let size = NSSize(width: 16, height: 16)

    static let image = NSImage(size: size, flipped: false) { rect in
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.tertiaryLabelColor.setFill()
        tile.fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard
            let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return true }
        let origin = NSPoint(x: rect.midX - gear.size.width / 2, y: rect.midY - gear.size.height / 2)
        gear.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
}

/// Stands in for a row until its first values arrive, in the shape the real content will take.
private final class ProcessRowPlaceholder: NSView {
    private static let barHeight: CGFloat = 9
    private static let nameOffset: CGFloat = 23
    private static let valueWidth: CGFloat = 36

    private let nameWidth: CGFloat

    init(nameWidth: CGFloat) {
        self.nameWidth = nameWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        let icon = NSRect(x: 0, y: bounds.midY - 8, width: 16, height: 16)
        NSBezierPath(roundedRect: icon, xRadius: 4, yRadius: 4).fill()
        fillBar(x: Self.nameOffset, width: nameWidth)
        fillBar(x: bounds.maxX - Self.valueWidth, width: Self.valueWidth)
    }

    private func fillBar(x: CGFloat, width: CGFloat) {
        let rect = NSRect(x: x, y: bounds.midY - Self.barHeight / 2, width: width, height: Self.barHeight)
        NSBezierPath(roundedRect: rect, xRadius: Self.barHeight / 2, yRadius: Self.barHeight / 2).fill()
    }
}

/// One app with everything that works for it, or one process on its own. While the pointer is on a row the person can
/// end, a button for that appears at its end and the figures make room for it, as the clear button of a notification
/// appears only under the pointer, so the list stays as quiet as the rest of the popover.
private final class ProcessRow: NSView {
    private static let iconSize: CGFloat = 16
    private static let endButtonSize: CGFloat = 16
    private static let endButtonSpacing: CGFloat = 6
    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private let placeholder: ProcessRowPlaceholder
    private let iconView = NSImageView()
    private let nameLabel = NSTextField.detailLabel()
    private let valueLabel = NSTextField.detailLabel(
        font: ProcessListView.valueFont,
        alignment: .right
    )
    private let secondLabel = NSTextField.detailLabel(
        font: ProcessListView.valueFont,
        alignment: .right
    )
    private let divider = RowDivider()
    private let endButton = NSButton()
    /// Where the figures end: at the row's edge, or before the button while it shows.
    private var figuresTrailing: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isEndButtonShown = false
    private var hasEndAction = false
    private var entry: ProcessEntry?
    private var shownName = ""
    private var shownCount = 0

    var onEnd: ((ProcessEntry) -> Void)?

    init(placeholderNameWidth: CGFloat, columns: ProcessListView.Columns?) {
        placeholder = ProcessRowPlaceholder(nameWidth: placeholderNameWidth)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // The name beside it says which process it is; VoiceOver would only say "image" first.
        iconView.setAccessibilityElement(false)
        setUpEndButton()
        [placeholder, iconView, nameLabel, valueLabel, endButton].forEach(addSubview)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 19),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            valueLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            endButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            endButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            endButton.widthAnchor.constraint(equalToConstant: Self.endButtonSize),
            endButton.heightAnchor.constraint(equalToConstant: Self.endButtonSize),
        ])
        if let columns {
            [divider, secondLabel].forEach(addSubview)
            divider.isHidden = true
            let trailing = secondLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
            figuresTrailing = trailing
            NSLayoutConstraint.activate([
                trailing,
                secondLabel.widthAnchor.constraint(equalToConstant: columns.width),
                secondLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
                divider.trailingAnchor.constraint(
                    equalTo: secondLabel.leadingAnchor, constant: -ProcessListView.columnSpacing),
                divider.centerYAnchor.constraint(equalTo: centerYAnchor),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 11),
                valueLabel.trailingAnchor.constraint(
                    equalTo: divider.leadingAnchor, constant: -ProcessListView.columnSpacing),
                valueLabel.widthAnchor.constraint(equalToConstant: columns.width),
            ])
        } else {
            let trailing = valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
            figuresTrailing = trailing
            trailing.isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The task manager's End Task, as a plain symbol in the quiet grey of the figures beside it.
    private func setUpEndButton() {
        let title = String(localized: "End Task")
        endButton.translatesAutoresizingMaskIntoConstraints = false
        endButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        endButton.imagePosition = .imageOnly
        endButton.isBordered = false
        endButton.contentTintColor = .tertiaryLabelColor
        endButton.toolTip = title
        endButton.target = self
        endButton.action = #selector(endClicked)
        endButton.isHidden = true
        endButton.alphaValue = 0
    }

    /// The source of this list has failed or gone away, which placeholders would hide for good.
    func showUnavailable(_ text: String) {
        entry = nil
        placeholder.isHidden = true
        iconView.image = nil
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.stringValue = text
        shownName = ""
        shownCount = 0
        valueLabel.setIfChanged("")
        secondLabel.setIfChanged("")
        divider.isHidden = true
        updateEnding()
    }

    func show(_ entry: ProcessEntry?, value: String, second: String?, icon: NSImage?) {
        self.entry = entry
        placeholder.isHidden = true
        setName(entry?.name ?? "", count: entry?.processCount ?? 1)
        valueLabel.setIfChanged(value)
        if let second {
            divider.isHidden = false
            secondLabel.setIfChanged(second)
        }
        if iconView.image !== icon { iconView.image = icon }
        updateEnding()
    }

    /// The number of processes after the name, quieter than it, as the task manager shows it.
    private func setName(_ name: String, count: Int) {
        guard name != shownName || count != shownCount else { return }
        shownName = name
        shownCount = count
        let font = nameLabel.font ?? .systemFont(ofSize: 12)
        let text = NSMutableAttributedString(
            string: name, attributes: [.foregroundColor: NSColor.labelColor, .font: font])
        if count > 1 {
            text.append(
                NSAttributedString(
                    string: " (\(count))", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]))
        }
        // An attributed string brings its own paragraph style, which would otherwise cut a long name off mid-letter.
        text.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: text.length))
        nameLabel.attributedStringValue = text
    }

    // MARK: Ending

    private var canEnd: Bool { entry?.canEnd == true && onEnd != nil }

    /// The button follows the pointer, and VoiceOver, which has no pointer to follow, gets the same as an action. The
    /// action asks the row for its entry when used, so it is made only when the row starts or stops being one to end.
    private func updateEnding() {
        if canEnd != hasEndAction {
            hasEndAction = canEnd
            let action = NSAccessibilityCustomAction(name: String(localized: "End Task")) { [weak self] in
                self?.endClicked()
                return true
            }
            nameLabel.setAccessibilityCustomActions(canEnd ? [action] : [])
        }
        setEndButtonShown(isPointerInside && canEnd)
    }

    private func setEndButtonShown(_ shown: Bool) {
        guard shown != isEndButtonShown, let figuresTrailing else { return }
        isEndButtonShown = shown
        let offset = shown ? -(Self.endButtonSize + Self.endButtonSpacing) : 0
        if shown { endButton.isHidden = false }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else {
            figuresTrailing.constant = offset
            endButton.alphaValue = shown ? 1 : 0
            endButton.isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            figuresTrailing.animator().constant = offset
            endButton.animator().alphaValue = shown ? 1 : 0
            layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            // The pointer may have come back meanwhile, and a button nobody sees must not take a click.
            MainActor.assumeIsolated {
                guard let self, !self.isEndButtonShown else { return }
                self.endButton.isHidden = true
            }
        }
    }

    #if TWEAKLY_AUTOMATION
        /// The pointer coming onto the row or leaving it, which a test on a display nobody sees cannot move there.
        func pretendPointer(inside: Bool) {
            isPointerInside = inside
            setEndButtonShown(inside && canEnd)
        }

        func pressEnd() {
            endButton.performClick(nil)
        }
    #endif

    @objc private func endClicked() {
        guard let entry, entry.canEnd else { return }
        onEnd?(entry)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return }
        // Always, as the popover's app is not the active one.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        setEndButtonShown(canEnd)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        setEndButtonShown(false)
    }
}

/// The apps and processes using the most of something, each app with its helpers added up as the task manager shows it.
/// Every row exists from the start and shows a placeholder, so the popover keeps its size and never looks empty while
/// the first figures arrive.
final class ProcessListView: NSStackView {
    /// Two values for each process, in fixed columns so the divider between them lines up across rows.
    struct Columns {
        let width: CGFloat

        /// - Parameter widest: The longest value to expect in a column.
        init(widest: String) {
            width = NSTextField.detailLabel(font: ProcessListView.valueFont).requiredWidth(for: widest)
        }

        /// Rates up to the gigabytes a second, as the disk and the network lists show.
        static let rates = Columns(widest: Format.rate(932_000_000))
    }

    fileprivate static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let columnSpacing: CGFloat = 8
    /// Uneven on purpose: identical bars would read as a table of blanks rather than names to come.
    private static let placeholderNameWidths: [CGFloat] = [118, 148, 96, 132, 108]

    /// About this many seconds of an empty list means it is not going to fill.
    private static let patience = 8

    private let rows: [ProcessRow]
    private let icons = ProcessIconProvider()
    private var emptyUpdates = 0
    private var shownEntries: [ProcessEntry] = []

    #if TWEAKLY_AUTOMATION
        func pretendPointer(onRow index: Int) {
            for (rowIndex, row) in rows.enumerated() { row.pretendPointer(inside: rowIndex == index) }
        }

        func pressEnd(onRow index: Int) {
            guard rows.indices.contains(index) else { return }
            rows[index].pressEnd()
        }

        /// One line a row: its name, how many processes it adds up, its main process and whether it can be ended.
        var rowsDescription: String {
            shownEntries.enumerated().map { index, entry in
                "\(index)\t\(entry.name)\t\(entry.processCount)\t\(entry.pid)\t\(entry.canEnd)"
            }.joined(separator: "\n") + "\n"
        }
    #endif

    /// Asks to end a row's app or process. Without it, no row offers to.
    var onEnd: ((ProcessEntry) -> Void)? {
        didSet { rows.forEach { $0.onEnd = onEnd } }
    }

    init(columns: Columns? = nil) {
        rows = ProcessListView.placeholderNameWidths.map { ProcessRow(placeholderNameWidth: $0, columns: columns) }
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: 2)
        rows.forEach(addFullWidth)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(
        _ entries: [ProcessEntry], value: (ProcessEntry) -> String, second: ((ProcessEntry) -> String)? = nil
    ) {
        // Nothing to show yet means the first figures are still on their way, at least for a while.
        guard !entries.isEmpty else {
            emptyUpdates += 1
            if emptyUpdates == Self.patience {
                for (index, row) in rows.enumerated() { row.isHidden = index > 0 }
                rows.first?.showUnavailable(String(localized: "No data"))
                // The rows no longer show it, so the same list coming back has to count as new.
                shownEntries = []
            }
            return
        }
        emptyUpdates = 0
        // The list is worked out every two seconds and arrives every second.
        guard entries != shownEntries else { return }
        shownEntries = entries
        for (index, row) in rows.enumerated() {
            row.isHidden = false
            if index < entries.count {
                let entry = entries[index]
                row.show(entry, value: value(entry), second: second?(entry), icon: icons.icon(for: entry))
            } else {
                row.show(nil, value: "", second: second == nil ? nil : "", icon: nil)
            }
        }
    }
}

/// A column of plain name and value rows that appear as needed, such as mounted volumes.
final class NameValueList: NSStackView {
    private var rows: [DetailRow] = []

    init() {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.rowSpacing)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ entries: [(name: String, value: String)]) {
        while rows.count < entries.count {
            let row = DetailRow("")
            rows.append(row)
            addFullWidth(row)
        }
        for (index, row) in rows.enumerated() {
            if index < entries.count {
                row.setTitle(entries[index].name)
                row.set(entries[index].value)
            } else {
                row.set(nil)
            }
        }
    }
}
