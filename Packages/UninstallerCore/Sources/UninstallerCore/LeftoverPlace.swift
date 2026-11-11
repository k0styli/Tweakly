import Foundation

/// What a file is to the person deciding whether to let it go, in the order the removal sheet lists them.
public enum LeftoverCategory: Int, Sendable, CaseIterable, Comparable {
    case app
    case data
    case caches
    case settings
    case savedState
    case logs
    case background

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A folder where apps keep files named after themselves. Each knows how its entries are named, and whether a name,
/// rather than an id, can say whose an entry is.
public enum LeftoverPlace: String, Sendable, CaseIterable {
    case applicationSupport
    case containers
    case groupContainers
    case applicationScripts
    case httpStorages
    case webKit
    case cookies
    case caches
    /// The per-user folder under `/private/var/folders` that `confstr` names, where apps' system caches go.
    case temporaryCaches
    case preferences
    case preferencesByHost
    case savedState
    case logs
    case launchAgents
    case systemApplicationSupport
    case systemCaches
    case systemPreferences
    case systemLogs
    case systemLaunchAgents
    case systemLaunchDaemons
    case privilegedHelperTools

    /// Relative to the home folder for a person's own places, absolute for the system's. The temporary caches have no
    /// fixed path, so the app asks the system for it.
    public var path: String? {
        switch self {
        case .applicationSupport: "Library/Application Support"
        case .containers: "Library/Containers"
        case .groupContainers: "Library/Group Containers"
        case .applicationScripts: "Library/Application Scripts"
        case .httpStorages: "Library/HTTPStorages"
        case .webKit: "Library/WebKit"
        case .cookies: "Library/Cookies"
        case .caches: "Library/Caches"
        case .temporaryCaches: nil
        case .preferences: "Library/Preferences"
        case .preferencesByHost: "Library/Preferences/ByHost"
        case .savedState: "Library/Saved Application State"
        case .logs: "Library/Logs"
        case .launchAgents: "Library/LaunchAgents"
        case .systemApplicationSupport: "/Library/Application Support"
        case .systemCaches: "/Library/Caches"
        case .systemPreferences: "/Library/Preferences"
        case .systemLogs: "/Library/Logs"
        case .systemLaunchAgents: "/Library/LaunchAgents"
        case .systemLaunchDaemons: "/Library/LaunchDaemons"
        case .privilegedHelperTools: "/Library/PrivilegedHelperTools"
        }
    }

    public var isSystem: Bool {
        switch self {
        case .systemApplicationSupport, .systemCaches, .systemPreferences, .systemLogs, .systemLaunchAgents,
            .systemLaunchDaemons, .privilegedHelperTools:
            true
        default: false
        }
    }

    public var category: LeftoverCategory {
        switch self {
        case .applicationSupport, .containers, .groupContainers, .applicationScripts, .httpStorages, .webKit, .cookies,
            .systemApplicationSupport:
            .data
        case .caches, .temporaryCaches, .systemCaches: .caches
        case .preferences, .preferencesByHost, .systemPreferences: .settings
        case .savedState: .savedState
        case .logs, .systemLogs: .logs
        case .launchAgents, .systemLaunchAgents, .systemLaunchDaemons, .privilegedHelperTools: .background
        }
    }

    /// Folders apps name in plain words, as "Application Support/Blender". Everywhere else only an id is trusted: a
    /// preference named "Notes" could be anyone's.
    public var matchesNames: Bool {
        switch self {
        case .applicationSupport, .caches, .logs, .systemApplicationSupport, .systemLogs: true
        default: false
        }
    }

    /// Folders named after an app group as well as after an app.
    public var matchesGroups: Bool {
        switch self {
        case .groupContainers, .applicationScripts: true
        default: false
        }
    }

    /// A job's plist, which says what it runs and for which app.
    public var holdsJobs: Bool {
        switch self {
        case .launchAgents, .systemLaunchAgents, .systemLaunchDaemons: true
        default: false
        }
    }

    /// The name an entry carries without what the place adds to every name: `.plist`, a host's id, `.savedState`.
    public func stem(of entry: String) -> String {
        var stem = entry
        for suffix in [".plist", ".savedState", ".binarycookies", ".log"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        if self == .preferencesByHost, let dot = stem.lastIndex(of: "."),
            Self.isHostID(stem[stem.index(after: dot)...])
        {
            stem = String(stem[..<dot])
        }
        return stem
    }

    /// The hardware id ByHost preferences end with: a UUID, or twelve hex digits on old Macs.
    private static func isHostID(_ text: Substring) -> Bool {
        let hex = text.filter { $0 != "-" }
        return (hex.count == 32 || hex.count == 12) && hex.allSatisfy(\.isHexDigit)
    }
}

/// The parts of a launchd job's plist that say whose it is.
public struct LaunchJob: Sendable, Hashable {
    public var label: String?
    /// `Program`, or else the first of `ProgramArguments`, or `BundleProgram`.
    public var program: String?
    public var associatedBundleIDs: [String]

    public init(label: String? = nil, program: String? = nil, associatedBundleIDs: [String] = []) {
        self.label = label
        self.program = program
        self.associatedBundleIDs = associatedBundleIDs
    }

    public init(plist: [String: Any]) {
        label = plist["Label"] as? String
        program =
            plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            ?? plist["BundleProgram"] as? String
        associatedBundleIDs = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
    }
}
