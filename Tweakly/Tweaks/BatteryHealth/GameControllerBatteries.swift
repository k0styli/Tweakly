import BatteryHealthCore
import Foundation
import GameController
import IOKit

/// Game controllers' batteries: PlayStation, Xbox, Switch Pro and MFi controllers, by Bluetooth or by cable. macOS gives
/// their charge only to the GameController framework, which needs no permission: on macOS 27.2 a DUALSHOCK 4 by
/// Bluetooth was missing from the power sources and from `system_profiler`, and GameController read 95 %. How it is
/// connected and its USB numbers come from its entry in the registry, found by name. Used only while the page is
/// chosen; connections and disconnections arrive as notifications.
final class GameControllerBatteries {
    struct Controller {
        var id: String
        var name: String
        var vendorID: Int?
        var productID: Int?
        var connection: Connection
        var reading: BatteryReading
    }

    private var observers: [NSObjectProtocol] = []

    init(changed: @escaping @MainActor () -> Void) {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { changed() }
                })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func read(now: Date) -> [Controller] {
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else { return [] }
        let hid = Self.hidDevices()
        return controllers.compactMap { controller in
            guard let battery = controller.battery else { return nil }
            let state: ChargeState? =
                switch battery.batteryState {
                case .charging: .charging
                case .full: .charged
                case .discharging: .discharging
                default: nil
                }
            // A controller that does not know its charge says 0 with an unknown state.
            guard state != nil || battery.batteryLevel > 0 else { return nil }
            var reading = BatteryReading(date: now)
            reading.percent = min(max(Int((battery.batteryLevel * 100).rounded()), 0), 100)
            reading.state = state
            let name = controller.vendorName ?? controller.productCategory
            let entry = hid[name]
            let numbers = entry.map { "\($0.vendor):\($0.product)" } ?? controller.productCategory
            return Controller(
                id: DeviceIdentity.id(kind: "controller", raw: numbers + ":" + name), name: name,
                vendorID: entry?.vendor, productID: entry?.product,
                connection: entry?.transport == "USB" ? .usb : .bluetooth, reading: reading)
        }
    }

    /// HID devices by their product name, as GameController names them. About 20 entries, well under a millisecond.
    private static func hidDevices() -> [String: (vendor: Int, product: Int, transport: String?)] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator)
                == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var found: [String: (vendor: Int, product: Int, transport: String?)] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let name = value("Product") as? String, let vendor = value("VendorID") as? Int,
                let product = value("ProductID") as? Int
            else { continue }
            found[name] = (vendor, product, value("Transport") as? String)
        }
        return found
    }
}
