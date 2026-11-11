import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Facts about this Mac that do not change while it runs.
public struct SystemInfo: Sendable {
    /// Whether this Mac has fans at all. Read once, because a Mac does not gain or lose one.
    public static let hasFans: Bool = {
        #if TWEAKLY_AUTOMATION
            // The made-up Mac of a test copy taking pictures has two, see DemoData.
            if DemoData.isOn { return true }
        #endif
        return FanReader.fanCount > 0
    }()

    /// When the Mac started. Unlike the system's uptime counter, the time since then includes sleep, as the
    /// `uptime` command and any person would count it.
    public static let bootDate: Date? = {
        var time = timeval()
        var length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &length, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }()

    public struct CoreCluster: Equatable, Sendable, Identifiable {
        public enum Kind: Sendable { case performance, efficiency, other }
        public let kind: Kind
        /// Positions in `CPUSnapshot.cores`.
        public let cores: [Int]
        public var id: Int { cores.first ?? -1 }
    }

    public let chipName: String
    public let modelIdentifier: String
    /// The Mac's name as Apple sells it, such as `MacBook Air (M2, 2022)`. The key is undocumented, so a Mac may
    /// not have it.
    public let productName: String?
    public let totalMemory: UInt64
    public let clusters: [CoreCluster]
    public let gpuName: String?
    public let gpuCoreCount: Int?

    public var coreCount: Int { clusters.reduce(0) { $0 + $1.cores.count } }

    /// Read once on first use, since none of this changes while the Mac runs.
    public static let current = read()

    static func read() -> SystemInfo {
        let gpu = readGPU()
        return SystemInfo(
            chipName: string("machdep.cpu.brand_string") ?? "Mac",
            modelIdentifier: string("hw.model") ?? "",
            productName: demoProductName ?? readProductName(),
            totalMemory: ProcessInfo.processInfo.physicalMemory,
            clusters: readClusters(),
            gpuName: gpu.name,
            gpuCoreCount: gpu.cores
        )
    }

    /// Whether this Mac has an internal battery. Asks the battery driver rather than the power sources
    /// API, which can take many seconds after boot to report it, and a login item starts early.
    public static var hasBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let installed = IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)
        return installed?.takeRetainedValue() as? Bool ?? true
    }

    /// The made-up Mac of a test copy taking pictures: the same chip, with the fan this one lacks. See DemoData.
    private static var demoProductName: String? {
        #if TWEAKLY_AUTOMATION
            DemoData.isOn ? "MacBook Pro (M2, 2022)" : nil
        #else
            nil
        #endif
    }

    private static func readProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let name = data(entry, "product-name") else { return nil }
        let text = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func string(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctlbyname(name, &buffer, &length, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &length, nil, 0) == 0 ? Int(value) : nil
    }

    private static func readClusters() -> [CoreCluster] {
        let fromTree = clustersFromDeviceTree()
        if !fromTree.isEmpty { return fromTree }
        // Without the device tree, fall back on efficiency cores being numbered first.
        let performance = integer("hw.perflevel0.logicalcpu") ?? integer("hw.logicalcpu") ?? 0
        let efficiency = integer("hw.perflevel1.logicalcpu") ?? 0
        var clusters: [CoreCluster] = []
        if efficiency > 0 {
            clusters.append(CoreCluster(kind: .efficiency, cores: Array(0..<efficiency)))
        }
        if performance > 0 {
            clusters.append(CoreCluster(kind: .performance, cores: Array(efficiency..<(efficiency + performance))))
        }
        return clusters.reversed()
    }

    /// Each CPU node names its cluster type and logical index, which is more reliable than guessing the order.
    private static func clustersFromDeviceTree() -> [CoreCluster] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var byType: [UInt8: [Int]] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let type = data(entry, "cluster-type")?.first,
                let id = data(entry, "logical-cpu-id"), id.count >= 4
            else { continue }
            byType[type, default: []].append(Int(id.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
        let order: [(UInt8, CoreCluster.Kind)] = [(UInt8(ascii: "P"), .performance), (UInt8(ascii: "E"), .efficiency)]
        var clusters = order.compactMap { type, kind in
            byType.removeValue(forKey: type).map { CoreCluster(kind: kind, cores: $0.sorted()) }
        }
        clusters += byType.keys.sorted().map { CoreCluster(kind: .other, cores: byType[$0, default: []].sorted()) }
        return clusters
    }

    private static func data(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
    }

    private static func readGPU() -> (name: String?, cores: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return (property("model") as? String, property("gpu-core-count") as? Int)
    }
}
