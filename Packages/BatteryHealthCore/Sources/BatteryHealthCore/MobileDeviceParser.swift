import Foundation

/// Reads what an iPhone, iPad or iPod tells this Mac: its lockdown values, the `com.apple.mobile.battery` domain and the
/// battery's registry entry from the diagnostics service.
public enum MobileDeviceParser {
    /// The device's kind from its model identifier, such as "iPhone16,1".
    public static func kind(productType: String?) -> DeviceKind {
        guard let productType else { return .other }
        if productType.hasPrefix("iPhone") { return .iPhone }
        if productType.hasPrefix("iPad") { return .iPad }
        if productType.hasPrefix("iPod") { return .iPod }
        if productType.hasPrefix("Watch") { return .watch }
        return .other
    }

    /// Cycles after which Apple says the battery keeps 80 % of its capacity. iPhone 15 and later: 1000; earlier
    /// iPhones 500 (support.apple.com/en-us/101575, /118450). iPad, iPod and Apple Watch: 1000.
    public static func designCycleCount(productType: String?) -> Int? {
        guard let productType else { return nil }
        switch kind(productType: productType) {
        case .iPhone:
            // iPhone15,4 and 15,5 are iPhone 15 and 15 Plus; iPhone15,2 and 15,3 are the 14 Pro.
            guard let (major, minor) = modelNumbers(productType, prefix: "iPhone") else { return nil }
            return major > 15 || (major == 15 && minor >= 4) ? 1000 : 500
        case .iPad, .iPod, .watch: return 1000
        default: return nil
        }
    }

    /// The registry reading with the domain's charge, which the device keeps up to date between registry updates.
    public static func reading(
        registry: [String: Any]?, batteryDomain: [String: Any]?, productType: String?, date: Date
    ) -> BatteryReading {
        var reading = registry.map { RegistryParser.reading(registry: $0, date: date) } ?? BatteryReading(date: date)
        if let domain = batteryDomain {
            if let percent = RegistryParser.int(domain["BatteryCurrentCapacity"]), (0...100).contains(percent) {
                reading.percent = percent
            }
            let isCharging = RegistryParser.bool(domain["BatteryIsCharging"])
            let isConnected = RegistryParser.bool(domain["ExternalConnected"])
            let isFull = RegistryParser.bool(domain["FullyCharged"])
            if let isCharging, let isConnected {
                reading.state =
                    isCharging ? .charging : isConnected ? (isFull == true ? .charged : .notCharging) : .discharging
            }
        }
        if reading.designCycleCount == nil { reading.designCycleCount = designCycleCount(productType: productType) }
        // The system's power figures on a phone are the whole device, and the adapter's is only worth showing while
        // something is plugged in.
        if !reading.isOnPower {
            reading.adapter = nil
            reading.adapterPower = nil
        }
        return reading
    }

    static func modelNumbers(_ productType: String, prefix: String) -> (Int, Int)? {
        let numbers = productType.dropFirst(prefix.count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}
