import AppKit

/// Cells of the uninstaller's lists, laid out by frame as the task manager's are, and set apart from the column's edges
/// by as much as the column titles above them (`ListHeaderCell.textInset`), so a title and its text start in one line.

/// An icon and a name, as the first column of Finder's list.
final class ListNameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("listName")
    private static let iconSize: CGFloat = 16
    private static let gap: CGFloat = 6

    /// Set for the lists that tick their rows, which have a box before the icon.
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    var showsCheckbox = false {
        didSet { checkbox.isHidden = !showsCheckbox }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        lock.contentTintColor = .secondaryLabelColor
        lock.isHidden = true
        checkbox.isHidden = true
        for view in [checkbox, icon, label, lock] as [NSView] { addSubview(view) }
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    /// - Parameter lockedHelp: when set, a lock after the name says what it means.
    func show(icon image: NSImage, name: String, help: String, lockedHelp: String? = nil) {
        icon.image = image
        if label.stringValue != name { label.stringValue = name }
        toolTip = help
        lock.isHidden = lockedHelp == nil
        lock.toolTip = lockedHelp
        lock.setAccessibilityLabel(lockedHelp)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = ListHeaderCell.textInset
        if showsCheckbox {
            let size = checkbox.fittingSize
            checkbox.frame = NSRect(
                x: x - 2, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height)
            x = checkbox.frame.maxX + 4
        }
        icon.frame = NSRect(
            x: x, y: floor((bounds.height - Self.iconSize) / 2), width: Self.iconSize, height: Self.iconSize)
        x = icon.frame.maxX + Self.gap
        let lockSize = lock.isHidden ? .zero : lock.fittingSize
        let labelHeight = label.fittingSize.height
        let room = max(bounds.width - x - ListHeaderCell.textInset - (lock.isHidden ? 0 : lockSize.width + 4), 0)
        let labelWidth = min(label.fittingSize.width, room)
        label.frame = NSRect(
            x: x, y: floor((bounds.height - labelHeight) / 2), width: labelWidth, height: labelHeight)
        if !lock.isHidden {
            lock.frame = NSRect(
                x: label.frame.maxX + 4, y: floor((bounds.height - lockSize.height) / 2), width: lockSize.width,
                height: lockSize.height)
        }
    }
}

/// A line of text, to the left or, for a figure, to the right with digits of one width.
final class ListTextCell: NSTableCellView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = Self.font
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: String, isSecondary: Bool = false) {
        if label.stringValue != text { label.stringValue = text }
        label.textColor = isSecondary ? .secondaryLabelColor : .labelColor
    }

    override func layout() {
        super.layout()
        let height = label.fittingSize.height
        label.frame = NSRect(
            x: ListHeaderCell.textInset, y: floor((bounds.height - height) / 2),
            width: max(bounds.width - ListHeaderCell.textInset * 2, 0), height: height)
    }
}
