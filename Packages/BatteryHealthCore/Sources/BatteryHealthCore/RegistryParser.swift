import Foundation

/// Reads the `AppleSmartBattery` entry of the I/O Registry. A Mac has it in its own registry; an iPhone, iPad or iPod
/// sends the same entry through its diagnostics service. None of its keys is documented, so each one is optional and
/// anything out of range counts as missing. Checked on a MacBook Air M2 with macOS 27.2 and an iPhone 15 Pro with
/// iOS 27.2.1.
public enum RegistryParser {
    /// The registry says 65535 for a time it has not worked out.
    private static let unknownTime = 65_535

    public static func reading(registry: [String: Any], date: Date) -> BatteryReading {
        var reading = BatteryReading(date: date)
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        /// Apple silicon keeps the capacities in `BatteryData`, Intel Macs and older devices at the top.
        func value(_ key: String) -> Any? { data[key] ?? registry[key] }
        func capacity(_ key: String) -> Int? {
            guard let number = int(value(key)), number > 0, number < 1_000_000 else { return nil }
            return number
        }

        reading.designCapacity = capacity("DesignCapacity")
        reading.fullChargeCapacity = capacity("AppleRawMaxCapacity") ?? capacity("FullChargeCapacity")
        reading.nominalChargeCapacity = capacity("NominalChargeCapacity")
        reading.remainingCapacity = capacity("AppleRawCurrentCapacity") ?? capacity("RemainingCapacity")
        if let cycles = int(registry["CycleCount"]), cycles >= 0, cycles < 100_000 {
            reading.cycleCount = cycles
        }
        if let cycles = int(registry["DesignCycleCount9C"]), cycles > 0, cycles < 100_000 {
            reading.designCycleCount = cycles
        }
        // Apple silicon reports charge in percent here, Intel in milliamp-hours against `MaxCapacity`.
        if let current = int(registry["CurrentCapacity"]), let maximum = int(registry["MaxCapacity"]), maximum > 0 {
            reading.percent = min(max(Int((Double(current) * 100 / Double(maximum)).rounded()), 0), 100)
        }

        let isCharging = bool(registry["IsCharging"]) ?? false
        let isFull = bool(registry["FullyCharged"]) ?? false
        let isConnected = bool(registry["ExternalConnected"]) ?? false
        reading.state =
            isCharging ? .charging : isConnected ? (isFull ? .charged : .notCharging) : .discharging

        if let millivolts = int(registry["Voltage"] ?? registry["AppleRawBatteryVoltage"]), millivolts > 0,
            millivolts < 100_000
        {
            reading.voltage = Double(millivolts) / 1_000
        }
        // A two's complement value: reading it as a signed number of 64 bits recovers the sign.
        if let number = (registry["InstantAmperage"] ?? registry["Amperage"]) as? NSNumber {
            let milliamps = Double(Int(truncatingIfNeeded: number.int64Value))
            if abs(milliamps) < 100_000 {
                reading.current = milliamps / 1_000
                if let voltage = reading.voltage { reading.batteryPower = voltage * milliamps / 1_000 }
            }
        }
        // Intel Macs and older iPhones give the temperature in hundredths of a degree.
        if let hundredths = int(registry["Temperature"] ?? registry["VirtualTemperature"]),
            (-4_000...10_000).contains(hundredths), hundredths != 0
        {
            reading.temperature = Double(hundredths) / 100
        }
        // On power and not charging, the time left means nothing to show.
        if isCharging || !isConnected, let minutes = time(registry, isCharging: isCharging) {
            reading.minutesRemaining = minutes
        }

        if let telemetry = registry["PowerTelemetryData"] as? [String: Any] {
            if let load = int(telemetry["SystemLoad"]), load > 0, load < 1_000_000 {
                reading.systemPower = Double(load) / 1_000
            }
            if isConnected, let input = int(telemetry["SystemPowerIn"]), input > 0, input < 1_000_000 {
                reading.adapterPower = Double(input) / 1_000
            }
        }
        if isConnected, let details = registry["AdapterDetails"] as? [String: Any] {
            reading.adapter = adapter(details)
        }
        if let outputs = registry["PowerOutDetails"] as? [[String: Any]] {
            let watts = outputs.compactMap { int($0["Watts"]) }.filter { $0 > 0 && $0 < 1_000_000 }
            if !watts.isEmpty { reading.powerToAccessories = Double(watts.reduce(0, +)) / 1_000 }
        }
        if let gauge = registry["DeviceName"] as? String, !gauge.isEmpty { reading.gauge = gauge }
        return reading
    }

    /// The adapter as the device describes it. Apple's name their wattage and kind; others often only say "pd charger".
    static func adapter(_ details: [String: Any]) -> PowerAdapter? {
        var adapter = PowerAdapter()
        if let name = (details["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            adapter.name = name
        }
        if let maker = (details["Manufacturer"] as? String)?.trimmingCharacters(in: .whitespaces), !maker.isEmpty {
            adapter.manufacturer = maker
        }
        if let watts = int(details["Watts"]), watts > 0, watts < 1_000 { adapter.watts = watts }
        if let millivolts = int(details["AdapterVoltage"]), millivolts > 0, millivolts < 100_000 {
            adapter.voltage = Double(millivolts) / 1_000
        }
        if let milliamps = int(details["Current"]), milliamps > 0, milliamps < 100_000 {
            adapter.current = Double(milliamps) / 1_000
        }
        adapter.isWireless = bool(details["IsWireless"]) ?? false
        return adapter == PowerAdapter() ? nil : adapter
    }

    private static func time(_ registry: [String: Any], isCharging: Bool) -> Int? {
        let keys = isCharging ? ["AvgTimeToFull"] : ["TimeRemaining", "AvgTimeToEmpty"]
        for key in keys {
            if let minutes = int(registry[key]), minutes > 0, minutes < unknownTime { return minutes }
        }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let number as Int: number
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let number as Int: number != 0
        default: nil
        }
    }
}
