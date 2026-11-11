import AppKit
import TaskManagerCore

/// What Get Info shows about a process or an app, in a popover by its row: the figures of the table and where the
/// program lives. It follows the table's updates while it is open.
final class ProcessInfoViewController: NSViewController {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private var values: [String: NSTextField] = [:]
    private static let order = [
        "pid", "parent", "user", "kind", "architecture", "processes", "cpu", "cpuTime", "memory", "threads", "disk",
        "network", "gpu", "path",
    ]

    override func loadView() {
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        nameLabel.lineBreakMode = .byTruncatingTail
        let header = NSStackView(views: [icon, nameLabel])
        header.spacing = 8
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        grid.rowSpacing = 5
        grid.columnSpacing = 10
        for key in Self.order {
            let label = NSTextField(labelWithString: Self.label(for: key))
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            // The names set the column's width, and the values give way to them.
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            let value = NSTextField(labelWithString: "")
            value.isSelectable = true
            value.lineBreakMode = key == "path" ? .byTruncatingMiddle : .byTruncatingTail
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            values[key] = value
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 280
        grid.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = stack
    }

    private static func label(for key: String) -> String {
        switch key {
        case "pid": String(localized: "Process ID")
        case "parent": String(localized: "Parent Process")
        case "user": TaskColumn.user.title
        case "kind": TaskColumn.kind.title
        case "architecture": TaskColumn.architecture.title
        case "processes": String(localized: "Processes")
        case "cpu": TaskColumn.cpu.title
        case "cpuTime": TaskColumn.cpuTime.title
        case "memory": TaskColumn.memory.title
        case "threads": TaskColumn.threads.title
        case "disk": TaskColumn.disk.title
        case "network": TaskColumn.network.title
        case "gpu": TaskColumn.gpu.title
        default: String(localized: "Location")
        }
    }

    func show(
        usage: ProcessUsage, section: ProcessSection, group: ProcessGroup?, image: NSImage, parentName: String?,
        userNames: [UInt32: String]
    ) {
        _ = view
        if icon.image !== image { icon.image = image }
        set(nameLabel, usage.name)
        func text(_ column: TaskColumn) -> String {
            ProcessText.value(of: column, usage, section: section, userNames: userNames) ?? ProcessText.unknown
        }
        let head = group?.head ?? usage
        set("pid", String(head.pid))
        set("parent", parentName.map { "\($0) (\(head.parentPID))" } ?? String(head.parentPID))
        set("user", text(.user))
        set("kind", text(.kind))
        set("architecture", text(.architecture))
        set("processes", String(group?.processCount ?? 1))
        set("cpu", text(.cpu))
        set("cpuTime", text(.cpuTime))
        set("memory", text(.memory))
        set("threads", text(.threads))
        let read = text(.diskRead)
        let written = text(.diskWrite)
        set("disk", String(localized: "\(read) read, \(written) written"))
        let received = text(.received)
        let sent = text(.sent)
        set("network", String(localized: "\(received) in, \(sent) out"))
        set("gpu", text(.gpu))
        let path = head.path.map { ProcessGrouping.outermostBundle(of: $0) ?? $0 }
        set("path", path ?? ProcessText.unknown)
        // A group's own number would only repeat the app's, so it is shown for groups alone. Threads are read only while
        // their column is shown.
        grid.row(at: Self.order.firstIndex(of: "processes") ?? 0).isHidden = (group?.processCount ?? 1) < 2
        grid.row(at: Self.order.firstIndex(of: "threads") ?? 0).isHidden = usage.threads == nil
    }

    private func set(_ key: String, _ text: String) {
        if let field = values[key] { set(field, text) }
    }

    private func set(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }
}
