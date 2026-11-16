import Foundation

/// How one app sounds: its own volume on top of the system's, whether it is muted, and where it plays. Kept by bundle
/// ID, so it outlives the app quitting and the Mac restarting.
public struct AppAudioRule: Codable, Equatable, Sendable {
    /// 1 plays the app as it is. Above 1 is a boost, only while boosting is allowed.
    public var volume: Double
    public var isMuted: Bool
    /// The UID of the output it plays on, nil for the system's output.
    public var outputUID: String?
    /// The app's own equalizer, before the output's. Nil or flat leaves its sound as it is.
    public var equalizer: EqualizerSettings?

    public init(
        volume: Double = 1, isMuted: Bool = false, outputUID: String? = nil, equalizer: EqualizerSettings? = nil
    ) {
        self.volume = volume
        self.isMuted = isMuted
        self.outputUID = outputUID
        self.equalizer = equalizer
    }

    public static let standard = AppAudioRule()

    /// Nothing to change, so the app's sound is left alone and costs nothing.
    public var isStandard: Bool {
        abs(volume - 1) < 0.005 && !isMuted && outputUID == nil && !hasEqualizer
    }

    /// Whether the app has an equalizer that changes anything.
    public var hasEqualizer: Bool { !(equalizer?.isFlat ?? true) }

    /// What the engine multiplies the app's sound by: never below silence or above the highest boost, whatever was
    /// stored.
    public var gain: Float {
        guard !isMuted, volume.isFinite else { return 0 }
        return Float(min(max(volume, 0), AudioRuleBook.highestVolume(boosting: true)))
    }
}

/// An output's own sound: its equalizer, under the name it had when last seen, so that a disconnected output can still
/// be told apart.
public struct OutputSound: Codable, Equatable, Sendable {
    public var name: String
    /// An `AudioDeviceKind`, for its symbol while it is not connected.
    public var kind: String?
    public var equalizer: EqualizerSettings

    public init(name: String, kind: AudioDeviceKind? = nil, equalizer: EqualizerSettings) {
        self.name = name
        self.kind = kind?.rawValue
        self.equalizer = equalizer
    }

    public var deviceKind: AudioDeviceKind? { kind.flatMap(AudioDeviceKind.init(rawValue:)) }
}

/// Every app's rule and every output's equalizer. Only what changes something is kept.
public struct AudioRuleBook: Codable, Equatable, Sendable {
    /// The highest volume a slider reaches: the app as it is, or twice that while boosting is allowed.
    public static func highestVolume(boosting: Bool) -> Double { boosting ? 2 : 1 }

    public private(set) var rules: [String: AppAudioRule]
    /// By output UID.
    public private(set) var outputs: [String: OutputSound]

    public init(rules: [String: AppAudioRule] = [:], outputs: [String: OutputSound] = [:]) {
        self.rules = rules.filter { !$0.value.isStandard }
        self.outputs = outputs.filter { !$0.value.equalizer.isFlat }
    }

    private enum CodingKeys: String, CodingKey { case rules, outputs }

    /// Rules saved before outputs had equalizers have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rules: try container.decodeIfPresent([String: AppAudioRule].self, forKey: .rules) ?? [:],
            outputs: try container.decodeIfPresent([String: OutputSound].self, forKey: .outputs) ?? [:])
    }

    /// Whether anything needs the process that plays: an app with a rule, or an output with an equalizer.
    public var isEmpty: Bool { rules.isEmpty && outputs.isEmpty }

    public func equalizer(forOutput uid: String) -> EqualizerSettings {
        outputs[uid]?.equalizer ?? .flat
    }

    /// A flat equalizer is forgotten, so the output's sound goes back to being left alone.
    public mutating func setEqualizer(
        _ equalizer: EqualizerSettings, forOutput uid: String, name: String, kind: AudioDeviceKind? = nil
    ) {
        let kind = kind ?? outputs[uid]?.deviceKind
        outputs[uid] =
            equalizer.isFlat ? nil : OutputSound(name: name, kind: kind, equalizer: equalizer.sanitized)
    }

    public func rule(for bundleID: String) -> AppAudioRule { rules[bundleID] ?? .standard }

    /// A standard rule is forgotten, so the app's sound goes back to being left alone.
    public mutating func set(_ rule: AppAudioRule, for bundleID: String) {
        rules[bundleID] = rule.isStandard ? nil : rule
    }

    /// With boosting turned off, nothing plays louder than the app itself any more.
    public mutating func limit(boosting: Bool) {
        let highest = Self.highestVolume(boosting: boosting)
        for (bundleID, rule) in rules where rule.volume > highest {
            var lowered = rule
            lowered.volume = highest
            set(lowered, for: bundleID)
        }
    }
}
