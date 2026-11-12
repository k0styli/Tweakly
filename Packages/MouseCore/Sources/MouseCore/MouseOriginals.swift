import Foundation

/// What each mouse had before Tweakly changed it, kept on disk while the change is in place.
///
/// The values Tweakly sets stay on the mouse after the process ends, until it is plugged in again. Read again after a
/// crash, a force quit or a kill, the mouse's own values would already be Tweakly's: the speed would be halved once more
/// at each start, and turning the tweak off would put back Tweakly's values rather than the system's. So what was read
/// first is kept until it has been put back.
public struct MouseOriginals: Codable, Equatable, Sendable {
    /// One mouse's values as the HID system reports them.
    public struct Values: Codable, Equatable, Sendable {
        /// Counts an inch.
        public var resolution: Double
        /// `HIDUseLinearScalingMouseAcceleration`, nil when the mouse had none.
        public var linear: Int?
        /// `HIDMouseAcceleration` in the HID system's 16.16 fixed point, nil when the mouse had none.
        public var acceleration: Int64?

        public init(resolution: Double, linear: Int?, acceleration: Int64?) {
            self.resolution = resolution
            self.linear = linear
            self.acceleration = acceleration
        }
    }

    /// By the mouse's registry ID, which stays while it is plugged in and changes when it is plugged in again, which
    /// is also when the system gives it its own values back.
    public private(set) var byMouse: [String: Values] = [:]

    public init() {}

    public var isEmpty: Bool { byMouse.isEmpty }

    /// The values to go back to for this mouse: those kept from before, if Tweakly had already changed it, otherwise
    /// what it has now, which are then kept.
    public mutating func original(of mouse: UInt64, now current: Values) -> Values {
        if let kept = byMouse[String(mouse)] { return kept }
        byMouse[String(mouse)] = current
        return current
    }

    public func kept(for mouse: UInt64) -> Values? {
        byMouse[String(mouse)]
    }

    /// Once its values are back.
    public mutating func forget(_ mouse: UInt64) {
        byMouse[String(mouse)] = nil
    }

    /// Mice no longer plugged in got their own values back from the system when they went.
    public mutating func keepOnly(_ mice: Set<UInt64>) {
        byMouse = byMouse.filter { key, _ in UInt64(key).map(mice.contains) ?? false }
    }
}
