import Darwin
import Foundation
import UninstallerCore
import os

/// Finds each app's files in the Library folders. Each folder is listed once for all apps, and only names are read, so
/// the whole Mac takes a fraction of a second; sizes come after, from `LeftoverSizer`.
///
/// Inside a container nothing is read without Full Disk Access: macOS protects other apps' data and would ask the
/// person each time. The containers' own names are not protected, and they say whose each is.
nonisolated enum LeftoverScanner {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "uninstaller")

    /// Each app's files, by the app's path.
    static func scan(_ catalog: AppCatalog, home: String, readsContainers: Bool) -> [String: [Leftover]] {
        let identities = catalog.apps.map(\.identity)
        let matcher = LeftoverMatcher(
            apps: identities, foreignIDs: catalog.foreignIDs, foreignNames: catalog.foreignNames)
        let uid = getuid()
        var found: [Int: [Leftover]] = [:]
        var claimedHelpers: [String: Int] = [:]
        let manager = FileManager.default

        func add(_ owner: Int, path: String, place: LeftoverPlace, job: StoppedJob? = nil) {
            let isContainer = place == .containers || place == .groupContainers
            guard !isProtected(path, isContainer: isContainer),
                AdministratorScript.isRemovable(path, home: home, temporaryCaches: temporaryCaches)
            else { return }
            let leftover = Leftover(
                path: path, place: place, needsAdministrator: place.isSystem || !canMove(path), job: job)
            found[owner, default: []].append(leftover)
        }

        for place in LeftoverPlace.allCases {
            guard let folder = folder(of: place, home: home),
                let entries = try? manager.contentsOfDirectory(atPath: folder)
            else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = folder + "/" + entry
                if place.holdsJobs {
                    guard entry.hasSuffix(".plist") else { continue }
                    let job = LaunchJob(plist: (NSDictionary(contentsOfFile: path) as? [String: Any]) ?? [:])
                    guard let owner = matcher.owner(ofJob: job, fileName: entry, in: place) else { continue }
                    let domain: StoppedJob.Domain = place == .systemLaunchDaemons ? .system : .user(uid: uid)
                    add(owner, path: path, place: place, job: StoppedJob(domain: domain, plist: path))
                    if let program = job.program, program.hasPrefix(helperTools + "/") {
                        claimedHelpers[helperItem(of: program)] = owner
                    }
                    continue
                }
                if let owner = matcher.owner(of: entry, in: place) {
                    add(owner, path: path, place: place)
                } else if place == .containers, readsContainers, let id = containerID(at: path),
                    let owner = matcher.owner(of: id, in: place)
                {
                    // Containers of newer apps are named by a UUID, with the app's id inside.
                    add(owner, path: path, place: place)
                } else if place == .applicationSupport || place == .systemApplicationSupport,
                    matcher.isVendorFolder(entry)
                {
                    for child in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where !child.hasPrefix(".") {
                        if let owner = matcher.owner(ofVendorChild: child, vendorFolder: entry) {
                            add(owner, path: path + "/" + child, place: place)
                        }
                    }
                }
            }
        }
        // A helper a claimed job runs is the same app's, whatever its name.
        for (helper, owner) in claimedHelpers where manager.fileExists(atPath: helper) {
            if !(found[owner] ?? []).contains(where: { $0.path == helper }) {
                add(owner, path: helper, place: .privilegedHelperTools)
            }
        }
        var byApp: [String: [Leftover]] = [:]
        for (owner, leftovers) in found {
            byApp[identities[owner].path] = leftovers
        }
        return byApp
    }

    /// The per-user cache folder under `/private/var/folders`, which has no fixed path.
    static let temporaryCaches: String? = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).resolvingSymlinksInPath.trimmingSuffix("/")
    }()

    private static let helperTools = "/Library/PrivilegedHelperTools"

    private static func folder(of place: LeftoverPlace, home: String) -> String? {
        if place == .temporaryCaches { return temporaryCaches }
        guard let path = place.path else { return nil }
        return place.isSystem ? path : home + "/" + path
    }

    /// The first item under `/Library/PrivilegedHelperTools` that a job's program lies in: the tool itself, or the
    /// bundle around it.
    private static func helperItem(of program: String) -> String {
        let root = helperTools + "/"
        let rest = program.dropFirst(root.count)
        return root + (rest.split(separator: "/").first.map(String.init) ?? String(rest))
    }

    /// The app id a UUID-named container records for itself.
    private static func containerID(at path: String) -> String? {
        let metadata = path + "/.com.apple.containermanagerd.metadata.plist"
        return (NSDictionary(contentsOfFile: metadata) as? [String: Any])?["MCMMetadataIdentifier"] as? String
    }

    /// What macOS keeps for itself even from root: a file with the restricted or no-unlink flag, or under System
    /// Integrity Protection. Moving one to the Trash leaves it there for good, as a cleaner found on macOS 27.0.1.
    /// A container's attributes are left unread, as macOS guards what lies inside other apps' containers.
    static func isProtected(_ path: String, isContainer: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        if info.st_flags & UInt32(SF_RESTRICTED | SF_NOUNLINK) != 0 { return true }
        return !isContainer && getxattr(path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Whether the person can move the item themselves. A folder needs its own write permission too, as moving it
    /// rewrites its link to the folder above.
    ///
    /// Judged from the owner and mode bits rather than `access`, which also says no for a container macOS guards from
    /// other apps. That one is the person's own: macOS asks them, it takes no password.
    static func canMove(_ path: String) -> Bool {
        var parent = stat()
        var item = stat()
        let parentPath = (path as NSString).deletingLastPathComponent
        guard lstat(parentPath, &parent) == 0, lstat(path, &item) == 0, canWrite(parent) else { return false }
        if (item.st_mode & S_IFMT) == S_IFDIR, !canWrite(item) { return false }
        // In a folder with the sticky bit, as /tmp, only the owner moves an item.
        return item.st_uid == getuid() || (parent.st_mode & S_ISVTX) == 0
    }

    private static func canWrite(_ info: stat) -> Bool {
        let uid = getuid()
        if uid == 0 { return true }
        if info.st_uid == uid { return info.st_mode & S_IWUSR != 0 }
        if isMember(of: info.st_gid) { return info.st_mode & S_IWGRP != 0 }
        return info.st_mode & S_IWOTH != 0
    }

    private static func isMember(of group: gid_t) -> Bool {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return getgid() == group || groups.prefix(Int(max(count, 0))).contains(group)
    }
}

/// Sizes of what an app keeps, as the space it takes on disk. Every file is counted once, including the hard links
/// some apps make between versions.
nonisolated enum LeftoverSizer {
    /// Nil for what cannot be read: a container without Full Disk Access.
    static func size(of leftover: Leftover, readsContainers: Bool) -> Int64? {
        if !readsContainers, leftover.place == .containers || leftover.place == .groupContainers { return nil }
        return size(of: leftover.path)
    }

    static func size(of path: String) -> Int64 {
        var total: Int64 = 0
        var seen = Set<UInt64>()
        path.withCString { pointer in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(pointer), nil]
            defer { free(paths[0]) }
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                let info = Int32(entry.pointee.fts_info)
                guard info == FTS_F || info == FTS_SL || info == FTS_D, let stat = entry.pointee.fts_statp else {
                    continue
                }
                if info == FTS_F, stat.pointee.st_nlink > 1, !seen.insert(stat.pointee.st_ino).inserted { continue }
                total += Int64(stat.pointee.st_blocks) * 512
            }
        }
        return total
    }
}

extension String {
    nonisolated fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
