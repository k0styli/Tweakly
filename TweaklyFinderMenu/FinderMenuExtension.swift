import AppKit
import FinderMenuCore
import FinderSync

/// Adds New File, Copy Path and Open in Terminal to Finder's shortcut menus.
///
/// Finder keeps this process while the extension is enabled in System Settings, so it holds nothing between menus and
/// asks the agent each time which items to show: with the tweak off or Tweakly not running, it shows none. The work
/// that needs the files themselves is the agent's, as this extension is sandboxed.
final class FinderMenuExtension: FIFinderSync {
    override init() {
        super.init()
        // The shortcut menu is offered only inside these, so the whole disk.
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let place: FinderMenuPlace
        switch menuKind {
        case .contextualMenuForItems: place = .items
        case .contextualMenuForContainer: place = .container
        case .contextualMenuForSidebar: place = .sidebar
        default: return nil
        }
        let items = place.shows(AgentChannel.items())
        guard !items.isEmpty else { return nil }
        let menu = NSMenu(title: "")
        if items.contains(.newFile) {
            menu.addItem(item(String(localized: "New File"), action: #selector(newFile(_:))))
        }
        if items.contains(.copyPath) {
            let action = place == .items ? #selector(copySelectedPaths(_:)) : #selector(copyFolderPath(_:))
            menu.addItem(item(copyTitle(place: place), action: action))
        }
        if items.contains(.openInTerminal) {
            menu.addItem(item(String(localized: "Open in Terminal"), action: #selector(openInTerminal(_:))))
        }
        return menu
    }

    private func copyTitle(place: FinderMenuPlace) -> String {
        let count = place == .items ? FIFinderSyncController.default().selectedItemURLs()?.count ?? 1 : 1
        return count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")
    }

    /// Without an icon, as Finder's own items around them have none.
    private func item(_ title: String, action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard let folder = FIFinderSyncController.default().targetedURL(),
            let name = NewFileName(
                base: String(
                    localized: "untitled file",
                    comment: "The name of a new empty file before the person types one, as Finder's untitled folder"),
                pathExtension: "txt")
        else { return }
        AgentChannel.send(.newFile(folder: folder.path(percentEncoded: false).withoutTrailingSlash, name: name))
    }

    @objc private func copySelectedPaths(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let urls = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        copy(urls)
    }

    @objc private func copyFolderPath(_ sender: NSMenuItem) {
        copy(FIFinderSyncController.default().targetedURL().map { [$0] } ?? [])
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        AgentChannel.send(.openInTerminal(path: target.path(percentEncoded: false).withoutTrailingSlash))
    }

    /// Done here, as the pasteboard is open to a sandboxed process and the agent need not take part.
    private func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let text = CopiedPaths.text(for: urls.map { $0.path(percentEncoded: false).withoutTrailingSlash })
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension String {
    /// Finder hands over folders with a trailing slash, which the agent would refuse as not plain.
    fileprivate var withoutTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
