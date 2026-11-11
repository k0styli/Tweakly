/// Which windows were used last, across Spaces.
///
/// The window server's order cannot say. Its full list is not ordered, a window on another Space has no place among
/// those on screen, and activating an app brings all its windows forward together, so the window behind the current
/// one is often just another of the same app. On the other hand that order is always right about the windows of
/// one app, because no event reports a click from one of its windows to another. So this list remembers the order
/// between apps and Spaces, and defers to the window server within an app.
public struct WindowRecency: Equatable, Sendable {
    /// Most recent first.
    public private(set) var recent: [UInt32] = []

    public init() {}

    public mutating func markUsed(_ window: UInt32) {
        recent.removeAll { $0 == window }
        recent.insert(window, at: 0)
        // Only `order` forgets what has gone, and someone may not press Command-Tab for weeks while using other apps.
        if recent.count > Self.mostRemembered { recent.removeLast() }
    }

    private static let mostRemembered = 256

    /// Orders the windows for a session and forgets those that are gone.
    ///
    /// - Parameters:
    ///   - windows: from `WindowFilter`, so those on screen come first and front to back.
    ///   - front: the window in use right now, if any.
    ///   - isSetAside: minimized and hidden windows, which someone put away on purpose and go last.
    public mutating func order(
        _ windows: [WindowRecord], front: UInt32?, isSetAside: (WindowRecord) -> Bool
    ) -> [WindowRecord] {
        if let front { markUsed(front) }
        var byID: [UInt32: WindowRecord] = [:]
        for window in windows { byID[window.id] = window }
        var ordered = recent.compactMap { byID[$0] }
        let known = Set(ordered.map(\.id))

        // New on screen: right behind whatever it is behind now. New out of sight: nothing says when, so last.
        var above: UInt32?
        for window in windows where window.isOnScreen {
            if !known.contains(window.id) {
                let position = above.flatMap { id in ordered.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
                ordered.insert(window, at: position)
            }
            above = window.id
        }
        ordered += windows.filter { !$0.isOnScreen && !known.contains($0.id) }

        Self.followWindowServerWithinEachApp(&ordered, zOrder: windows.filter(\.isOnScreen))
        if let front, let position = ordered.firstIndex(where: { $0.id == front }) {
            ordered.insert(ordered.remove(at: position), at: 0)
        }

        // Asking costs a call to the window server, so each window is asked once.
        var inUse: [WindowRecord] = []
        var setAside: [WindowRecord] = []
        for window in ordered {
            if isSetAside(window) { setAside.append(window) } else { inUse.append(window) }
        }
        let result = inUse + setAside
        recent = result.map(\.id)
        return result
    }

    /// Keeps the places each app has in the list, and fills them with its windows in front-to-back order.
    private static func followWindowServerWithinEachApp(_ ordered: inout [WindowRecord], zOrder: [WindowRecord]) {
        var depth: [UInt32: Int] = [:]
        for (index, window) in zOrder.enumerated() { depth[window.id] = index }
        var places: [Int32: [Int]] = [:]
        for (position, window) in ordered.enumerated() where depth[window.id] != nil {
            places[window.ownerPID, default: []].append(position)
        }
        for positions in places.values where positions.count > 1 {
            let sorted = positions.map { ordered[$0] }.sorted { (depth[$0.id] ?? 0) < (depth[$1.id] ?? 0) }
            for (position, window) in zip(positions, sorted) { ordered[position] = window }
        }
    }
}
