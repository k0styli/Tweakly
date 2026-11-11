import AppKit
import TaskManagerCore

/// The task manager's table: every process, apps first, each app's helpers inside its row.
///
/// An `NSTableView` with group rows for the two sections and the system's disclosure triangles for the apps, rather than
/// an outline view: while the section titles stay where they are, which they do between most updates even as the order
/// changes, every row on screen is refilled where it is. Rebuilding the rows measured three times the cost.
final class ProcessesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Key {
        static let columns = "taskManagerColumns"
        static let sort = "taskManagerSort"
        static let autosave = "TaskManagerProcesses"
    }

    private let tableView = ProcessTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let helperButton = NSButton()
    /// Asks to install or update the root helper, which shows the figures of other users' processes.
    var onInstallHelper: (() -> Void)?
    private let icons = ProcessIcons()
    private var infoPopover: NSPopover?
    private var accentObserver: NSObjectProtocol?
    private var infoContent: ProcessInfoViewController?
    private let defaults = UserDefaults.standard

    private(set) var table = ProcessTable()
    private var snapshot = ProcessSnapshot()
    /// Where each name falls in Finder's order, learnt once for each name, so sorting by name compares numbers.
    private var names = FinderOrder()
    /// Whether `names` knows every name of the current snapshot.
    private var namesAreLearnt = false
    /// An update that came while the person scrolled, shown once the scrolling ends. Lines that change under a moving
    /// list read as the list jerking, and filling them costs the frame its time.
    private var deferredSnapshot: ProcessSnapshot?
    private var liveScrollStart: TimeInterval?
    private var liveScrollObservers: [NSObjectProtocol] = []
    private var expanded: Set<ProcessKey> = []
    private var sort: TaskSort
    private var selected: TaskRow?
    private var isRestoringSelection = false
    private var hasData = false

    var query = "" {
        didSet { if query != oldValue { rebuild() } }
    }
    /// The figures for the whole Mac, shown under the table.
    var totals = "" {
        didSet { if totals != oldValue { updateStatus() } }
    }
    var onDemandChange: ((ProcessDemand) -> Void)?
    var onSelectionChange: (() -> Void)?

    init() {
        sort = Self.readSort(UserDefaults.standard)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        // The system's inset list, with room at both edges and rounded selections, as Finder's lists have on macOS 26.
        tableView.style = .inset
        // Plain rows: the shaded figures already set the rows apart, and stripes under them only add noise.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        // A section's title scrolls away with it, rather than staying on top of the next section.
        tableView.floatsGroupRows = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // A thin gap between cells, so the shaded columns read as separate figures, as in Windows.
        tableView.intercellSpacing = NSSize(width: 2, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.onToggle = { [weak self] open in self?.setSelectedGroup(open: open) }
        tableView.canSelect = { [weak self] row in
            guard let self, self.table.rows.indices.contains(row) else { return false }
            if case .section = self.table.rows[row] { return false }
            return true
        }
        tableView.onKeyCommand = { [weak self] command in
            switch command {
            case .endTask: self?.endTarget(force: false)
            case .forceQuit: self?.endTarget(force: true)
            case .info: self?.toggleInfo()
            }
        }
        for column in TaskColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let header = ListHeaderCell(textCell: column.title)
            header.font = tableColumn.headerCell.font
            header.key = column.rawValue
            tableColumn.headerCell = header
            tableColumn.title = column.title
            tableColumn.headerToolTip = column.help
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 140 : 44
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: column.sortsAscendingFirst)
            tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        // Its own header class, which AppKit gives no banner of the older filled kind; see `ListHeaderPlacement`.
        tableView.headerView = ListHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: tableView.headerView?.frame.height ?? 28))
        tableView.autosaveName = Key.autosave
        tableView.autosaveTableColumns = true
        applyVisibleColumns(readVisibleColumns())
        findShadedEdges()
        tableView.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]
        highlightSortedColumn()
        // The page can start its feed before SwiftUI loads this view, when the table has no columns yet and the feed
        // would read neither the network nor the GPU.
        onDemandChange?(demand)

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        // The shading is in the accent colour, which can change in System Settings while the window is open.
        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                ProcessShade.forget()
                self?.tableView.reloadData()
            }
        }

        let center = NotificationCenter.default
        liveScrollObservers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main)
            {
                [weak self] _ in
                MainActor.assumeIsolated { self?.liveScrollStart = ProcessInfo.processInfo.systemUptime }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.liveScrollDidEnd() }
            },
        ]

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
        helperButton.bezelStyle = .push
        helperButton.controlSize = .small
        helperButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helperButton.target = self
        helperButton.action = #selector(installHelper)
        helperButton.isHidden = true
        // A hidden button leaves the line to the figures, centred under the whole table.
        let bar = NSStackView(views: [statusLabel, helperButton])
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
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        view = root
    }

    var tableForFocus: NSView { tableView }

    private var hasFittedColumns = false

    /// Hidden columns still count towards the table's first width, which the name column would then take up. Fitting
    /// once the table has its real width gives the name what is left.
    override func viewDidLayout() {
        super.viewDidLayout()
        placeHeaderBar()
        guard !hasFittedColumns, scrollView.contentView.bounds.width > 0 else { return }
        hasFittedColumns = true
        fitColumns()
    }

    private func fitColumns() {
        tableView.sizeToFit()
    }

    private let headerPlacement = ListHeaderPlacement()

    private func placeHeaderBar() {
        headerPlacement.place(in: scrollView, table: tableView)
    }

    // MARK: Data

    func apply(_ newSnapshot: ProcessSnapshot) {
        // A scroll that never told its end, or a scroller held for long, still lets the figures through now and then.
        if let liveScrollStart, ProcessInfo.processInfo.systemUptime - liveScrollStart < Self.longestDeferral {
            deferredSnapshot = newSnapshot
            return
        }
        deferredSnapshot = nil
        snapshot = newSnapshot
        namesAreLearnt = false
        hasData = true
        let present = Set(newSnapshot.groups.map(\.id))
        expanded.formIntersection(present)
        icons.forget(except: Set(newSnapshot.groups.map(\.head.pid)))
        rebuild(keepingLinesInPlace: true)
        if infoPopover?.isShown == true { refreshInfo() }
    }

    private static let longestDeferral: TimeInterval = 5

    private func liveScrollDidEnd() {
        liveScrollStart = nil
        if let deferredSnapshot { apply(deferredSnapshot) }
    }

    /// `keepingLinesInPlace` is for the updates that come by themselves: the lines the person is looking at stay where
    /// they are on screen while others come and go above them. A change the person made, such as a new sort, does not.
    private func rebuild(keepingLinesInPlace: Bool = false) {
        let previous = table
        let anchors = keepingLinesInPlace ? screenAnchors() : []
        #if TWEAKLY_AUTOMATION
            let buildStart = DispatchTime.now().uptimeNanoseconds
        #endif
        if sort.column == .name || sort.column == .user, !namesAreLearnt {
            names.learn(snapshot.groups, userNames: snapshot.userNames)
            namesAreLearnt = true
        }
        table = ProcessTable(
            groups: snapshot.groups, sort: sort, query: query, expanded: expanded, userNames: snapshot.userNames,
            names: names)
        #if TWEAKLY_AUTOMATION
            TaskManagerTiming.shared.add("build table", since: buildStart)
        #endif
        #if TWEAKLY_AUTOMATION
            let fillStart = DispatchTime.now().uptimeNanoseconds
        #endif
        // Background processes come and go every few seconds, which only adds or takes away lines at the end while the
        // section titles stay where they are. The lines on screen are then refilled where they are, at a third of the cost.
        if table.sectionPositions == previous.sectionPositions, tableView.numberOfRows == previous.rows.count {
            if table.rows.count != previous.rows.count { tableView.noteNumberOfRowsChanged() }
            refreshAvailableRows()
            #if TWEAKLY_AUTOMATION
                TaskManagerTiming.shared.add("refresh rows", since: fillStart)
            #endif
        } else {
            tableView.reloadData()
            #if TWEAKLY_AUTOMATION
                TaskManagerTiming.shared.add("reload", since: fillStart)
            #endif
        }
        restore(anchors)
        restoreSelection()
        updateStatus()
    }

    /// A line on screen and how far below the top of the list it sits.
    private struct ScreenAnchor {
        let row: TaskRow
        let offset: CGFloat
    }

    /// The top of the visible list, under the column titles.
    private var listTop: CGFloat {
        let clip = scrollView.contentView
        return clip.bounds.minY + clip.contentInsets.top
    }

    /// What should stay put on screen through an update, best first. In an order that holds still, by name or number,
    /// the lines at the top; if they are gone, the title of their section. An order by load reshuffles on every update
    /// and is one list without titles, as in Windows, so nothing holds it: the busiest stay at the top where the person
    /// looks for them. None at the very top of the list, which stays at the top so that a new app shows up.
    private func screenAnchors() -> [ScreenAnchor] {
        let clip = scrollView.contentView
        guard clip.bounds.minY > -clip.contentInsets.top + 0.5, !table.rows.isEmpty else { return [] }
        let top = listTop
        // A band rather than a point, which could fall in the gap between two lines.
        let first = tableView.rows(in: NSRect(x: 0, y: top, width: tableView.bounds.width, height: 6)).location
        guard first >= 0, first < table.rows.count else { return [] }
        var anchors: [ScreenAnchor] = []
        func add(_ row: Int) {
            anchors.append(ScreenAnchor(row: table.rows[row], offset: tableView.rect(ofRow: row).minY - top))
        }
        let holdsStill: Bool =
            switch sort.column {
            case .name, .pid, .user, .kind, .architecture: true
            default: false
            }
        if holdsStill {
            for row in first..<min(first + 5, table.rows.count) { add(row) }
        }
        if let section = table.rows[...first].lastIndex(where: { if case .section = $0 { true } else { false } }) {
            add(section)
        }
        return anchors
    }

    private func restore(_ anchors: [ScreenAnchor]) {
        guard !anchors.isEmpty else { return }
        for anchor in anchors {
            guard let row = table.rows.firstIndex(of: anchor.row) else { continue }
            let clip = scrollView.contentView
            let lowest = -clip.contentInsets.top
            let highest = max(tableView.frame.height - clip.bounds.height + clip.contentInsets.bottom, lowest)
            let wanted = tableView.rect(ofRow: row).minY - anchor.offset - clip.contentInsets.top
            let y = min(max(wanted, lowest), highest)
            if abs(y - clip.bounds.minY) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
            return
        }
    }

    /// Every line the table holds a view for, which includes those it prepared just off screen for scrolling: left as
    /// they were, they would scroll in showing an older update, or another process than the line now holds.
    private func refreshAvailableRows() {
        let columns: [(index: Int, column: TaskColumn, identifier: NSUserInterfaceItemIdentifier)] =
            tableView.tableColumns.enumerated().compactMap { index, tableColumn in
                guard !tableColumn.isHidden, let column = TaskColumn(rawValue: tableColumn.identifier.rawValue) else {
                    return nil
                }
                return (index, column, tableColumn.identifier)
            }
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < table.rows.count else { return }
            if case .section(let section) = table.rows[row] {
                (rowView.view(atColumn: 0) as? ProcessSectionCell)?.show(title(of: section))
                return
            }
            for slot in columns {
                guard let cell = rowView.view(atColumn: slot.index) as? NSView else { continue }
                fill(cell, column: slot.column, identifier: slot.identifier, row: row)
            }
        }
    }

    private func restoreSelection() {
        guard let selected else { return }
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        if let index = table.rows.firstIndex(of: selected) {
            if tableView.selectedRow != index { tableView.selectRowIndexes([index], byExtendingSelection: false) }
        } else {
            self.selected = nil
            tableView.deselectAll(nil)
            selectionDidChange()
        }
    }

    private func selectionDidChange() {
        if infoPopover?.isShown == true {
            if selected == nil { infoPopover?.close() } else { refreshInfo() }
        }
        onSelectionChange?()
    }

    @objc private func installHelper() {
        onInstallHelper?()
    }

    private func updateStatus() {
        guard hasData else {
            statusLabel.stringValue = ""
            return
        }
        // Only while something is missing that the helper would show.
        let title: String? =
            switch snapshot.helper {
            case _ where snapshot.unreadableCount == 0: nil
            case .notInstalled: String(localized: "System Process Figures…")
            // A helper that does not answer is most likely signed differently from this copy, as after a change of
            // certificate, and installing it again puts that right.
            case .outdated, .failing: String(localized: "Update Helper…")
            case .working: nil
            }
        helperButton.isHidden = title == nil
        if let title, helperButton.title != title { helperButton.title = title }
        let count = String(localized: "\(snapshot.processCount) processes")
        statusLabel.stringValue = totals.isEmpty ? count : count + "   " + totals
    }

    private func title(of section: ProcessSection) -> String {
        let count = table.count(in: section)
        return switch section {
        case .apps: String(localized: "Apps (\(count))")
        case .background: String(localized: "Background Processes (\(count))")
        case .system: String(localized: "System Processes (\(count))")
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { table.rows.count }

    /// Rows that tell their figures when they are selected, see `ProcessRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .section = table.rows[row] { return nil }
        return tableView.makeView(withIdentifier: ProcessRowView.identifier, owner: nil) as? ProcessRowView
            ?? ProcessRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = table.rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = table.rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .section(let section) = table.rows[row] {
            let cell =
                tableView.makeView(withIdentifier: ProcessSectionCell.identifier, owner: nil) as? ProcessSectionCell
                ?? ProcessSectionCell()
            cell.show(title(of: section))
            return cell
        }
        guard let tableColumn, let column = TaskColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let cell: NSView
        if column == .name {
            let name =
                tableView.makeView(withIdentifier: ProcessNameCell.identifier, owner: nil) as? ProcessNameCell
                ?? ProcessNameCell()
            name.disclosure.target = self
            name.disclosure.action = #selector(toggleGroup(_:))
            cell = name
        } else {
            cell =
                tableView.makeView(withIdentifier: column.identifier, owner: nil)
                ?? ProcessTextCell(identifier: column.identifier, alignment: column.isNumeric ? .right : .left)
        }
        fill(cell, column: column, identifier: tableColumn.identifier, row: row)
        return cell
    }

    private func fill(_ cell: NSView, column: TaskColumn, identifier: NSUserInterfaceItemIdentifier, row: Int) {
        guard row < table.rows.count else { return }
        let line = table.rows[row]
        guard let usage = table.usage(of: line), let section = table.section(of: line) else { return }
        if column == .name, let cell = cell as? ProcessNameCell {
            switch line {
            case .group(let key):
                let group = table.group(key)
                let count = group?.processCount ?? 1
                // Only an app has an app's icon to look up; asking the system about every plain process took a third of
                // refilling the rows every few seconds.
                let head = group?.head ?? usage
                cell.show(
                    name: usage.name, count: count,
                    image: icons.icon(for: head, isApp: snapshot.appPIDs.contains(head.pid)),
                    canOpen: count > 1 && !table.openedBySearch.contains(key),
                    isOpen: expanded.contains(key) || table.openedBySearch.contains(key), isMember: false)
            case .member(let key, let member):
                cell.show(
                    name: usage.name, count: 1,
                    image: icons.icon(for: usage, isApp: member == key && snapshot.appPIDs.contains(usage.pid)),
                    canOpen: false,
                    isOpen: false, isMember: true)
            case .section:
                break
            }
        } else if let cell = cell as? ProcessTextCell {
            cell.setRoundedCorners(blockCorners(column: identifier, row: row))
            cell.show(
                ProcessText.value(of: column, usage, section: section, userNames: snapshot.userNames),
                isZero: ProcessText.isZero(column, usage),
                shade: LoadShade.level(
                    of: column, usage, coreCount: ProcessText.coreCount, totalMemory: ProcessText.totalMemory))
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key,
            let column = TaskColumn(rawValue: key)
        else { return }
        sort = TaskSort(column: column, ascending: first.ascending)
        defaults.set([column.rawValue, sort.ascending ? "ascending" : "descending"], forKey: Key.sort)
        highlightSortedColumn()
        rebuild()
    }

    /// The title of the column the list is sorted by stands out and the others recede, as in Finder. The titles draw that
    /// themselves; the header only has to draw again.
    private func highlightSortedColumn() {
        tableView.headerView?.needsDisplay = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        let row = tableView.selectedRow
        selected = row >= 0 && row < table.rows.count ? table.rows[row] : nil
        selectionDidChange()
    }

    // MARK: Groups

    @objc private func toggleGroup(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < table.rows.count, case .group(let key) = table.rows[row] else { return }
        // Option opens or closes every group, as with Finder's triangles.
        let everything = NSEvent.modifierFlags.contains(.option)
        let opens = sender.state == .on
        if everything {
            let all = Set(table.groups.values.filter { $0.processCount > 1 }.map(\.id))
            expanded = opens ? all : []
        } else if opens {
            expanded.insert(key)
        } else {
            expanded.remove(key)
        }
        rebuild()
    }

    /// The arrow keys, as in an outline: right opens the selected app, left closes it or goes up to it from a helper.
    private func setSelectedGroup(open: Bool) {
        guard let selected else { return }
        switch selected {
        case .group(let key) where open:
            guard table.group(key).map({ $0.processCount > 1 }) == true else { return }
            expanded.insert(key)
        case .group(let key):
            expanded.remove(key)
        case .member(let key, _) where !open:
            expanded.remove(key)
            self.selected = .group(key)
        default:
            return
        }
        rebuild()
        if let index = table.rows.firstIndex(of: self.selected ?? selected) { tableView.scrollRowToVisible(index) }
        selectionDidChange()
    }

    // MARK: Selection and actions

    /// What the buttons, keys and menus act on. A context menu selects its row first, as in Activity Monitor, so that
    /// this is always the row the person sees highlighted.
    private var targetRow: TaskRow? { selected }

    var hasTarget: Bool {
        guard let target = targetRow, let usage = table.usage(of: target) else { return false }
        return ProcessActions.canEnd(usage.pid)
    }

    var selectedUsage: (usage: ProcessUsage, section: ProcessSection, group: ProcessGroup?)? {
        guard let target = targetRow, let usage = table.usage(of: target), let section = table.section(of: target)
        else { return nil }
        if case .group(let key) = target { return (usage, section, table.group(key)) }
        return (usage, section, nil)
    }

    /// Get Info: a popover by the selected row that follows the table's updates, or closes if it was open.
    func toggleInfo() {
        if let infoPopover, infoPopover.isShown {
            infoPopover.close()
            return
        }
        let row = tableView.selectedRow
        guard row >= 0, selectedUsage != nil else { return }
        let content = ProcessInfoViewController()
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        infoContent = content
        infoPopover = popover
        refreshInfo()
        content.view.layoutSubtreeIfNeeded()
        popover.contentSize = content.view.fittingSize
        popover.show(relativeTo: tableView.rect(ofRow: row), of: tableView, preferredEdge: .maxY)
    }

    private func refreshInfo() {
        guard let infoContent, let target = selectedUsage else { return }
        let head = target.group?.head ?? target.usage
        let parent = table.groups.values.lazy.flatMap { [$0.head] + $0.members }.first { $0.pid == head.parentPID }
        infoContent.show(
            usage: target.usage, section: target.section, group: target.group,
            image: icons.icon(for: head, isApp: target.group != nil), parentName: parent?.name,
            userNames: snapshot.userNames)
    }

    @objc func endTask(_ sender: Any?) { endTarget(force: false) }
    @objc func forceQuit(_ sender: Any?) { endTarget(force: true) }
    @objc func showInfo(_ sender: Any?) { toggleInfo() }
    @objc func showInFinder(_ sender: Any?) { showTargetInFinder() }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = TaskColumn(rawValue: raw) else { return }
        toggle(column)
    }

    @objc func restoreDefaultColumns(_ sender: Any?) { resetColumns() }

    func endTarget(force: Bool) {
        guard let target = targetRow, let usage = table.usage(of: target), ProcessActions.canEnd(usage.pid),
            let window = view.window
        else { return }
        let group: ProcessGroup? = if case .group(let key) = target { table.group(key) } else { nil }
        let head = group?.head ?? usage
        ProcessActions.confirm(
            name: usage.name, processCount: group?.processCount ?? 1, logsOut: ProcessActions.endsSession(head),
            isSystem: ProcessActions.isSystem(head) || group?.members.contains(where: ProcessActions.isSystem) == true,
            force: force, in: window
        ) { [weak self] force in
            if let group {
                ProcessActions.end(group: group, force: force)
            } else {
                ProcessActions.end(process: usage, force: force)
            }
            self?.onEnded?()
        }
    }

    var onEnded: (() -> Void)?

    func showTargetInFinder() {
        guard let usage = selectedUsage?.group?.head ?? selectedUsage?.usage, let path = usage.path else { return }
        let url = URL(fileURLWithPath: ProcessGrouping.outermostBundle(of: path) ?? path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func doubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        toggleInfo()
    }

    // MARK: Columns

    /// The first and last shaded columns as they are shown, which hold the corners of each section's block. Columns
    /// move, appear and go away, so this is worked out again whenever they do.
    private var shadedEdges: (first: NSUserInterfaceItemIdentifier?, last: NSUserInterfaceItemIdentifier?) = (nil, nil)

    private func findShadedEdges() {
        let shaded = tableView.tableColumns.filter { column in
            !column.isHidden && TaskColumn(rawValue: column.identifier.rawValue).map(LoadShade.isShaded) == true
        }
        shadedEdges = (shaded.first?.identifier, shaded.last?.identifier)
    }

    /// Which corners of the section's block of shaded figures this cell holds: the first and last shaded columns, on the
    /// first and last rows of a section. Layers are not flipped, so the top of a cell is its largest y.
    private func blockCorners(column: NSUserInterfaceItemIdentifier, row: Int) -> CACornerMask {
        let isFirstColumn = column == shadedEdges.first
        let isLastColumn = column == shadedEdges.last
        guard isFirstColumn || isLastColumn else { return [] }
        func isSection(_ index: Int) -> Bool {
            guard table.rows.indices.contains(index) else { return true }
            if case .section = table.rows[index] { return true }
            return false
        }
        let isTop = isSection(row - 1)
        let isBottom = isSection(row + 1)
        var corners: CACornerMask = []
        if isFirstColumn, isTop { corners.insert(.layerMinXMaxYCorner) }
        if isFirstColumn, isBottom { corners.insert(.layerMinXMinYCorner) }
        if isLastColumn, isTop { corners.insert(.layerMaxXMaxYCorner) }
        if isLastColumn, isBottom { corners.insert(.layerMaxXMinYCorner) }
        return corners
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        findShadedEdges()
        refreshAvailableRows()
    }

    var visibleColumns: [TaskColumn] {
        tableView.tableColumns.filter { !$0.isHidden }.compactMap { TaskColumn(rawValue: $0.identifier.rawValue) }
    }

    func isShown(_ column: TaskColumn) -> Bool {
        tableView.tableColumn(withIdentifier: column.identifier)?.isHidden == false
    }

    func toggle(_ column: TaskColumn) {
        guard column.canBeHidden, let tableColumn = tableView.tableColumn(withIdentifier: column.identifier) else {
            return
        }
        tableColumn.isHidden.toggle()
        findShadedEdges()
        fitColumns()
        let shown = TaskColumn.allCases.filter(isShown)
        defaults.set(shown.map(\.rawValue), forKey: Key.columns)
        onDemandChange?(demand)
        // A column that appears is filled when the table asks for it, and one that goes needs nothing.
        if !tableColumn.isHidden { tableView.reloadData() }
    }

    func resetColumns() {
        defaults.removeObject(forKey: Key.columns)
        applyVisibleColumns(readVisibleColumns())
        findShadedEdges()
        fitColumns()
        onDemandChange?(demand)
        tableView.reloadData()
    }

    var demand: ProcessDemand {
        ProcessDemand(
            threads: isShown(.threads), gpu: isShown(.gpu),
            network: isShown(.network) || isShown(.received) || isShown(.sent))
    }

    private func readVisibleColumns() -> Set<TaskColumn> {
        guard let saved = defaults.stringArray(forKey: Key.columns) else {
            return Set(TaskColumn.allCases.filter(\.isShownByDefault))
        }
        return Set(saved.compactMap(TaskColumn.init(rawValue:))).union([.name])
    }

    private func applyVisibleColumns(_ shown: Set<TaskColumn>) {
        for tableColumn in tableView.tableColumns {
            guard let column = TaskColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.isHidden = !shown.contains(column)
        }
    }

    private static func readSort(_ defaults: UserDefaults) -> TaskSort {
        guard let saved = defaults.stringArray(forKey: Key.sort), saved.count == 2,
            let column = TaskColumn(rawValue: saved[0])
        else { return .standard }
        return TaskSort(column: column, ascending: saved[1] == "ascending")
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === tableView.headerView?.menu {
            TaskManagerMenus.addColumnItems(to: menu, target: self)
            return
        }
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < table.rows.count, let usage = table.usage(of: table.rows[clicked]) else { return }
        if tableView.selectedRow != clicked { tableView.selectRowIndexes([clicked], byExtendingSelection: false) }
        TaskManagerMenus.addProcessItems(to: menu, target: self)
        for item in menu.items where item.action == #selector(endTask(_:)) || item.action == #selector(forceQuit(_:)) {
            item.isEnabled = ProcessActions.canEnd(usage.pid)
        }
        menu.autoenablesItems = false
    }

    #if TWEAKLY_AUTOMATION
        /// Each row as text, for checking what the table shows without looking at it.
        var stateForTesting: String {
            var lines: [String] = []
            for (index, row) in table.rows.enumerated() {
                switch row {
                case .section(let section):
                    lines.append("== \(title(of: section))")
                default:
                    guard let usage = table.usage(of: row), let section = table.section(of: row) else { continue }
                    let cells = visibleColumns.map {
                        ProcessText.value(of: $0, usage, section: section, userNames: snapshot.userNames)
                            ?? ProcessText.unknown
                    }
                    let mark = tableView.selectedRow == index ? "*" : " "
                    let indent = if case .member = row { "    " } else { "" }
                    lines.append(mark + indent + cells.joined(separator: " | "))
                }
            }
            let widths = tableView.tableColumns.filter { !$0.isHidden }.map {
                "\($0.identifier.rawValue) \(Int($0.width))"
            }
            return "columns: \(widths.joined(separator: ", ")) table \(Int(tableView.frame.width)) clip "
                + "\(Int(scrollView.contentView.bounds.width))\nsort: \(sort.column.rawValue) "
                + "\(sort.ascending ? "up" : "down")\nstatus: \(statusLabel.stringValue)\n"
                + lines.joined(separator: "\n")
                + "\n"
        }

        func expandForTesting(name: String) {
            if let group = table.groups.values.first(where: { $0.name == name }) {
                expanded.insert(group.id)
                rebuild()
            }
        }

        func selectForTesting(name: String) {
            let pid = Int32(name)
            guard
                let index = table.rows.firstIndex(where: {
                    guard let usage = table.usage(of: $0) else { return false }
                    return usage.name == name || usage.pid == pid
                })
            else { return }
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }

        var headerForTesting: String {
            guard let header = tableView.headerView else { return "no header" }
            var lines = ["header \(header.frame) in \(String(describing: header.superview.map { type(of: $0) }))"]
            lines.append(
                "column 0 \(header.headerRect(ofColumn: 0)) table \(tableView.frame) clip \(scrollView.contentView.frame)"
            )
            func walk(_ view: NSView, _ depth: Int) {
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)")
                for child in view.subviews { walk(child, depth + 1) }
            }
            walk(scrollView, 0)
            return lines.joined(separator: "\n") + "\n"
        }

        func scrollForTesting(toRow row: Int) {
            guard row >= 0, row < tableView.numberOfRows else { return }
            tableView.scroll(NSPoint(x: 0, y: tableView.rect(ofRow: row).minY - 1))
        }

        func sortForTesting(_ column: TaskColumn, ascending: Bool) {
            tableView.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
        }

        private var bench: ScrollBench?
        private var anchorTimer: Timer?

        /// Scrolls up and down the whole list at `speed` points a second for `seconds`, as a live scroll, and writes how
        /// long each frame took: a frame much longer than the display's is one the person sees as a hitch.
        func scrollBenchForTesting(seconds: Double, speed: CGFloat, to path: String) {
            bench = ScrollBench(scrollView: scrollView, table: tableView, seconds: seconds, speed: speed) {
                [weak self] report in
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
                self?.bench = nil
            }
        }

        /// The row at the top of the list under the titles, once a tick for `seconds`, and how often a different one took
        /// its place while nobody scrolled: each change is the list jumping under the person's eyes.
        func anchorCheckForTesting(seconds: Double, to path: String) {
            var names: [String] = []
            let started = Date()
            anchorTimer?.invalidate()
            anchorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard Date().timeIntervalSince(started) < seconds else {
                        self.anchorTimer?.invalidate()
                        self.anchorTimer = nil
                        var changes = 0
                        for (old, new) in zip(names, names.dropFirst()) where old != new { changes += 1 }
                        let report = "samples \(names.count) changes \(changes)\n" + names.joined(separator: "\n")
                        try? report.write(toFile: path, atomically: true, encoding: .utf8)
                        return
                    }
                    let clip = self.scrollView.contentView
                    let top = clip.bounds.minY + clip.contentInsets.top + 1
                    let row = self.tableView.row(at: NSPoint(x: 1, y: top))
                    let name =
                        row >= 0 && row < self.table.rows.count
                        ? self.table.usage(of: self.table.rows[row])?.name ?? "section" : "none"
                    names.append("\(name) @\(Int(self.tableView.rect(ofRow: max(row, 0)).minY - top))")
                }
            }
        }
    #endif
}

/// A row with the system's own selection across its whole width, blue while the list has the keyboard and grey
/// otherwise. It only tells its figures that it is selected, so they drop their shading, which would otherwise break the
/// grey band into pieces.
final class ProcessRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("processRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as ProcessTextCell in subviews { cell.isRowSelected = isSelected }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ProcessTextCell)?.isRowSelected = isSelected
    }
}

/// The arrow keys open and close groups, as in Finder's list, and the context menu's shortcuts work while the table has
/// the keyboard.
final class ProcessTableView: NSTableView {
    enum KeyCommand { case endTask, forceQuit, info }

    var onToggle: ((Bool) -> Void)?
    var onKeyCommand: ((KeyCommand) -> Void)?
    var canSelect: ((Int) -> Bool)?

    /// A click on nothing, between rows or on a section's title lets go of the selection, as in Finder.
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, canSelect?(row) != false else {
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }

    /// Escape lets go of the selection too.
    override func cancelOperation(_ sender: Any?) {
        deselectAll(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .capsLock, .function, .numericPad,
        ])
        let command: KeyCommand? =
            switch (event.specialKey, event.charactersIgnoringModifiers, flags) {
            case (.backspace?, _, [.command]), (.delete?, _, [.command]): .endTask
            case (.backspace?, _, [.command, .option]), (.delete?, _, [.command, .option]): .forceQuit
            case (_, "i"?, [.command]): .info
            default: nil
            }
        guard let command else { return super.performKeyEquivalent(with: event) }
        onKeyCommand?(command)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?: onToggle?(true)
        case .leftArrow?: onToggle?(false)
        default:
            if event.keyCode == 53 {
                deselectAll(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
