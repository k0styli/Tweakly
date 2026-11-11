import Foundation
import Synchronization
import Testing

@testable import SystemMetrics

private final class FakeSampler: MetricSampler {
    nonisolated(unsafe) static var values: [Double] = []
    nonisolated(unsafe) static var detailsClosed = 0
    var resets = 0
    private var index = 0

    func reset() { resets += 1 }

    func closeDetails() { Self.detailsClosed += 1 }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        defer { index += 1 }
        let value = Self.values.isEmpty ? 0.5 : Self.values[min(index, Self.values.count - 1)]
        return .cpu(CPUSnapshot(usage: value))
    }
}

/// Like the processor's: a rate, so its first reading has nothing to say.
private final class RateSampler: MetricSampler {
    private var readings = 0

    func reset() {}

    func sample(level: SamplingLevel) -> MetricUpdate? {
        defer { readings += 1 }
        return readings == 0 ? nil : .cpu(CPUSnapshot(usage: 0.5))
    }
}

private final class Recorder: Sendable {
    private let batches = Mutex<[[MetricUpdate]]>([])
    func record(_ batch: [MetricUpdate]) { batches.withLock { $0.append(batch) } }
    var count: Int { batches.withLock { $0.count } }
}

/// The engine's rules decide how much the app costs at rest, so they are worth pinning down.
@Suite(.serialized) struct EngineTests {
    private func makeEngine(_ recorder: Recorder, values: [Double] = []) -> MetricsEngine {
        FakeSampler.values = values
        FakeSampler.detailsClosed = 0
        return MetricsEngine(output: { recorder.record($0) }, makeSampler: { _ in FakeSampler() })
    }

    @Test func emptyPlanRunsNothing() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan())
        #expect(await engine.isTimerRunning == false)
        #expect(await engine.activeSamplerCount == 0)
    }

    @Test func removingEveryMetricStopsEverything() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        #expect(await engine.isTimerRunning)
        #expect(await engine.activeSamplerCount == 1)
        await engine.update(to: SamplingPlan())
        #expect(await engine.isTimerRunning == false)
        #expect(await engine.activeSamplerCount == 0)
    }

    @Test func aChartHearsEveryReadingAndAnythingElseOnlyAChange() async {
        let quiet = Recorder()
        let engine = makeEngine(quiet)
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        await engine.tick(now: uptimeSeconds() + 10)
        #expect(quiet.count == 1)

        let every = Recorder()
        let charting = makeEngine(every)
        await charting.update(to: SamplingPlan(levels: [.cpu: .menu], kindsReportingEverySample: [.cpu]))
        await charting.tick(now: uptimeSeconds() + 10)
        #expect(every.count == 2)
    }

    @Test func aListOfProcessesDoesNotTakeTheRestOfTheDetails() {
        let plan = SamplingPlan(levels: [.cpu: .overview, .memory: .overview], kindsListingProcesses: [.cpu])
        #expect(plan.listsProcesses(of: .cpu, at: .overview))
        #expect(plan.listsProcesses(of: .memory, at: .overview) == false)
        #expect(plan.listsProcesses(of: .memory, at: .detail))
        // These two rank processes by something of their own.
        #expect(plan.listsProcesses(of: .gpu, at: .detail) == false)
        #expect(plan.listsProcesses(of: .network, at: .detail) == false)
    }

    @Test func takingTheFirstFewMatchesSortingThemAll() {
        for _ in 0..<200 {
            let values = (0..<Int.random(in: 0...40)).map { (key: Int.random(in: 0...9), index: $0) }
            let order: ((key: Int, index: Int), (key: Int, index: Int)) -> Bool = { $0.key > $1.key }
            let expected = values.sorted(by: order).prefix(5).map(\.index)
            #expect(ProcessSampler.first(5, of: values, by: order).map(\.index) == expected)
        }
    }

    @Test func freeSpaceThatStaysPutNeedsNoFullReading() {
        let total: UInt64 = 500_000_000_000
        var check = DiskSampler.FreeSpaceCheck()
        func needed(_ free: UInt64, at time: TimeInterval) -> Bool {
            check.needsFullReading(free: free, total: total, at: time)
        }
        #expect(needed(100_000_000_000, at: 0))
        check.fullReadingWasTaken(at: 0, free: 100_000_000_000)
        // Under a fifth of a percent of the disk, in either direction.
        let slightlyMore = needed(100_500_000_000, at: 120)
        let slightlyLess = needed(99_500_000_000, at: 240)
        #expect(slightlyMore == false)
        #expect(slightlyLess == false)
        let clearlyMore = needed(101_500_000_000, at: 360)
        #expect(clearlyMore)
        check.fullReadingWasTaken(at: 360, free: 101_500_000_000)
        // Space that can be cleared moves on its own, so a full reading is never too far away.
        let soonAfter = needed(101_500_000_000, at: 1_000)
        let muchLater = needed(101_500_000_000, at: 2_200)
        #expect(soonAfter == false)
        #expect(muchLater)
    }

    @Test func aFullReadingForOtherReasonsMovesTheStart() {
        let total: UInt64 = 500_000_000_000
        var check = DiskSampler.FreeSpaceCheck()
        let first = check.needsFullReading(free: 100_000_000_000, total: total, at: 0)
        #expect(first)
        check.fullReadingWasTaken(at: 0, free: 100_000_000_000)
        // Details opened later and took a full reading with 2 GB less free, without asking the check.
        check.fullReadingWasTaken(at: 100, free: 98_000_000_000)
        // The next look from the menu bar compares with that, so the same space needs no second full reading.
        let next = check.needsFullReading(free: 98_000_000_000, total: total, at: 110)
        #expect(next == false)
    }

    @Test func eachMetricCanHaveItsOwnPace() {
        let plan = SamplingPlan(
            levels: [.cpu: .menu, .gpu: .menu], menuInterval: 2, menuIntervals: [.cpu: 1, .gpu: 5])
        #expect(plan.cadence(of: .cpu, at: .menu) == 1)
        #expect(plan.cadence(of: .gpu, at: .menu) == 5)
        #expect(plan.cadence(of: .memory, at: .menu) == 2)
        #expect(plan.timerInterval == 1)
    }

    @Test func leavingDetailsClosesThemAtOnce() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        #expect(FakeSampler.detailsClosed == 0)
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        #expect(FakeSampler.detailsClosed == 1)
    }

    @Test func pausingClosesDetails() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail], isPaused: true))
        #expect(FakeSampler.detailsClosed == 1)
    }

    /// The list's temperature sensors stay open for as long as the list does, whatever else changes in the plan.
    @Test func aSummaryKeepsItsSensorsUntilItCloses() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .summary]))
        await engine.update(to: SamplingPlan(levels: [.cpu: .summary, .memory: .summary]))
        #expect(FakeSampler.detailsClosed == 0)
        await engine.update(to: SamplingPlan())
        #expect(await engine.activeSamplerCount == 0)
    }

    /// A summary opens only some sensors, so moving to details has to open the rest.
    @Test func movingFromASummaryToDetailsStartsThemAfresh() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .summary]))
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        #expect(FakeSampler.detailsClosed == 1)
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        #expect(FakeSampler.detailsClosed == 1)
    }

    @Test func aSummaryListsNoProcessesAndKeepsTheDiskSlow() {
        let plan = SamplingPlan(levels: [.cpu: .summary, .disk: .summary, .battery: .summary])
        #expect(plan.listsProcesses(of: .cpu, at: .summary) == false)
        #expect(plan.listsProcesses(of: .battery, at: .summary) == false)
        #expect(plan.cadence(of: .cpu, at: .summary) == 1)
        #expect(plan.cadence(of: .battery, at: .summary) == 1)
        // Its free space costs about 80M instructions to ask for, and it does not move in a second.
        #expect(plan.cadence(of: .disk, at: .summary) == 120)
    }

    /// An item that comes back from behind the notch must not show its old value until the next tick.
    @Test func theDiskSamplerOutlivesItsItemGoingOutOfSight() async {
        let engine = makeEngine(Recorder())
        let intervals: [MetricKind: TimeInterval] = [.disk: 2, .cpu: 2]
        await engine.update(to: SamplingPlan(levels: [.disk: .menu, .cpu: .menu], menuIntervals: intervals))
        #expect(await engine.activeSamplerCount == 2)
        await engine.update(to: SamplingPlan(levels: [:], menuIntervals: intervals))
        #expect(await engine.activeSamplerCount == 1)
        await engine.update(to: SamplingPlan(levels: [:], menuIntervals: [:]))
        #expect(await engine.activeSamplerCount == 0)
    }

    @Test func anItemComingBackIsSampledAtOnce() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder)
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        #expect(recorder.count == 1)
        await engine.update(to: SamplingPlan())
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        #expect(recorder.count == 2)
    }

    @Test func aRateComingBackIsReadAgainSoon() async throws {
        let recorder = Recorder()
        let engine = MetricsEngine(output: { recorder.record($0) }, makeSampler: { _ in RateSampler() })
        // Another item keeps a long timer going, so only a follow-up can deliver within the test.
        await engine.update(to: SamplingPlan(levels: [.gpu: .menu], menuInterval: 60))
        try await Task.sleep(for: .milliseconds(800))
        let before = recorder.count
        await engine.update(to: SamplingPlan(levels: [.gpu: .menu, .cpu: .menu], menuInterval: 60))
        #expect(recorder.count == before)
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.count == before + 1)
    }

    @Test func pausingStopsTheTimerAndResumingRestartsIt() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu], isPaused: true))
        #expect(await engine.isTimerRunning == false)
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        #expect(await engine.isTimerRunning)
    }

    @Test func pausedEngineDeliversNothing() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder)
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu], isPaused: true))
        await engine.tick(now: uptimeSeconds() + 1_000)
        #expect(recorder.count == 0)
    }

    @Test func eventDrivenBatteryNeedsNoTimer() async {
        let engine = makeEngine(Recorder())
        await engine.update(to: SamplingPlan(levels: [.battery: .menu]))
        #expect(await engine.isTimerRunning == false)
    }

    @Test func unchangedMenuValueIsNotDelivered() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder, values: [0.5, 0.5, 0.5, 0.7])
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu], menuInterval: 2))
        #expect(recorder.count == 1)
        let start = uptimeSeconds() + 1_000
        await engine.tick(now: start)
        await engine.tick(now: start + 2)
        #expect(recorder.count == 1)
        await engine.tick(now: start + 4)
        #expect(recorder.count == 2)
    }

    @Test func detailIsDeliveredEvenWhenUnchanged() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder, values: [0.5])
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        let first = recorder.count
        let start = uptimeSeconds() + 1_000
        await engine.tick(now: start)
        await engine.tick(now: start + 1)
        #expect(recorder.count == first + 2)
    }

    @Test func tickRespectsCadence() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder, values: (0..<20).map { Double($0) / 20 })
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu], menuInterval: 5))
        let first = recorder.count
        let start = uptimeSeconds() + 1_000
        await engine.tick(now: start)
        await engine.tick(now: start + 1)
        #expect(recorder.count == first + 1)
        await engine.tick(now: start + 5)
        #expect(recorder.count == first + 2)
    }

    @Test func timerFollowsFastestCadence() {
        let plan = SamplingPlan(levels: [.disk: .menu, .cpu: .menu], menuInterval: 5)
        #expect(plan.timerInterval == 5)
        #expect(SamplingPlan(levels: [.disk: .menu]).timerInterval == 120)
        #expect(SamplingPlan(levels: [.cpu: .detail], menuInterval: 5).timerInterval == 1)
        #expect(SamplingPlan(levels: [.battery: .detail]).timerInterval == 1)
    }

    /// Load and speed need two readings, and a ring that stays empty for half a second looks broken.
    @Test func anOverviewIsSampledAgainSoonAfterItOpens() async throws {
        let recorder = Recorder()
        let engine = makeEngine(recorder, values: [0.5])
        await engine.update(to: SamplingPlan(levels: [.cpu: .overview]))
        #expect(recorder.count == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.count == 2)
    }

    @Test func raisingLevelDeliversImmediately() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder, values: [0.5])
        await engine.update(to: SamplingPlan(levels: [.cpu: .menu]))
        let before = recorder.count
        await engine.update(to: SamplingPlan(levels: [.cpu: .detail]))
        #expect(recorder.count == before + 1)
    }
}

/// Reads the real system, so these only check that values make sense on the Mac running them.
@Suite struct LiveSamplerTests {
    private func settle() { Thread.sleep(forTimeInterval: 0.25) }

    /// The kernel rate-limits `host_statistics` per second and answers with cached values past that,
    /// which a process running many samplers at once reaches. The app stays far below the limit.
    private func firstValue(of sampler: CPUSampler, level: SamplingLevel) throws -> MetricUpdate {
        for _ in 0..<12 {
            settle()
            if let value = sampler.sample(level: level) { return value }
        }
        return try #require(sampler.sample(level: level))
    }

    @Test func cpu() throws {
        let sampler = CPUSampler()
        _ = try firstValue(of: sampler, level: .detail)
        settle()
        guard case .cpu(let cpu) = try firstValue(of: sampler, level: .detail) else {
            Issue.record("wrong kind")
            return
        }
        #expect((0...1).contains(cpu.usage))
        #expect(!cpu.cores.isEmpty)
        #expect(cpu.cores.allSatisfy { (0...1).contains($0) })
        let temperature = try #require(cpu.temperature)
        #expect((10...110).contains(temperature))
    }

    @Test func freshSamplersWaitForAMeaningfulWindow() {
        #expect(CPUSampler().sample(level: .menu) == nil)
        #expect(NetworkSampler().sample(level: .menu) == nil)
    }

    @Test func networkForgetsRatesAcrossReset() throws {
        let sampler = NetworkSampler()
        settle()
        _ = sampler.sample(level: .menu)
        sampler.reset()
        #expect(sampler.sample(level: .menu) == nil)
    }

    @Test func memory() throws {
        guard case .memory(let memory) = try #require(MemorySampler().sample(level: .detail)) else {
            Issue.record("wrong kind")
            return
        }
        #expect(memory.total > 0)
        #expect(memory.used > 0)
        #expect(memory.used <= memory.total)
        #expect(memory.app + memory.wired + memory.compressed == memory.used)
    }

    @Test func gpu() throws {
        guard case .gpu(let gpu) = try #require(GPUSampler().sample(level: .detail)) else {
            Issue.record("wrong kind")
            return
        }
        #expect((0...1).contains(try #require(gpu.usage)))
        #expect(try #require(gpu.memoryAllocated) > 0)
    }

    @Test func disk() throws {
        let sampler = DiskSampler()
        _ = sampler.sample(level: .detail)
        settle()
        guard case .disk(let disk) = try #require(sampler.sample(level: .detail)) else {
            Issue.record("wrong kind")
            return
        }
        let main = try #require(disk.main)
        #expect(main.total > main.available)
        #expect((0...1).contains(main.usedFraction))
        #expect(try #require(disk.readRate) >= 0)
    }

    @Test func network() throws {
        let sampler = NetworkSampler()
        settle()
        guard case .network(let network) = try #require(sampler.sample(level: .detail)) else {
            Issue.record("wrong kind")
            return
        }
        #expect(network.downRate >= 0)
        #expect(network.totalDown > 0)
    }

    @Test func battery() throws {
        guard case .battery(let battery) = try #require(BatterySampler().sample(level: .detail)) else {
            Issue.record("wrong kind")
            return
        }
        #expect(battery.isPresent == SystemInfo.hasBattery)
        if battery.isPresent {
            #expect((0...100).contains(battery.percent))
            let health = try #require(battery.health)
            #expect(health.cycleCount != nil)
            #expect(health.fullChargeCapacity != nil)
        }
    }

    @Test func processes() {
        let sampler = ProcessSampler()
        let first = sampler.rank()
        #expect(!first.byMemory.isEmpty)
        #expect(first.byMemory.allSatisfy { !$0.name.isEmpty })
        let memory = first.byMemory.map(\.memory)
        #expect(memory == memory.sorted(by: >))
        #expect(first.byCPU.isEmpty, "the first pass has no baseline, so it must not rank by CPU")

        Thread.sleep(forTimeInterval: 0.5)
        let second = sampler.rank()
        #expect(!second.byCPU.isEmpty)
        #expect(second.byCPU.allSatisfy { $0.cpu > 0 })
        #expect(second.byCPU.allSatisfy { $0.pid != getpid() }, "the first figures leave out this process")
        let cpu = second.byCPU.map(\.cpu)
        #expect(cpu == cpu.sorted(by: >))
    }

    @Test func frequencies() throws {
        let reader = try #require(CPUFrequencyReader())
        #expect(reader.read() == nil, "the first read only takes the baseline")
        // Keep a core busy, so at least one cluster is guaranteed to be active.
        let end = uptimeSeconds() + 0.3
        var spin = 0
        while uptimeSeconds() < end { spin &+= 1 }
        #expect(spin > 0)
        let values = try #require(reader.read())
        let overall = try #require(values.overall)
        #expect((100...6000).contains(overall))
    }

    /// The sensors report nothing useful while the GPU is powered off, which is a moment, not a failure.
    @Test func gpuTemperature() throws {
        #expect(!ThermalKeys.discovered.gpu.isEmpty)
        let reader = try #require(ThermalReader())
        var temperature: Double?
        for _ in 0..<50 where temperature == nil {
            temperature = reader.gpuTemperature()
            if temperature == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect((10...110).contains(try #require(temperature)))
    }

    @Test func sensorsOfAPoweredOffBlockGiveNoTemperature() {
        #expect(ThermalReader.typicalTemperature([0, 4.6, 0, 4.6, 0, 4.6]) == nil)
        #expect(ThermalReader.typicalTemperature([0, 4.6, 40, 44]) == 42)
    }

    @Test func menuLevelClosesSensors() throws {
        let sampler = CPUSampler()
        _ = try firstValue(of: sampler, level: .detail)
        guard case .cpu(let menu) = try #require(sampler.sample(level: .menu)) else {
            Issue.record("wrong kind")
            return
        }
        #expect(menu.temperature == nil)
        #expect(menu.cores.isEmpty)
    }

    @Test func systemInfo() {
        let info = SystemInfo.read()
        #expect(info.coreCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect(!info.chipName.isEmpty)
        let allCores = info.clusters.flatMap(\.cores).sorted()
        #expect(allCores == Array(0..<info.coreCount))
    }

    /// Run with `swift test --filter samplerCost` to see what each sampler costs per call.
    @Test func samplerCost() {
        let samplers: [(String, any MetricSampler)] = [
            ("cpu", CPUSampler()), ("gpu", GPUSampler()), ("memory", MemorySampler()),
            ("disk", DiskSampler()), ("network", NetworkSampler()), ("battery", BatterySampler()),
        ]
        for (name, sampler) in samplers {
            for level in [SamplingLevel.menu, .detail] {
                let start = uptimeSeconds()
                for _ in 0..<50 { _ = sampler.sample(level: level) }
                let micros = Int((uptimeSeconds() - start) / 50 * 1_000_000)
                print("cost \(name) \(level): \(micros) us")
            }
        }
        let processes = ProcessSampler()
        let start = uptimeSeconds()
        _ = processes.rank()
        print("cost processes: \(Int((uptimeSeconds() - start) * 1_000_000)) us")
    }
}
