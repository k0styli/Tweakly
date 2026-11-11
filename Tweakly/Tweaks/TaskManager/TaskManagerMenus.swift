import AppKit
import TaskManagerCore

/// The table's context menu and its header's menu of columns, which go to the table.
enum TaskManagerMenus {
    static func addColumnItems(to menu: NSMenu, target: ProcessesViewController) {
        for column in TaskColumn.allCases where column.canBeHidden {
            let item = menu.addItem(
                withTitle: column.title, action: #selector(ProcessesViewController.toggleColumn(_:)), keyEquivalent: "")
            item.representedObject = column.rawValue
            item.target = target
            item.state = target.isShown(column) ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Restore Default Columns"),
            action: #selector(ProcessesViewController.restoreDefaultColumns(_:)), keyEquivalent: ""
        ).target = target
    }

    static func addProcessItems(to menu: NSMenu, target: ProcessesViewController) {
        menu.addItem(
            withTitle: String(localized: "End Task"), action: #selector(ProcessesViewController.endTask(_:)),
            keyEquivalent: "\u{8}"
        ).target = target
        let force = menu.addItem(
            withTitle: String(localized: "Force Quit"), action: #selector(ProcessesViewController.forceQuit(_:)),
            keyEquivalent: "\u{8}")
        force.keyEquivalentModifierMask = [.command, .option]
        force.target = target
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Get Info"), action: #selector(ProcessesViewController.showInfo(_:)),
            keyEquivalent: "i"
        ).target = target
        let finder = menu.addItem(
            withTitle: String(localized: "Show in Finder"), action: #selector(ProcessesViewController.showInFinder(_:)),
            keyEquivalent: "r")
        finder.keyEquivalentModifierMask = [.command, .shift]
        finder.target = target
    }
}
