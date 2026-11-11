import Foundation

/// A process connected to the system's sound server, as Core Audio lists it.
public struct AudioClient: Equatable, Sendable {
    /// Its Core Audio process object, which a tap names.
    public var objectID: UInt32
    public var pid: Int32
    public var isPlaying: Bool
    /// The UID of the output it plays on, which an app such as a call app may choose for itself.
    public var outputUID: String?

    public init(objectID: UInt32, pid: Int32, isPlaying: Bool, outputUID: String? = nil) {
        self.objectID = objectID
        self.pid = pid
        self.isPlaying = isPlaying
        self.outputUID = outputUID
    }
}

/// The app a person knows a process by: the app itself, or the app a helper plays for, such as Safari for its
/// WebKit process.
public struct AudioOwner: Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// The app's own process, for its icon.
    public var pid: Int32

    public init(bundleID: String, name: String, pid: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// One row of the mixer: an app and every process that plays for it.
public struct MixerApp: Identifiable, Equatable, Sendable {
    public var owner: AudioOwner
    public var objectIDs: [UInt32]
    public var isPlaying: Bool
    /// The output it plays on by itself: a playing process's, or any of its processes'. Nil for the system's output.
    public var outputUID: String?

    public var id: String { owner.bundleID }

    public init(owner: AudioOwner, objectIDs: [UInt32], isPlaying: Bool, outputUID: String? = nil) {
        self.owner = owner
        self.objectIDs = objectIDs
        self.isPlaying = isPlaying
        self.outputUID = outputUID
    }
}

public enum AudioAppGrouping {
    /// Gathers Core Audio's clients into the apps they play for. A client with no app it can be put under, such as a
    /// system daemon, is left out, and so is this app itself.
    public static func apps(clients: [AudioClient], owner: (AudioClient) -> AudioOwner?) -> [MixerApp] {
        var order: [String] = []
        var byApp: [String: MixerApp] = [:]
        for client in clients {
            guard let owner = owner(client) else { continue }
            if var app = byApp[owner.bundleID] {
                app.objectIDs.append(client.objectID)
                // What a playing process plays on says more than a silent one's.
                if client.isPlaying && !app.isPlaying || app.outputUID == nil {
                    app.outputUID = client.outputUID ?? app.outputUID
                }
                app.isPlaying = app.isPlaying || client.isPlaying
                byApp[owner.bundleID] = app
            } else {
                order.append(owner.bundleID)
                byApp[owner.bundleID] = MixerApp(
                    owner: owner, objectIDs: [client.objectID], isPlaying: client.isPlaying,
                    outputUID: client.outputUID)
            }
        }
        return order.compactMap { byApp[$0] }
    }

    /// The rows the popover shows: apps playing now, apps with a rule of their own, and apps it showed already while
    /// open, so that a row never jumps away under the pointer. Kept in the order they first appeared.
    public static func shown(
        _ apps: [MixerApp], ruled: Set<String>, alreadyShown: [String]
    ) -> [MixerApp] {
        let wanted = apps.filter { $0.isPlaying || ruled.contains($0.id) || alreadyShown.contains($0.id) }
        let known = wanted.filter { alreadyShown.contains($0.id) }.sorted {
            (alreadyShown.firstIndex(of: $0.id) ?? 0) < (alreadyShown.firstIndex(of: $1.id) ?? 0)
        }
        let new = wanted.filter { !alreadyShown.contains($0.id) }.sorted {
            $0.owner.name.localizedStandardCompare($1.owner.name) == .orderedAscending
        }
        return known + new
    }
}
