import CoreGraphics

/// UNDOCUMENTED FIELD. Which kind a system-defined event is, for an event tap that runs off the
/// main thread.
///
/// The documented way, `NSEvent(cgEvent:).subtype`, must not be used there: on macOS 27.2 converting an event that
/// follows a press of Caps Lock runs the system's input source handling, which asserts it is on the main queue and
/// takes the app down. It may also switch the input source. `CGEventField` has no name for this field, but 83 holds
/// the subtype on macOS 27.2 on an M2, checked against `NSEvent` for subtypes 0 to 40.
///
/// Should the field ever move, the answer stops matching any subtype, so a caller lets the event through.
public enum SystemDefinedEvent {
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the volume, brightness and playback keys.
    public static let auxiliaryKeysSubtype = 8

    private static let subtypeField = CGEventField(rawValue: 83)

    public static func subtype(of event: CGEvent) -> Int? {
        subtypeField.map { Int(event.getIntegerValueField($0)) }
    }
}
