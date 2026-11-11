import CoreGraphics

/// UNDOCUMENTED EVENT. The trackpad's swipe to go back or forward, posted as the two gesture events
/// the system sends for it, began and ended, so apps that know the swipe but not a mouse's side buttons, Safari and
/// Finder among them, go back and forward.
///
/// `CGEventType` has no name for the gesture type, 29, nor `CGEventField` for its fields: 110 is the HID event type, 16
/// for a navigation swipe; 132 the phase, 1 began and 4 ended; 115 the direction, 0x04 left for back and 0x08 right for
/// forward. These are LinearMouse's values; checked on macOS 27.2 on an M2, where Firefox went back and forward on them.
/// Should a macOS stop understanding them, apps simply see nothing happen.
public enum NavigationSwipe {
    public enum Direction: Sendable {
        case back, forward
    }

    private static let gestureType = CGEventType(rawValue: 29)
    private static let hidTypeField = CGEventField(rawValue: 110)
    private static let phaseField = CGEventField(rawValue: 132)
    private static let directionField = CGEventField(rawValue: 115)
    private static let navigationSwipe: Int64 = 16
    private static let began: Int64 = 1
    private static let ended: Int64 = 4

    public static func post(_ direction: Direction) {
        guard let gestureType, let hidTypeField, let phaseField, let directionField else { return }
        for phase in [began, ended] {
            guard let event = CGEvent(source: nil) else { continue }
            event.type = gestureType
            event.setIntegerValueField(hidTypeField, value: navigationSwipe)
            event.setIntegerValueField(phaseField, value: phase)
            if phase == began { event.setIntegerValueField(directionField, value: direction == .back ? 0x04 : 0x08) }
            event.post(tap: .cgSessionEventTap)
        }
    }
}
