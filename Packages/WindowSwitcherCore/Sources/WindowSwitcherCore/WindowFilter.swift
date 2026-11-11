import CoreGraphics

/// One entry of the window server's list, reduced to what decides whether it gets a tile.
public struct WindowRecord: Equatable, Sendable {
    public var id: UInt32
    public var ownerPID: Int32
    public var title: String
    public var frame: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(
        id: UInt32, ownerPID: Int32, title: String, frame: CGRect, layer: Int = 0, alpha: Double = 1,
        isOnScreen: Bool
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// What Accessibility says a window of an app is.
public enum WindowKind: Equatable, Sendable {
    /// A window with the title bar of one.
    case standard
    /// A window of its own in a dialog's role. An app can also use this for a bubble, as Telegram does for a menu.
    case dialog
    /// A window by role, of no kind Accessibility can name. Measured: Chrome's find bar and its "Press ⌘Q again" notice,
    /// and Telegram's notices, all untitled and with no close button. Reported by others as the kind of real windows too:
    /// Firefox's full-screen video and the windows of some games, which are titled or big.
    case unusual
    /// Listed with the app's windows under another role, as Firefox's downloads popup is, with the role of a popover and
    /// a window number of its own.
    case part
    /// Not among the app's windows, as a sheet or a popover usually is not. An app's list can also simply miss a window.
    case notListed

    public init(role: String, subrole: String?) {
        guard role == "AXWindow" else {
            self = .part
            return
        }
        switch subrole {
        case "AXStandardWindow": self = .standard
        case "AXDialog": self = .dialog
        default: self = .unusual
        }
    }
}

/// Decides which entries of the window server's list are windows a person would call windows.
///
/// That list is mostly not: on macOS 27.2 each app also owns several untitled 1470×33 and 64×64 windows that
/// never appear on screen. A window out of sight is told apart by the Spaces it belongs to, which only a private
/// call reports: a window on another Space or a minimized one belongs to one, while those stand-ins and a
/// background tab belong to none. On screen, anything an app shows can be a window of its own to the window server, so
/// Accessibility says what each one really is. See `WindowKind`.
public enum WindowFilter {
    private static let minimumSide: CGFloat = 60
    /// Both sides of a window this big make it more than a bubble, whatever Accessibility calls it.
    private static let bigSide: CGFloat = 400
    /// A strip is at most this share of the height of the window it belongs to.
    private static let largestStripShare: CGFloat = 1.0 / 3
    /// Window frames that should line up can be this far apart.
    private static let edgeTolerance: CGFloat = 1

    /// - Parameters:
    ///   - onScreen: the window server's on-screen list, which comes front to back.
    ///   - all: its full list, whose order says nothing about which window was used last.
    ///   - spaceCount: how many Spaces a window belongs to, or nil if the system cannot say.
    ///   - kind: what Accessibility says this window is, or nil if it cannot say. Asking means waiting for the app, so
    ///     an answer is worth keeping for as long as the window lasts.
    /// - Returns: windows on screen front to back, then those out of sight. If the Spaces cannot be read,
    ///   only windows on screen, because nothing else can be told apart from a stand-in or a background tab.
    public static func switchable(
        onScreen: [WindowRecord], all: [WindowRecord], regularApps: Set<Int32>,
        spaceCount: (UInt32) -> Int?, kind: (WindowRecord) -> WindowKind? = { _ in nil }
    ) -> [WindowRecord] {
        func isOrdinary(_ window: WindowRecord) -> Bool {
            window.layer == 0 && window.alpha > 0 && regularApps.contains(window.ownerPID)
                && window.frame.width >= minimumSide && window.frame.height >= minimumSide
        }
        let ordinary = onScreen.filter(isOrdinary)
        let visible = ordinary.filter { window in
            !isStrip(window, among: ordinary) && isReal(window, kind: kind(window), among: ordinary)
        }
        let seen = Set(ordinary.map(\.id))
        let hidden = all.filter { window in
            guard isOrdinary(window), !window.isOnScreen, !seen.contains(window.id) else { return false }
            guard (spaceCount(window.id) ?? 0) > 0 else { return false }
            // Most untitled windows out of sight are stand-ins, so one has to be confirmed to count. That also
            // rules out an untitled window on another Space, which Accessibility cannot see.
            return !window.title.isEmpty || kind(window) == .standard
        }
        return visible + hidden
    }

    /// A full-screen Chrome keeps its tabs and toolbar in untitled windows of their own, as wide as the window and
    /// touching it, and Accessibility lists some of them as windows too. Capturing one gives the same picture as the
    /// window itself. Told apart by shape, as a title needs Screen Recording and Accessibility can be out of reach.
    private static func isStrip(_ window: WindowRecord, among others: [WindowRecord]) -> Bool {
        guard window.title.isEmpty else { return false }
        return others.contains { other in
            other.id != window.id && other.ownerPID == window.ownerPID
                && abs(other.frame.minX - window.frame.minX) <= edgeTolerance
                && abs(other.frame.width - window.frame.width) <= edgeTolerance
                && window.frame.height <= other.frame.height * largestStripShare
                && window.frame.maxY >= other.frame.minY - edgeTolerance
                && window.frame.minY <= other.frame.maxY + edgeTolerance
        }
    }

    private static func isReal(_ window: WindowRecord, kind: WindowKind?, among others: [WindowRecord]) -> Bool {
        let siblings = others.filter { $0.id != window.id && $0.ownerPID == window.ownerPID }
        let isTitled = !window.title.isEmpty
        let isInside = siblings.contains { $0.frame.contains(window.frame) }
        switch kind {
        case .standard:
            return true
        case .part:
            return false
        case .notListed:
            return isTitled && !isInside
        case .dialog where isTitled:
            return true
        case .dialog, .unusual:
            let isBig = window.frame.width >= bigSide && window.frame.height >= bigSide
            return (isTitled || isBig) && !isInside
        case nil:
            // An app that does not answer must not lose its windows, so only what looks like nothing else goes.
            return isTitled
                || !siblings.contains { $0.frame.width * $0.frame.height > window.frame.width * window.frame.height }
        }
    }
}

extension WindowFilter {
    private static let finder = "com.apple.finder"

    /// A running app with no window gets a tile, or there would be no way to reach it from the switcher. Finder is
    /// the exception: it never quits, its only surface then is the desktop, which is always there to click, and
    /// its tile just looks like a window that does not exist.
    public static func getsTileWithoutWindows(bundleID: String?) -> Bool {
        bundleID != finder
    }

    /// Q does nothing to Finder in the system's switcher either. Asked to quit, it would close every window it has.
    public static func canBeQuit(bundleID: String?) -> Bool {
        bundleID != finder
    }
}

/// Finds a window among those Accessibility reports by what both sides know, for when the private call
/// that names a window's number is gone. Returns nil rather than guess between equally good candidates.
public enum WindowMatcher {
    public static func bestIndex(
        title: String, frame: CGRect, among candidates: [(title: String, frame: CGRect)]
    ) -> Int? {
        func only(_ test: ((title: String, frame: CGRect)) -> Bool) -> Int? {
            let matches = candidates.indices.filter { test(candidates[$0]) }
            return matches.count == 1 ? matches[0] : nil
        }
        return only { $0.title == title && $0.frame == frame }
            ?? only { $0.frame == frame }
            ?? (title.isEmpty ? nil : only { $0.title == title })
    }
}
