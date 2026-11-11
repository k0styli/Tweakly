import AppKit

/// The column titles of Tweakly's lists, the task manager's and the uninstaller's, drawn as Finder's are, so the lists
/// read as one app's.

/// A column title drawn as Finder's are on macOS 26 and 27: no background of its own, so the titles sit on the same
/// colour as the toolbar and the list; a thin divider between columns and none before the first; the sorted column's
/// title in the label colour and semibold with the system's own sort arrow, the others in the secondary colour. A fresh
/// `NSTableHeaderCell` draws the older filled bar instead.
final class ListHeaderCell: NSTableHeaderCell {
    /// The column's sort key, which tells whether the list is sorted by it.
    var key = ""
    private static let dividerInset: CGFloat = 7
    /// As far from the column's edges as the text of the cells below it.
    static let textInset: CGFloat = 7

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let table = (controlView as? NSTableHeaderView)?.tableView
        let sort = table?.sortDescriptors.first
        let isSorted = sort?.key == key
        let isLast = table?.tableColumns.last { !$0.isHidden }?.identifier.rawValue == key
        if !isLast {
            NSColor.separatorColor.setFill()
            NSRect(
                x: cellFrame.maxX - 1, y: cellFrame.minY + Self.dividerInset, width: 1,
                height: max(cellFrame.height - Self.dividerInset * 2, 0)
            ).fill()
        }
        var textFrame = cellFrame.insetBy(dx: Self.textInset, dy: 0)
        if isSorted, let sort {
            let indicator = sortIndicatorRect(forBounds: cellFrame)
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: sort.ascending, priority: 0)
            if alignment == .right {
                textFrame.size.width = max(indicator.minX - 4 - textFrame.minX, 0)
            } else {
                textFrame.size.width = max(min(textFrame.maxX, indicator.minX - 4) - textFrame.minX, 0)
            }
        }
        let size = font?.pointSize ?? NSFont.smallSystemFontSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: isSorted ? .semibold : .regular),
            .foregroundColor: isSorted ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let height = ceil(title.size().height)
        title.draw(
            in: NSRect(
                x: textFrame.minX, y: cellFrame.minY + floor((cellFrame.height - height) / 2), width: textFrame.width,
                height: height))
    }
}

/// The header of a list: only the titles of the columns, so nothing fills the margin before the first one,
/// which the inset style would otherwise draw as an empty title with a divider.
final class ListHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            var rect = headerRect(ofColumn: index)
            // Over the cells below, not the column: the system's lists set the first column's cells 6 pt in and end the
            // last one's 6 pt early, so titles drawn by the column stood that far off the names and figures under them.
            let cell = tableView.frameOfCell(atColumn: index, row: 0)
            if cell.width > 0 {
                rect.origin.x = cell.minX
                rect.size.width = cell.width
            }
            guard rect.intersects(dirtyRect) else { continue }
            column.headerCell.draw(withFrame: rect, in: self)
        }
    }
}

/// The bar behind the toolbar and the column titles, in the material that matched Finder's on macOS 27.2: in dark mode
/// `underWindowBackground`, 51 51 53 against Finder's 51 51 52; in light mode `windowBackground`, white like Finder's,
/// where the other material came out grey.
final class ListHeaderBar: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        matchAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchAppearance()
    }

    private func matchAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let wanted: NSVisualEffectView.Material = isDark ? .underWindowBackground : .windowBackground
        if material != wanted { material = wanted }
    }
}

/// Puts one solid bar behind the toolbar and a list's column titles, with a thin line under it, as Finder's list has on
/// macOS 26 and 27. The list runs under the toolbar, as Finder's does, and rows scrolled up go under the bar. The titles
/// themselves draw no background, see `ListHeaderCell`. Call it from the controller's `viewDidLayout`: the scroll view
/// arranges its own parts each time it lays out, so the bar is put back under the titles each time.
@MainActor final class ListHeaderPlacement {
    private var bar: ListHeaderBar?
    private var line: NSBox?

    func place(in scrollView: NSScrollView, table: NSTableView) {
        guard let header = table.headerView, let strip = header.superview, strip.superview === scrollView else {
            return
        }
        let bar = self.bar ?? ListHeaderBar()
        let line = self.line ?? NSBox()
        if self.bar == nil {
            line.boxType = .separator
            self.bar = bar
            self.line = line
        }
        let views = scrollView.subviews
        if let barIndex = views.firstIndex(of: bar), let stripIndex = views.firstIndex(of: strip),
            barIndex < stripIndex,
            let lineIndex = views.firstIndex(of: line), lineIndex > barIndex, lineIndex < stripIndex
        {
        } else {
            scrollView.addSubview(bar, positioned: .below, relativeTo: strip)
            scrollView.addSubview(line, positioned: .below, relativeTo: strip)
        }
        // From the top of the window's content, under the toolbar, down to the bottom of the titles.
        let bottom = strip.frame.maxY
        let frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: bottom)
        if bar.frame != frame { bar.frame = frame }
        let lineFrame = NSRect(x: 0, y: bottom - 1, width: scrollView.bounds.width, height: 1)
        if line.frame != lineFrame { line.frame = lineFrame }
    }
}
