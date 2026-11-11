import Foundation

/// How one app sounds: its own volume on top of the system's, whether it is muted, and where it plays. Kept by bundle
/// ID, so it outlives the app quitting and the Mac restarting.
public struct AppAudioRule: Codable, Equatable, Sendable {
    /// 1 plays the app as it is. Above 1 is a boost, only while boosting is allowed.
    public var volume: Double
    public var isMuted: Bool
    /// The UID of the output it plays on, nil for the system's output.
    public var outputUID: String?

    public init(volume: Double = 1, isMuted: Bool = false, outputUID: String? = nil) {
        self.volume = volume
        self.isMuted = isMuted
        self.outputUID = outputUID
    }

    public static let standard = AppAudioRule()

    /// Nothing to change, so the app's sound is left alone and costs nothing.
    public var isStandard: Bool {
        abs(volume - 1) < 0.005 && !isMuted && outputUID == nil
    }

    /// What the engine multiplies the app's sound by: never below silence or above the highest boost, whatever was
    /// stored.
    public var gain: Float {
        guard !isMuted, volume.isFinite else { return 0 }
        return Float(min(max(volume, 0), AudioRuleBook.highestVolume(boosting: true)))
    }
}

/// Every app's rule. Only apps with something to change are kept.
public struct AudioRuleBook: Codable, Equatable, Sendable {
    /// The highest volume a slider reaches: the app as it is, or twice that while boosting is allowed.
    public static func highestVolume(boosting: Bool) -> Double { boosting ? 2 : 1 }

    public private(set) var rules: [String: AppAudioRule]

    public init(rules: [String: AppAudioRule] = [:]) {
        self.rules = rules.filter { !$0.value.isStandard }
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
