import Foundation
import IOKit
import Synchronization

final class DiskSampler: MetricSampler {
    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]
    /// Purgeable-aware free space and the list of drives are not free to read, and they change slowly.
    private static let detailRefreshInterval: TimeInterval = 10
    private static let startupVolumePath = "/"

    private var drivers: [io_service_t] = []
    private var reads = RateCounter()
    private var writes = RateCounter()
    private var readRate: Double?
    private var writeRate: Double?
    private var lastRateTime: TimeInterval = 0
    private var readHistory = RingBuffer(capacity: historyCapacity)
    private var writeHistory = RingBuffer(capacity: historyCapacity)
    private var main: VolumeInfo?
    private var freeSpaceCheck = FreeSpaceCheck()
    private var lastFullReading: TimeInterval = -.infinity
    /// The last full reading of any disk sampler in this process. A sampler lives as long as what shows the disk, so
    /// the simple view's ring, and an item back from behind the notch, start without one: without this they would each
    /// take a full reading, the costliest call in the app, for a figure that has hardly moved.
    private static let lastReading = Mutex<(main: VolumeInfo, check: FreeSpaceCheck, time: TimeInterval)?>(nil)

    init() {
        if let last = Self.lastReading.withLock({ $0 }) {
            main = last.main
            freeSpaceCheck = last.check
            lastFullReading = last.time
        }
    }

    private func rememberFullReading(at now: TimeInterval) {
        freeSpaceCheck.fullReadingWasTaken(at: now, free: FreeSpaceCheck.readPlainSpace()?.free)
        lastFullReading = now
        guard let main else { return }
        let check = freeSpaceCheck
        Self.lastReading.withLock { $0 = (main, check, now) }
    }
    private static let shortestFullReadingInterval: TimeInterval = 1
    private var drive: DriveHealth?
    private var lastDetailRefresh: TimeInterval = 0
    private let otherVolumes = OtherVolumesReader()

    deinit {
        releaseDrivers()
    }

    func reset() {
        closeDetails()
    }

    func closeDetails() {
        // I/O counters are only read while someone is looking at them, so start fresh next time.
        reads.reset()
        writes.reset()
        readRate = nil
        writeRate = nil
        lastRateTime = 0
        drive = nil
        lastDetailRefresh = 0
        releaseDrivers()
        // Rates are only taken while details show, so the next look's chart must not join on to this one's, as if a
        // burst seen yesterday had happened a moment ago.
        if readHistory.count > 0 || writeHistory.count > 0 {
            readHistory = RingBuffer(capacity: historyCapacity)
            writeHistory = RingBuffer(capacity: historyCapacity)
        }
    }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        guard level == .detail else {
            // Whole percents in the menu bar do not show what the check lets pass, while the window shows bytes.
            let now = uptimeSeconds()
            // The follow-up reading a quarter of a second after something opens has no rates to complete here, and a
            // full reading asks the system to count purgeable space, the costliest call in the app.
            let isFresh = now - lastFullReading < Self.shortestFullReadingInterval
            if (level > .menu && !isFresh) || main == nil || freeSpaceCheck.needsFullReading(at: now) {
                main = Self.volume(at: Self.startupVolume)
                rememberFullReading(at: now)
            }
            closeDetails()
            return .disk(DiskSnapshot(main: main))
        }
        if uptimeSeconds() - lastDetailRefresh >= Self.detailRefreshInterval {
            refreshDetail()
            lastDetailRefresh = uptimeSeconds()
        }
        // Read after the refresh, which takes a while, or that time would count as part of the rate's window.
        let now = uptimeSeconds()
        if now - lastRateTime >= minimumSampleInterval {
            let counters = readCounters()
            readRate = reads.rate(value: counters.read, time: now)
            writeRate = writes.rate(value: counters.write, time: now)
            lastRateTime = now
            if let readRate { readHistory.append(Float(readRate)) }
            if let writeRate { writeHistory.append(Float(writeRate)) }
        }
        var snapshot = DiskSnapshot(main: main, others: otherVolumes.current())
        snapshot.drive = drive
        snapshot.readRate = readRate
        snapshot.writeRate = writeRate
        snapshot.readHistory = readHistory.values
        snapshot.writeHistory = writeHistory.values
        return .disk(snapshot)
    }

    /// Decides whether free space is worth asking about. The full question also counts what the system could clear,
    /// which goes through a daemon and costs about 80M instructions. Plain free space costs a thousandth of that, and
    /// while it stays put the full answer has hardly any reason to differ, so that is what gets asked first.
    struct FreeSpaceCheck: Sendable {
        /// A fifth of a percent of the disk, well under what shows in a whole-percent label.
        private static let smallestChange = 0.002
        /// Space that can be cleared can come and go without touching free space, so this is as long as it waits.
        private static let longestWait: TimeInterval = 1800

        private var lastFreeBytes: UInt64?
        private var lastFullReading: TimeInterval?

        mutating func needsFullReading(at now: TimeInterval) -> Bool {
            guard let space = Self.readPlainSpace() else { return true }
            return needsFullReading(free: space.free, total: space.total, at: now)
        }

        mutating func needsFullReading(free: UInt64, total: UInt64, at now: TimeInterval) -> Bool {
            guard let last = lastFreeBytes, let time = lastFullReading, now - time < Self.longestWait else {
                lastFreeBytes = free
                return true
            }
            let moved = free > last ? free - last : last - free
            guard Double(moved) >= Double(total) * Self.smallestChange else { return false }
            lastFreeBytes = free
            return true
        }

        /// What a full reading just saw is the next comparison's start, whatever led to it: one taken as details
        /// opened would otherwise leave an older start, and the next look would take another full reading at once.
        mutating func fullReadingWasTaken(at now: TimeInterval, free: UInt64?) {
            lastFullReading = now
            if let free { lastFreeBytes = free }
        }

        static func readPlainSpace() -> (free: UInt64, total: UInt64)? {
            var info = statfs()
            guard statfs(startupVolumePath, &info) == 0 else { return nil }
            let blockSize = UInt64(info.f_bsize)
            return (info.f_bavail * blockSize, info.f_blocks * blockSize)
        }
    }

    /// A new URL each time, because a URL keeps its resource values until a run loop turns, and this queue
    /// has none: a long-lived one reports the same free space forever.
    private static var startupVolume: URL { URL(fileURLWithPath: startupVolumePath) }

    private func refreshDetail() {
        main = Self.volume(at: Self.startupVolume)
        // A full reading like the menu bar's, so the menu bar does not take another as soon as details close.
        rememberFullReading(at: uptimeSeconds())
        drive = DriveHealthReader.read()
        // A drive that appears adds its whole lifetime traffic to the sum, which must not read as a rate.
        let found = Self.physicalDrivers()
        if found.count != drivers.count {
            reads.reset()
            writes.reset()
        }
        releaseDrivers()
        drivers = found
        otherVolumes.refresh()
    }

    fileprivate static func volume(at url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(volumeKeys)),
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
        // Some volumes do not answer this key, which is no reason to call them full.
        let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? free
        return VolumeInfo(
            name: values.volumeName ?? url.lastPathComponent,
            path: url.path,
            total: UInt64(total),
            available: available,
            purgeable: available > free ? available - free : 0
        )
    }

    /// Lists the other mounted volumes away from the sampling queue. A network share whose server has gone
    /// can block a file system call for minutes, which must not stop every other metric.
    private final class OtherVolumesReader {
        private struct State {
            var volumes: [VolumeInfo] = []
            var isRunning = false
        }

        private final class Shared: Sendable {
            let state = Mutex(State())
        }

        private let shared = Shared()

        func current() -> [VolumeInfo] {
            shared.state.withLock { $0.volumes }
        }

        func refresh() {
            let shared = shared
            let isBusy = shared.state.withLock { state in
                defer { state.isRunning = true }
                return state.isRunning
            }
            guard !isBusy else { return }
            DispatchQueue.global(qos: .utility).async {
                let urls =
                    // No keys: `volume(at:)` reads them from a fresh URL, and asking here too would mean a second
                    // purgeable-aware query for every volume, the startup volume included.
                    FileManager.default.mountedVolumeURLs(
                        includingResourceValuesForKeys: [], options: [.skipHiddenVolumes]) ?? []
                let volumes = urls.filter { $0.path != DiskSampler.startupVolumePath }.compactMap(
                    DiskSampler.volume(at:))
                shared.state.withLock { state in
                    state.volumes = volumes
                    state.isRunning = false
                }
            }
        }
    }

    private func readCounters() -> (read: UInt64, write: UInt64) {
        if drivers.isEmpty { drivers = Self.physicalDrivers() }
        var read: UInt64 = 0
        var write: UInt64 = 0
        for driver in drivers {
            let value = IORegistryEntryCreateCFProperty(driver, statisticsKey, kCFAllocatorDefault, 0)
            guard let object = value?.takeRetainedValue(), CFGetTypeID(object) == CFDictionaryGetTypeID() else {
                continue
            }
            // Read in place rather than bridged to a Swift dictionary every second for two of its numbers.
            let stats = unsafeDowncast(object, to: CFDictionary.self)
            read &+= Self.counter(bytesReadKey, in: stats)
            write &+= Self.counter(bytesWrittenKey, in: stats)
        }
        return (read, write)
    }

    private let statisticsKey = "Statistics" as CFString
    private let bytesReadKey = "Bytes (Read)" as CFString
    private let bytesWrittenKey = "Bytes (Write)" as CFString

    private static func counter(_ key: CFString, in dictionary: CFDictionary) -> UInt64 {
        guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
        let object = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
        guard CFGetTypeID(object) == CFNumberGetTypeID() else { return 0 }
        var result: Int64 = 0
        return CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .sInt64Type, &result)
            ? UInt64(bitPattern: result) : 0
    }

    /// Storage drivers backed by real hardware. Disk images are skipped because their traffic also
    /// reaches the physical disk underneath and would otherwise be counted twice.
    private static func physicalDrivers() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var drivers: [io_service_t] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            if isVirtual(driver) {
                IOObjectRelease(driver)
            } else {
                drivers.append(driver)
            }
        }
        return drivers
    }

    private static func isVirtual(_ driver: io_service_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        let value = IORegistryEntryCreateCFProperty(
            parent, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)
        let characteristics = value?.takeRetainedValue() as? [String: Any]
        return characteristics?["Physical Interconnect"] as? String == "Virtual Interface"
    }

    private func releaseDrivers() {
        drivers.forEach { IOObjectRelease($0) }
        drivers = []
    }
}
