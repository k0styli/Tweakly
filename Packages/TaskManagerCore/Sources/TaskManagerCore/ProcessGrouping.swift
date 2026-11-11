/// A running app as the system knows it, which is what a group forms around.
public struct AppIdentity: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// The `.app` folder, if it has one.
    public var bundlePath: String?
    /// It has a Dock icon and menus, which puts it in Apps rather than in Background Processes, as in Windows.
    public var isRegular: Bool

    public init(pid: Int32, name: String, bundlePath: String?, isRegular: Bool) {
        self.pid = pid
        self.name = name
        self.bundlePath = bundlePath
        self.isRegular = isRegular
    }
}

/// The three parts of the list, as in Windows: apps with a window, background processes of programs that were installed,
/// and the processes of macOS itself.
public enum ProcessSection: Int, Sendable, CaseIterable, Comparable {
    case apps, background, system

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An app with every process that works for it, or a process on its own.
public struct ProcessGroup: Sendable, Equatable, Identifiable {
    public var section: ProcessSection
    public var name: String
    public var head: ProcessUsage
    /// The helpers and child processes, without the head.
    public var members: [ProcessUsage]
    /// The head and its members added up, under the group's name.
    public var total: ProcessUsage

    public var id: ProcessKey { head.key }
    public var processCount: Int { members.count + 1 }

    public init(section: ProcessSection, name: String, head: ProcessUsage, members: [ProcessUsage]) {
        self.section = section
        self.name = name
        self.head = head
        self.members = members
        total = Self.total(of: head, members: members, name: name)
    }

    static func total(of head: ProcessUsage, members: [ProcessUsage], name: String) -> ProcessUsage {
        var total = head
        total.name = name
        for member in members {
            total.cpu = add(total.cpu, member.cpu)
            total.cpuTime = add(total.cpuTime, member.cpuTime)
            total.memory = add(total.memory, member.memory)
            total.diskReadRate = add(total.diskReadRate, member.diskReadRate)
            total.diskWriteRate = add(total.diskWriteRate, member.diskWriteRate)
            total.gpu = add(total.gpu, member.gpu).map { min($0, 1) }
            total.receiveRate = add(total.receiveRate, member.receiveRate)
            total.sendRate = add(total.sendRate, member.sendRate)
            total.threads = add(total.threads, member.threads)
        }
        return total
    }

    /// What is known adds up. Nothing known stays nothing, rather than reading as zero.
    private static func add<Value: AdditiveArithmetic>(_ left: Value?, _ right: Value?) -> Value? {
        guard left != nil || right != nil else { return nil }
        return (left ?? .zero) + (right ?? .zero)
    }
}

/// Puts each app's helpers into the app's row, as Windows does, where Activity Monitor only nests processes under the one
/// that started them.
///
/// A process belongs to an app when the system names the app responsible for it, when the app started it or started what
/// started it, or when it lives inside the app's bundle. The first catches services that launchd starts for an app, the
/// second a shell in Terminal or a renderer in a browser, and the third a crash reporter started on its own.
public enum ProcessGrouping {
    /// Deeper than any real chain of parents, and short enough that a loop in stale data ends quickly.
    static let deepestAncestry = 64

    /// `user` is the person running the task manager: a process of anyone else belongs to the system.
    public static func groups(
        of processes: [ProcessUsage], apps: [Int32: AppIdentity], responsible: [Int32: Int32] = [:], user: UInt32 = 501
    ) -> [ProcessGroup] {
        var byPID: [Int32: ProcessUsage] = [:]
        byPID.reserveCapacity(processes.count)
        for var process in processes {
            // A helper the system knows as an app has a better name there, such as Firefox's web content processes.
            if let app = apps[process.pid] { process.name = app.name }
            byPID[process.pid] = process
        }
        let regular = Set(byPID.keys.filter { apps[$0]?.isRegular == true })
        let regularForBundle = headsForBundles(regular, apps: apps)

        // An app without a Dock icon heads a group of its own in Background Processes, unless it works for an app in
        // the Dock, as a browser's helper apps do.
        var heads = regular
        for (pid, app) in apps where !app.isRegular {
            guard let process = byPID[pid] else { continue }
            let owner =
                owner(of: process, heads: regular, byPID: byPID, responsible: responsible)
                ?? outermostBundle(of: process.path).flatMap { regularForBundle[$0] }
            if owner == nil { heads.insert(pid) }
        }
        let headForBundle = headsForBundles(heads, apps: apps)

        var members: [Int32: [ProcessUsage]] = [:]
        var loners: [ProcessUsage] = []
        for process in byPID.values where !heads.contains(process.pid) {
            if let head = owner(of: process, heads: heads, byPID: byPID, responsible: responsible)
                ?? outermostBundle(of: process.path).flatMap({ headForBundle[$0] })
            {
                members[head, default: []].append(process)
            } else {
                loners.append(process)
            }
        }

        var groups: [ProcessGroup] = []
        groups.reserveCapacity(heads.count + loners.count)
        for pid in heads {
            guard let head = byPID[pid], let app = apps[pid] else { continue }
            let section: ProcessSection = app.isRegular ? .apps : isSystem(head, user: user) ? .system : .background
            groups.append(ProcessGroup(section: section, name: app.name, head: head, members: members[pid] ?? []))
        }
        for loner in loners {
            let section: ProcessSection = isSystem(loner, user: user) ? .system : .background
            groups.append(ProcessGroup(section: section, name: loner.name, head: loner, members: []))
        }
        return groups
    }

    /// Where macOS keeps its own programs. `/usr/local` is where people install theirs.
    static let systemFolders = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/"]

    /// A process of macOS: another user's, such as root's, or one whose program lives in the system's own folders, as
    /// Dock and Control Center do. A process whose program cannot be named is the kernel's or the system's too.
    public static func isSystem(_ process: ProcessUsage, user: UInt32) -> Bool {
        guard process.userID == user, let path = process.path else { return true }
        if path.hasPrefix("/usr/local/") { return false }
        return systemFolders.contains { path.hasPrefix($0) }
    }

    /// The head for each app bundle. An app in the Dock wins over an agent from the same bundle, such as a menu bar
    /// helper app, and the lower process number wins otherwise, so the choice holds from one update to the next.
    private static func headsForBundles(_ heads: Set<Int32>, apps: [Int32: AppIdentity]) -> [String: Int32] {
        var result: [String: Int32] = [:]
        for pid in heads.sorted() {
            guard let app = apps[pid], let bundle = app.bundlePath else { continue }
            if let existing = result[bundle], apps[existing]?.isRegular == true || !app.isRegular { continue }
            result[bundle] = pid
        }
        return result
    }

    private static func owner(
        of process: ProcessUsage, heads: Set<Int32>, byPID: [Int32: ProcessUsage], responsible: [Int32: Int32]
    ) -> Int32? {
        if let named = responsible[process.pid], named != process.pid, heads.contains(named) { return named }
        var parent = process.parentPID
        for _ in 0..<deepestAncestry {
            // launchd is everyone's parent in the end, and the kernel has none.
            guard parent > 1, parent != process.pid else { return nil }
            if heads.contains(parent) { return parent }
            guard let next = byPID[parent] else { return nil }
            parent = next.parentPID
        }
        return nil
    }

    /// The outermost `.app` folder a path lies in. Helpers sit in apps inside the app, and it is the outer one that
    /// people know.
    public static func outermostBundle(of path: String?) -> String? {
        guard var path else { return nil }
        // A search byte by byte: Foundation's `range(of:)` took more than half the time of grouping 500 processes.
        let end = path.withUTF8 { bytes -> Int? in
            guard bytes.count >= 5 else { return nil }
            for index in 0...(bytes.count - 5)
            where bytes[index] == 0x2E && bytes[index + 1] == 0x61 && bytes[index + 2] == 0x70
                && bytes[index + 3] == 0x70 && bytes[index + 4] == 0x2F
            {
                return index + 4
            }
            return nil
        }
        guard let end else { return nil }
        return String(decoding: path.utf8.prefix(end), as: UTF8.self)
    }

    /// The innermost `.app` folder whose `Contents/MacOS` holds this executable, for the name and icon a helper app has
    /// of its own, such as Google Chrome Helper (Renderer).
    public static func innermostBundle(of path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[parts.count - 2] == "MacOS", parts[parts.count - 3] == "Contents",
            parts[parts.count - 4].hasSuffix(".app")
        else { return nil }
        return parts[..<(parts.count - 3)].joined(separator: "/")
    }
}
