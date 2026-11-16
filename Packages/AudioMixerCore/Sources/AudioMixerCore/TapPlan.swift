import Foundation

/// What the engine runs: for each output, the apps whose sound it takes, changes and plays there, and with an
/// equalizer on the output, everything else played on it too.
public struct TapGroup: Equatable, Sendable {
    public var outputUID: String
    public var taps: [TapItem]
    /// Everything else the output plays, taken for its equalizer; nil when it has none.
    public var output: OutputTap?

    public init(outputUID: String, taps: [TapItem], output: OutputTap? = nil) {
        self.outputUID = outputUID
        self.taps = taps
        self.output = output
    }

    /// The same apps from the same processes, in the same order, and the output taken or not, leaving out the same
    /// processes, so a running group only has to take the new gains and equalizers.
    public func hasSameSound(as other: TapGroup) -> Bool {
        outputUID == other.outputUID && taps.count == other.taps.count
            && zip(taps, other.taps).allSatisfy { $0.hasSameSound(as: $1) }
            && output.map(\.excluded).map(Set.init) == other.output.map(\.excluded).map(Set.init)
    }
}

/// An output's whole sound but for what is taken apart: this process, and the apps with taps of their own, which
/// reach it through those.
public struct OutputTap: Equatable, Sendable {
    public var excluded: [UInt32]
    public var equalizer: EqualizerSettings

    public init(excluded: [UInt32], equalizer: EqualizerSettings) {
        self.excluded = excluded
        self.equalizer = equalizer
    }
}

public struct TapItem: Equatable, Sendable {
    public var bundleID: String
    /// Every process playing for the app, which one tap takes together.
    public var objectIDs: [UInt32]
    public var gain: Float
    public var equalizer: EqualizerSettings

    public init(bundleID: String, objectIDs: [UInt32], gain: Float, equalizer: EqualizerSettings = .flat) {
        self.bundleID = bundleID
        self.objectIDs = objectIDs
        self.gain = gain
        self.equalizer = equalizer
    }

    /// The same processes, so only the gain differs and nothing has to be built again.
    public func hasSameSound(as other: TapItem) -> Bool {
        bundleID == other.bundleID && Set(objectIDs) == Set(other.objectIDs)
    }
}

public enum TapPlan {
    /// How long an app that went quiet keeps its tap: players pause and go on, and building a tap again lets the
    /// first moment of sound through as it was.
    public static let linger: TimeInterval = 30
    /// How long an app given back its own sound keeps its tap, at its own volume. A slider dragged across 100 % gives
    /// it back for an instant, and taking the tap out and putting it back would build its output's group twice, each
    /// time letting every app on it through as it was for a moment.
    public static let releaseHold: TimeInterval = 5

    /// Only apps with a rule of their own, and only while they play or did a moment ago, are taken. Everything else
    /// reaches the output as macOS sends it and costs nothing. A tap takes all an app plays, wherever it plays, so an
    /// app without an output of its own in the rule goes on playing where it chose to, a call app on its headset say,
    /// and only an app that chose nothing plays on the system's output. An app set to an output that is not connected
    /// plays where it would anyway.
    ///
    /// An output with an equalizer is taken whole while anything plays on it, or did a moment ago, leaving out this
    /// process and the apps taken apart.
    ///
    /// - Parameters:
    ///   - holding: Apps given back their own sound a moment ago, see `releaseHold`, which stay where they are at
    ///     their own volume.
    ///   - activeOutputs: Outputs something plays on, or did within `linger`.
    ///   - ownObjectID: This process, whose own sound on an output must never be taken again.
    public static func groups(
        apps: [MixerApp], rules: AudioRuleBook, active: Set<String>, systemOutputUID: String?,
        connectedOutputs: Set<String>, holding: Set<String> = [], activeOutputs: Set<String> = [],
        ownObjectID: UInt32? = nil
    ) -> [TapGroup] {
        var order: [String] = []
        var groups: [String: [TapItem]] = [:]
        for app in apps where active.contains(app.id) && !app.objectIDs.isEmpty {
            let rule = rules.rule(for: app.id)
            let isHeld = holding.contains(app.id)
            guard !rule.isStandard || isHeld else { continue }
            let natural = app.outputUID ?? systemOutputUID
            let chosen = rule.outputUID.flatMap { connectedOutputs.contains($0) ? $0 : nil }
            guard let output = chosen ?? natural else { continue }
            // Its own volume where it plays anyway is the same sound: nothing to take.
            if output == natural, abs(rule.volume - 1) < 0.005, !rule.isMuted, !rule.hasEqualizer, !isHeld {
                continue
            }
            if groups[output] == nil { order.append(output) }
            groups[output, default: []].append(
                TapItem(
                    bundleID: app.id, objectIDs: app.objectIDs.sorted(), gain: rule.gain,
                    equalizer: rule.equalizer ?? .flat))
        }
        // The apps taken apart, wherever they play now, and this process are left out of every output's whole sound.
        // Without knowing this process, no output is taken whole: it would take back its own sound, round and round.
        let takenApart = Set(groups.values.flatMap { $0.flatMap(\.objectIDs) })
        var outputs: [String: OutputTap] = [:]
        guard let ownObjectID else { return order.map { TapGroup(outputUID: $0, taps: groups[$0] ?? []) } }
        let excluded = takenApart.union([ownObjectID]).sorted()
        for (uid, sound) in rules.outputs.sorted(by: { $0.key < $1.key })
        where !sound.equalizer.isFlat && connectedOutputs.contains(uid) && activeOutputs.contains(uid) {
            if groups[uid] == nil { order.append(uid) }
            outputs[uid] = OutputTap(excluded: excluded, equalizer: sound.equalizer)
        }
        return order.map { TapGroup(outputUID: $0, taps: groups[$0] ?? [], output: outputs[$0]) }
    }

    /// The outputs something plays on, other than this process: a client playing, on the output it opened or, having
    /// opened none, on the system's.
    public static func playingOutputs(clients: [AudioClient], systemOutputUID: String?, ownPID: Int32) -> Set<String> {
        Set(
            clients.filter { $0.isPlaying && $0.pid != ownPID }
                .compactMap { $0.outputUID ?? systemOutputUID })
    }

    /// When each app was last heard, brought up to date at a look: an app playing now, and one that was playing at the
    /// last look and has gone quiet since, were both heard just now. Only a look can tell, so an app that played for
    /// ten minutes and paused counts from the pause, not from when it began.
    public static func heard(
        lastPlayed: [String: Date], wasPlaying: Set<String>, playing: Set<String>, now: Date
    ) -> [String: Date] {
        var heard = lastPlayed
        for id in playing.union(wasPlaying) { heard[id] = now }
        return heard
    }

    /// The apps that count as active at a moment: playing, or quiet for less than `linger`.
    public static func active(lastPlayed: [String: Date], playing: Set<String>, now: Date) -> Set<String> {
        playing.union(lastPlayed.filter { now.timeIntervalSince($0.value) < linger }.keys)
    }
}

/// Keeps a boosted app from clipping: the sound passes unchanged up to the knee, then bends smoothly towards full scale
/// and never reaches past it.
public enum SoftLimiter {
    public static let knee: Float = 0.9

    @inline(__always)
    public static func limit(_ sample: Float) -> Float {
        let size = abs(sample)
        // Nothing that is not a number reaches the speakers.
        guard size.isFinite else { return 0 }
        guard size > knee else { return sample }
        let room = 1 - knee
        let bent = knee + room * Float(tanh(Double((size - knee) / room)))
        return sample < 0 ? -bent : bent
    }
}

/// Moves a gain to its new value across one buffer rather than at once, which would click.
public struct GainRamp: Sendable {
    public private(set) var current: Float

    public init(_ value: Float) { current = value }

    /// The gain of the buffer's first frame and how much it changes each frame after, ending at `target`.
    public mutating func begin(towards target: Float, frames: Int) -> (start: Float, step: Float) {
        let start = current
        current = target
        guard frames > 0, start != target else { return (target, 0) }
        let step = (target - start) / Float(frames)
        return (start + step, step)
    }
}
