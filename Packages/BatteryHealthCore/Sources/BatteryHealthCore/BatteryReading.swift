import Foundation

/// What kind of thing a battery belongs to, which decides its picture, its words and what is worth showing about it.
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case mac
    case iPhone
    case iPad
    case iPod
    case watch
    case headphones
    case speaker
    case mouse
    case keyboard
    case trackpad
    case gameController
    case ups
    case other

    /// Devices whose battery reports its capacity, so health can be worked out.
    public var reportsCapacity: Bool {
        switch self {
        case .mac, .iPhone, .iPad, .iPod: true
        default: false
        }
    }
}

/// How the data reached this Mac.
public enum Connection: String, Codable, Sendable {
    case builtIn
    case usb
    case wifi
    case bluetooth
    /// Asked of the iPhone it is paired with, as Apple Watch is.
    case pairedPhone
}

public enum ChargeState: String, Codable, Sendable {
    case charging
    case charged
    /// On power without charging: held at a limit, too warm, or Optimized Charging waiting.
    case notCharging
    case discharging
}

/// The system's own word on the battery, where it gives one.
public enum BatteryCondition: String, Codable, Sendable {
    case normal
    case serviceRecommended
}

/// One part of a device with batteries of its own: each AirPod and the case.
public struct BatteryPart: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case left
        case right
        case chargingCase
        case single
    }

    public var role: Role
    public var percent: Int
    public var isCharging: Bool

    public init(role: Role, percent: Int, isCharging: Bool = false) {
        self.role = role
        self.percent = percent
        self.isCharging = isCharging
    }
}

/// What powers the device, as it describes itself.
public struct PowerAdapter: Codable, Equatable, Sendable {
    /// "35W USB-C Power Adapter"; many chargers give no name.
    public var name: String?
    public var manufacturer: String?
    /// What the adapter is rated for.
    public var watts: Int?
    /// What the device agreed to take from it: volts and amps.
    public var voltage: Double?
    public var current: Double?
    public var isWireless = false

    public init(
        name: String? = nil, manufacturer: String? = nil, watts: Int? = nil, voltage: Double? = nil,
        current: Double? = nil, isWireless: Bool = false
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.watts = watts
        self.voltage = voltage
        self.current = current
        self.isWireless = isWireless
    }
}

/// The extremes a battery's gauge has kept since it started counting.
public struct BatteryLifetime: Codable, Equatable, Sendable {
    /// Degrees Celsius.
    public var highestTemperature: Double?
    public var lowestTemperature: Double?
    public var averageTemperature: Double?
    /// Amps, both as positive numbers.
    public var highestChargeCurrent: Double?
    public var highestDischargeCurrent: Double?
    /// Volts of the whole pack.
    public var highestVoltage: Double?
    public var lowestVoltage: Double?
    /// Hours the gauge has counted since it was first powered. On the MacBook Air checked it started seven weeks after
    /// the pack's manufacture date, and coconutBattery takes the date it gives for the manufacture date.
    public var operatingHours: Int?

    public init() {}

    public var isEmpty: Bool { self == BatteryLifetime() }
}

/// Everything read from one battery at one moment. Every figure is optional: devices report different sets, and keys
/// that are not documented can go away with any update.
public struct BatteryReading: Codable, Equatable, Sendable {
    public var date: Date
    /// Charge as the device shows it, 0–100.
    public var percent: Int?
    public var state: ChargeState?
    public var minutesRemaining: Int?

    /// Milliamp-hours. The capacity the battery was designed with.
    public var designCapacity: Int?
    /// What a full charge gives now, under the present load and temperature, as the gauge works it out
    /// (`AppleRawMaxCapacity`). coconutBattery's figure.
    public var fullChargeCapacity: Int?
    /// What the battery holds when full, smoothed by the gauge (`NominalChargeCapacity`). Closer to the system's own
    /// figure.
    public var nominalChargeCapacity: Int?
    /// What it holds now.
    public var remainingCapacity: Int?
    /// The system's own Maximum Capacity in percent, where it can be read: System Settings on a Mac.
    public var systemMaximumCapacity: Int?
    public var condition: BatteryCondition?

    public var cycleCount: Int?
    /// The cycles it is designed to keep 80 % for.
    public var designCycleCount: Int?

    /// Degrees Celsius.
    public var temperature: Double?
    /// Volts of the pack.
    public var voltage: Double?
    /// Amps, positive while charging and negative while discharging.
    public var current: Double?
    /// Watts going into the battery when positive, out of it when negative.
    public var batteryPower: Double?
    /// Watts the device itself uses.
    public var systemPower: Double?
    /// Watts coming in from the adapter.
    public var adapterPower: Double?
    /// Watts this Mac gives to devices on its ports.
    public var powerToAccessories: Double?
    public var adapter: PowerAdapter?
    public var isLowPowerMode: Bool?

    public var cellVoltages: [Double]?
    public var lifetime: BatteryLifetime?
    /// The day the pack was made, as its gauge keeps it.
    public var manufactureDate: Date?
    /// The day the device was first set up, as iPhone keeps it ("First Use" in its Settings).
    public var firstUseDate: Date?
    /// The fuel gauge chip, such as "bq40z651".
    public var gauge: String?

    /// Accessories with more than one battery, such as AirPods, list each part; a single battery is in `percent`.
    public var parts: [BatteryPart]

    public init(date: Date) {
        self.date = date
        parts = []
    }

    /// coconutBattery's health: what a full charge gives now against what the battery was designed for. Above 100 % is
    /// real for a new battery and is kept.
    public var health: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0, full > 0 else { return nil }
        return Double(full) / Double(design)
    }

    /// What the battery holds when full against its design, the figure the system's own number is based on.
    public var nominalHealth: Double? {
        guard let nominal = nominalChargeCapacity, let design = designCapacity, design > 0, nominal > 0 else {
            return nil
        }
        return Double(nominal) / Double(design)
    }

    public var isOnPower: Bool {
        switch state {
        case .charging, .charged, .notCharging: true
        case .discharging, nil: false
        }
    }

    /// The lowest charge among the parts, or the single one: what decides when the device runs out.
    public var lowestPercent: Int? {
        let earbuds = parts.filter { $0.role != .chargingCase }.map(\.percent)
        return earbuds.min() ?? percent ?? parts.map(\.percent).min()
    }
}
