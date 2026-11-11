import AppKit
import Observation
import UninstallerCore

/// The page's table of apps, built as the task manager's is: the system's inset list under the toolbar, Finder's column
/// titles with their bar (`ListHeaderPlacement`), numbers set to the right with their titles, and the line of totals
/// under it. Stripes, as the list of apps in System Settings › Storage has, because its rows are long and plain.
final class AppsTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Column: String, CaseIterable {
        case name, kind, lastOpened, size, data

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .kind: String(localized: "Kind")
            case .lastOpened: String(localized: "Last Opened")
            case .size: String(localized: "Size")
            case .data: String(localized: "Data")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 200
            case .kind: 118
            case .lastOpened: 100
            case .size, .data: 80
            }
        }

        var isNumeric: Bool { self == .size || self == .data }
        /// Names read from A, figures from the biggest, dates from the latest.
        var sortsAscendingFirst: Bool { self == .name || self == .kind }

        var help: String? {
            switch self {
            case .size: String(localized: "What the app itself takes")
            case .data: String(localized: "What the app keeps in the Library: data, caches, settings and the rest")
            default: nil
            }
        }
    }

    private static let rowHeight: CGFloat = 24

    private unowned let model: UninstallerModel
    private let tableView = AppsTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton()
    private let headerPlacement = ListHeaderPlacement()
    private var rows: [UninstallerModel.Row] = []
    private var isApplyingSelection = false

    init(model: UninstallerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 2, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onUninstall = { [weak self] in self?.model.begin(.uninstall) }
        tableView.registerForDraggedTypes([.fileURL])
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let header = ListHeaderCell(textCell: column.title)
            header.font = tableColumn.headerCell.font
            header.key = column.rawValue
            header.alignment = column.isNumeric ? .right : .left
            tableColumn.headerCell = header
            tableColumn.title = column.title
            tableColumn.headerToolTip = column.help
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 140 : 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: column.sortsAscendingFirst)
            tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        tableView.headerView = ListHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: tableView.headerView?.frame.height ?? 28))
        tableView.sortDescriptors = [NSSortDescriptor(key: model.sort.column.rawValue, ascending: model.sort.ascending)]
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessButton.bezelStyle = .push
        accessButton.controlSize = .small
        accessButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessButton.title = String(localized: "Full Disk Access…")
        accessButton.toolTip = String(localized: "Show the size of the data apps keep in their containers")
        accessButton.target = self
        accessButton.action = #selector(explainDiskAccess)
        accessButton.isHidden = true
        // As the task manager's line: the figures centred under the table, and the button beside them while it is needed.
        let bar = NSStackView(views: [statusLabel, accessButton])
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(separator)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        view = root
        observeModel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        headerPlacement.place(in: scrollView, table: tableView)
    }

    var tableForFocus: NSView { tableView }

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

    // MARK: The model

    /// Follows the model with Observation: what the table shows, the line under it, and the selection made elsewhere,
    /// such as by dropping an app on the page.
    private func observeModel() {
        withObservationTracking {
            _ = model.visibleRows
            _ = model.status
            _ = model.needsFullDiskAccess
            _ = model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refresh()
                    self.observeModel()
                }
            }
        }
        refresh()
    }

    private func refresh() {
        let newRows = model.visibleRows
        if newRows.map(\.id) == rows.map(\.id) {
            // Same rows in the same order: only what changed is drawn again, so the list does not flicker as sizes come.
            let changed = IndexSet(newRows.indices.filter { newRows[$0] != rows[$0] })
            rows = newRows
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(tableView.tableColumns.indices))
            }
        } else {
            rows = newRows
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
        }
        applySelection()
        statusLabel.stringValue = model.status
        accessButton.isHidden = !model.needsFullDiskAccess
    }

    private func applySelection() {
        let wanted = model.selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let current = tableView.selectedRow
        guard wanted != (current >= 0 ? current : nil) else { return }
        isApplyingSelection = true
        if let wanted {
            tableView.selectRowIndexes([wanted], byExtendingSelection: false)
            tableView.scrollRowToVisible(wanted)
        } else {
            tableView.deselectAll(nil)
        }
        isApplyingSelection = false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
            rows.indices.contains(row)
        else { return nil }
        let item = rows[row]
        if column == .name {
            let cell =
                tableView.makeView(withIdentifier: ListNameCell.identifier, owner: nil) as? ListNameCell
                ?? ListNameCell()
            cell.show(icon: model.icon(for: item), name: item.name, help: UninstallerText.shortPath(item.id))
            return cell
        }
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ListTextCell
            ?? ListTextCell(identifier: tableColumn.identifier, alignment: column.isNumeric ? .right : .left)
        switch column {
        case .name: break
        case .kind: cell.show(item.kindTitle)
        case .lastOpened:
            cell.show(item.app.lastOpened.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
        case .size: cell.show(item.app.size.map { Format.fileSize(UInt64(max($0, 0))) } ?? "")
        case .data:
            // Nothing while it is measured; a dash for an app that keeps nothing; grey for a figure without the
            // containers, which need Full Disk Access.
            let text: String
            if item.leftovers?.isEmpty == true {
                text = "—"
            } else {
                text = item.dataSize.map { Format.fileSize(UInt64(max($0, 0))) } ?? ""
            }
            cell.show(text, isSecondary: item.hasUnreadableData)
            cell.toolTip =
                item.hasUnreadableData
                ? String(localized: "Without the data in its containers, which needs Full Disk Access") : nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = tableView.selectedRow
        model.selection = rows.indices.contains(row) ? rows[row].id : nil
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
            let column = Column(rawValue: key)
        else { return }
        model.sort = AppSort(column: column, ascending: descriptor.ascending)
        // The sorted column's title is drawn bolder, see `ListHeaderCell`.
        tableView.headerView?.needsDisplay = true
    }

    // MARK: Dropping apps

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard !Self.apps(in: info).isEmpty else { return [] }
        // The whole list takes the drop, not a place between rows.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let apps = Self.apps(in: info)
        guard !apps.isEmpty else { return false }
        model.open(droppedApps: apps)
        return true
    }

    private static func apps(in info: NSDraggingInfo) -> [URL] {
        let urls =
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(AppCatalog.mayList(dropped:))
    }

    // MARK: The context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        let id = rows[row].id
        menu.addItem(item(String(localized: "Uninstall…"), #selector(uninstallClicked(_:)), id))
        menu.addItem(item(String(localized: "Reset…"), #selector(resetClicked(_:)), id))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show in Finder"), #selector(revealClicked(_:)), id))
    }

    private func item(_ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func uninstallClicked(_ sender: NSMenuItem) {
        model.begin(.uninstall, for: sender.representedObject as? String)
    }

    @objc private func resetClicked(_ sender: NSMenuItem) {
        model.begin(.reset, for: sender.representedObject as? String)
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        model.reveal(sender.representedObject as? String)
    }

    // MARK: Full Disk Access

    /// What the access is for and how to give it, as System Settings has no request for it that an app can make.
    @objc private func explainDiskAccess() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "See what apps keep in their containers?")
        alert.informativeText = String(
            localized:
                "macOS protects what App Store apps and some others keep in their containers. To measure it and move it to the Trash without macOS asking each time, add Tweakly to Full Disk Access in System Settings: press +, then choose Tweakly in Applications."
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { FullDiskAccess.openSettings() }
        }
    }
}

/// How the table is sorted, kept between visits of the page.
struct AppSort: Equatable {
    private static let key = "uninstallerSort"

    var column: AppsTableController.Column
    var ascending: Bool

    /// The biggest apps first, as in System Settings › Storage.
    static let standard = AppSort(column: .size, ascending: false)

    static func saved() -> AppSort {
        guard let text = UserDefaults.standard.string(forKey: key) else { return .standard }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let column = AppsTableController.Column(rawValue: String(parts[0])) else {
            return .standard
        }
        return AppSort(column: column, ascending: parts[1] == "up")
    }

    func save() {
        if self == .standard {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set("\(column.rawValue) \(ascending ? "up" : "down")", forKey: Self.key)
        }
    }

    func sorted(_ rows: [UninstallerModel.Row]) -> [UninstallerModel.Row] {
        rows.sorted { lhs, rhs in
            let order: ComparisonResult =
                switch column {
                case .name: lhs.name.localizedStandardCompare(rhs.name)
                case .kind: lhs.kindTitle.localizedStandardCompare(rhs.kindTitle)
                case .lastOpened: Self.compare(lhs.sortDate, rhs.sortDate)
                case .size: Self.compare(lhs.sortSize, rhs.sortSize)
                case .data: Self.compare(lhs.sortData, rhs.sortData)
                }
            // Ties keep a fixed order by name, so equal rows do not swap places as figures arrive.
            if order == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

/// ⌘⌫ asks to uninstall the selected app, as it moves a file to the Trash in Finder. A click on nothing lets go of the
/// selection, and so does Escape.
final class AppsTableView: NSTableView {
    var onUninstall: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard row(at: convert(event.locationInWindow, from: nil)) >= 0 else {
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        deselectAll(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .capsLock, .function, .numericPad,
        ])
        if window?.firstResponder === self, flags == [.command],
            event.specialKey == .backspace || event.specialKey == .delete, selectedRow >= 0
        {
            onUninstall?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
