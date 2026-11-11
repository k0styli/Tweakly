import AppKit
import CoreServices
import Security
import UninstallerCore
import os

/// An app that can be removed, as the table shows it.
nonisolated struct InstalledApp: Identifiable, Sendable, Hashable {
    let identity: AppIdentity
    let name: String
    let kind: AppKind
    let isAppStore: Bool
    let lastOpened: Date?
    /// Spotlight's figure, which System Settings shows too, or measured when Spotlight has none.
    var size: Int64?
    /// A second copy of an app that is also installed, as System Settings marks it: the one opened less recently.
    var isDuplicate = false

    var id: String { identity.path }
}

/// Every app in the app folders, and what the Mac's other apps are called, so that their files are never taken for
/// the removed app's: those of macOS, and copies elsewhere, such as a second Firefox in Downloads.
///
/// Spotlight gives each app's size, last use and processors at once, as it does for System Settings, so the table
/// fills without reading the 180 000 files inside the apps, which took 3–4 seconds on a MacBook Air M2.
nonisolated struct AppCatalog: Sendable {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "uninstaller")

    var apps: [InstalledApp] = []
    var foreignIDs: Set<String> = []
    var foreignNames: Set<String> = []
    /// Every copy of each app the Mac has, by its id in lower case: those in the list and those elsewhere. Copies share
    /// their files, so while another one is there, they stay.
    private var copies: [String: [String]] = [:]

    /// - Parameter extra: apps someone dropped on the page from elsewhere, such as a disk image or Downloads.
    static func read(home: String, extra: [URL] = []) -> AppCatalog {
        let folders = appBundles(in: ["/Applications", home + "/Applications"])
        let listed = Set(folders.map(\.path))
        let urls = folders + extra.filter { !listed.contains($0.path) && mayList(dropped: $0) }
        let apps = OSAllocatedUnfairLock(initialState: [InstalledApp?](repeating: nil, count: urls.count))
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let app = installedApp(at: urls[index])
            apps.withLock { $0[index] = app }
        }
        var catalog = AppCatalog()
        catalog.apps = markDuplicates(apps.withLock { $0 }.compactMap { $0 })
        for app in catalog.apps { catalog.copies[app.identity.bundleID.lowercased(), default: []].append(app.id) }
        catalog.readOtherApps(besides: Set(catalog.apps.map(\.identity.path)))
        return catalog
    }

    /// Another copy of the app, whose files are its too.
    func otherCopy(of app: InstalledApp) -> String? {
        copies[app.identity.bundleID.lowercased()]?.first { $0 != app.id }
    }

    /// Apps in the folders and one level of folders below, as `/Applications/Utilities`. Links, such as Safari's into
    /// the system volume, and Tweakly itself are left out.
    private static func appBundles(in folders: [String]) -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        for folder in folders {
            let root = URL(fileURLWithPath: folder)
            for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard !isLink(entry) else { continue }
                if entry.pathExtension == "app" {
                    found.append(entry)
                } else if isFolder(entry) {
                    for inner in (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    where inner.pathExtension == "app" && !isLink(inner) {
                        found.append(inner)
                    }
                }
            }
        }
        return found
    }

    /// Whether an app dropped on the page from elsewhere may be listed. The app folders are read with the same rules:
    /// no link, such as Safari's into the system volume; nothing of macOS's own; no app inside another, as Simulator in
    /// Xcode or a login item, which would break the app around it; nothing on a disk that cannot be written to, as a
    /// mounted disk image.
    static func mayList(dropped url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard url.pathExtension == "app", !path.hasPrefix("/System/"), !isLink(url) else { return false }
        let parent = (path as NSString).deletingLastPathComponent.lowercased()
        guard !parent.contains(".app/"), !parent.hasSuffix(".app") else { return false }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly != true
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    private static func installedApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !isTweakly(bundleID) else {
            return nil
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        var names = [fileName]
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String, !names.contains(name) {
                names.append(name)
            }
        }
        let signing = signingInfo(of: url)
        let identity = AppIdentity(
            path: url.path, bundleID: bundleID, names: names, teamID: signing.team, groups: signing.groups,
            embeddedIDs: embeddedIDs(in: bundle))
        let metadata = MDItemCreateWithURL(nil, url as CFURL)
        func attribute<T>(_ name: CFString) -> T? {
            guard let metadata else { return nil }
            return MDItemCopyAttribute(metadata, name) as? T
        }
        let architectures: [String] =
            attribute(kMDItemExecutableArchitectures)
            ?? (bundle.executableArchitectures ?? []).compactMap { Self.architectureName($0.intValue) }
        let hasReceipt: Bool =
            attribute("kMDItemAppStoreHasReceipt" as CFString)
            ?? FileManager.default.fileExists(atPath: url.path + "/Contents/_MASReceipt/receipt")
        var displayName = FileManager.default.displayName(atPath: url.path)
        // Finder shows the extension where the person asked it to; the list never does.
        if displayName.hasSuffix(".app") { displayName.removeLast(4) }
        let size: NSNumber? = attribute("kMDItemPhysicalSize" as CFString)
        return InstalledApp(
            identity: identity, name: displayName, kind: AppKind(architectures: architectures),
            isAppStore: hasReceipt, lastOpened: attribute(kMDItemLastUsedDate), size: size.map(\.int64Value))
    }

    /// Tweakly and its test copies, which remove themselves differently.
    private static func isTweakly(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return id == "me.tweakly.Tweakly" || id.hasPrefix("me.tweakly.Tweakly.")
    }

    private static func architectureName(_ type: Int) -> String? {
        switch type {
        case NSBundleExecutableArchitectureARM64: "arm64"
        case NSBundleExecutableArchitectureX86_64: "x86_64"
        default: nil
        }
    }

    /// The team and the app groups from the signature. Only the signature's own data is read; nothing is verified.
    private static func signingInfo(of url: URL) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let info = info as? [String: Any]
        else { return (nil, []) }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (info[kSecCodeInfoTeamIdentifier as String] as? String, groups)
    }

    /// Ids of what an app carries: its extensions, services, login items, helpers and the apps inside it, each with
    /// files of its own named after it. Only the folders where these live are read, never the whole bundle, which for
    /// Xcode holds over 100 000 files.
    private static func embeddedIDs(in bundle: Bundle) -> [String] {
        let manager = FileManager.default
        let contents = bundle.bundleURL.appending(path: "Contents")
        var ids: [String] = []
        let bundleFolders = [
            "PlugIns", "XPCServices", "Library/LoginItems", "Library/SystemExtensions", "Helpers", "Frameworks",
            "MacOS", "Applications",
        ]
        for folder in bundleFolders {
            let url = contents.appending(path: folder)
            for entry in (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            where ["app", "appex", "xpc", "systemextension"].contains(entry.pathExtension) {
                if let id = Bundle(url: entry)?.bundleIdentifier { ids.append(id) }
            }
        }
        // Privileged helpers are named after their labels, and the app lists them for the system to check.
        let services = contents.appending(path: "Library/LaunchServices")
        ids += (try? manager.contentsOfDirectory(atPath: services.path)) ?? []
        if let helpers = bundle.object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: Any] {
            ids += helpers.keys
        }
        for folder in ["Library/LaunchAgents", "Library/LaunchDaemons"] {
            let url = contents.appending(path: folder)
            for entry in (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            where entry.pathExtension == "plist" {
                if let label = (NSDictionary(contentsOf: entry) as? [String: Any])?["Label"] as? String {
                    ids.append(label)
                }
            }
        }
        return ids.filter { $0.contains(".") && !$0.hasPrefix(".") }
    }

    /// Of several copies of one app, the one opened last is the app and the others are its duplicates.
    private static func markDuplicates(_ apps: [InstalledApp]) -> [InstalledApp] {
        let groups = Dictionary(grouping: apps.indices) { apps[$0].identity.bundleID.lowercased() }
        var marked = apps
        for indices in groups.values where indices.count > 1 {
            let ordered = indices.sorted {
                (apps[$0].lastOpened ?? .distantPast) > (apps[$1].lastOpened ?? .distantPast)
            }
            for index in ordered.dropFirst() { marked[index].isDuplicate = true }
        }
        return marked
    }

    /// Every other app Spotlight knows on this Mac's own disks: macOS's, those inside other apps, and copies kept
    /// elsewhere. What carries their names stays.
    private mutating func readOtherApps(besides listed: Set<String>) {
        let query = MDQueryCreate(
            kCFAllocatorDefault, "kMDItemContentType == 'com.apple.application-bundle'" as CFString,
            [kMDItemCFBundleIdentifier, kMDItemFSName, kMDItemDisplayName] as CFArray, nil)
        guard let query else { return }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            Self.log.error("Spotlight did not list the apps, so only the app folders guard against mistakes")
            return
        }
        let listedFolders = listed.map { $0 + "/" }
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                !listed.contains(path), !path.hasPrefix("/Volumes/"),
                !listedFolders.contains(where: path.hasPrefix)
            else { continue }
            if let id = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String {
                foreignIDs.insert(id.lowercased())
                if copies[id.lowercased()] != nil { copies[id.lowercased(), default: []].append(path) }
            }
            for attribute in [kMDItemFSName, kMDItemDisplayName] {
                guard let name = MDItemCopyAttribute(item, attribute) as? String else { continue }
                let key = NameKey.key((name as NSString).deletingPathExtension)
                if NameKey.isDistinctive(key) { foreignNames.insert(key) }
            }
        }
    }
}
