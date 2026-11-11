import Foundation

/// When a wallpaper stops moving. Sleep, the lock screen and a sleeping display always stop it.
public struct PauseRules: Codable, Equatable, Hashable, Sendable {
    /// While an app is in full screen, or windows cover every bit of the screen. A zoomed window leaves the desktop seen
    /// behind the menu bar and the Dock, and the video goes on there. On from the start.
    public var whenHidden: Bool
    public var onBattery: Bool
    public var inLowPowerMode: Bool
    /// While the Mac is hot enough for the system to slow it down.
    public var whenHot: Bool

    public init(whenHidden: Bool = true, onBattery: Bool = false, inLowPowerMode: Bool = true, whenHot: Bool = true) {
        self.whenHidden = whenHidden
        self.onBattery = onBattery
        self.inLowPowerMode = inLowPowerMode
        self.whenHot = whenHot
    }

    private enum CodingKeys: String, CodingKey {
        case whenHidden, onBattery, inLowPowerMode, whenHot
    }

    /// A rule added later reads as its default from rules saved before it, keeping the others someone chose.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = PauseRules()
        whenHidden = try container.decodeIfPresent(Bool.self, forKey: .whenHidden) ?? standard.whenHidden
        onBattery = try container.decodeIfPresent(Bool.self, forKey: .onBattery) ?? standard.onBattery
        inLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .inLowPowerMode) ?? standard.inLowPowerMode
        whenHot = try container.decodeIfPresent(Bool.self, forKey: .whenHot) ?? standard.whenHot
    }
}

/// What one display's wallpaper knows about the moment.
public struct PlaybackSituation: Equatable, Sendable {
    /// Whether any of the desktop can be seen, behind the clear menu bar and Dock too: false behind an app in full
    /// screen, under windows that cover all of the screen, on a sleeping display and at the login window.
    public var isVisible: Bool
    public var isDisplayAsleep: Bool
    public var isScreenLocked: Bool
    /// From the moment the system says it will sleep until it says it woke.
    public var isSystemAsleep: Bool
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    public var isHot: Bool

    public init(
        isVisible: Bool = true, isDisplayAsleep: Bool = false, isScreenLocked: Bool = false,
        isSystemAsleep: Bool = false, isOnBattery: Bool = false, isLowPowerMode: Bool = false, isHot: Bool = false
    ) {
        self.isVisible = isVisible
        self.isDisplayAsleep = isDisplayAsleep
        self.isScreenLocked = isScreenLocked
        self.isSystemAsleep = isSystemAsleep
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isHot = isHot
    }
}

/// Why a wallpaper is not moving.
public enum PauseReason: String, Equatable, Sendable {
    case hidden, asleep, locked, battery, lowPower, hot
}

/// What a display's player should do.
public enum PlaybackMode: Equatable, Sendable {
    case play
    /// Stopped on the current frame, ready to go on at once.
    case pause(PauseReason)
    /// Nothing is decoding or held: the desktop picture, its first frame, shows until it plays again from where it
    /// stopped.
    case release(PauseReason)

    public var isPlaying: Bool { self == .play }

    public var reason: PauseReason? {
        switch self {
        case .play: nil
        case .pause(let reason), .release(let reason): reason
        }
    }
}

public enum PlaybackPolicy {
    /// No timer is involved: every change arrives as an event.
    public static func mode(for situation: PlaybackSituation, rules: PauseRules) -> PlaybackMode {
        // Waking from sleep takes long enough to set up a player again, and a player kept through it may not come
        // back. It goes on from where it stopped.
        if situation.isSystemAsleep { return .release(.asleep) }
        // The display coming back or the screen unlocking shows the desktop at once, so the frame stays ready.
        if situation.isDisplayAsleep { return .pause(.asleep) }
        if situation.isScreenLocked { return .pause(.locked) }
        // The paused player keeps its frame, so it goes on from the same place the moment the desktop shows.
        if !situation.isVisible && rules.whenHidden { return .pause(.hidden) }
        // Seen but saving power: the frame stays on screen, and a paused player is the cheapest way to show it.
        if rules.inLowPowerMode && situation.isLowPowerMode { return .pause(.lowPower) }
        if rules.onBattery && situation.isOnBattery { return .pause(.battery) }
        if rules.whenHot && situation.isHot { return .pause(.hot) }
        return .play
    }
}

/// Why the tweak turned itself off, kept for its page until someone turns it on again.
public enum LiveWallpaperStopReason: Codable, Equatable, Hashable, Sendable {
    /// The video's file is gone from the wallpapers folder.
    case fileMissing(title: String)
    /// The file is there, and the system could not play it.
    case unplayable(title: String)
    /// The process that plays stopped by itself more than once.
    case stoppedUnexpectedly
}
