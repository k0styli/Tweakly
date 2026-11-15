import Darwin
import Foundation

/// What is known about one process without its path. Read once, as none of it changes while the process lives.
struct ProcessIdentity: Equatable {
    /// The kernel's name for it, cut to 16 characters: a stand-in for when its path cannot be read.
    var shortName: String
    var parentPID: Int32
    /// Nil when the system would not say.
    var userID: UInt32?
    /// Microseconds since 1970, which tells a process apart from a later one given the same number. Zero when unknown.
    var start: UInt64
}

/// The row a process is counted in: an app with everything that works for it, or a process on its own.
struct ProcessOwner: Hashable {
    enum Key: Hashable {
        case app(String)
        case process(Int32)
    }

    let key: Key

    var bundlePath: String? {
        if case .app(let path) = key { path } else { nil }
    }
}

/// Who each process is and which app it works for, so that the popovers' lists add up an app as the task manager does.
///
/// A process counts towards the app its responsible process counts towards, as macOS sees it, or else towards its
/// parent's, and only failing both towards the app whose bundle it lies in. That gathers an app's helpers, the services
/// launchd starts for it, such as Safari's web content, and the programs it runs with all they run in turn, such as a
/// shell in Terminal. The parent comes before the bundle because a program an app starts may have a bundle of its own:
/// an app may start a tool in `tool.app` through a helper that disclaims responsibility for it.
/// Without the private lookup of the responsible process, grouping goes by the parents and the bundle alone.
///
/// Everything is looked up once a process, and only as far as it is needed: a helper whose parent already names its app
/// never has its own path read, and only the rows on screen get a name. The list stays only while it is on screen.
struct ProcessIdentities {
    /// The system's answers, which a test can stand in for.
    struct Lookups: Sendable {
        var identity: @Sendable (Int32) -> ProcessIdentity?
        var path: @Sendable (Int32) -> String?
        var responsible: @Sendable (Int32) -> Int32?
        var appName: @Sendable (String) -> String

        static let live = Lookups(
            identity: ProcessIdentities.readIdentity(of:),
            path: ProcessIdentities.readPath(of:),
            responsible: ResponsibleProcess.pid(responsibleFor:),
            appName: ProcessIdentities.readAppName(at:)
        )
    }

    /// Deeper than any real chain of parents, and short enough that a loop in stale data ends quickly.
    static let deepestAncestry = 64

    private let lookups: Lookups
    private var known: [Int32: ProcessIdentity] = [:]
    /// Nil inside for a path that could not be read, which is not asked again.
    private var paths: [Int32: String?] = [:]
    private var owners: [Int32: ProcessOwner] = [:]
    private var appNames: [String: String] = [:]

    init(lookups: Lookups = .live) {
        self.lookups = lookups
    }

    mutating func identity(of pid: Int32, fallbackName: String? = nil) -> ProcessIdentity {
        if let identity = known[pid] { return identity }
        let identity =
            lookups.identity(pid) ?? ProcessIdentity(shortName: fallbackName ?? "", parentPID: 0, userID: nil, start: 0)
        known[pid] = identity
        return identity
    }

    mutating func path(of pid: Int32) -> String? {
        if let path = paths[pid] { return path }
        let path = lookups.path(pid)
        paths[pid] = .some(path)
        return path
    }

    mutating func owner(of pid: Int32, fallbackName: String? = nil) -> ProcessOwner {
        _ = identity(of: pid, fallbackName: fallbackName)
        return owner(of: pid, depth: 0)
    }

    private mutating func owner(of pid: Int32, depth: Int) -> ProcessOwner {
        if let owner = owners[pid] { return owner }
        let alone = ProcessOwner(key: .process(pid))
        // No real chain of parents is this long, while stale data can go round in a loop.
        guard depth < Self.deepestAncestry else { return alone }
        var owner: ProcessOwner?
        if let responsible = lookups.responsible(pid), responsible != pid {
            owner = app(owning: responsible, depth: depth + 1)
        }
        // launchd is everyone's parent in the end, and the kernel has none.
        let parent = identity(of: pid).parentPID
        if owner == nil, parent > 1, parent != pid { owner = app(owning: parent, depth: depth + 1) }
        if owner == nil, let bundle = Self.outermostBundle(of: path(of: pid)) {
            owner = ProcessOwner(key: .app(bundle))
        }
        owners[pid] = owner ?? alone
        return owner ?? alone
    }

    /// The app another process counts towards, if it counts towards one at all.
    private mutating func app(owning pid: Int32, depth: Int) -> ProcessOwner? {
        let owner = owner(of: pid, depth: depth)
        return owner.bundlePath == nil ? nil : owner
    }

    /// Forgets processes that are gone, and with them the parents looked up on the way to an app.
    mutating func removeAll(where isGone: (Int32) -> Bool) {
        known = known.filter { !isGone($0.key) }
        paths = paths.filter { !isGone($0.key) }
        owners = owners.filter { !isGone($0.key) }
    }

    /// A row for an owner, given the processes it adds up. The figures are the caller's to fill in.
    mutating func entry(for owner: ProcessOwner, pids: [Int32]) -> ProcessEntry {
        let sorted = pids.sorted()
        // The app's own process, where it is among them: its number is the one that asks the app to quit.
        let bundle = owner.bundlePath
        var headIndex = 0
        var isAppsOwn = false
        if let bundle, let index = sorted.firstIndex(where: { Self.innermostBundle(of: path(of: $0)) == bundle }) {
            headIndex = index
            isAppsOwn = true
        }
        let head = sorted.isEmpty ? 0 : sorted[headIndex]
        var entry = ProcessEntry(
            pid: head, name: name(of: owner), path: sorted.isEmpty ? nil : path(of: head), cpu: 0, memory: 0)
        let ownUser = getuid()
        let ownPID = getpid()
        var allOwn = !sorted.isEmpty
        entry.members = sorted.map { pid in
            let identity = identity(of: pid)
            allOwn = allOwn && pid > 1 && identity.userID == ownUser
            return ProcessMember(pid: pid, start: identity.start)
        }
        entry.bundlePath = bundle
        // An app the person runs quits by its own command and takes care of the rest itself, such as a virtual machine
        // Parallels runs as root. Anything else needs every process to be the person's, to send each a signal.
        let isPersonsApp = isAppsOwn && identity(of: head).userID == ownUser
        entry.canEnd = !sorted.contains(ownPID) && (allOwn || isPersonsApp)
        return entry
    }

    /// Asked only for the rows on screen: Finder's name for an app took about a millisecond, and a Mac runs dozens.
    mutating func name(of owner: ProcessOwner) -> String {
        switch owner.key {
        case .process(let pid):
            if let name = ProcessSampler.displayName(path: path(of: pid)) { return name }
            let short = identity(of: pid).shortName
            return short.isEmpty ? "\(pid)" : short
        case .app(let bundle):
            if let name = appNames[bundle] { return name }
            let name = lookups.appName(bundle)
            appNames[bundle] = name
            return name
        }
    }

    /// The outermost `.app` folder a path lies in. Helpers sit in apps inside the app, and it is the outer one that
    /// people know.
    static func outermostBundle(of path: String?) -> String? {
        guard var path else { return nil }
        // A search byte by byte: Foundation's `range(of:)` took most of the time of grouping in the task manager.
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

    /// The `.app` folder whose `Contents/MacOS` holds this executable: the app's own process rather than a helper.
    static func innermostBundle(of path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[parts.count - 2] == "MacOS", parts[parts.count - 3] == "Contents",
            parts[parts.count - 4].hasSuffix(".app")
        else { return nil }
        return parts[..<(parts.count - 3)].joined(separator: "/")
    }

    /// The parent, the user and the start in one call. Another user's process answers only the short form, without a
    /// start, which is enough to group it but not to end it.
    private static func readIdentity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return ProcessIdentity(
                shortName: withUnsafeBytes(of: info.pbi_comm) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                },
                parentPID: Int32(bitPattern: info.pbi_ppid), userID: info.pbi_uid,
                start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
        }
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { return nil }
        return ProcessIdentity(
            shortName: withUnsafeBytes(of: short.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
            parentPID: Int32(bitPattern: short.pbsi_ppid), userID: short.pbsi_uid, start: 0)
    }

    private static func readPath(of pid: Int32) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN) * 4) { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            let length = proc_pidpath(pid, base, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: base, count: Int(length)), as: UTF8.self)
        }
    }

    /// The name Finder shows, in the language the app runs in.
    private static func readAppName(at bundle: String) -> String {
        let name = FileManager.default.displayName(atPath: bundle)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Whether the number still names the process that started then. A process that has ended may have handed its
    /// number to a newer one, which must be left alone.
    static func isRunning(_ member: ProcessMember) -> Bool {
        guard member.start != 0 else { return true }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(member.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec) == member.start
    }
}
