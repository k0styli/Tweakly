import Foundation

/// What an app calls itself and what it may have named its files with: the ids from its bundle and signature, and the
/// names a folder of its might carry.
public struct AppIdentity: Sendable, Hashable {
    public var path: String
    public var bundleID: String
    /// The bundle's file name, its name and display name, and its executable's name.
    public var names: [String]
    public var teamID: String?
    /// App groups and iCloud containers from its signature, which name its shared containers.
    public var groups: [String]
    /// Ids of what it carries inside: apps, extensions, services, login items and privileged helpers. Their files are
    /// the app's too.
    public var embeddedIDs: [String]

    public init(
        path: String, bundleID: String, names: [String], teamID: String? = nil, groups: [String] = [],
        embeddedIDs: [String] = []
    ) {
        self.path = path
        self.bundleID = bundleID
        self.names = names
        self.teamID = teamID
        self.groups = groups
        self.embeddedIDs = embeddedIDs
    }

    /// Apple's own apps from the App Store, such as Pages or Xcode. Their names are words macOS uses everywhere, so
    /// only their own ids find their files.
    public var isApple: Bool { bundleID.lowercased().hasPrefix("com.apple.") }

    /// Its own id and the ids inside it that come from the same company. A service of a framework it carries, such as
    /// Sparkle's, belongs to the framework and to every app that carries it.
    public var ownedIDs: [String] {
        guard !isApple, let domain = Self.domain(of: bundleID) else { return [bundleID] }
        return [bundleID] + embeddedIDs.filter { Self.domain(of: $0) == domain }
    }

    /// Who an id comes from: `com.docker` for `com.docker.vmnetd`, and `io.github.clash-verge-rev` for an app published
    /// on GitHub, where the second part says only where it lives.
    static func domain(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let length = hostingNames.contains(String(parts[1])) ? 3 : 2
        guard parts.count >= length else { return nil }
        return parts.prefix(length).joined(separator: ".")
    }

    /// The company part of a three-part id, such as `google` for `com.google.Chrome`, which some apps name a folder
    /// after and put their own folder in.
    public var vendorKey: String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        guard !Self.hostingNames.contains(vendor), vendor.count >= 3 else { return nil }
        return NameKey.key(vendor)
    }

    /// Second parts that name a place an app is published from, not who makes it.
    private static let hostingNames: Set<String> = ["github", "gitlab", "sourceforge", "apple", "app", "apps", "www"]

    /// The names a folder of its might carry, reduced to letters and digits.
    public var nameKeys: Set<String> {
        guard !isApple else { return [] }
        var keys = Set<String>()
        for name in names {
            for variant in [name, NameKey.withoutVersion(name)] {
                let key = NameKey.key(variant)
                if NameKey.isDistinctive(key) { keys.insert(key) }
            }
        }
        return keys
    }
}

/// Names compared the way people and apps vary them: in any case, with or without spaces and punctuation.
public enum NameKey {
    public static func key(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// "Bartender 6" and "Kurdy Uploader (version 1.7.86)" name the same folders as "Bartender" and "Kurdy Uploader".
    public static func withoutVersion(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // Only a number after a space is a version: "Bartender 6", not "Mac2".
        if let space = name.lastIndex(of: " "), space != name.startIndex {
            let tail = name[name.index(after: space)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber || $0 == "." }) { name = String(name[..<space]) }
        }
        return name
    }

    /// A word too common to say whose folder it is, or too short to be a name at all.
    public static func isDistinctive(_ key: String) -> Bool {
        key.count >= 3 && !genericWords.contains(key)
    }

    private static let genericWords: Set<String> = [
        "app", "apps", "application", "applications", "helper", "helpers", "agent", "daemon", "service", "services",
        "support", "data", "cache", "caches", "log", "logs", "update", "updates", "updater", "installer", "install",
        "setup", "launcher", "plugin", "plugins", "common", "shared", "default", "temp", "tmp", "electron", "crashpad",
        "crashhandler", "sentry", "sparkle", "music", "notes", "photos", "mail", "news", "books", "maps", "calendar",
        "contacts", "reminders", "messages", "safari", "finder", "preview", "terminal", "console", "settings",
        "preferences", "documents", "downloads", "desktop", "library", "user", "users", "main", "run", "bin", "tool",
        "tools", "sdk", "web", "browser", "games", "game", "player", "editor", "studio", "client", "server", "home",
    ]
}

/// What the processor in an app's executable is, as System Settings shows it beside each app.
public enum AppKind: Sendable, Hashable {
    case appleSilicon
    case universal
    case intel
    case unknown

    public init(architectures: [String]) {
        let arm = architectures.contains { $0.hasPrefix("arm64") }
        let intel = architectures.contains { $0.hasPrefix("x86_64") || $0 == "i386" }
        switch (arm, intel) {
        case (true, true): self = .universal
        case (true, false): self = .appleSilicon
        case (false, true): self = .intel
        case (false, false): self = .unknown
        }
    }
}
