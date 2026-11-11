import Dispatch
import Foundation

/// One metric's data source. Conformers are only ever touched from the engine's queue.
protocol MetricSampler: AnyObject {
    /// Forgets rate baselines, because time and counters may have jumped (for example after sleep).
    func reset()
    func sample(level: SamplingLevel) -> MetricUpdate?
    /// Details are no longer on screen. Sensors, connections, pings and helper processes stop here and
    /// now, whatever the next sample's timing, because a menu level may not sample for hours.
    func closeDetails()
}

extension MetricSampler {
    func closeDetails() {}
}

/// Runs every sampler on one low-priority queue from one timer, so all metrics share a single wakeup.
///
/// With an empty plan there is no timer, no sampler and no observer. A paused plan keeps its samplers, with
/// their baselines and history, but nothing in them runs.
public actor MetricsEngine {
    public typealias Output = @Sendable ([MetricUpdate]) -> Void

    /// Long enough for rates to mean something, short enough that values appear almost at once.
    private static let firstTickDelay: TimeInterval = 0.5
    /// Just past `minimumSampleInterval`, so details fill in about as fast as the popover appears.
    private static let followUpDelay: TimeInterval = 0.25

    private let queue: DispatchSerialQueue
    private let output: Output
    private let makeSampler: (MetricKind) -> any MetricSampler
    private var plan = SamplingPlan()
    private var samplers: [MetricKind: any MetricSampler] = [:]
    private var processes: ProcessSampler?
    private var lastSampled: [MetricKind: TimeInterval] = [:]
    private var lastMenuValue: [MetricKind: MenuValue] = [:]
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval?
    private var powerObserver: PowerSourceObserver?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(output: @escaping Output) {
        self.init(output: output, makeSampler: Self.liveSampler)
    }

    init(output: @escaping Output, makeSampler: @escaping (MetricKind) -> any MetricSampler) {
        self.queue = DispatchSerialQueue(label: "me.tweakly.Tweakly.metrics", qos: .utility)
        self.output = output
        self.makeSampler = makeSampler
    }

    /// Plans apply in the order they are sent, which a detached task would not guarantee.
    public nonisolated func apply(_ plan: SamplingPlan) {
        queue.async { [self] in
            assumeIsolated { $0.update(to: plan) }
        }
    }

    func update(to newPlan: SamplingPlan) {
        let previous = plan
        plan = newPlan
        let active = newPlan.isPaused ? [:] : newPlan.levels

        for kind in samplers.keys where newPlan.levels[kind] == nil {
            // An item goes out of sight with every full-screen app and comes back. A new disk sampler would have
            // to ask for purgeable-aware free space again, about 80M instructions, so this one stays with its item.
            if kind != .disk || newPlan.menuIntervals[kind] == nil { samplers[kind] = nil }
            lastSampled[kind] = nil
            lastMenuValue[kind] = nil
        }
        for (kind, sampler) in samplers
        where (active[kind] ?? .menu) < .summary || active[kind] != previous.levels[kind] {
            sampler.closeDetails()
        }
        let resuming = previous.isPaused && !newPlan.isPaused
        if resuming { samplers.values.forEach { $0.reset() } }

        var due: [MetricKind] = []
        for (kind, level) in active {
            if samplers[kind] == nil { samplers[kind] = makeSampler(kind) }
            // A consumer asking for more data, or waking up, should not wait for the next tick.
            if resuming || level > (previous.levels[kind] ?? .menu) || previous.levels[kind] == nil {
                due.append(kind)
            }
        }
        if active.contains(where: { newPlan.listsProcesses(of: $0.key, at: $0.value) }) {
            if processes == nil { processes = ProcessSampler() }
        } else {
            processes = nil
        }
        updatePowerObserver(isNeeded: active[.battery] != nil)
        rescheduleTimer()
        sample(due, now: uptimeSeconds())
        var needingSecondReading = Set(
            active.filter { kind, level in
                let had = previous.levels[kind]
                if level >= .summary { return had != level }
                return had == nil && (level == .overview || newPlan.listsProcesses(of: kind, at: level))
            }.keys)
        // A new sampler of a rate, the processor's or the network's, has nothing to say on its first reading. An item
        // coming back into sight would otherwise show its old value until the next tick, seconds away.
        needingSecondReading.formUnion(due.filter { lastSampled[$0] == nil })
        if !needingSecondReading.isEmpty { scheduleFollowUp(Array(needingSecondReading)) }
    }

    /// Per-core loads, process CPU and rates need two readings. Sampling again shortly after something
    /// opens shows them almost at once, whatever the timer happens to be doing.
    private func scheduleFollowUp(_ kinds: [MetricKind]) {
        queue.asyncAfter(deadline: .now() + Self.followUpDelay) { [weak self] in
            self?.assumeIsolated { engine in
                guard !engine.plan.isPaused else { return }
                engine.sample(kinds.filter { engine.plan.levels[$0] != nil }, now: uptimeSeconds())
            }
        }
    }

    func tick(now: TimeInterval = uptimeSeconds()) {
        guard !plan.isPaused else { return }
        var due: [MetricKind] = []
        for (kind, level) in plan.levels {
            guard let cadence = plan.cadence(of: kind, at: level) else { continue }
            // Slightly early counts as on time, so a coalesced timer does not skip a whole cycle.
            if now - (lastSampled[kind] ?? 0) >= cadence * 0.9 { due.append(kind) }
        }
        sample(due, now: now)
    }

    var isTimerRunning: Bool { timer != nil }
    var activeSamplerCount: Int { samplers.count }

    private func sample(_ kinds: [MetricKind], now: TimeInterval) {
        guard !kinds.isEmpty else { return }
        var updates: [MetricUpdate] = []
        let ranking = processes?.rank()
        for kind in kinds {
            guard let level = plan.levels[kind], var update = samplers[kind]?.sample(level: level) else { continue }
            lastSampled[kind] = now
            let value = update.menuValue
            if level == .menu, !plan.kindsReportingEverySample.contains(kind), lastMenuValue[kind] == value { continue }
            lastMenuValue[kind] = value
            if let ranking, plan.listsProcesses(of: kind, at: level) {
                switch update {
                case .cpu(var cpu):
                    cpu.topProcesses = ranking.byCPU
                    update = .cpu(cpu)
                case .memory(var memory):
                    memory.topProcesses = ranking.byMemory
                    update = .memory(memory)
                case .battery(var battery):
                    battery.topProcesses = ranking.byCPU
                    update = .battery(battery)
                case .disk(var disk):
                    disk.topProcesses = ranking.byDisk
                    update = .disk(disk)
                default:
                    break
                }
            }
            updates.append(update)
        }
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn { updates = updates.map(DemoData.disguise) }
        #endif
        if !updates.isEmpty { output(updates) }
    }

    private func rescheduleTimer() {
        let interval = plan.timerInterval
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.cancel()
        timer = nil
        guard let interval else { return }
        let source = DispatchSource.makeTimerSource(flags: [], queue: queue)
        // A tenth of the interval as leeway lets the system batch this wakeup with others.
        source.schedule(
            deadline: .now() + min(interval, Self.firstTickDelay),
            repeating: interval,
            leeway: .milliseconds(Int(interval * 100))
        )
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.tick() }
        }
        source.resume()
        timer = source
    }

    private func updatePowerObserver(isNeeded: Bool) {
        guard isNeeded else {
            powerObserver = nil
            return
        }
        guard powerObserver == nil else { return }
        powerObserver = PowerSourceObserver(queue: queue) { [weak self] in
            self?.assumeIsolated { $0.sample([.battery], now: uptimeSeconds()) }
        }
    }

    private static func liveSampler(for kind: MetricKind) -> any MetricSampler {
        switch kind {
        case .cpu: CPUSampler()
        case .gpu: GPUSampler()
        case .memory: MemorySampler()
        case .disk: DiskSampler()
        case .network: NetworkSampler()
        case .battery: BatterySampler()
        case .fans:
            #if TWEAKLY_AUTOMATION
                DemoData.isOn ? DemoFanSampler() : FanSampler()
            #else
                FanSampler()
            #endif
        }
    }
}
