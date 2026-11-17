import Foundation

/// Reads descriptions from IOKit's power sources: the internal battery and a UPS through the public API, and Bluetooth
/// accessories through the private listing that the Batteries widget is built on. Keys of accessories are not
/// documented.
public enum PowerSourceParser {
    /// One device made of the power sources that share an accessory: AirPods come as left, right and case.
    public struct Accessory: Equatable, Sendable {
        /// Stable for the device and never shown: its Bluetooth address or the system's identifier.
        public var identifier: String
        public var name: String
        public var kind: DeviceKind
        public var vendorID: Int?
        public var productID: Int?
        public var reading: BatteryReading
    }

    /// The internal battery's charge, state and time, which the system works out better than the registry does.
    public static func applyInternal(_ description: [String: Any], to reading: inout BatteryReading) {
        if let percent = percent(description) { reading.percent = percent }
        let isCharging = RegistryParser.bool(description["Is Charging"]) ?? false
        let isCharged = RegistryParser.bool(description["Is Charged"]) ?? false
        let onPower = description["Power Source State"] as? String == "AC Power"
        reading.state = isCharged ? .charged : isCharging ? .charging : onPower ? .notCharging : .discharging
        let key = isCharging ? "Time to Full Charge" : "Time to Empty"
        // Zero or less while the system is still estimating, and when full.
        reading.minutesRemaining = RegistryParser.int(description[key]).flatMap { $0 > 0 ? $0 : nil }
        if let lowPower = RegistryParser.bool(description["LPM Active"]) { reading.isLowPowerMode = lowPower }
        switch description["BatteryHealthCondition"] as? String {
        case nil: break
        case "": reading.condition = .normal
        default: reading.condition = .serviceRecommended
        }
    }

    /// A UPS on a USB port, read through the public API.
    public static func ups(_ description: [String: Any], date: Date) -> Accessory? {
        guard description["Type"] as? String == "UPS" else { return nil }
        var reading = BatteryReading(date: date)
        reading.percent = percent(description)
        let isCharging = RegistryParser.bool(description["Is Charging"]) ?? false
        let onPower = description["Power Source State"] as? String == "AC Power"
        reading.state = isCharging ? .charging : onPower ? .charged : .discharging
        if let minutes = RegistryParser.int(description["Time to Empty"]), minutes > 0, !onPower {
            reading.minutesRemaining = minutes
        }
        let name = (description["Name"] as? String) ?? "UPS"
        let identifier = [
            description["Vendor ID"].map { "\($0)" }, description["Product ID"].map { "\($0)" }, name,
        ].compactMap(\.self).joined(separator: ":")
        return Accessory(
            identifier: "ups:" + identifier, name: name, kind: .ups,
            vendorID: RegistryParser.int(description["Vendor ID"]),
            productID: RegistryParser.int(description["Product ID"]), reading: reading)
    }

    /// Accessories from the private listing, with parts of one device put together.
    public static func accessories(_ descriptions: [[String: Any]], date: Date) -> [Accessory] {
        var order: [String] = []
        var found: [String: Accessory] = [:]
        for description in descriptions {
            let type = description["Type"] as? String
            guard type != "InternalBattery", type != "UPS", let percent = percent(description) else { continue }
            let group =
                (description["Group Identifier"] as? String) ?? (description["Accessory Identifier"] as? String)
                ?? (description["Name"] as? String) ?? "accessory"
            let isCharging = RegistryParser.bool(description["Is Charging"]) ?? false
            let role = partRole(description["Part Identifier"] as? String)
            var accessory =
                found[group]
                ?? Accessory(
                    identifier: "accessory:" + group, name: (description["Name"] as? String) ?? "",
                    kind: kind(description), vendorID: RegistryParser.int(description["Vendor ID"]),
                    productID: RegistryParser.int(description["Product ID"]), reading: BatteryReading(date: date))
            if let role {
                accessory.reading.parts.append(BatteryPart(role: role, percent: percent, isCharging: isCharging))
                // The case names the whole set less well than an earbud does ("AirPods Pro Case").
                if role != .chargingCase, let name = description["Name"] as? String, !name.isEmpty {
                    accessory.name = name
                }
            } else {
                accessory.reading.percent = percent
                accessory.reading.state = isCharging ? .charging : .discharging
            }
            if found[group] == nil { order.append(group) }
            found[group] = accessory
        }
        return order.compactMap { group in
            guard var accessory = found[group] else { return nil }
            accessory.reading.parts.sort { $0.role.order < $1.role.order }
            if accessory.reading.percent == nil, accessory.reading.parts.contains(where: \.isCharging) {
                accessory.reading.state = .charging
            }
            return accessory
        }
    }

    static func percent(_ description: [String: Any]) -> Int? {
        guard let current = RegistryParser.int(description["Current Capacity"]) else { return nil }
        let maximum = RegistryParser.int(description["Max Capacity"]) ?? 100
        guard maximum > 0, current >= 0 else { return nil }
        return min(Int((Double(current) * 100 / Double(maximum)).rounded()), 100)
    }

    static func partRole(_ part: String?) -> BatteryPart.Role? {
        switch part?.lowercased() {
        case "left": .left
        case "right": .right
        case "case": .chargingCase
        case "single", "combined": .single
        default: nil
        }
    }

    /// The category the system gives, or failing that what the name and Apple's product numbers say.
    static func kind(_ description: [String: Any]) -> DeviceKind {
        let category = (description["Accessory Category"] as? String ?? "").lowercased()
        let name = (description["Name"] as? String ?? "").lowercased()
        let text = category + " " + name
        if text.contains("mouse") { return .mouse }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("keyboard") { return .keyboard }
        if text.contains("headphone") || text.contains("headset") || text.contains("audio") || text.contains("airpods")
            || text.contains("beats") || text.contains("buds")
        {
            return .headphones
        }
        if text.contains("speaker") || text.contains("soundbar") { return .speaker }
        if text.contains("game") || text.contains("controller") { return .gameController }
        if text.contains("watch") { return .watch }
        return .other
    }
}

extension BatteryPart.Role {
    /// Left, right, then the case, as the system lists them.
    var order: Int {
        switch self {
        case .left: 0
        case .right: 1
        case .single: 2
        case .chargingCase: 3
        }
    }
}
