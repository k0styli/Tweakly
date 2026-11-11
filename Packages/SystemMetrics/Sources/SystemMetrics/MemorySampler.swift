import Darwin

/// Splits raw VM counters into the categories Activity Monitor shows.
struct MemoryBreakdown: Equatable {
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var used: UInt64 { app + wired + compressed }

    init(
        total: UInt64,
        pageSize: UInt64,
        internalPages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64
    ) {
        app = (internalPages - min(purgeablePages, internalPages)) * pageSize
        wired = wiredPages * pageSize
        compressed = compressorPages * pageSize
        cached = (externalPages + purgeablePages) * pageSize
        let accounted = app + wired + compressed + cached
        free = total > accounted ? total - accounted : 0
    }
}

final class MemorySampler: MetricSampler {
    private let total: UInt64
    private let usable: UInt64
    private let pageSize = UInt64(sysconf(_SC_PAGESIZE))
    private var history = RingBuffer(capacity: historyCapacity)

    init() {
        let total = Self.readSize("hw.memsize")
        self.total = total
        // Checked on macOS 27.2 on an M2, where the difference matches the pages the VM counters leave out
        // exactly. Without this key, all the installed memory counts as usable.
        let usable = Self.readSize("hw.memsize_usable")
        self.usable = usable > 0 ? usable : total
    }

    private static func readSize(_ name: String) -> UInt64 {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &size, &length, nil, 0) == 0 else { return 0 }
        return size
    }

    func reset() {}

    func sample(level: SamplingLevel) -> MetricUpdate? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let breakdown = MemoryBreakdown(
            total: usable,
            pageSize: pageSize,
            internalPages: UInt64(info.internal_page_count),
            purgeablePages: UInt64(info.purgeable_count),
            externalPages: UInt64(info.external_page_count),
            wiredPages: UInt64(info.wire_count),
            compressorPages: UInt64(info.compressor_page_count)
        )
        var snapshot = MemorySnapshot()
        snapshot.total = total
        snapshot.usable = usable
        snapshot.used = breakdown.used
        snapshot.app = breakdown.app
        snapshot.wired = breakdown.wired
        snapshot.compressed = breakdown.compressed
        snapshot.cached = breakdown.cached
        snapshot.free = breakdown.free
        history.append(Float(snapshot.usedFraction))
        guard level >= .overview else { return .memory(snapshot) }
        snapshot.history = history.values
        snapshot.pressure = readPressure()
        guard level == .detail else { return .memory(snapshot) }
        snapshot.swapUsed = readSwapUsed()
        return .memory(snapshot)
    }

    private func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    private func readSwapUsed() -> UInt64 {
        var swap = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &length, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }
}
