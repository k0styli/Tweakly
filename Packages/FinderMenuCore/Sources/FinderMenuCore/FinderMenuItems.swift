/// The items Tweakly can add to Finder's shortcut menu. Each one can be turned off on its own.
public struct FinderMenuItems: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let newFile = FinderMenuItems(rawValue: 1 << 0)
    public static let copyPath = FinderMenuItems(rawValue: 1 << 1)
    public static let openInTerminal = FinderMenuItems(rawValue: 1 << 2)

    public static let all: FinderMenuItems = [.newFile, .copyPath, .openInTerminal]
}

/// Where in Finder the menu was opened, which decides what each item means there.
public enum FinderMenuPlace: Sendable {
    /// One or more selected files or folders.
    case items
    /// The empty space of a folder's window, or the desktop.
    case container
    /// A folder in the sidebar.
    case sidebar

    /// A new file belongs where Finder's own New Folder is: in the folder whose window was clicked.
    public func shows(_ items: FinderMenuItems) -> FinderMenuItems {
        switch self {
        case .container: items
        case .items, .sidebar: items.subtracting(.newFile)
        }
    }
}
