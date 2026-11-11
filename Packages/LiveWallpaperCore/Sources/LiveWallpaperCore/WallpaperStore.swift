import Foundation

/// The system's own record of what every display and Space shows, kept by WallpaperAgent in
/// `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. It is not documented; its shape here was read
/// on macOS 27.2. Public API cannot put an Aerial back, as it reports one as the default picture, and it reaches only the
/// Space in front, while the store keeps a choice for each Space. So the store as it was before the first change is
/// kept, and when the tweak goes off every desktop entry that shows one of Tweakly's pictures gets back what it held.
/// The store is undocumented, so this is a deliberate choice.
///
/// Shape: `SystemDefault`, `AllSpacesAndDisplays` (or the string `$null`), `Displays` by display UUID, and `Spaces` by
/// Space ID, each with `Default` and `Displays` by display UUID. Each of these places holds `Desktop` and `Idle`, the
/// screen saver, and a choice is `Content.Choices`, a list of `Provider` and `Configuration`, a property list.
public enum WallpaperStore {
    /// The keys that lead to one place with a `Desktop` entry.
    public typealias Location = [String]

    public enum Restoration {
        /// Nothing in the store shows a picture of ours.
        case unchanged
        case changed([String: Any])
        /// The store is not shaped as expected, so it is left alone and the public way is used instead.
        case unknownShape
    }

    static let imageProvider = "com.apple.wallpaper.choice.image"

    /// Every place in the store that may hold a desktop choice.
    public static func locations(in store: [String: Any]) -> [Location]? {
        guard let displays = store["Displays"] as? [String: Any], let spaces = store["Spaces"] as? [String: Any]
        else { return nil }
        var found: [Location] = []
        for top in ["SystemDefault", "AllSpacesAndDisplays"] where store[top] is [String: Any] {
            found.append([top])
        }
        found += displays.keys.sorted().map { ["Displays", $0] }
        for space in spaces.keys.sorted() {
            guard let entry = spaces[space] as? [String: Any] else { return nil }
            if entry["Default"] is [String: Any] { found.append(["Spaces", space, "Default"]) }
            if let perDisplay = entry["Displays"] as? [String: Any] {
                found += perDisplay.keys.sorted().map { ["Spaces", space, "Displays", $0] }
            }
        }
        return found
    }

    /// The paths of the picture files a desktop entry shows, or nil if any choice is something else, such as an Aerial.
    public static func picturePaths(of desktop: [String: Any]) -> [String]? {
        guard let content = desktop["Content"] as? [String: Any], let choices = content["Choices"] as? [Any],
            !choices.isEmpty
        else { return nil }
        var paths: [String] = []
        for case let choice as [String: Any] in choices {
            guard choice["Provider"] as? String == imageProvider, let data = choice["Configuration"] as? Data,
                let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let url = configuration["url"] as? [String: Any], let text = url["relative"] as? String,
                let fileURL = URL(string: text), fileURL.isFileURL
            else { return nil }
            paths.append(fileURL.path)
        }
        return paths.count == choices.count ? paths : nil
    }

    /// Whether a desktop entry shows only pictures that `isOurs` claims.
    public static func showsOurs(_ desktop: [String: Any], isOurs: (String) -> Bool) -> Bool {
        guard let paths = picturePaths(of: desktop) else { return false }
        return paths.allSatisfy(isOurs)
    }

    /// The store with each desktop entry that shows a picture of ours put back as the snapshot had it. An entry the
    /// snapshot did not have is removed, so the system falls back to the display's or its own default again. An entry
    /// that already showed a picture of ours in the snapshot, left by an older version, gets the display's or the
    /// system's choice from the snapshot. Entries that show anything else are the person's own and stay.
    public static func restored(
        _ current: [String: Any], from snapshot: [String: Any], isOurs: (String) -> Bool
    ) -> Restoration {
        guard let places = locations(in: current), locations(in: snapshot) != nil else { return .unknownShape }
        var result = current
        var changed = false
        for place in places {
            guard let entry = value(at: place, in: current) as? [String: Any],
                let desktop = entry["Desktop"] as? [String: Any], showsOurs(desktop, isOurs: isOurs)
            else { continue }
            // A place of the system's own that was not a choice at all, such as `$null`, goes back to being that.
            if place.count == 1, let raw = value(at: place, in: snapshot), !(raw is [String: Any]) {
                result[place[0]] = raw
                changed = true
                continue
            }
            let before = value(at: place, in: snapshot) as? [String: Any]
            let replacement: [String: Any]?
            if let old = before?["Desktop"] as? [String: Any], !showsOurs(old, isOurs: isOurs) {
                replacement = old
            } else if before?["Desktop"] != nil || place.count <= 2 {
                replacement = fallback(for: place, in: snapshot, isOurs: isOurs)
            } else {
                replacement = nil
            }
            var updated = entry
            if let replacement {
                updated["Desktop"] = replacement
            } else if place.count > 2 {
                updated.removeValue(forKey: "Desktop")
            } else {
                // The system's own places always keep a choice: with nothing better, ours stays.
                continue
            }
            result = setting(updated, at: place, in: result)
            changed = true
        }
        return changed ? .changed(result) : .unchanged
    }

    /// The closest choice from the snapshot that is not ours: the display's own, then the system's.
    private static func fallback(for place: Location, in snapshot: [String: Any], isOurs: (String) -> Bool)
        -> [String: Any]?
    {
        var candidates: [Location] = []
        if place.count == 4 || (place.count == 2 && place[0] == "Displays") {
            candidates.append(["Displays", place[place.count - 1]])
        }
        candidates.append(["SystemDefault"])
        for candidate in candidates where candidate != place {
            if let entry = value(at: candidate, in: snapshot) as? [String: Any],
                let desktop = entry["Desktop"] as? [String: Any], !showsOurs(desktop, isOurs: isOurs)
            {
                return desktop
            }
        }
        return nil
    }

    static func value(at place: Location, in store: [String: Any]) -> Any? {
        var current: Any? = store
        for key in place {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    static func setting(_ newValue: [String: Any], at place: Location, in store: [String: Any]) -> [String: Any] {
        guard let first = place.first else { return store }
        var copy = store
        if place.count == 1 {
            copy[first] = newValue
        } else {
            let inner = copy[first] as? [String: Any] ?? [:]
            copy[first] = setting(newValue, at: Array(place.dropFirst()), in: inner)
        }
        return copy
    }
}
