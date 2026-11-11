import Foundation
import Testing

@testable import SystemMetrics

@Suite struct CompactRateTests {
    @Test(arguments: [
        (0.0, 0, CompactRate.Unit.kilobytes),
        (-5.0, 0, .kilobytes),
        (499.0, 0, .kilobytes),
        (340_000.0, 3400, .kilobytes),
        (999_499.0, 9990, .kilobytes),
        (999_500.0, 10, .megabytes),
        (1_240_000.0, 12, .megabytes),
        (9_949_999.0, 99, .megabytes),
        (9_950_000.0, 100, .megabytes),
        (123_400_000.0, 1230, .megabytes),
        (999_500_000.0, 10, .gigabytes),
        (2_340_000_000.0, 23, .gigabytes),
    ])
    func rounding(rate: Double, tenths: Int, unit: CompactRate.Unit) {
        let compact = CompactRate(bytesPerSecond: rate)
        #expect(compact.tenths == tenths)
        #expect(compact.unit == unit)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e300])
    func aRateThatMakesNoSenseDoesNotStopTheApp(rate: Double) {
        _ = MetricUpdate.network(NetworkSnapshot(downRate: rate, upRate: rate)).menuValue
    }

    @Test func decimalOnlyWhereItHelps() {
        #expect(CompactRate(bytesPerSecond: 340_000).showsDecimal == false)
        #expect(CompactRate(bytesPerSecond: 1_240_000).showsDecimal)
        #expect(CompactRate(bytesPerSecond: 12_000_000).showsDecimal == false)
        #expect(CompactRate(bytesPerSecond: 2_340_000_000).showsDecimal)
    }

    @Test func nearbyRatesProduceTheSameMenuValue() {
        let first = MetricUpdate.network(NetworkSnapshot(downRate: 340_100, upRate: 1_000))
        let second = MetricUpdate.network(NetworkSnapshot(downRate: 340_400, upRate: 1_100))
        #expect(first.menuValue == second.menuValue)
    }
}

@Suite struct RingBufferTests {
    @Test func keepsInsertionOrderBeforeFilling() {
        var buffer = RingBuffer(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.values == [1, 2])
    }

    @Test func dropsOldestAfterFilling() {
        var buffer = RingBuffer(capacity: 3)
        (1...5).forEach { buffer.append(Float($0)) }
        #expect(buffer.values == [3, 4, 5])
        #expect(buffer.count == 3)
    }

    @Test func emptyHasNoValues() {
        #expect(RingBuffer(capacity: 2).values.isEmpty)
    }
}

@Suite struct RateCounterTests {
    @Test func firstReadingHasNoRate() {
        var counter = RateCounter()
        #expect(counter.rate(value: 100, time: 1) == nil)
    }

    @Test func computesBytesPerSecond() {
        var counter = RateCounter()
        _ = counter.rate(value: 100, time: 1)
        #expect(counter.rate(value: 300, time: 3) == 100)
    }

    @Test func counterResetDoesNotSpike() {
        var counter = RateCounter()
        _ = counter.rate(value: 1_000_000, time: 1)
        #expect(counter.rate(value: 10, time: 2) == nil)
        #expect(counter.rate(value: 20, time: 3) == 10)
    }

    @Test func zeroElapsedTimeIsIgnored() {
        var counter = RateCounter()
        _ = counter.rate(value: 10, time: 1)
        #expect(counter.rate(value: 20, time: 1) == nil)
    }

    @Test func resetForgetsBaseline() {
        var counter = RateCounter()
        _ = counter.rate(value: 10, time: 1)
        counter.reset()
        #expect(counter.rate(value: 20, time: 2) == nil)
    }
}

@Suite struct TrafficCounterTests {
    @Test func theSameInterfacesGiveARate() {
        var counter = TrafficCounter()
        _ = counter.rates(down: 100, up: 10, from: [1, 5], time: 1)
        let rates = counter.rates(down: 300, up: 30, from: [1, 5], time: 2)
        #expect(rates.down == 200)
        #expect(rates.up == 20)
    }

    /// A dock's network adapter comes back with all it has ever moved, which is not one second's traffic.
    @Test func anAdapterComingBackIsNotASpike() {
        var counter = TrafficCounter()
        _ = counter.rates(down: 100, up: 10, from: [1], time: 1)
        let back = counter.rates(down: 900_000_000_000, up: 9_000_000, from: [1, 5], time: 2)
        #expect(back.down == nil)
        #expect(back.up == nil)
        let after = counter.rates(down: 900_000_000_500, up: 9_000_050, from: [1, 5], time: 3)
        #expect(after.down == 500)
        #expect(after.up == 50)
    }

    @Test func anAdapterGoingAwayStartsAnewToo() {
        var counter = TrafficCounter()
        _ = counter.rates(down: 900, up: 90, from: [1, 5], time: 1)
        #expect(counter.rates(down: 100, up: 10, from: [1], time: 2).down == nil)
        #expect(counter.rates(down: 200, up: 20, from: [1], time: 3).down == 100)
    }
}

@Suite struct CPULoadTests {
    @Test func splitsUserAndSystem() throws {
        let old = CPUTicks(user: 100, system: 100, idle: 100, nice: 0)
        let new = CPUTicks(user: 120, system: 110, idle: 170, nice: 0)
        let load = try #require(CPULoad(from: old, to: new))
        #expect(load.user == 0.2)
        #expect(load.system == 0.1)
        #expect(abs(load.usage - 0.3) < 0.0001)
    }

    @Test func niceCountsAsUser() throws {
        let old = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let new = CPUTicks(user: 10, system: 0, idle: 80, nice: 10)
        #expect(try #require(CPULoad(from: old, to: new)).user == 0.2)
    }

    @Test func noElapsedTicksHasNoLoad() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        #expect(CPULoad(from: ticks, to: ticks) == nil)
    }

    @Test func backwardsCountersHaveNoLoad() {
        let old = CPUTicks(user: 100, system: 1, idle: 1, nice: 0)
        let new = CPUTicks(user: 1, system: 1, idle: 500, nice: 0)
        #expect(CPULoad(from: old, to: new) == nil)
    }
}

@Suite struct MemoryBreakdownTests {
    private func breakdown(internal internalPages: UInt64, purgeable: UInt64 = 0) -> MemoryBreakdown {
        MemoryBreakdown(
            total: 1_000,
            pageSize: 10,
            internalPages: internalPages,
            purgeablePages: purgeable,
            externalPages: 10,
            wiredPages: 5,
            compressorPages: 5
        )
    }

    @Test func matchesActivityMonitorCategories() {
        let memory = breakdown(internal: 30, purgeable: 10)
        #expect(memory.app == 200)
        #expect(memory.cached == 200)
        #expect(memory.used == 300)
        #expect(memory.free == 500)
    }

    @Test func purgeableLargerThanInternalDoesNotUnderflow() {
        #expect(breakdown(internal: 5, purgeable: 10).app == 0)
    }

    @Test func overcountingClampsFreeToZero() {
        #expect(breakdown(internal: 200).free == 0)
    }
}

@Suite struct ProcessNameTests {
    @Test(arguments: [
        ("/Applications/Safari.app/Contents/MacOS/Safari", "Safari"),
        ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome"),
        (
            "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Chrome Helper (Renderer)",
            "Helper"
        ),
        ("/usr/libexec/trustd", "trustd"),
    ])
    func displayName(path: String, expected: String) {
        #expect(ProcessSampler.displayName(path: path) == expected)
    }

    @Test func missingPathHasNoName() {
        #expect(ProcessSampler.displayName(path: nil) == nil)
        #expect(ProcessSampler.displayName(path: "") == nil)
    }
}

@Suite struct BatteryHealthTests {
    @Test func negativeAmperageMeansDischarging() throws {
        let values: [String: Any] = [
            "BatteryData": ["DesignCapacity": 4563, "NominalChargeCapacity": 4143], "CycleCount": 228,
            "Temperature": 3050, "Voltage": 11249, "InstantAmperage": NSNumber(value: Int64(-228)),
        ]
        let health = BatterySampler.health(from: values)
        #expect(health.fullChargeCapacity == 4143)
        #expect(health.designCapacity == 4563)
        #expect(health.cycleCount == 228)
        #expect(health.temperature == 30.5)
        #expect(abs(try #require(health.power) - 2.565) < 0.001)
    }

    @Test func positiveAmperageMeansCharging() throws {
        let values: [String: Any] = ["Voltage": 12000, "Amperage": NSNumber(value: Int64(1000))]
        #expect(try #require(BatterySampler.health(from: values).power) == -12)
    }

    @Test func missingKeysLeaveValuesEmpty() {
        let health = BatterySampler.health(from: [:])
        #expect(health.fullChargeCapacity == nil)
        #expect(health.temperature == nil)
        #expect(health.power == nil)
    }
}

@Suite struct UsageAveragesTests {
    private func ticks(busy: UInt64, idle: UInt64) -> CPUTicks {
        CPUTicks(user: busy, system: 0, idle: idle, nice: 0)
    }

    @Test func nilUntilWatchedForLongEnough() {
        var averages = UsageAverages()
        averages.record(ticks(busy: 0, idle: 0), at: 1_000)
        #expect(averages.average(over: 60, current: ticks(busy: 10, idle: 10), at: 1_030) == nil)
    }

    @Test func comparesAgainstTheCheckpointBeforeTheWindow() throws {
        var averages = UsageAverages()
        averages.record(ticks(busy: 0, idle: 0), at: 1_000)
        averages.record(ticks(busy: 100, idle: 0), at: 1_015)
        averages.record(ticks(busy: 100, idle: 100), at: 1_075)
        // The window covers only the idle stretch since the second checkpoint: 100 busy-free ticks.
        let value = try #require(averages.average(over: 60, current: ticks(busy: 125, idle: 175), at: 1_075))
        #expect(abs(value - 0.125) < 0.0001)
    }

    @Test func checkpointsCloserThanTheSpacingAreSkipped() throws {
        var averages = UsageAverages()
        averages.record(ticks(busy: 0, idle: 0), at: 1_000)
        averages.record(ticks(busy: 999, idle: 0), at: 1_005)
        let value = try #require(averages.average(over: 60, current: ticks(busy: 10, idle: 10), at: 1_060))
        #expect(value == 0.5)
    }

    @Test func aCheckpointFromBeforeALongPauseGivesNoFigure() {
        var averages = UsageAverages()
        averages.record(ticks(busy: 0, idle: 0), at: 1_000)
        #expect(averages.average(over: 60, current: ticks(busy: 10, idle: 10), at: 1_089) != nil)
        #expect(averages.average(over: 60, current: ticks(busy: 10, idle: 10), at: 4_600) == nil)
    }

    @Test func oldCheckpointsAreDropped() {
        var averages = UsageAverages()
        for index in 0..<200 {
            averages.record(ticks(busy: UInt64(index), idle: 0), at: 1_000 + Double(index) * 15)
        }
        let now = 1_000 + 199.0 * 15
        #expect(averages.average(over: 900, current: ticks(busy: 500, idle: 0), at: now) != nil)
        #expect(averages.average(over: 3_000, current: ticks(busy: 500, idle: 0), at: now) == nil)
    }
}

@Suite struct ClusterActivityTests {
    private func state(_ name: String, _ residency: Int64) -> ClusterActivity.State {
        ClusterActivity.State(name: name, residency: residency)
    }

    @Test func weightsFrequencyByTimeInEachState() throws {
        var activity = ClusterActivity()
        activity.add(states: [state("IDLE", 1_000), state("V0", 3), state("V1", 1)], table: [1_000, 2_000])
        #expect(try #require(activity.averageFrequency) == 1_250)
    }

    @Test func idleClusterHasNoFrequency() {
        var activity = ClusterActivity()
        activity.add(states: [state("IDLE", 1_000), state("V0", 0), state("V1", 0)], table: [1_000, 2_000])
        #expect(activity.averageFrequency == nil)
    }

    @Test func mismatchedTableIsIgnoredRatherThanGuessed() {
        var activity = ClusterActivity()
        activity.add(states: [state("IDLE", 1), state("V0", 5), state("V1", 5)], table: [1_000])
        #expect(activity.averageFrequency == nil)
    }

    @Test func downAndOffAreNotActive() throws {
        var activity = ClusterActivity()
        activity.add(states: [state("OFF", 9), state("DOWN", 9), state("V0", 2)], table: [600])
        #expect(try #require(activity.averageFrequency) == 600)
    }

    @Test func overallIsWeightedByActiveTimeAcrossClusters() throws {
        var efficiency = ClusterActivity()
        efficiency.add(states: [state("V0", 3)], table: [1_000])
        var performance = ClusterActivity()
        performance.add(states: [state("V0", 1)], table: [3_000])
        let values = CPUFrequencies(efficiency: efficiency, performance: performance)
        #expect(values.efficiency == 1_000)
        #expect(values.performance == 3_000)
        #expect(try #require(values.overall) == 1_500)
    }

    @Test func tableReadsHertzAndKilohertz() {
        func data(_ values: [UInt32]) -> Data {
            values.withUnsafeBytes { Data($0) }
        }
        #expect(
            PowerManagerTables.frequencies(from: data([600_000_000, 800, 2_424_000_000, 1000])) == [600, 2_424])
        #expect(PowerManagerTables.frequencies(from: data([600_000, 800, 4_512_000, 1000])) == [600, 4_512])
        #expect(PowerManagerTables.frequencies(from: Data()) == [])
    }
}

@Suite struct ThermalTests {
    @Test func oddCountUsesTheMiddleValue() {
        #expect(ThermalReader.typicalTemperature([40, 74, 50]) == 50)
    }

    @Test func evenCountAveragesTheMiddleTwo() {
        #expect(ThermalReader.typicalTemperature([40, 50, 60, 90]) == 55)
    }

    @Test func impossibleReadingsAreIgnored() {
        #expect(ThermalReader.typicalTemperature([0, -1.5, 300, 45]) == 45)
        #expect(ThermalReader.typicalTemperature([0, 300]) == nil)
        #expect(ThermalReader.typicalTemperature([]) == nil)
    }
}

@Suite struct ProcessEntryTests {
    private func entry(_ path: String?) -> ProcessEntry {
        ProcessEntry(pid: 1, name: "x", path: path, cpu: 0, memory: 0)
    }

    @Test(arguments: [
        ("/Applications/Safari.app/Contents/MacOS/Safari", "/Applications/Safari.app"),
        (
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            "/Applications/Claude.app"
        ),
    ])
    func helpersBelongToTheOutermostApp(path: String, expected: String) {
        #expect(entry(path).appBundlePath == expected)
    }

    @Test func toolsOutsideAnAppHaveNoBundle() {
        #expect(entry("/usr/libexec/trustd").appBundlePath == nil)
        #expect(entry(nil).appBundlePath == nil)
    }
}

@Suite struct MenuValueTests {
    @Test func unavailableWithoutData() {
        #expect(MetricUpdate.gpu(GPUSnapshot()).menuValue == .unavailable)
        #expect(MetricUpdate.disk(DiskSnapshot()).menuValue == .unavailable)
        #expect(MetricUpdate.memory(MemorySnapshot()).menuValue == .unavailable)
        #expect(MetricUpdate.battery(BatterySnapshot()).menuValue == .unavailable)
    }

    @Test func percentIsClampedAndRounded() {
        #expect(MetricUpdate.cpu(CPUSnapshot(usage: 0.125)).menuValue == .percent(13))
        #expect(MetricUpdate.cpu(CPUSnapshot(usage: 1.4)).menuValue == .percent(100))
        #expect(MetricUpdate.cpu(CPUSnapshot(usage: -1)).menuValue == .percent(0))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func aReadingThatIsNoNumberDoesNotStopTheApp(value: Double) {
        #expect(MetricUpdate.cpu(CPUSnapshot(usage: value)).menuValue == .percent(value == .infinity ? 100 : 0))
        let fan = FanReading(index: 0, actual: value, target: 0, minimum: 1000, maximum: 4000, isManual: false)
        guard case .fan(let rpm, _, _) = MetricUpdate.fans(FanSnapshot(fans: [fan])).menuValue else {
            Issue.record("a fan is there, so it should show")
            return
        }
        #expect(rpm == 0)
    }

    @Test func aHugeFanReadingDoesNotStopTheApp() {
        let fan = FanReading(index: 0, actual: 1e300, target: 0, minimum: 1000, maximum: 4000, isManual: false)
        guard case .fan(let rpm, let percent, _) = MetricUpdate.fans(FanSnapshot(fans: [fan])).menuValue else {
            Issue.record("a fan is there, so it should show")
            return
        }
        #expect(rpm == 0)
        #expect(percent == 100)
    }

    @Test func nonsenseFanSpeedsAreNotBelieved() {
        #expect(FanReader.believableSpeeds.contains(0))
        #expect(FanReader.believableSpeeds.contains(4744))
        #expect(!FanReader.believableSpeeds.contains(.nan))
        #expect(!FanReader.believableSpeeds.contains(.infinity))
        #expect(!FanReader.believableSpeeds.contains(-1))
        #expect(!FanReader.believableSpeeds.contains(1e30))
    }
}
