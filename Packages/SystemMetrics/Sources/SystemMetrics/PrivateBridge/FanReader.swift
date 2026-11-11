import Foundation

/// PRIVATE INTERFACE. Reads the fans through the SMC, without any special rights. Writing is the root helper's business and
/// is not possible from here.
///
/// Checked on macOS 26.6.2 on an M1 Pro (MacBookPro18,1), with two fans: `FNum` is `ui8`, `F0Ac`, `F0Mn`, `F0Mx` and `F0Tg`
/// are `flt`, `F0Md` is `ui8` and reads 3 while the system runs the fan and 1 while set by hand. Other reports say the M5 calls that last one `F0md`,
/// so both are looked for. A key that is missing hides that fan or that value and nothing else.
final class FanReader {
    /// Far above any Mac, and it stops a nonsense count from turning into many calls.
    private static let mostFans = 8
    /// What the mode key holds while something other than the system sets the speed.
    private static let manualMode: UInt8 = 1
    /// Far above any fan. These keys were only ever seen as floats on an M1 Pro, and another chip may store them some other
    /// way. Read as a float that can come out as anything, even not a number, which turning it into a whole number would
    /// not survive.
    static let believableSpeeds: ClosedRange<Float> = 0...100_000

    private struct Keys {
        /// Its place among the fans that can be read, which stays its own when one reading fails. The helper counts the same
        /// way, and one of these two going by the Mac's own numbers would give a speed to the wrong fan.
        let number: Int
        let actual: UInt32
        let target: UInt32
        let mode: UInt32?
        let minimum: Float
        let maximum: Float
    }

    static var fanCount: Int {
        SMCClient().map(count(in:)) ?? 0
    }

    private let smc: SMCClient
    private let fans: [Keys]

    init?() {
        guard let smc = SMCClient() else { return nil }
        self.smc = smc
        let count = Self.count(in: smc)
        var fans: [Keys] = []
        for index in 0..<count {
            guard let minimum = smc.readFloat(key: SMCClient.code("F\(index)Mn")),
                let maximum = smc.readFloat(key: SMCClient.code("F\(index)Mx")),
                Self.believableSpeeds.contains(minimum), Self.believableSpeeds.contains(maximum)
            else { continue }
            let modeKeys = ["F\(index)Md", "F\(index)md"].map(SMCClient.code)
            fans.append(
                Keys(
                    number: fans.count, actual: SMCClient.code("F\(index)Ac"), target: SMCClient.code("F\(index)Tg"),
                    mode: modeKeys.first { smc.info(of: $0) != nil }, minimum: minimum, maximum: maximum))
        }
        guard !fans.isEmpty else { return nil }
        self.fans = fans
    }

    /// With `isComplete` off only the speed is read, which is all that following a temperature needs: each key costs about
    /// 195 µs, and this runs for as long as a curve does.
    func read(isComplete: Bool) -> [FanReading] {
        fans.compactMap { keys in
            guard let actual = smc.readFloat(key: keys.actual), Self.believableSpeeds.contains(actual) else {
                return nil
            }
            let target = isComplete ? smc.readFloat(key: keys.target) ?? 0 : 0
            return FanReading(
                index: keys.number, actual: Double(actual),
                target: Self.believableSpeeds.contains(target) ? Double(target) : 0,
                minimum: Double(keys.minimum), maximum: Double(keys.maximum),
                isManual: isComplete && keys.mode.flatMap(smc.readByte(key:)) == Self.manualMode)
        }
    }

    private static func count(in smc: SMCClient) -> Int {
        min(Int(smc.readByte(key: SMCClient.code("FNum")) ?? 0), mostFans)
    }
}

/// The temperatures a fan follows, read often for little. A Mac has dozens of sensors at about 195 µs each, which every few
/// seconds all day would be a real cost, so now and then all of them are read to find the hottest, and in between only those.
final class FanThermalReader {
    private static let fullReadInterval: TimeInterval = 30
    private static let hotProcessorKeysKept = 3
    private static let hotGraphicsKeysKept = 1

    private static let batteryKeys = ["TB0T", "TB1T", "TB2T"].map(SMCClient.code)

    private let smc: SMCClient
    private var hotCPU: [UInt32] = []
    private var hotGPU: [UInt32] = []
    private var typicalCPU: Double?
    private var battery: Double?
    private var lastFullRead: TimeInterval?

    init?() {
        guard let smc = SMCClient() else { return nil }
        self.smc = smc
    }

    func read(now: TimeInterval) -> FanTemperatures {
        if lastFullRead.map({ now - $0 >= Self.fullReadInterval }) ?? true {
            return readAll(now: now)
        }
        // A sensor in the hot set can go quiet as its block powers down, which must not look like a cool chip.
        let cpu = hottest(of: hotCPU)
        let gpu = hottest(of: hotGPU)
        if cpu == nil, !hotCPU.isEmpty { return readAll(now: now) }
        return FanTemperatures(hottestCPU: cpu, typicalCPU: typicalCPU, hottestGPU: gpu, battery: battery)
    }

    private func readAll(now: TimeInterval) -> FanTemperatures {
        lastFullRead = now
        let keys = ThermalKeys.discovered
        let cpu = believable(keys.cpu)
        let gpu = believable(keys.gpu)
        hotCPU = hotKeys(in: cpu, keeping: Self.hotProcessorKeysKept)
        hotGPU = hotKeys(in: gpu, keeping: Self.hotGraphicsKeysKept)
        typicalCPU = ThermalReader.typicalTemperature(cpu.map(\.value))
        // A battery warms up slowly, so it only needs a look now and then.
        battery = ThermalReader.typicalTemperature(Self.batteryKeys.compactMap(smc.readFloat(key:)))
        return FanTemperatures(
            hottestCPU: cpu.map(\.value).max().map(Double.init), typicalCPU: typicalCPU,
            hottestGPU: gpu.map(\.value).max().map(Double.init), battery: battery)
    }

    private func believable(_ keys: [UInt32]) -> [(key: UInt32, value: Float)] {
        keys.compactMap { key in
            guard let value = smc.readFloat(key: key), ThermalReader.plausibleRange.contains(value) else { return nil }
            return (key, value)
        }
    }

    private func hotKeys(in readings: [(key: UInt32, value: Float)], keeping count: Int) -> [UInt32] {
        readings.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }

    private func hottest(of keys: [UInt32]) -> Double? {
        believable(keys).map(\.value).max().map(Double.init)
    }
}
