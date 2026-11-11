import Carbon
import IOKit.hidsystem
import os

/// What wiping the keys may change even while they are swallowed, because it happens below event taps: Caps Lock, and
/// the input source if Caps Lock or Globe switches it. It is put back afterwards, so the first thing typed after
/// cleaning is not in the wrong case or language.
struct KeyboardState {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "keyboard-cleaning")

    private let capsLock: Bool?
    private let inputSource: TISInputSource?

    init() {
        capsLock = Self.readCapsLock()
        inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    func restore() {
        // In this order, as selecting an input source resets Caps Lock. Only when it changed: selecting one tells every
        // app the language changed, and shows its name by the cursor.
        if let inputSource, InputSources.identifier(of: inputSource) != InputSources.currentIdentifier {
            TISSelectInputSource(inputSource)
        }
        if let capsLock, Self.readCapsLock() != capsLock { Self.writeCapsLock(capsLock) }
    }

    private static func withSystem<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return nil }
        defer { IOServiceClose(connection) }
        return body(connection)
    }

    private static func readCapsLock() -> Bool? {
        withSystem { connection in
            var state = false
            let status = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state)
            return status == KERN_SUCCESS ? state : nil
        }
    }

    private static func writeCapsLock(_ isOn: Bool) {
        let status = withSystem { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), isOn) }
        if status != KERN_SUCCESS { log.notice("Could not put Caps Lock back") }
    }
}
