import Foundation
import IOKit
import IOKit.ps
import notify

final class BatterySampler: MetricSampler {
    /// The registry updates about once a minute and its whole dictionary is read to get at a few keys, so a
    /// reading is kept for a while. A change of power source shows at once, as it decides what is read from it.
    private static let registryInterval: TimeInterval = 10
    private var sensors: BatterySensorReader?
    /// Tried once while the details are open: a Mac whose SMC refuses would otherwise be asked again every second.
    private var triedSensors = false
    private var registry: (health: BatteryHealth?, state: BatteryState, time: TimeInterval)?

    func reset() {
        closeDetails()
    }

    func closeDetails() {
        sensors = nil
        triedSensors = false
        registry = nil
    }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        var snapshot = Self.readPowerSource()
        guard level >= .summary, snapshot.isPresent else {
            // The sensors stay closed unless they are on screen, so the menu bar value never pays for them.
            closeDetails()
            return .battery(snapshot)
        }
        if sensors == nil, !triedSensors {
            triedSensors = true
            sensors = BatterySensorReader()
        }
        let now = uptimeSeconds()
        if registry == nil || registry?.state != snapshot.state
            || now - (registry?.time ?? 0) >= Self.registryInterval
        {
            var health = Self.readHealth()
            let maximumCapacity = Self.maximumCapacity(health)
            health?.maximumCapacityPercent = maximumCapacity
            registry = (health, snapshot.state, now)
        }
        // The system's own figure comes from a tool that answers in a few seconds, after the first look: until then
        // it is asked again with each reading, which only reads what came back.
        if let known = registry?.health, known.maximumCapacityPercent == nil {
            registry?.health?.maximumCapacityPercent = Self.maximumCapacity(known)
        }
        var health = registry?.health
        if health?.temperature == nil { health?.temperature = sensors?.batteryTemperature(now: now) }
        snapshot.health = health

        let onBattery = snapshot.state == .discharging
        // The sensors follow the load from second to second, while the registry falls behind by far more.
        // Without them, its figure only stands for the Mac's own use on battery: on a charger it says
        // what goes into the pack instead.
        snapshot.powerDraw = sensors?.draw(onBattery: onBattery) ?? (onBattery ? health?.power.map { abs($0) } : nil)
        if !onBattery { snapshot.adapterPower = sensors?.adapterInput() }
        return .battery(snapshot)
    }

    private static func maximumCapacity(_ health: BatteryHealth?) -> Int? {
        switch SystemBatteryHealth.current() {
        case .known(let percent):
            return percent
        case .pending:
            return nil
        case .unavailable:
            guard let full = health?.fullChargeCapacity, let design = health?.designCapacity, design > 0 else {
                return nil
            }
            return full * 100 / design
        }
    }

    private static func readPowerSource() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return snapshot }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
            snapshot.isPresent = true
            snapshot.percent = maximum > 0 ? min(max(current * 100 / maximum, 0), 100) : 0
            snapshot.state = isCharged ? .charged : isCharging ? .charging : onAC ? .notCharging : .discharging
            let minutes = description[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            snapshot.minutesRemaining = minutes.flatMap { $0 > 0 ? $0 : nil }
            break
        }
        return snapshot
    }

    private static func readHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let values = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        var result = health(from: values)
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        result.adapterWatts = adapter?[kIOPSPowerAdapterWattsKey] as? Int
        return result
    }

    /// Interprets `AppleSmartBattery` properties. Amperage arrives as a two's complement value, so
    /// reading it as a signed integer recovers its sign. Keys are undocumented, so each one is optional.
    static func health(from values: [String: Any]) -> BatteryHealth {
        var health = BatteryHealth()
        let details = values["BatteryData"] as? [String: Any]
        health.fullChargeCapacity = values["NominalChargeCapacity"] as? Int ?? details?["NominalChargeCapacity"] as? Int
        health.designCapacity = values["DesignCapacity"] as? Int ?? details?["DesignCapacity"] as? Int
        health.cycleCount = values["CycleCount"] as? Int
        health.designCycleCount = values["DesignCycleCount9C"] as? Int
        if let temperature = values["Temperature"] as? Int ?? values["VirtualTemperature"] as? Int {
            health.temperature = Double(temperature) / 100
        }
        if let voltage = values["Voltage"] as? Int {
            health.voltage = Double(voltage) / 1_000
        }
        if let amperage = (values["InstantAmperage"] ?? values["Amperage"]) as? NSNumber {
            health.current = Int(truncatingIfNeeded: amperage.int64Value)
            if let voltage = values["Voltage"] as? Int {
                health.power = -Double(voltage) * Double(amperage.int64Value) / 1_000_000
            }
        }
        return health
    }
}

/// Fires when the power source or remaining charge changes, so the battery never has to be polled.
final class PowerSourceObserver {
    private var tokens: [Int32] = []

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        // Any change of any power source's attributes, which covers the time remaining and the switch between the
        // adapter and the battery. Listening to those two as well woke the app two or three times for one change.
        var token: Int32 = 0
        let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, queue) { _ in handler() }
        if status == NOTIFY_STATUS_OK { tokens.append(token) }
    }

    deinit {
        tokens.forEach { notify_cancel($0) }
    }
}
