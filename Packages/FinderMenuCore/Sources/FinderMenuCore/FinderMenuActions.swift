/// What a path turned out to be on disk, for deciding where a terminal opens.
public enum FinderItemKind: Sendable {
    case folder
    /// A folder that Finder shows as one file, such as an app.
    case package
    case file
}

public enum TerminalTarget {
    /// The folder to open a terminal in: a folder itself, or the folder that holds a file or an app, as Finder shows
    /// both as single items.
    public static func folder(for path: String, kind: FinderItemKind) -> String {
        switch kind {
        case .folder: path
        case .file, .package: parent(of: path)
        }
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}

public enum CopiedPaths {
    /// One path a line, so several paste as a list.
    public static func text(for paths: [String]) -> String {
        paths.joined(separator: "\n")
    }
}
