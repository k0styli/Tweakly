import Foundation

/// Reads what an iPhone's companion proxy says about a paired Apple Watch. The proxy answers one key at a time from the
/// watch's registry on the phone; only the charge and whether it charges are there, not its capacity. These are the keys
/// AirBattery reads; coconutBattery reads no watch at all. Not checked on a watch here: the iPhone tried has none.
public enum WatchParser {
    public static let keys = [
        "DeviceName", "ProductType", "ProductVersion", "BatteryCurrentCapacity", "BatteryIsCharging",
    ]

    public static func reading(_ values: [String: Any], date: Date) -> BatteryReading? {
        guard let percent = RegistryParser.int(values["BatteryCurrentCapacity"]), (0...100).contains(percent) else {
            return nil
        }
        var reading = BatteryReading(date: date)
        reading.percent = percent
        let isCharging = RegistryParser.bool(values["BatteryIsCharging"]) ?? false
        reading.state = isCharging ? .charging : .discharging
        reading.designCycleCount = MobileDeviceParser.designCycleCount(productType: values["ProductType"] as? String)
        return reading
    }
}
