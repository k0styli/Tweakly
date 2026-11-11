import Foundation

/// What a person can adjust about the panel and its pictures. The defaults are the values chosen by measuring, and each
/// setting has a set of choices so nothing unreasonable can be asked.
public struct SwitcherTuning: Equatable, Sendable {
    public static let panelDelayChoices = [0, 50, 100, 130, 200, 300]
    public static let tileHeightChoices = [120, 148, 176]
    public static let capturesAtOnceRange = 1...10
    public static let retakeChoices = [0, 5, 10, 30, 60]
    public static let keepSharpChoices = [15, 30, 60, 120, 300]
    public static let compressionChoices = [0.6, 0.85, 0.95]

    /// Building the panel takes about 40 ms, so it starts this long earlier, to be ready at that moment.
    private static let buildLead: TimeInterval = 0.05

    /// Shorter presses switch straight away, as they do in the system's switcher: no panel and no capture, so also no
    /// recording indicator.
    public var panelDelayMilliseconds = 130
    public var largestTileHeight = 176
    public var fitsBackgroundToRows = false
    /// A capture that has begun cannot be called off, so starting them all together would keep them running long after
    /// a panel has closed. On macOS 27.2 the system takes them about one at a time, about 45 ms each on real windows, so
    /// ten at once are no faster than four. Two are a little slower the first time after launch.
    public var capturesAtOnce = 4
    /// A picture this recent is not taken again, except of the window in use, which is what has been changing. Going
    /// back and forth would otherwise capture every window on every press.
    public var retakeAfterSeconds = 10
    /// A panel opened again soon starts from the sharp pictures it just had. Past this they are released.
    public var keepSharpPicturesSeconds = 60
    public var savesCompressedPictures = true
    /// Nearly what the picture looks like at the size of a tile.
    public var compressionQuality = 0.85
    /// Without pictures the tiles show app icons, nothing lights the recording indicator and Screen Recording is not
    /// needed, for anyone who would rather have that.
    public var showsPreviews = true
    public var showsWindowsOnOtherDesktops = true
    public var showsMinimizedWindows = true
    public var showsAppsWithoutWindows = true

    public init() {}

    /// Whether a window that passed `WindowFilter` gets a tile. A window of a hidden app counts as minimized: it is out
    /// of sight on this desktop for the same reason, because someone put it away.
    /// - Parameter isOnCurrentDesktop: nil if the system cannot say, which leaves it to the filter's own rule.
    public func shows(isOnScreen: Bool, isOnCurrentDesktop: Bool?) -> Bool {
        if isOnScreen { return true }
        switch isOnCurrentDesktop {
        case true?: return showsMinimizedWindows
        case false?: return showsWindowsOnOtherDesktops
        case nil: return true
        }
    }

    /// Asking about the desktop is a call to the window server, so it is made only if the answer could matter.
    public var filtersWindowsOutOfSight: Bool { !showsMinimizedWindows || !showsWindowsOnOtherDesktops }

    public var panelDelay: TimeInterval { TimeInterval(panelDelayMilliseconds) / 1000 }
    public var buildDelay: TimeInterval { max(panelDelay - Self.buildLead, 0) }

    /// Each value on its nearest choice, whatever was stored, so that a picker always has something selected.
    public var validated: SwitcherTuning {
        var result = self
        result.panelDelayMilliseconds = Self.nearest(panelDelayMilliseconds, in: Self.panelDelayChoices)
        result.largestTileHeight = Self.nearest(largestTileHeight, in: Self.tileHeightChoices)
        result.capturesAtOnce = min(
            max(capturesAtOnce, Self.capturesAtOnceRange.lowerBound), Self.capturesAtOnceRange.upperBound)
        result.retakeAfterSeconds = Self.nearest(retakeAfterSeconds, in: Self.retakeChoices)
        result.keepSharpPicturesSeconds = Self.nearest(keepSharpPicturesSeconds, in: Self.keepSharpChoices)
        result.compressionQuality =
            Self.compressionChoices.min { abs($0 - compressionQuality) < abs($1 - compressionQuality) }
            ?? compressionQuality
        return result
    }

    /// Brought within reach of the choices first: this reads whatever is in the preferences, and a difference with a number
    /// near the end of the range would overflow and stop the app, on every launch from then on.
    private static func nearest(_ value: Int, in choices: [Int]) -> Int {
        let value = min(max(value, -farFromAnyChoice), farFromAnyChoice)
        return choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    private static let farFromAnyChoice = 1_000_000
}
