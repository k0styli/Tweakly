import BatteryHealthCore
import Foundation
import IOKit
import IOKit.ps
import notify

/// Reads batteries for the Battery Health page, in the window's process and only while the page is open: this Mac's
/// battery from the registry's `AppleSmartBattery` and `AppleSmartBatteryPack`, IOKit's power sources and the SMC (live
/// watts and temperature), each cell from `AppleSmartBatteryBank`; a UPS through the public power sources; Bluetooth accessories through IOKit's private
/// listing.
///
/// Each read runs on the reader's own queue and answers there.
public final class BatteryHealthReader: @unchecked Sendable {
    // Unchecked: `sensors`, `triedSensors`, `slow` and `registryCache` are touched only on `queue`.
    /// What this Mac reports about its own power.
    public struct MacReport: Sendable {
        /// Nil on a Mac with no battery.
        public var battery: BatteryReading?
        /// Watts the Mac uses: from the SMC each second, or the registry's figure from the last minute.
        public var systemPower: Double?
        public var ups: [PowerSourceParser.Accessory]
    }

    private var sensors: BatterySensorReader?
    private var triedSensors = false
    /// The pack's lifetime record moves by the hour, so it is read now and then.
    private var slow: (pack: [String: Any]?, time: TimeInterval)?
    private static let slowInterval: TimeInterval = 300
    /// The registry updates about once a minute and its whole dictionary, bridged to Swift, is most of a read's cost,
    /// so between the system's own notices it is fetched every 30 seconds while the SMC gives the live watts.
    private var registryCache: (values: [String: Any], time: TimeInterval)?
    private static let registryInterval: TimeInterval = 30

    private let queue = DispatchQueue(label: "me.tweakly.battery-health", qos: .utility)

    public init() {}

    /// This Mac's battery, a UPS and the accessories, read together. `fresh` fetches the registry again, for when the
    /// system said something changed.
    public func read(fresh: Bool, _ done: @escaping @Sendable (MacReport, [PowerSourceParser.Accessory]) -> Void) {
        queue.async { [self] in
            if fresh { registryCache = nil }
            let now = Date()
            done(readMac(now: now), PowerSourceParser.accessories(AccessoryPowerSources.descriptions(), date: now))
        }
    }

    /// Lets go of the SMC, for when the page closes.
    public func close() {
        queue.async { [self] in
            sensors = nil
            triedSensors = false
            slow = nil
            registryCache = nil
        }
    }

    func readMac(now: Date) -> MacReport {
        if sensors == nil, !triedSensors {
            triedSensors = true
            sensors = BatterySensorReader()
        }
        let sources = Self.publicSources()
        let builtIn = sources.first { $0["Type"] as? String == kIOPSInternalBatteryType }
        let ups = sources.compactMap { PowerSourceParser.ups($0, date: now) }
        let uptime = uptimeSeconds()
        if registryCache == nil || uptime - (registryCache?.time ?? 0) >= Self.registryInterval {
            registryCache = Self.registry("AppleSmartBattery").map { ($0, uptime) }
        }
        guard let registry = registryCache?.values, builtIn != nil || SystemInfo.hasBattery else {
            return MacReport(battery: nil, systemPower: sensors?.draw(onBattery: false), ups: ups)
        }
        var reading = RegistryParser.reading(registry: registry, date: now)
        if let builtIn { PowerSourceParser.applyInternal(builtIn, to: &reading) }

        switch SystemBatteryHealth.current() {
        case .known(let percent): reading.systemMaximumCapacity = percent
        case .pending, .unavailable: break
        }
        if reading.condition == nil, let condition = SystemBatteryHealth.condition() {
            reading.condition = condition == "Good" ? .normal : .serviceRecommended
        }
        if slow == nil || uptime - (slow?.time ?? 0) >= Self.slowInterval {
            slow = (Self.registry("AppleSmartBatteryPack"), uptime)
        }
        if let sensors {
            reading.temperature = reading.temperature ?? sensors.batteryTemperature(now: uptime)
            let onBattery = reading.state == .discharging
            if let draw = sensors.draw(onBattery: onBattery) { reading.systemPower = draw }
            if !onBattery, let input = sensors.adapterInput() { reading.adapterPower = input }
        }
        if let pack = slow?.pack { PackParser.apply(pack: pack, to: &reading) }
        // Each cell follows the registry, which the cache above already paces.
        reading.cellVoltages = Self.cellVoltages()
        if !reading.isOnPower {
            reading.adapter = nil
            reading.adapterPower = nil
        }
        return MacReport(battery: reading, systemPower: reading.systemPower, ups: ups)
    }

    private static func publicSources() -> [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// Volts of each cell group, from the battery's banks in the public registry. On the MacBook Air checked they add
    /// up to the pack's voltage, as the SMC's `BC1V`… did.
    private static func cellVoltages() -> [Double]? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryBank"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var banks: [[String: Any]] = []
        while case let bank = IOIteratorNext(iterator), bank != 0 {
            defer { IOObjectRelease(bank) }
            let data = IORegistryEntryCreateCFProperty(bank, "BatteryData" as CFString, kCFAllocatorDefault, 0)
            if let values = data?.takeRetainedValue() as? [String: Any] { banks.append(values) }
        }
        return PackParser.cellVoltages(banks: banks)
    }

    private static func registry(_ entryClass: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(entryClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let values = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return values
    }
}

/// Tells when any battery the system knows changes, accessories' too, so the page never polls for it.
public final class PowerSourceChanges {
    private var tokens: [Int32] = []

    public init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        for name in [kIOPSNotifyAnyPowerSource] + AccessoryPowerSources.notifications {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, queue, { _ in handler() }) == NOTIFY_STATUS_OK {
                tokens.append(token)
            }
        }
    }

    deinit {
        tokens.forEach { notify_cancel($0) }
    }
}
