import Foundation

/// Says which app a file in the Library belongs to. An entry is an app's only when exactly one app can claim it: a
/// container two apps share, or data that another copy of the app still uses, stays where it is.
///
/// Built from every app that can be removed, plus the ids and names of the apps that cannot or live elsewhere, such as
/// those of macOS, so that "Music" or another copy of Firefox is never taken for the app being removed.
public struct LeftoverMatcher: Sendable {
    private let apps: [AppIdentity]
    private var idOwners: [String: Set<Int>] = [:]
    private var groupOwners: [String: Set<Int>] = [:]
    private var nameOwners: [String: Set<Int>] = [:]
    private var vendorNames: [String: [String: Set<Int>]] = [:]
    private let foreignIDs: Set<String>
    private let foreignNames: Set<String>

    /// Ids end with one of these when they belong to an edition of an app installed apart from it, such as Chrome
    /// Canary next to Chrome. Its files are not the app's, even if that edition is gone.
    private static let editionMarkers: Set<String> = [
        "beta", "canary", "nightly", "dev", "developer", "insiders", "preview", "alpha", "edu", "debug", "test",
        "staging", "ptb", "setapp", "lite", "pro", "free", "trial",
    ]

    /// - Parameters:
    ///   - apps: the apps that can be removed, each a candidate owner.
    ///   - foreignIDs: ids of other apps on the Mac, none of which is being removed.
    ///   - foreignNames: their names, as found by `NameKey.key`.
    public init(apps: [AppIdentity], foreignIDs: Set<String> = [], foreignNames: Set<String> = []) {
        self.apps = apps
        self.foreignIDs = Set(foreignIDs.map { $0.lowercased() })
        self.foreignNames = foreignNames
        for (index, app) in apps.enumerated() {
            for id in app.ownedIDs { idOwners[id.lowercased(), default: []].insert(index) }
            for group in app.groups { groupOwners[group.lowercased(), default: []].insert(index) }
            for key in app.nameKeys {
                nameOwners[key, default: []].insert(index)
                if let vendor = app.vendorKey { vendorNames[vendor, default: [:]][key, default: []].insert(index) }
            }
        }
    }

    /// The app an entry of a place belongs to, if exactly one does.
    public func owner(of entry: String, in place: LeftoverPlace) -> Int? {
        let stem = place.stem(of: entry)
        // A group two apps declare is theirs together, and stays while either does.
        if place.matchesGroups, let owners = groupOwners[stem.lowercased()] { return Self.single(owners) }
        if let owner = idOwner(stem) { return owner }
        if let owner = teamPrefixedOwner(stem) { return owner }
        if place.matchesNames, let owner = nameOwner(stem) { return owner }
        return nil
    }

    /// The app a folder inside a company's folder belongs to, as "Application Support/Google/Chrome".
    public func owner(ofVendorChild child: String, vendorFolder: String) -> Int? {
        let key = NameKey.key(child)
        guard NameKey.isDistinctive(key), !foreignNames.contains(key),
            let names = vendorNames[NameKey.key(vendorFolder)]
        else { return nil }
        return Self.single(names[key])
    }

    /// Whether a folder can be a company's folder worth looking into.
    public func isVendorFolder(_ name: String) -> Bool { vendorNames[NameKey.key(name)] != nil }

    /// The app a launchd job belongs to: the one whose bundle it runs from, the one it names as its own, or the one its
    /// label or file name says.
    public func owner(ofJob job: LaunchJob, fileName: String, in place: LeftoverPlace) -> Int? {
        if let program = job.program {
            let inside = apps.indices.filter { program.hasPrefix(apps[$0].path + "/") }
            if inside.count == 1 { return inside[0] }
        }
        let named = Set(
            job.associatedBundleIDs.flatMap { id in
                apps.indices.filter { apps[$0].bundleID.caseInsensitiveCompare(id) == .orderedSame }
            })
        if !job.associatedBundleIDs.isEmpty {
            // A job that names its app belongs to that one alone, whatever its label says.
            return Self.single(named)
        }
        if let label = job.label, let owner = idOwner(label) { return owner }
        return owner(of: fileName, in: place)
    }

    // MARK: Rules

    /// The app whose id the stem is, or begins with at a dot: `com.figma.Desktop.ShipIt` is Figma's. The longest id
    /// wins, and an id of an app that stays, or of another edition, stops the search.
    private func idOwner(_ stem: String) -> Int? {
        var candidate = stem.lowercased()
        let isApples = candidate.hasPrefix("com.apple.")
        while true {
            if foreignIDs.contains(candidate) { return nil }
            if let owners = idOwners[candidate] {
                guard let owner = Self.single(owners) else { return nil }
                // macOS's own files are never another app's, whatever it carries inside.
                if isApples, !apps[owner].isApple { return nil }
                return owner
            }
            guard let dot = candidate.lastIndex(of: "."), candidate[..<dot].contains(".") else { return nil }
            if Self.editionMarkers.contains(String(candidate[candidate.index(after: dot)...])) { return nil }
            candidate = String(candidate[..<dot])
        }
    }

    /// A group container named with the team's id before the app's, as `22MMUN2RN5.lv` would be for an app that did
    /// not declare it.
    private func teamPrefixedOwner(_ stem: String) -> Int? {
        guard let dot = stem.firstIndex(of: ".") else { return nil }
        let team = stem[..<dot]
        guard team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }),
            let owner = idOwner(String(stem[stem.index(after: dot)...])), apps[owner].teamID == String(team)
        else { return nil }
        return owner
    }

    /// The app a plain name is, as "Blender", "KurdyUploader" or "Telegram Desktop". No name that another app on the
    /// Mac also has.
    private func nameOwner(_ stem: String) -> Int? {
        let key = NameKey.key(stem)
        guard NameKey.isDistinctive(key) else { return nil }
        var keys = [key]
        // Desktop apps of services name their folders so: "Telegram Desktop", "Docker Desktop".
        if key.hasSuffix("desktop"), key.count > 7 + 2 { keys.append(String(key.dropLast(7))) }
        var owners = Set<Int>()
        for key in keys {
            if foreignNames.contains(key) { return nil }
            owners.formUnion(nameOwners[key] ?? [])
        }
        return Self.single(owners)
    }

    /// The one app among several copies of the same app is none: their files are shared.
    private static func single(_ owners: Set<Int>?) -> Int? {
        guard let owners, owners.count == 1 else { return nil }
        return owners.first
    }
}
