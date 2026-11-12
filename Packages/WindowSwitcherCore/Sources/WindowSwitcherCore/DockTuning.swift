import CoreGraphics
import Foundation

/// What a person can adjust about the Dock's previews and the click on an icon.
public struct DockTuning: Equatable, Sendable {
    /// What a click on the icon of the app in front does, beyond what the Dock itself does.
    public enum ClickAction: String, CaseIterable, Sendable {
        /// The Dock's own behaviour: the app stays as it is.
        case nothing
        /// Its windows go into the Dock, as a click on a taskbar button does in Windows.
        case minimize
        /// The app is hidden, as with Command-H, and comes back as it was.
        case hide
    }

    public static let delayChoices = [0, 200, 400, 700]
    public static let tileHeightChoices = [104, 132, 160]

    /// Off the Dock, the panel goes as the Dock's bubble under it does, measured frame by frame on macOS 27.2: a fade
    /// of 0.27 s with an eased start and end. It starts this much later than the bubble's: starting together, the
    /// bubble would show through the fading glass at up to a quarter of its strength at the middle, and this late at
    /// under 3 %. It is also the time the pointer has to reach the panel, and coming in stops the fade.
    public static let fadeDelay: TimeInterval = 0.12
    public static let fadeDuration: TimeInterval = 0.27
    /// From the icon to the panel: where the Dock puts the bubble with the app's name, measured on macOS 27.2, so the
    /// panel covers that bubble. The bubble's drop reaches 6.5 pt back towards the icon; the panel's reaches
    /// `tailLength`, and glass draws its edge half a point beyond its frame.
    public static let panelGap: CGFloat = 9
    public static let tailLength: CGFloat = 6
    public static let screenMargin: CGFloat = 8

    public var showsPanel = true
    /// None: the Dock shows its own bubble at once, and the panel has to cover it from the start. 400 ms felt far too
    /// slow, as the bubble came first.
    public var delayMilliseconds = 0
    public var largestTileHeight = 132
    public var clickAction = ClickAction.minimize

    public init() {}

    public var delay: TimeInterval { TimeInterval(delayMilliseconds) / 1000 }

    /// The switcher's tiles, smaller and closer together, in glass whose corners are concentric with theirs: the label's
    /// radius of 14 and inset of 6 make the tile's 20, and the padding of 12 makes the panel's 32.
    public var layoutMetrics: SwitcherLayout.Metrics {
        var metrics = SwitcherLayout.Metrics()
        metrics.padding = 12
        metrics.spacing = 12
        metrics.cornerRadius = 32
        metrics.maximumTileHeight = CGFloat(largestTileHeight)
        metrics.minimumTileHeight = 72
        metrics.smallestTileHeight = 56
        return metrics
    }

    /// Each value on its nearest choice, whatever was stored, so that a picker always has something selected.
    public var validated: DockTuning {
        var result = self
        result.delayMilliseconds = Self.nearest(delayMilliseconds, in: Self.delayChoices)
        result.largestTileHeight = Self.nearest(largestTileHeight, in: Self.tileHeightChoices)
        return result
    }

    /// Brought within reach first, so that a difference with a number near the end of the range cannot overflow.
    private static func nearest(_ value: Int, in choices: [Int]) -> Int {
        let value = min(max(value, -1_000_000), 1_000_000)
        return choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}

/// When the panel over the Dock shows, changes and goes, from what the Dock says about the pointer and what the panel's
/// own tracking says. The caller owns the two timers; this says when to start and stop them and what to do when one
/// fires, so the rules can be tested without waiting.
public struct DockHover: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case show(Int32)
        case hide
        case startShowTimer
        case stopShowTimer
        case startHideTimer
        case stopHideTimer
    }

    /// The running app whose icon the pointer is on, nil when it is on anything else or off the Dock.
    public private(set) var hovered: Int32?
    public private(set) var shown: Int32?
    public private(set) var pending: Int32?
    public private(set) var isInPanel = false

    public init() {}

    /// - Parameter onIcon: the pointer is on an icon, which is not a running app's when `app` is nil, rather than
    ///   off the Dock.
    public mutating func pointerOnDock(app: Int32?, onIcon: Bool) -> [Action] {
        hovered = app
        guard let app else {
            pending = nil
            guard shown != nil, !isInPanel else { return [.stopShowTimer] }
            // On another icon the Dock shows that icon's name at once, and the panel must not linger over it. Only
            // off the Dock may the pointer be on its way to the panel.
            guard !onIcon else {
                shown = nil
                return [.stopShowTimer, .stopHideTimer, .hide]
            }
            return [.stopShowTimer, .startHideTimer]
        }
        if app == shown {
            pending = nil
            return [.stopShowTimer, .stopHideTimer]
        }
        // Moving along the Dock with a panel up goes straight to the next app, as the taskbar does.
        if shown != nil {
            shown = app
            pending = nil
            return [.stopShowTimer, .stopHideTimer, .show(app)]
        }
        pending = app
        return [.startShowTimer]
    }

    public mutating func pointerInPanel(_ inside: Bool) -> [Action] {
        isInPanel = inside
        if inside { return [.stopHideTimer] }
        guard let shown, shown != hovered else { return [] }
        return [.startHideTimer]
    }

    public mutating func showTimerFired() -> [Action] {
        defer { pending = nil }
        guard let pending, pending == hovered else { return [] }
        shown = pending
        return [.show(pending)]
    }

    public mutating func hideTimerFired() -> [Action] {
        guard shown != nil, !isInPanel, hovered != shown else { return [] }
        shown = nil
        return [.hide]
    }

    /// The app had nothing to show after all, so its icon shows no panel until the pointer comes to it again.
    public mutating func nothingToShow() {
        shown = nil
    }

    /// A click, a change of Space, Command-Tab: whatever is up goes at once and nothing waits to show.
    public mutating func dismiss() -> [Action] {
        let wasShown = shown != nil
        shown = nil
        pending = nil
        isInPanel = false
        return [.stopShowTimer, .stopHideTimer] + (wasShown ? [.hide] : [])
    }
}

/// What makes a press on an icon a click, and what the click does.
public enum DockClick {
    /// A longer press opens the icon's menu.
    public static let longestPress: TimeInterval = 0.5
    /// A longer move drags the icon.
    public static let farthestMove: CGFloat = 5

    public static func isClick(from down: CGPoint, to up: CGPoint, after seconds: TimeInterval) -> Bool {
        seconds >= 0 && seconds <= longestPress && hypot(up.x - down.x, up.y - down.y) <= farthestMove
    }

    /// Only the app that was in front when the button went down, with a window in sight: the Dock brings any other
    /// app forward or back its minimized window, and that stays its job.
    public static func action(
        _ setting: DockTuning.ClickAction, appWasFrontmost: Bool, hasWindowsInSight: Bool
    ) -> DockTuning.ClickAction {
        appWasFrontmost && hasWindowsInSight ? setting : .nothing
    }
}

/// Which edge the Dock is on, and where its panel goes. Screen coordinates with the origin at the bottom left.
public enum DockGeometry {
    public enum Edge: Equatable, Sendable {
        case bottom, left, right
    }

    public static func edge(ofDock dock: CGRect, on screen: CGRect) -> Edge {
        if dock.width >= dock.height { return .bottom }
        return dock.midX < screen.midX ? .left : .right
    }

    /// Where the Dock puts the bubble with an app's name, centred on the icon, and moved along the Dock as far as it
    /// takes to stay on the screen. A panel taller or wider than the room keeps its side towards the Dock in place.
    public static func panelOrigin(
        size: CGSize, icon: CGRect, edge: Edge, visible: CGRect,
        gap: CGFloat = DockTuning.panelGap, margin: CGFloat = DockTuning.screenMargin
    ) -> CGPoint {
        func along(_ center: CGFloat, length: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            let lowest = low + margin
            let highest = high - margin - length
            return (min(max(center - length / 2, lowest), max(highest, lowest))).rounded()
        }
        switch edge {
        case .bottom:
            return CGPoint(
                x: along(icon.midX, length: size.width, low: visible.minX, high: visible.maxX),
                y: (icon.maxY + gap).rounded())
        case .left:
            return CGPoint(
                x: (icon.maxX + gap).rounded(),
                y: along(icon.midY, length: size.height, low: visible.minY, high: visible.maxY))
        case .right:
            return CGPoint(
                x: (icon.minX - gap - size.width).rounded(),
                y: along(icon.midY, length: size.height, low: visible.minY, high: visible.maxY))
        }
    }

    /// Where along the panel's edge towards the Dock its drop points at the icon: opposite the icon, but never into the
    /// panel's rounded corners. Measured from the panel's own origin, along that edge.
    public static func tailOffset(icon: CGRect, panel: CGRect, edge: Edge, cornerRadius: CGFloat) -> CGFloat {
        let (center, low, length) =
            edge == .bottom ? (icon.midX, panel.minX, panel.width) : (icon.midY, panel.minY, panel.height)
        return min(max(center - low, cornerRadius), max(length - cornerRadius, cornerRadius)).rounded()
    }

    /// The most the panel's tiles may cover, leaving most of the screen in view: a little less than the width along a
    /// bottom Dock and under half the height above it, and the other way round beside one at the side.
    public static func room(for edge: Edge, visible: CGRect) -> (available: CGSize, overflow: CGSize) {
        switch edge {
        case .bottom:
            return (
                CGSize(width: visible.width * 0.9, height: visible.height * 0.45),
                CGSize(width: visible.width * 0.9, height: visible.height * 0.75)
            )
        case .left, .right:
            return (
                CGSize(width: visible.width * 0.5, height: visible.height * 0.9),
                CGSize(width: visible.width * 0.75, height: visible.height * 0.9)
            )
        }
    }
}
