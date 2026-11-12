/// Where the keyboard is in Finder, which decides what Command-X and Command-V mean.
public enum FinderFocus: Equatable, Sendable {
    /// A name being edited, the search field, a sheet: these keys belong to the text.
    case text
    /// Anything else, including nothing Accessibility could name. Treating that as files is safe, because Finder
    /// then just copies whatever it would copy, and no cut is noted unless files really reached the pasteboard.
    case files

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public init(role: String?) {
        self = role.map(Self.textRoles.contains) == true ? .text : .files
    }
}

/// Whether Escape is about the files, and so cancels a cut. In a window of files or on the desktop it is; with Quick Look
/// up, a menu open or another of Finder's panels in front, it only closes that, and the cut goes on waiting. Checked on
/// macOS 27.2: with only the desktop, Finder has no focused window and its focus is the group of desktop icons.
public enum FinderEscape {
    private static let menuRoles: Set<String> = ["AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem"]

    public static func isAboutFiles(focusRole: String?, windowSubrole: String?) -> Bool {
        if let focusRole, menuRoles.contains(focusRole) { return false }
        guard let windowSubrole else { return true }
        return windowSubrole == "AXStandardWindow"
    }
}

/// Whether files are waiting to be moved. Finder has no cut of its own, only copying and "Move Item Here", so a cut
/// is a copy this tweak remembers. The pasteboard's change count says whether that copy is still what it holds.
public struct FinderCutState: Equatable, Sendable {
    public enum CutAction: Equatable, Sendable {
        case forward
        case copyFiles
    }

    public enum PasteAction: Equatable, Sendable {
        case forward
        case moveFiles
        /// The press that moved them, repeating. To Finder it would be an ordinary paste of files already moved.
        case ignore
    }

    private var pendingChange: Int?
    /// What the pasteboard held when files were moved, until it has been emptied.
    private var movedChange: Int?

    public init() {}

    /// Whether files are waiting, and the pasteboard still holds them.
    public func isPending(change: Int) -> Bool {
        pendingChange == change
    }

    /// Whether Command-V should still come here, which is also for a moment after the move.
    public func holdsPaste(change: Int) -> Bool {
        pendingChange == change || movedChange == change
    }

    public func actionForCut(focus: FinderFocus) -> CutAction {
        focus == .text ? .forward : .copyFiles
    }

    public mutating func filesCopied(change: Int) {
        pendingChange = change
    }

    public mutating func actionForPaste(focus: FinderFocus, change: Int) -> PasteAction {
        if movedChange == change, focus != .text { return .ignore }
        guard pendingChange == change else {
            // Something else was copied since, so this is an ordinary paste of that.
            pendingChange = nil
            return .forward
        }
        // Pasting into a name being edited leaves the cut waiting.
        guard focus != .text else { return .forward }
        pendingChange = nil
        movedChange = change
        return .moveFiles
    }

    /// The pasteboard has been emptied, or holds something else by now.
    public mutating func finishedMoving() {
        movedChange = nil
    }

    /// Returns whether there was a cut to cancel. Escape in a name being edited only leaves the name, as Command-V there
    /// only pastes into it, and the cut goes on waiting.
    public mutating func cancel(focus: FinderFocus, change: Int) -> Bool {
        guard focus != .text else { return false }
        defer { pendingChange = nil }
        return pendingChange == change
    }
}
