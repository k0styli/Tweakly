import Foundation
import IOKit
import Synchronization

/// PRIVATE INTERFACE. Talks to the System Management Controller, which has no public API.
///
/// The selector, the command numbers and the 80-byte structure below are undocumented. Checked on
/// macOS 27.2 on an M2. Any failure makes the calls return nil, which hides the temperature and
/// leaves everything else working.
final class SMCClient {
    private static let structureSize = 80
    private static let selector: UInt32 = 2

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case read = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0
    private var input = [UInt8](repeating: 0, count: structureSize)
    private var output = [UInt8](repeating: 0, count: structureSize)

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            metricsLog.notice("This Mac has no AppleSMC service")
            return nil
        }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, machTask, 0, &connection) == KERN_SUCCESS else {
            metricsLog.notice("AppleSMC refused a connection")
            return nil
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func readFloat(key: UInt32) -> Float? {
        guard perform(.read, key: key, dataSize: 4) else { return nil }
        return output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Offset.bytes, as: Float.self) }
    }

    func readByte(key: UInt32) -> UInt8? {
        guard perform(.read, key: key, dataSize: 1) else { return nil }
        return output[Offset.bytes]
    }

    /// The total number of keys, stored as a big-endian integer unlike the sensor values.
    func keyCount() -> Int? {
        guard perform(.read, key: Self.code("#KEY"), dataSize: 4) else { return nil }
        return output[Offset.bytes..<(Offset.bytes + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }

    func key(at index: UInt32) -> UInt32? {
        guard perform(.keyAtIndex, index: index) else { return nil }
        return output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Offset.key, as: UInt32.self) }
    }

    func info(of key: UInt32) -> (size: UInt32, type: UInt32)? {
        guard perform(.keyInfo, key: key) else { return nil }
        return output.withUnsafeBytes {
            (
                $0.loadUnaligned(fromByteOffset: Offset.dataSize, as: UInt32.self),
                $0.loadUnaligned(fromByteOffset: Offset.dataType, as: UInt32.self)
            )
        }
    }

    private func perform(_ command: Command, key: UInt32 = 0, dataSize: UInt32 = 0, index: UInt32 = 0) -> Bool {
        input.withUnsafeMutableBytes { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.storeBytes(of: key, toByteOffset: Offset.key, as: UInt32.self)
            raw.storeBytes(of: dataSize, toByteOffset: Offset.dataSize, as: UInt32.self)
            raw.storeBytes(of: command.rawValue, toByteOffset: Offset.command, as: UInt8.self)
            raw.storeBytes(of: index, toByteOffset: Offset.index, as: UInt32.self)
        }
        var outputSize = Self.structureSize
        let result = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(
                    connection, Self.selector, inBytes.baseAddress, Self.structureSize, outBytes.baseAddress,
                    &outputSize)
            }
        }
        return result == KERN_SUCCESS && output[Offset.result] == 0
    }
}

/// Which SMC keys hold CPU and GPU temperatures. Key names change with every chip, so they are found
/// by prefix rather than listed per model. A scan takes about 40 ms and only happens once per process.
///
/// Keys are chosen by their type alone. A block that is powered off reports nonsense for the moment (the
/// GPU's keys read 0 and 4.6 about one time in twenty), so judging them by their value here could drop
/// them until the app restarts. Readings are checked each time instead.
struct ThermalKeys: Sendable {
    /// Far above the 1764 keys of an M2, and it stops a nonsense count from turning into billions of calls.
    private static let maximumKeyCount = 20_000
    private static let retryInterval: TimeInterval = 60
    private static let cache = Mutex<(keys: ThermalKeys?, lastAttempt: TimeInterval?)>((nil, nil))

    let cpu: [UInt32]
    let gpu: [UInt32]

    /// A scan that found nothing may just have met a passing failure, so only a good result is kept for
    /// the life of the process. Until then it is tried again now and then.
    static var discovered: ThermalKeys {
        cache.withLock { cache in
            if let keys = cache.keys { return keys }
            let now = uptimeSeconds()
            if let last = cache.lastAttempt, now - last < retryInterval { return ThermalKeys(cpu: [], gpu: []) }
            cache.lastAttempt = now
            let keys = discover()
            if !keys.cpu.isEmpty || !keys.gpu.isEmpty { cache.keys = keys }
            return keys
        }
    }

    private static func discover() -> ThermalKeys {
        guard let smc = SMCClient(), let count = smc.keyCount(), count <= maximumKeyCount else {
            metricsLog.notice("Could not list the SMC's keys")
            return ThermalKeys(cpu: [], gpu: [])
        }
        let floatType = SMCClient.code("flt ")
        var cpu: [UInt32] = []
        var gpu: [UInt32] = []
        for index in 0..<UInt32(count) {
            guard let key = smc.key(at: index) else { continue }
            let prefix = key >> 16
            let isCPU = prefix == SMCClient.code("Tp") || prefix == SMCClient.code("Te")
            let isGPU = prefix == SMCClient.code("Tg")
            guard isCPU || isGPU, let info = smc.info(of: key), info.size == 4, info.type == floatType else {
                continue
            }
            if isCPU { cpu.append(key) } else { gpu.append(key) }
        }
        return ThermalKeys(cpu: cpu, gpu: gpu)
    }
}

final class ThermalReader {
    /// Unused sensors, and those of a block that is powered off, report zero or nonsense values.
    static let plausibleRange: ClosedRange<Float> = 5...125

    private let smc: SMCClient

    init?() {
        guard let smc = SMCClient() else { return nil }
        self.smc = smc
    }

    func cpuTemperature() -> Double? {
        Self.typicalTemperature(ThermalKeys.discovered.cpu.compactMap(smc.readFloat(key:)))
    }

    func gpuTemperature() -> Double? {
        Self.typicalTemperature(ThermalKeys.discovered.gpu.compactMap(smc.readFloat(key:)))
    }

    /// The median, because many sensors report a low, typical and peak value side by side, and an
    /// average would be pulled towards whichever momentary peak happens to be highest.
    static func typicalTemperature(_ readings: [Float]) -> Double? {
        let values = readings.filter(plausibleRange.contains).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count % 2 == 1 ? Double(values[middle]) : Double(values[middle - 1] + values[middle]) / 2
    }
}

/// How much power the Mac uses right now, and how warm the battery is. Unlike the battery's registry
/// values, which the system refreshes only every so often, the power keys follow the load from second to
/// second. Checked on macOS 27.2 on an M2, where they agree with the registry: on battery `PPBR` matched
/// voltage times current whenever those updated, and while charging the adapter's 32.7 W in `PDTR`
/// matched 26.4 W going into the battery plus the system's 6.7 W in `PSTR`. That Mac's registry has no
/// battery temperature at all. A key that is missing or of another type on some other chip only means
/// that value comes from the registry or stays hidden.
final class BatterySensorReader {
    /// A battery warms up slowly, so there is no reason to cross into the SMC every second for this.
    private static let temperatureInterval: TimeInterval = 5

    private let smc: SMCClient
    private let batteryKey: UInt32?
    private let systemKey: UInt32?
    private let adapterKey: UInt32?
    private let temperatureKeys: [UInt32]
    private var temperature: Double?
    private var lastTemperatureRead: TimeInterval?

    init?() {
        guard let smc = SMCClient() else { return nil }
        self.smc = smc
        let floatType = SMCClient.code("flt ")
        func verified(_ name: String) -> UInt32? {
            let key = SMCClient.code(name)
            guard let info = smc.info(of: key), info.size == 4, info.type == floatType else { return nil }
            return key
        }
        batteryKey = verified("PPBR")
        systemKey = verified("PSTR")
        adapterKey = verified("PDTR")
        temperatureKeys = ["TB0T", "TB1T", "TB2T"].compactMap(verified)
    }

    /// Watts the Mac itself uses, leaving out any power going into the battery. On battery it is what
    /// drains from the pack, which runs a little above the system's own figure.
    func draw(onBattery: Bool) -> Double? {
        read(onBattery ? batteryKey : systemKey)
    }

    /// Watts coming in from the power adapter.
    func adapterInput() -> Double? {
        read(adapterKey)
    }

    /// In degrees Celsius.
    func batteryTemperature(now: TimeInterval) -> Double? {
        if let last = lastTemperatureRead, now - last < Self.temperatureInterval { return temperature }
        lastTemperatureRead = now
        temperature = ThermalReader.typicalTemperature(temperatureKeys.compactMap(smc.readFloat(key:)))
        return temperature
    }

    private func read(_ key: UInt32?) -> Double? {
        guard let key, let value = smc.readFloat(key: key), value.isFinite, value >= 0, value < 1000 else {
            return nil
        }
        return Double(value)
    }
}
