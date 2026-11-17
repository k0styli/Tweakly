import Foundation
import Testing

@testable import BatteryHealthCore

/// Registry entries as a MacBook Air M2 (macOS 27.2) and an iPhone 15 Pro (iOS 27.2.1) gave them, cut to the keys read.
private enum Samples {
    static let date = Date(timeIntervalSince1970: 1_794_928_717)

    static var mac: [String: Any] {
        [
            "BatteryData": [
                "AppleRawCurrentCapacity": 4065, "AppleRawMaxCapacity": 4065, "CurrentCapacity": 100,
                "DesignCapacity": 4563, "FullChargeCapacity": 4065, "MaxCapacity": 100,
                "NominalChargeCapacity": 4192, "RemainingCapacity": 4065,
            ] as [String: Any],
            "AdapterDetails": [
                "AdapterVoltage": 20000, "Current": 1740, "Description": "pd charger", "IsWireless": false,
                "Manufacturer": "Apple Inc.", "Name": "35W USB-C Power Adapter ", "Watts": 35,
            ] as [String: Any],
            "Amperage": 0, "InstantAmperage": 0, "CurrentCapacity": 100, "MaxCapacity": 100, "CycleCount": 239,
            "DesignCycleCount9C": 1000, "DeviceName": "bq40z651", "ExternalConnected": true, "FullyCharged": true,
            "IsCharging": false, "Voltage": 13066, "AvgTimeToEmpty": 65535, "TimeRemaining": 65535,
            "PowerTelemetryData": ["SystemLoad": 6239, "SystemPowerIn": 6239] as [String: Any],
            "PowerOutDetails": [["Watts": 2144, "PortIndex": 1] as [String: Any]],
        ]
    }

    static var iPhone: [String: Any] {
        [
            "BatteryData": [
                "AppleRawCurrentCapacity": 2937, "AppleRawMaxCapacity": 2938, "DesignCapacity": 3254,
                "FullChargeCapacity": 2938, "NominalChargeCapacity": 2878, "CurrentCapacity": 100, "MaxCapacity": 100,
            ] as [String: Any],
            "AdapterDetails": [
                "AdapterVoltage": 5000, "Current": 3000, "Description": "pd charger", "IsWireless": false,
                "Watts": 15,
            ] as [String: Any],
            "Amperage": 88, "InstantAmperage": 90, "CurrentCapacity": 100, "MaxCapacity": 100, "CycleCount": 911,
            "ExternalConnected": true, "FullyCharged": false, "IsCharging": true, "Voltage": 4416,
            "TimeRemaining": 462, "AvgTimeToEmpty": 320,
            "PowerTelemetryData": ["SystemLoad": 1918, "SystemPowerIn": 2306] as [String: Any],
        ]
    }

    static var iPhoneDomain: [String: Any] {
        [
            "BatteryCurrentCapacity": 100, "BatteryIsCharging": true, "ExternalConnected": true,
            "FullyCharged": false, "HasBattery": true,
        ]
    }
}

@Suite struct RegistryTests {
    @Test func macOnAppleSilicon() throws {
        let reading = RegistryParser.reading(registry: Samples.mac, date: Samples.date)
        #expect(reading.designCapacity == 4563)
        #expect(reading.fullChargeCapacity == 4065)
        #expect(reading.nominalChargeCapacity == 4192)
        #expect(reading.remainingCapacity == 4065)
        #expect(reading.cycleCount == 239)
        #expect(reading.designCycleCount == 1000)
        #expect(reading.percent == 100)
        #expect(reading.state == .charged)
        #expect(reading.minutesRemaining == nil)
        #expect(reading.gauge == "bq40z651")
        #expect(reading.voltage == 13.066)
        #expect(reading.current == 0)
        #expect(reading.systemPower == 6.239)
        #expect(reading.adapterPower == 6.239)
        #expect(reading.powerToAccessories == 2.144)
        let health = try #require(reading.health)
        // coconutBattery shows 89.1 % for this battery, System Settings 92 %.
        #expect(abs(health - 0.8909) < 0.0001)
        #expect(abs(try #require(reading.nominalHealth) - 0.9187) < 0.0001)
        let adapter = try #require(reading.adapter)
        #expect(adapter.name == "35W USB-C Power Adapter")
        #expect(adapter.manufacturer == "Apple Inc.")
        #expect(adapter.watts == 35)
        #expect(adapter.voltage == 20)
        #expect(adapter.current == 1.74)
        #expect(!adapter.isWireless)
    }

    @Test func dischargingCurrentKeepsItsSign() {
        var registry = Samples.mac
        registry["ExternalConnected"] = false
        registry["FullyCharged"] = false
        // -1250 mA, as the registry stores it.
        registry["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -1250))
        registry["TimeRemaining"] = 340
        let reading = RegistryParser.reading(registry: registry, date: Samples.date)
        #expect(reading.state == .discharging)
        #expect(reading.current == -1.25)
        #expect(abs((reading.batteryPower ?? 0) + 16.3325) < 0.0001)
        #expect(reading.minutesRemaining == 340)
        #expect(reading.adapter == nil)
        #expect(reading.adapterPower == nil)
    }

    @Test func intelLayoutAtTheTop() {
        let registry: [String: Any] = [
            "DesignCapacity": 5103, "AppleRawMaxCapacity": 4410, "CurrentCapacity": 2205, "MaxCapacity": 4410,
            "CycleCount": 512, "Temperature": 3012, "IsCharging": false, "ExternalConnected": false,
        ]
        let reading = RegistryParser.reading(registry: registry, date: Samples.date)
        #expect(reading.designCapacity == 5103)
        #expect(reading.fullChargeCapacity == 4410)
        #expect(reading.percent == 50)
        #expect(reading.temperature == 30.12)
    }

    @Test func nonsenseIsDropped() {
        let registry: [String: Any] = [
            "BatteryData": ["DesignCapacity": 0, "AppleRawMaxCapacity": -5] as [String: Any],
            "CycleCount": -1, "Voltage": 0, "Temperature": 0,
        ]
        let reading = RegistryParser.reading(registry: registry, date: Samples.date)
        #expect(reading.designCapacity == nil)
        #expect(reading.fullChargeCapacity == nil)
        #expect(reading.health == nil)
        #expect(reading.cycleCount == nil)
        #expect(reading.voltage == nil)
        #expect(reading.temperature == nil)
    }
}

@Suite struct MobileDeviceTests {
    @Test func iPhoneByCable() throws {
        let reading = MobileDeviceParser.reading(
            registry: Samples.iPhone, batteryDomain: Samples.iPhoneDomain, productType: "iPhone16,1",
            date: Samples.date)
        #expect(reading.fullChargeCapacity == 2938)
        #expect(reading.designCapacity == 3254)
        #expect(reading.nominalChargeCapacity == 2878)
        #expect(reading.cycleCount == 911)
        #expect(reading.designCycleCount == 1000)
        #expect(reading.state == .charging)
        #expect(reading.percent == 100)
        #expect(abs(try #require(reading.health) - 0.9029) < 0.0001)
        #expect(reading.current == 0.09)
        #expect(abs((reading.batteryPower ?? 0) - 0.39744) < 0.00001)
        #expect(reading.systemPower == 1.918)
        #expect(reading.adapterPower == 2.306)
        #expect(reading.adapter?.watts == 15)
        #expect(reading.adapter?.name == nil)
        // Charging, so no time to empty.
        #expect(reading.minutesRemaining == nil)
    }

    @Test func lockedPhoneGivesOnlyItsCharge() {
        let domain: [String: Any] = [
            "BatteryCurrentCapacity": 41, "BatteryIsCharging": false, "ExternalConnected": false,
        ]
        let reading = MobileDeviceParser.reading(
            registry: nil, batteryDomain: domain, productType: "iPhone15,2", date: Samples.date)
        #expect(reading.percent == 41)
        #expect(reading.state == .discharging)
        #expect(reading.health == nil)
        #expect(reading.designCycleCount == 500)
    }

    @Test func designCycles() {
        #expect(MobileDeviceParser.designCycleCount(productType: "iPhone14,6") == 500)
        #expect(MobileDeviceParser.designCycleCount(productType: "iPhone15,3") == 500)
        #expect(MobileDeviceParser.designCycleCount(productType: "iPhone15,4") == 1000)
        #expect(MobileDeviceParser.designCycleCount(productType: "iPhone17,3") == 1000)
        #expect(MobileDeviceParser.designCycleCount(productType: "iPad16,3") == 1000)
        #expect(MobileDeviceParser.designCycleCount(productType: "Watch7,1") == 1000)
        #expect(MobileDeviceParser.designCycleCount(productType: "AppleTV14,1") == nil)
        #expect(MobileDeviceParser.designCycleCount(productType: nil) == nil)
        #expect(MobileDeviceParser.kind(productType: "iPod9,1") == .iPod)
    }
}

@Suite struct PowerSourceTests {
    @Test func airPodsPartsBecomeOneDevice() throws {
        let sources: [[String: Any]] = [
            ["Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100],
            [
                "Name": "AirPods Pro", "Part Identifier": "Right", "Group Identifier": "G1", "Current Capacity": 70,
                "Max Capacity": 100, "Accessory Category": "Headphone", "Product ID": 8212, "Vendor ID": 76,
            ],
            [
                "Name": "AirPods Pro", "Part Identifier": "Left", "Group Identifier": "G1", "Current Capacity": 75,
                "Max Capacity": 100, "Is Charging": true,
            ],
            ["Name": "AirPods Pro Case", "Part Identifier": "Case", "Group Identifier": "G1", "Current Capacity": 40],
            [
                "Name": "Magic Mouse", "Accessory Category": "Mouse", "Current Capacity": 55,
                "Accessory Identifier": "M",
            ],
            [
                "Name": "JBL Flip 6", "Accessory Category": "Speaker", "Current Capacity": 70,
                "Accessory Identifier": "S",
            ],
        ]
        let found = PowerSourceParser.accessories(sources, date: Samples.date)
        #expect(found.count == 3)
        #expect(found.last?.kind == .speaker)
        let airPods = try #require(found.first)
        #expect(airPods.name == "AirPods Pro")
        #expect(airPods.kind == .headphones)
        #expect(airPods.productID == 8212)
        #expect(airPods.reading.parts.map(\.role) == [.left, .right, .chargingCase])
        #expect(airPods.reading.parts.map(\.percent) == [75, 70, 40])
        #expect(airPods.reading.state == .charging)
        #expect(airPods.reading.lowestPercent == 70)
        let mouse = try #require(found.dropLast().last)
        #expect(mouse.kind == .mouse)
        #expect(mouse.reading.percent == 55)
        #expect(mouse.reading.parts.isEmpty)
    }

    @Test func internalBattery() {
        var reading = BatteryReading(date: Samples.date)
        PowerSourceParser.applyInternal(
            [
                "Current Capacity": 64, "Max Capacity": 100, "Is Charging": false,
                "Power Source State": "Battery Power",
                "Time to Empty": 312, "LPM Active": 1, "BatteryHealthCondition": "Check Battery",
            ], to: &reading)
        #expect(reading.percent == 64)
        #expect(reading.state == .discharging)
        #expect(reading.minutesRemaining == 312)
        #expect(reading.isLowPowerMode == true)
        #expect(reading.condition == .serviceRecommended)
    }

    @Test func ups() throws {
        let ups = try #require(
            PowerSourceParser.ups(
                [
                    "Type": "UPS", "Name": "Back-UPS ES 700", "Current Capacity": 90, "Max Capacity": 100,
                    "Power Source State": "Battery Power", "Time to Empty": 25, "Vendor ID": 1309, "Product ID": 2,
                ], date: Samples.date))
        #expect(ups.kind == .ups)
        #expect(ups.reading.percent == 90)
        #expect(ups.reading.state == .discharging)
        #expect(ups.reading.minutesRemaining == 25)
        #expect(PowerSourceParser.ups(["Type": "InternalBattery"], date: Samples.date) == nil)
    }
}

@Suite struct PackTests {
    /// `AppleSmartBatteryPack` of the same MacBook Air and iPhone, cut to the keys read.
    static var macPack: [String: Any] {
        [
            "BatteryData": [
                "Temperature": 2819, "ManufactureDate": 60_680_257_417_523, "DateOfFirstUse": 0,
                "LifetimeData": [
                    "AverageTemperature": 240, "MaximumChargeCurrent": 5071, "MaximumDischargeCurrent": -3398,
                    "MaximumPackVoltage": 13304, "MaximumTemperature": 40, "MinimumPackVoltage": 8396,
                    "MinimumTemperature": 10, "TotalOperatingTime": 26781,
                ] as [String: Any],
            ] as [String: Any]
        ]
    }

    static var iPhonePack: [String: Any] {
        [
            "BatteryData": [
                "Temperature": 2939, "ManufactureDate": 61_784_013_680_697, "DateOfFirstUse": 738_374_400,
                "LifetimeData": [
                    "AverageTemperature": 26, "MaximumChargeCurrent": 4434, "MaximumDischargeCurrent": -7685,
                    "MaximumPackVoltage": 4480, "MaximumTemperature": 531, "MinimumPackVoltage": 2815,
                    "MinimumTemperature": -76, "TotalOperatingTime": 26657,
                ] as [String: Any],
            ] as [String: Any]
        ]
    }

    private var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test func macPack() throws {
        var reading = BatteryReading(date: Samples.date)
        PackParser.apply(pack: Self.macPack, to: &reading)
        #expect(reading.temperature == 28.19)
        let lifetime = try #require(reading.lifetime)
        #expect(lifetime.highestTemperature == 40)
        #expect(lifetime.lowestTemperature == 10)
        #expect(lifetime.averageTemperature == 24)
        #expect(lifetime.highestChargeCurrent == 5.071)
        #expect(lifetime.highestDischargeCurrent == 3.398)
        #expect(lifetime.highestVoltage == 13.304)
        #expect(lifetime.lowestVoltage == 8.396)
        #expect(lifetime.operatingHours == 26781)
        let made = try #require(reading.manufactureDate)
        #expect(gmt.dateComponents([.year, .month, .day], from: made) == DateComponents(year: 2023, month: 9, day: 7))
        #expect(reading.firstUseDate == nil)
        // coconutBattery shows 2023-10-29 for this battery: where the gauge's hours begin.
        let start = PackParser.gaugeStart(operatingHours: 26781, at: Date(timeIntervalSince1970: 1_794_929_193))
        #expect(
            gmt.dateComponents([.year, .month, .day], from: start) == DateComponents(year: 2023, month: 10, day: 28))
    }

    @Test func iPhonePack() throws {
        var reading = BatteryReading(date: Samples.date)
        reading.temperature = 31
        PackParser.apply(pack: Self.iPhonePack, to: &reading)
        // A live figure read before wins over the pack's.
        #expect(reading.temperature == 31)
        let lifetime = try #require(reading.lifetime)
        #expect(lifetime.highestTemperature == 53.1)
        #expect(lifetime.lowestTemperature == -7.6)
        #expect(lifetime.averageTemperature == 26)
        #expect(lifetime.highestDischargeCurrent == 7.685)
        #expect(reading.manufactureDate == nil)
        let firstUse = try #require(reading.firstUseDate)
        #expect(
            gmt.dateComponents([.year, .month, .day], from: firstUse) == DateComponents(year: 2024, month: 5, day: 26))
    }

    @Test func nonsenseDates() {
        let limit = Samples.date
        #expect(PackParser.manufactureDate(0, before: limit) == nil)
        // "301302": month 13.
        #expect(PackParser.manufactureDate(0x3230_3331_3033, before: limit) == nil)
        // Five digits.
        #expect(PackParser.manufactureDate(0x30_3330_3033, before: limit) == nil)
        // Letters.
        #expect(PackParser.manufactureDate(0x4142_4344_4546, before: limit) == nil)
        #expect(PackParser.lifetime([:]) == nil)
        #expect(PackParser.lifetime(["TotalOperatingTime": -3, "MaximumTemperature": 9000]) == nil)
    }

    @Test func cells() {
        let banks: [[String: Any]] = [
            ["CellVoltage": 4262, "Qmax": 4584], ["CellVoltage": 4258], ["CellVoltage": 4262],
        ]
        #expect(PackParser.cellVoltages(banks: banks) == [4.262, 4.258, 4.262])
        #expect(PackParser.cellVoltages(banks: [["CellVoltage": 0]]) == nil)
        #expect(PackParser.cellVoltages(banks: []) == nil)
    }
}

@Suite struct ArchiveTests {
    private static let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func phone(at date: Date, full: Int?, cycles: Int?, name: String = "iPhone") -> KnownDevice {
        var reading = BatteryReading(date: date)
        reading.fullChargeCapacity = full
        reading.designCapacity = full == nil ? nil : 3254
        reading.cycleCount = cycles
        reading.percent = 50
        return KnownDevice(
            id: "ios:1", kind: .iPhone, name: name, model: "iPhone16,1", connection: .usb, reading: reading)
    }

    @Test func oneHistoryPointADay() {
        var archive = BatteryArchive()
        let start = Samples.date
        archive.record(phone(at: start, full: 2940, cycles: 910), calendar: calendar)
        archive.record(phone(at: start.addingTimeInterval(60), full: 2938, cycles: 911), calendar: calendar)
        archive.record(phone(at: start.addingTimeInterval(2 * Self.day), full: 2930, cycles: 915), calendar: calendar)
        let history = archive.devices[0].history
        #expect(history.count == 2)
        #expect(history.map(\.cycleCount) == [911, 915])
    }

    @Test func shortReadKeepsHealth() {
        var archive = BatteryArchive()
        archive.record(phone(at: Samples.date, full: 2938, cycles: 911), calendar: calendar)
        archive.record(phone(at: Samples.date.addingTimeInterval(600), full: nil, cycles: nil), calendar: calendar)
        let latest = archive.devices[0].latest
        #expect(latest.fullChargeCapacity == 2938)
        #expect(latest.cycleCount == 911)
        #expect(latest.date == Samples.date.addingTimeInterval(600))
        #expect(archive.devices[0].history.count == 1)
    }

    @Test func clockSetBackDoesNotReorder() {
        var archive = BatteryArchive()
        archive.record(phone(at: Samples.date, full: 2938, cycles: 911), calendar: calendar)
        archive.record(phone(at: Samples.date - 3 * Self.day, full: 2950, cycles: 900), calendar: calendar)
        #expect(archive.devices[0].history.map(\.cycleCount) == [911])
    }

    @Test func oldHistoryThinsToWeeks() {
        var history: [HistoryPoint] = []
        let start = Samples.date
        for day in 0..<800 {
            BatteryArchive.add(
                HistoryPoint(
                    date: start + Double(day) * Self.day, fullChargeCapacity: 4000 - day, designCapacity: 4563),
                to: &history, calendar: calendar)
        }
        let cutoff = start + 799 * Self.day - BatteryArchive.dailyWindow
        let recent = history.filter { $0.date >= cutoff }
        let old = history.filter { $0.date < cutoff }
        #expect(recent.count == 401)
        // About 57 weeks before the window.
        #expect((55...59).contains(old.count))
        #expect(history.map(\.date) == history.map(\.date).sorted())
    }

    @Test func roundTripAndForget() throws {
        var archive = BatteryArchive()
        archive.record(phone(at: Samples.date, full: 2938, cycles: 911), calendar: calendar)
        let data = try archive.encoded()
        let back = try #require(BatteryArchive.decoded(data))
        #expect(back == archive)
        var newer = archive
        newer.version = BatteryArchive.currentVersion + 1
        #expect(BatteryArchive.decoded(try newer.encoded()) == nil)
        #expect(BatteryArchive.version(of: try newer.encoded()) == BatteryArchive.currentVersion + 1)
        #expect(BatteryArchive.version(of: Data("{".utf8)) == nil)
        #expect(BatteryArchive.decoded(Data("{".utf8)) == nil)
        archive.forget("ios:1")
        #expect(archive.devices.isEmpty)
    }

    @Test func identityHidesTheRawIdentifier() {
        let id = DeviceIdentity.id(kind: "ios", raw: "TEST-DEVICE-0001")
        #expect(id.hasPrefix("ios:"))
        #expect(id.count == 4 + 24)
        #expect(!id.contains("TEST"))
        #expect(id == DeviceIdentity.id(kind: "ios", raw: "TEST-DEVICE-0001"))
    }
}
