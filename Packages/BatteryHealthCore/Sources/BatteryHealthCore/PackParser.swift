import Foundation

/// The battery pack's own registry entry, `AppleSmartBatteryPack`, which a Mac lists publicly and an iPhone sends
/// through its diagnostics service: the temperature, the gauge's lifetime record and the pack's dates. Checked on a
/// MacBook Air M2 (macOS 27.2) and an iPhone 15 Pro (iOS 27.2.1).
public enum PackParser {
    /// iOS counts dates from 2001, as Core Foundation does.
    private static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

    public static func apply(pack: [String: Any], to reading: inout BatteryReading) {
        let data = pack["BatteryData"] as? [String: Any] ?? pack
        if reading.temperature == nil, let hundredths = RegistryParser.int(data["Temperature"]),
            (-4_000...10_000).contains(hundredths), hundredths != 0
        {
            reading.temperature = Double(hundredths) / 100
        }
        if let lifetime = (data["LifetimeData"] as? [String: Any]).flatMap(lifetime) { reading.lifetime = lifetime }
        if let made = RegistryParser.int(data["ManufactureDate"]).flatMap({ manufactureDate($0, before: reading.date) })
        {
            reading.manufactureDate = made
        }
        if let seconds = RegistryParser.int(data["DateOfFirstUse"]), seconds > 0 {
            let date = referenceDate.addingTimeInterval(Double(seconds))
            if date <= reading.date, date > Date(timeIntervalSince1970: 1_262_304_000) { reading.firstUseDate = date }
        }
    }

    /// The gauge's record. A Mac keeps the highest and lowest temperature in degrees and the average in tenths; an
    /// iPhone the other way round. A highest above 100 is in tenths, the lowest then too, an average above 60 as well.
    static func lifetime(_ data: [String: Any]) -> BatteryLifetime? {
        var lifetime = BatteryLifetime()
        let high = RegistryParser.int(data["MaximumTemperature"])
        let tenths = (high ?? 0) > 100
        if let high {
            let degrees = tenths ? Double(high) / 10 : Double(high)
            if (-40...120).contains(degrees) { lifetime.highestTemperature = degrees }
        }
        if let low = RegistryParser.int(data["MinimumTemperature"]) {
            let degrees = tenths ? Double(low) / 10 : Double(low)
            if (-40...120).contains(degrees) { lifetime.lowestTemperature = degrees }
        }
        if let average = RegistryParser.int(data["AverageTemperature"]) {
            let degrees = average > 60 ? Double(average) / 10 : Double(average)
            if (-40...60).contains(degrees) { lifetime.averageTemperature = degrees }
        }
        if let high = lifetime.highestTemperature, let low = lifetime.lowestTemperature, low > high {
            lifetime.highestTemperature = nil
            lifetime.lowestTemperature = nil
        }
        if let charge = RegistryParser.int(data["MaximumChargeCurrent"]), charge > 0, charge < 50_000 {
            lifetime.highestChargeCurrent = Double(charge) / 1_000
        }
        if let discharge = RegistryParser.int(data["MaximumDischargeCurrent"]), discharge < 0, discharge > -50_000 {
            lifetime.highestDischargeCurrent = Double(-discharge) / 1_000
        }
        if let volts = RegistryParser.int(data["MaximumPackVoltage"]), volts > 0, volts < 100_000 {
            lifetime.highestVoltage = Double(volts) / 1_000
        }
        if let volts = RegistryParser.int(data["MinimumPackVoltage"]), volts > 0, volts < 100_000 {
            lifetime.lowestVoltage = Double(volts) / 1_000
        }
        // More than 20 years of hours would be a misread.
        if let hours = RegistryParser.int(data["TotalOperatingTime"]), hours > 0, hours < 24 * 365 * 20 {
            lifetime.operatingHours = hours
        }
        return lifetime.isEmpty ? nil : lifetime
    }

    /// Six ASCII digits packed into a number, last first: "310907" read backwards from 0x373039303133, years from
    /// 1992, so 2023-09-07. That Mac's battery serial puts its cells in week 35 of 2023, the week before. An iPhone 15
    /// Pro gave digits that do not make a date in this way, and is left without one.
    static func manufactureDate(_ packed: Int, before limit: Date) -> Date? {
        guard packed > 0 else { return nil }
        var digits: [UInt8] = []
        var rest = UInt64(packed)
        while rest > 0 {
            digits.append(UInt8(rest & 0xFF))
            rest >>= 8
        }
        guard digits.count == 6, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        let values = digits.map { Int($0 - 0x30) }
        let year = 1992 + values[0] * 10 + values[1]
        let month = values[2] * 10 + values[3]
        let day = values[4] * 10 + values[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard (1...12).contains(month), (1...31).contains(day),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.day, from: date) == day, date <= limit, year >= 2005
        else { return nil }
        return date
    }

    /// When the gauge started counting.
    public static func gaugeStart(operatingHours: Int, at date: Date) -> Date {
        date.addingTimeInterval(-Double(operatingHours) * 3_600)
    }
}

/// What a Mac's SMC adds: each cell group's voltage. The keys are undocumented; on the MacBook Air M2 checked, the three
/// added up to the pack's voltage in the registry.
public enum MacBatteryParser {
    public static let cellKeys = (1...6).map { "BC\($0)V" }

    /// Volts of each cell group, in order, while they read as a lithium cell can.
    public static func cellVoltages(_ values: [String: Int]) -> [Double]? {
        let cells = cellKeys.compactMap { values[$0] }.filter { (2_000...5_000).contains($0) }
        return cells.isEmpty ? nil : cells.map { Double($0) / 1_000 }
    }
}
