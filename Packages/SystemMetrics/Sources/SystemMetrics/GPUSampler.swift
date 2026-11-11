import Foundation
import IOKit

/// Reads the accelerator's `PerformanceStatistics` from the I/O Registry. The keys are not formally
/// documented, so a missing key leaves its value nil instead of failing the sample.
final class GPUSampler: MetricSampler {
    /// Each sensor read crosses into the SMC or IOReport, and these do not need a faster pace.
    private static let sensorInterval: TimeInterval = 3

    private let utilizationKey = "Device Utilization %" as CFString
    private let rendererKey = "Renderer Utilization %" as CFString
    private let tilerKey = "Tiler Utilization %" as CFString
    private let memoryInUseKey = "In use system memory" as CFString
    private let allocatedKey = "Alloc system memory" as CFString
    private var service: io_service_t = 0
    private var history = RingBuffer(capacity: historyCapacity)

    private var thermal: ThermalReader?
    private var sensors: GPUSensorReader?
    private var processes: GPUProcessSampler?
    private var detailsOpen = false
    private var hasFirstReading = false
    private var lastSensorRead: TimeInterval = 0
    private var temperature: Double?
    private var reading = GPUSensorReader.Reading()
    private var framesPerSecond: Double?
    private var lastFrameRead: TimeInterval = 0

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    func reset() {
        closeDetails()
    }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        var snapshot = GPUSnapshot()
        if level < .summary { closeDetails() }
        guard let statistics = readStatistics() else {
            snapshot.history = level >= .overview ? history.values : []
            return .gpu(snapshot)
        }
        if let usage = Self.integer(utilizationKey, in: statistics) {
            snapshot.usage = Self.fraction(usage)
            history.append(Float(Self.fraction(usage)))
        }
        guard level >= .overview else { return .gpu(snapshot) }
        snapshot.history = history.values
        guard level >= .summary else { return .gpu(snapshot) }
        snapshot.renderer = Self.integer(rendererKey, in: statistics).map(Self.fraction)
        snapshot.tiler = Self.integer(tilerKey, in: statistics).map(Self.fraction)
        snapshot.memoryInUse = Self.integer(memoryInUseKey, in: statistics).map { UInt64(max($0, 0)) }
        readSensors(now: uptimeSeconds(), withEverything: level == .detail)
        snapshot.temperature = temperature
        guard level == .detail else { return .gpu(snapshot) }
        snapshot.memoryAllocated = Self.integer(allocatedKey, in: statistics).map { UInt64(max($0, 0)) }
        snapshot.frequency = reading.frequency
        snapshot.power = reading.power
        snapshot.neuralEngine = reading.neuralEngine
        snapshot.framesPerSecond = framesPerSecond
        snapshot.topProcesses = processes?.rank(accelerator: service) ?? []
        return .gpu(snapshot)
    }

    /// Everything here stays closed unless it is on screen, so the menu bar value never pays for it.
    private func readSensors(now: TimeInterval, withEverything: Bool) {
        if !detailsOpen {
            detailsOpen = true
            thermal = ThermalReader()
            temperature = thermal?.gpuTemperature()
            if withEverything {
                sensors = GPUSensorReader()
                processes = GPUProcessSampler()
                _ = sensors?.read(now: now)
                _ = sensors?.framesPerSecond(now: now)
            }
            lastSensorRead = now
            lastFrameRead = now
            return
        }
        // The frame rate changes the moment anything moves, so it keeps the pace of the details.
        if now - lastFrameRead >= minimumSampleInterval {
            lastFrameRead = now
            framesPerSecond = sensors?.framesPerSecond(now: now)
        }
        // The power and frequency in the details need two readings, so their first real ones should not wait for the
        // full interval. The temperature alone was read the moment the summary opened. A temperature the GPU did not
        // give while it was powered off is asked again soon too.
        let isWaitingForSecondReading = !hasFirstReading && (sensors != nil || temperature == nil)
        guard now - lastSensorRead >= (isWaitingForSecondReading ? minimumSampleInterval : Self.sensorInterval) else {
            return
        }
        lastSensorRead = now
        hasFirstReading = true
        // The sensors say nothing useful while the GPU is powered off, and it has not gone cold in that moment.
        temperature = thermal?.gpuTemperature() ?? temperature
        reading = sensors?.read(now: now) ?? .init()
    }

    func closeDetails() {
        guard detailsOpen else { return }
        detailsOpen = false
        hasFirstReading = false
        thermal = nil
        sensors = nil
        processes = nil
        temperature = nil
        reading = .init()
        framesPerSecond = nil
    }

    private static func fraction(_ percent: Int) -> Double {
        Double(min(max(percent, 0), 100)) / 100
    }

    private func readStatistics() -> CFDictionary? {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            guard service != 0 else { return nil }
        }
        let value = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        guard let value, CFGetTypeID(value) == CFDictionaryGetTypeID() else {
            // The service may have gone away; look it up again next time.
            IOObjectRelease(service)
            service = 0
            return nil
        }
        return unsafeDowncast(value, to: CFDictionary.self)
    }

    /// Reads one number straight from the dictionary. The menu bar needs only this, and bridging the whole
    /// dictionary to Swift on every update would cost as much again as a fifth of reading it from the system.
    private static func integer(_ key: CFString, in dictionary: CFDictionary) -> Int? {
        guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
        guard CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        var result = 0
        return CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .longType, &result) ? result : nil
    }
}
