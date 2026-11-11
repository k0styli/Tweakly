import AppKit
import Observation
import UninstallerCore

/// The removal sheet's list, laid out as the list of apps in System Settings › Storage: no frame around it, one line
/// under the column titles, stripes across the whole width, and the selected item's path in a bar under the list,
/// rather than a path in every row. A box at the start of each row keeps an item where it is.
final class RemovalTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Column: String, CaseIterable {
        case name, kind, size

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .kind: String(localized: "Kind")
            case .size: String(localized: "Size")
            }
        }
    }

    private static let rowHeight: CGFloat = 24

    private let plan: RemovalPlan
    private let tableView = RowsOnlyTableView()
    private let scrollView = NSScrollView()
    private let headerLine = NSBox()
    private let pathControl = NSPathControl()
    private var icons: [String: NSImage] = [:]
    private var items: [RemovalPlan.Item] = []

    init(plan: RemovalPlan) {
        self.plan = plan
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 2, height: 0)
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(revealClicked)
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let header = ListHeaderCell(textCell: column.title)
            header.font = tableColumn.headerCell.font
            // The key tells the cell which column is last, which has no divider after it.
            header.key = column.rawValue
            header.alignment = column == .size ? .right : .left
            tableColumn.headerCell = header
            tableColumn.title = column.title
            switch column {
            case .name:
                tableColumn.width = 330
                tableColumn.minWidth = 160
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            case .kind:
                tableColumn.width = 130
                tableColumn.minWidth = 80
                tableColumn.resizingMask = .userResizingMask
            case .size:
                tableColumn.width = 86
                tableColumn.minWidth = 60
                tableColumn.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.headerView = ListHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: tableView.headerView?.frame.height ?? 28))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        headerLine.boxType = .separator
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        root.addSubview(scrollView)
        root.addSubview(pathControl)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -4),
            pathControl.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pathControl.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = root
        observePlan()
    }

    /// One line under the titles, from edge to edge, as in the Storage list; nothing around the list.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let header = tableView.headerView, let strip = header.superview, strip.superview === scrollView else {
            return
        }
        if headerLine.superview !== scrollView { scrollView.addSubview(headerLine) }
        let frame = NSRect(x: 0, y: strip.frame.maxY - 1, width: scrollView.bounds.width, height: 1)
        if headerLine.frame != frame { headerLine.frame = frame }
    }

    #if TWEAKLY_AUTOMATION
        /// Where each title and the first row's cells sit, to line them up without a screen.
        var geometryForTesting: String {
            var lines = [
                "table \(tableView.bounds) style \(tableView.style.rawValue) spacing \(tableView.intercellSpacing)"
            ]
            for index in tableView.tableColumns.indices {
                let header = tableView.headerView?.headerRect(ofColumn: index) ?? .zero
                let column = tableView.rect(ofColumn: index)
                let cell = tableView.numberOfRows > 0 ? tableView.frameOfCell(atColumn: index, row: 0) : .zero
                let view = tableView.view(atColumn: index, row: 0, makeIfNecessary: false)
                let viewFrame = view.map { tableView.convert($0.bounds, from: $0) } ?? .zero
                lines.append("col \(index) header \(header) column \(column) cell \(cell) view \(viewFrame)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    #endif

    // MARK: The plan

    private func observePlan() {
        withObservationTracking {
            _ = plan.items
            _ = plan.isWorking
            _ = plan.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refresh()
                    self.observePlan()
                }
            }
        }
        refresh()
    }

    private func refresh() {
        let newItems = plan.items
        if newItems.map(\.id) == items.map(\.id) {
            let changed = IndexSet(newItems.indices.filter { newItems[$0] != items[$0] })
            items = newItems
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(tableView.tableColumns.indices))
            }
        } else {
            items = newItems
            tableView.reloadData()
        }
        let wanted = plan.selection.flatMap { id in items.firstIndex { $0.id == id } }
        if wanted != (tableView.selectedRow >= 0 ? tableView.selectedRow : nil) {
            if let wanted {
                tableView.selectRowIndexes([wanted], byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }
        for row in items.indices {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ListNameCell)?.checkbox.isEnabled =
                !plan.isWorking
        }
        showPath()
    }

    private func showPath() {
        let url = plan.selection.map { URL(fileURLWithPath: $0) }
        if pathControl.url != url { pathControl.url = url }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
            items.indices.contains(row)
        else { return nil }
        let item = items[row]
        let leftover = item.leftover
        switch column {
        case .name:
            let cell =
                tableView.makeView(withIdentifier: ListNameCell.identifier, owner: nil) as? ListNameCell
                ?? ListNameCell()
            cell.showsCheckbox = true
            cell.checkbox.state = item.isChecked ? .on : .off
            cell.checkbox.isEnabled = !plan.isWorking
            cell.checkbox.target = self
            cell.checkbox.action = #selector(toggle(_:))
            cell.checkbox.setAccessibilityLabel(leftover.name)
            cell.show(
                icon: icon(leftover.path), name: leftover.name, help: UninstallerText.shortPath(leftover.path),
                lockedHelp: leftover.needsAdministrator ? String(localized: "Needs an administrator’s password") : nil)
            return cell
        case .kind, .size:
            let cell =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ListTextCell
                ?? ListTextCell(identifier: tableColumn.identifier, alignment: column == .size ? .right : .left)
            if column == .kind {
                cell.show(UninstallerText.category(leftover.category), isSecondary: true)
            } else {
                cell.show(UninstallerText.size(leftover.size))
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let id = items.indices.contains(row) ? items[row].id : nil
        if plan.selection != id { plan.selection = id }
        showPath()
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard items.indices.contains(row), let index = plan.items.firstIndex(where: { $0.id == items[row].id })
        else { return }
        plan.items[index].isChecked = sender.state == .on
    }

    @objc private func revealClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: items[row].id)])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        let item = NSMenuItem(
            title: String(localized: "Show in Finder"), action: #selector(revealFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = items[row].id
        menu.addItem(item)
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// Stripes only behind the rows, as a short list in a sheet ends where its items end: stripes drawn on into the empty
/// space were cut at the list's bottom edge into a sliver that read as a stray line.
final class RowsOnlyTableView: NSTableView {
    override func drawBackground(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let rows = NSRect(
            x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect(ofRow: numberOfRows - 1).maxY)
        super.drawBackground(inClipRect: clipRect.intersection(rows))
    }
}
