import Foundation

/// One file or folder that goes with an app, or the app itself.
public struct Leftover: Sendable, Hashable, Identifiable {
    public var path: String
    /// Nil for the app itself.
    public var place: LeftoverPlace?
    /// Nil while it is being measured, and for what cannot be read without Full Disk Access.
    public var size: Int64?
    /// Owned by root or by another user, or in a folder only root can change.
    public var needsAdministrator: Bool
    /// A launchd job this file defines, stopped before it goes.
    public var job: StoppedJob?

    public init(
        path: String, place: LeftoverPlace?, size: Int64? = nil, needsAdministrator: Bool = false,
        job: StoppedJob? = nil
    ) {
        self.path = path
        self.place = place
        self.size = size
        self.needsAdministrator = needsAdministrator
        self.job = job
    }

    public var id: String { path }
    public var category: LeftoverCategory { place?.category ?? .app }
    public var name: String { (path as NSString).lastPathComponent }

    /// The sheet's order: the app, then its data, caches and the rest, the biggest first within each.
    public static func sheetOrder(_ lhs: Leftover, _ rhs: Leftover) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        if (lhs.size ?? -1) != (rhs.size ?? -1) { return (lhs.size ?? -1) > (rhs.size ?? -1) }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

/// A launchd job to stop before its plist goes, or it would run on, and start again, until the next restart.
public struct StoppedJob: Sendable, Hashable {
    public enum Domain: Sendable, Hashable {
        case system
        /// A person's own session, where agents run.
        case user(uid: UInt32)

        var target: String {
            switch self {
            case .system: "system"
            case .user(let uid): "gui/\(uid)"
            }
        }
    }

    public var domain: Domain
    public var plist: String

    public init(domain: Domain, plist: String) {
        self.domain = domain
        self.plist = plist
    }

    /// What `launchctl` takes to stop it.
    public var arguments: [String] { ["bootout", domain.target, plist] }
}

/// The shell script that removes what only an administrator can, run once behind the system's request for a password.
/// It stops the jobs, then moves each item straight into the person's Trash, under the first of its names that is free,
/// as Finder does. Each item is then handed to the person where macOS allows it, so emptying the Trash needs no password;
/// macOS does not allow it inside another app's bundle, which App Management guards even from root, so an App Store app
/// stays root's in the Trash. Nothing is deleted outright.
///
/// The script prints the index and new place of every item it moved, one a line.
public enum AdministratorScript {
    /// - Parameters:
    ///   - firstMustMove: The first item is the app itself, which goes before anything else does, and if it cannot go,
    ///     nothing else does either: an app left in place without its data would be a reset nobody asked for.
    ///   - keepingOwner: Items left root's, as an App Store app, whose bundle macOS will not let even root hand over:
    ///     trying would only walk every file in it.
    public static func removal(
        moving paths: [String], toTrash trash: String, stopping jobs: [StoppedJob], owner uid: UInt32,
        group gid: UInt32, firstMustMove: Bool = false, keepingOwner: Set<Int> = []
    ) -> String {
        var lines: [String] = []
        func move(_ index: Int) {
            let path = paths[index]
            let source = quoted(path)
            let targets = trashNames(for: (path as NSString).lastPathComponent).map { quoted(trash + "/" + $0) }
            // Only what has a single link is handed over: a file linked from elsewhere as well, say a system file
            // someone linked into a folder anyone can write to, stays root's.
            let handOver =
                keepingOwner.contains(index)
                ? ""
                : "/usr/bin/find \"$t\" -xdev \\( -type d -o -type l -o \\( -type f -links 1 \\) \\) "
                    + "-exec /usr/sbin/chown -h \(uid):\(gid) {} + 2>/dev/null; "
            // A name already taken is skipped: `mv` would put the item inside a folder of that name.
            // Only an item that is there: one already gone would read as moved.
            lines.append(
                "if [ -e \(source) ] || [ -L \(source) ]; then for t in \(targets.joined(separator: " ")); do "
                    + "[ -e \"$t\" ] || [ -L \"$t\" ] && continue; /bin/mv -n \(source) \"$t\" 2>/dev/null; "
                    + "if [ ! -e \(source) ] && [ ! -L \(source) ]; then \(handOver)"
                    + "echo \"\(index)\t$t\"; break; fi; done; fi")
        }
        let first = firstMustMove && !paths.isEmpty
        if first {
            move(0)
            let source = quoted(paths[0])
            lines.append("if [ -e \(source) ] || [ -L \(source) ]; then exit 0; fi")
        }
        for job in jobs {
            lines.append("/bin/launchctl \(job.arguments.map(quoted).joined(separator: " ")) 2>/dev/null")
        }
        for index in paths.indices.dropFirst(first ? 1 : 0) { move(index) }
        // A failed move shows by its item still being in place, which the app checks for itself.
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    /// The names an item can take in the Trash, in order: its own, then with a number, as "Xcode 2.app".
    public static func trashNames(for name: String, count: Int = 20) -> [String] {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return [name] + (2...max(count, 2)).map { ext.isEmpty ? "\(stem) \($0)" : "\(stem) \($0).\(ext)" }
    }

    /// The new place of each item the script moved, by its index, from what it printed. `do shell script` gives the
    /// lines back with carriage returns.
    public static func movedItems(in output: String) -> [Int: String] {
        var moved: [Int: String] = [:]
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]) else { continue }
            moved[index] = String(parts[1])
        }
        return moved
    }

    /// In single quotes, which the shell takes literally, with each quote of the text closed, escaped and reopened.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a path is somewhere this tweak may take things from: an app folder, the person's Library, or one of the
    /// system folders apps install into. Never a folder itself, never a path that climbs back up or hides a line break.
    public static func isRemovable(_ path: String, home: String, temporaryCaches: String? = nil) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        var roots = [
            "/Applications", home + "/Applications", home + "/Library", "/Library/LaunchDaemons",
            "/Library/LaunchAgents", "/Library/PrivilegedHelperTools", "/Library/Application Support",
            "/Library/Caches",
            "/Library/Preferences", "/Library/Logs",
        ]
        if let temporaryCaches { roots.append(temporaryCaches) }
        return roots.contains { root in
            guard path.hasPrefix(root + "/") else { return false }
            let inside = path.dropFirst(root.count + 1)
            // From an app folder only apps; in the Library, at least one level below a named folder.
            if root.hasSuffix("/Applications") { return inside.hasSuffix(".app") }
            if root == home + "/Library" { return inside.contains("/") }
            return !inside.isEmpty
        }
    }
}
