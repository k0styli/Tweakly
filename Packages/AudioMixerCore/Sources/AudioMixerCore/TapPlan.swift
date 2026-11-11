import Foundation

/// What the engine runs: for each output, the apps whose sound it takes, changes and plays there.
public struct TapGroup: Equatable, Sendable {
    public var outputUID: String
    public var taps: [TapItem]

    public init(outputUID: String, taps: [TapItem]) {
        self.outputUID = outputUID
        self.taps = taps
    }

    /// The same apps from the same processes, in the same order, so a running group only has to take the new gains.
    public func hasSameSound(as other: TapGroup) -> Bool {
        outputUID == other.outputUID && taps.count == other.taps.count
            && zip(taps, other.taps).allSatisfy { $0.hasSameSound(as: $1) }
    }
}

public struct TapItem: Equatable, Sendable {
    public var bundleID: String
    /// Every process playing for the app, which one tap takes together.
    public var objectIDs: [UInt32]
    public var gain: Float

    public init(bundleID: String, objectIDs: [UInt32], gain: Float) {
        self.bundleID = bundleID
        self.objectIDs = objectIDs
        self.gain = gain
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
    /// - Parameter holding: Apps given back their own sound a moment ago, see `releaseHold`, which stay where they are
    ///   at their own volume.
    public static func groups(
        apps: [MixerApp], rules: AudioRuleBook, active: Set<String>, systemOutputUID: String?,
        connectedOutputs: Set<String>, holding: Set<String> = []
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
            if output == natural, abs(rule.volume - 1) < 0.005, !rule.isMuted, !isHeld { continue }
            if groups[output] == nil { order.append(output) }
            groups[output, default: []].append(
                TapItem(bundleID: app.id, objectIDs: app.objectIDs.sorted(), gain: rule.gain))
        }
        return order.map { TapGroup(outputUID: $0, taps: groups[$0] ?? []) }
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
