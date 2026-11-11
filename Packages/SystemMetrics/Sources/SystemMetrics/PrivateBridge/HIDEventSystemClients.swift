import Darwin
import IOKit.hidsystem

/// PRIVATE INTERFACE. A client of the HID event system of the passive kind, which may read and set
/// a mouse's pointer resolution and its linear acceleration, the two properties behind a mouse's own speed and its
/// acceleration switch. The public simple client may not even read them: on macOS 27.2 it answers only the properties
/// `IOHIDProperties.h` lists, and of those only `HIDMouseAcceleration` concerns the pointer.
///
/// Checked on macOS 27.2 on an M2 from an app with no permission at all, neither Accessibility nor Input Monitoring: the
/// passive client reads and sets both, and the system asks for nothing. LinearMouse uses `IOHIDEventSystemClientCreate`,
/// which makes the monitor kind, the one that receives events and so may need Input Monitoring; a passive client
/// receives none. Without the symbol there is no client, and the mouse tweak leaves the pointer to the system and says
/// so on its page.
public enum HIDEventSystemClients {
    /// A function pointer looked up once and never changed, which is what makes sharing it safe.
    private struct Symbols: @unchecked Sendable {
        typealias CreateWithType =
            @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?
        let create: CreateWithType?

        init() {
            let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
            create = PrivateSymbols.find("IOHIDEventSystemClientCreateWithType", in: library).map {
                unsafeBitCast($0, to: CreateWithType.self)
            }
        }
    }

    private static let symbols = Symbols()
    /// `kIOHIDEventSystemClientTypePassive` in IOHIDFamily's private headers.
    private static let passiveType: Int32 = 2

    /// Whether this macOS still has the call, without making a client.
    public static var canMakePassive: Bool { symbols.create != nil }

    public static func passive() -> IOHIDEventSystemClient? {
        symbols.create?(kCFAllocatorDefault, passiveType, nil)?.takeRetainedValue()
    }
}
