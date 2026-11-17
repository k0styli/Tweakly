import Foundation
import IOKit.ps

/// PRIVATE INTERFACE. Batteries of Bluetooth accessories, as the system's Batteries widget sees them: IOKit's
/// `IOPSCopyPowerSourcesByType` with type 4, accessories only (0 is all, 1 the internal battery, 2 a UPS, 3 both). AirPods
/// come as one power source per part with a part and a group identifier. It needs no permission, unlike Bluetooth
/// itself. Checked on macOS 27.2: types 0, 1 and 3 list the internal battery and 2 and 4 nothing without accessories.
/// Without the symbol the page shows no accessories and says why.
enum AccessoryPowerSources {
    private struct Symbols: @unchecked Sendable {
        // Unchecked: a function pointer looked up once and never changed.
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        let byType: ByType?

        init() {
            let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
            byType = PrivateSymbols.find("IOPSCopyPowerSourcesByType", in: library).map {
                unsafeBitCast($0, to: ByType.self)
            }
        }
    }

    private static let accessoriesOnly: Int32 = 4
    private static let symbols = Symbols()

    static var isAvailable: Bool { symbols.byType != nil }

    /// Posted for accessories, which the public `kIOPSNotifyAnyPowerSource` leaves out.
    static let notifications = [
        "com.apple.system.accpowersources.source", "com.apple.system.accpowersources.attach",
    ]

    static func descriptions() -> [[String: Any]] {
        guard let byType = symbols.byType, let info = byType(accessoriesOnly)?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}

extension BatteryHealthReader {
    /// Whether accessories can be read at all on this system.
    public static var readsAccessories: Bool { AccessoryPowerSources.isAvailable }
}
