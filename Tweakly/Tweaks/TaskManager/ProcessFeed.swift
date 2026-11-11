import AppKit
import SystemMetrics
import TaskManagerCore

/// What the Processes table needs read, from the columns on screen: threads and the GPU each cost a call per process, and
/// the network a tool of its own.
struct ProcessDemand: Equatable, Sendable {
    var threads = false
    var gpu = true
    var network = true
}

/// One update of the table.
struct ProcessSnapshot: Sendable {
    var groups: [ProcessGroup] = []
    var processCount = 0
    var userNames: [UInt32: String] = [:]
    /// Processes whose figures could not be read, which are other users' without the helper.
    var unreadableCount = 0
    var helper = SystemProcessHelper.State.notInstalled
    /// The processes the system knows as apps, the only ones whose icon is worth asking it for.
    var appPIDs: Set<Int32> = []
}

/// Reads every process at the chosen pace, only while the Processes tab is on screen. Stopping lets go of the readers, the
/// network tool and every baseline, so a hidden tab costs nothing.
final class ProcessFeed {
    /// Long enough for a first rate to mean something, short enough that it seems to arrive with the window.
    private static let followUpDelay: TimeInterval = 0.35

    var onUpdate: ((ProcessSnapshot) -> Void)?
    var demand = ProcessDemand()
    var interval: TimeInterval = 1 {
        // While running, paused included: a pause holds no timer, and a speed chosen after it must start one.
        didSet { if sampler != nil { schedule() } }
    }

    private var sampler: ProcessTableSampler?
    private var apps: RunningApps?
    private var timer: Timer?
    private var isSampling = false

    var isRunning: Bool { sampler != nil }

    func start() {
        guard sampler == nil else { return }
        sampler = ProcessTableSampler()
        apps = RunningApps()
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followUpDelay) { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sampler = nil
        apps = nil
    }

    /// After the helper was installed or updated: a new sampler asks the new helper for its version, where the old one
    /// would go on with what the old helper said.
    func restart() {
        guard sampler != nil else { return }
        stop()
        start()
    }

    /// After a process was asked to end, so that it leaves the table as soon as it is gone.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followUpDelay) { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard interval > 0 else {
            timer = nil
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A tenth as leeway lets the system batch this wakeup with others.
        timer.tolerance = interval / 10
        // Also while a scroller or a column is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // A slow reading is not queued behind another.
        guard let sampler, let runningApps = apps, !isSampling else { return }
        isSampling = true
        #if TWEAKLY_AUTOMATION
            let appsStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let apps = runningApps.identities()
        let demand = demand
        #if TWEAKLY_AUTOMATION
            TaskManagerTiming.shared.add("apps", since: appsStart)
        #endif
        Task.detached(priority: .utility) { [weak self] in
            #if TWEAKLY_AUTOMATION
                let sampleStart = DispatchTime.now().uptimeNanoseconds
            #endif
            let snapshot = await sampler.sample(apps: apps, demand: demand)
            #if TWEAKLY_AUTOMATION
                let sampleTime = DispatchTime.now().uptimeNanoseconds - sampleStart
            #endif
            await MainActor.run {
                guard let self else { return }
                self.isSampling = false
                // Stopped meanwhile, or restarted with a new baseline.
                guard self.sampler === sampler else { return }
                #if TWEAKLY_AUTOMATION
                    TaskManagerTiming.shared.add("sample", nanoseconds: sampleTime)
                    let applyStart = DispatchTime.now().uptimeNanoseconds
                #endif
                self.onUpdate?(snapshot)
                #if TWEAKLY_AUTOMATION
                    TaskManagerTiming.shared.add("apply", since: applyStart)
                #endif
            }
        }
    }
}

/// The readers and their baselines, on a queue of their own at low priority.
actor ProcessTableSampler {
    private let queue = DispatchSerialQueue(label: "me.tweakly.Tweakly.task-manager", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let reader = ProcessCounterReader()
    private let helper = SystemProcessHelper()
    private var gpuReader: GPUTimeReader?
    private var networkReader: (any ProcessNetworkRates)?
    private var tracker = UsageTracker()
    /// Which app each process works for, asked once for each process, as that never changes. Zero means none.
    private var responsible: [ProcessKey: Int32] = [:]
    /// By the executable's path, which is all a name depends on.
    private var displayNames: [String: String] = [:]
    /// When the helper last said each process it reads started. A late answer then leaves every other user's process
    /// as it was, rather than a new one: its group stays open, its row selected, and its rates go on.
    private var helperStarts: [Int32: UInt64] = [:]
    private var userNames: [UInt32: String] = [:]

    #if TWEAKLY_AUTOMATION
        private var demo: DemoProcessTable?
    #endif

    func sample(apps: [Int32: AppIdentity], demand: ProcessDemand) async -> ProcessSnapshot {
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn {
                var table = demo ?? DemoProcessTable()
                let reading = table.read(at: uptime())
                demo = table
                let usages = tracker.update(reading.counters, at: uptime())
                let groups = ProcessGrouping.groups(
                    of: usages, apps: reading.apps, responsible: reading.responsible, user: getuid())
                return ProcessSnapshot(
                    groups: groups, processCount: reading.counters.count, userNames: reading.userNames,
                    unreadableCount: 0, helper: .notInstalled, appPIDs: Set(reading.apps.keys))
            }
        #endif
        if demand.gpu, gpuReader == nil { gpuReader = GPUTimeReader() }
        if !demand.gpu { gpuReader = nil }
        // The kernel's counters each second where the private interface answers, and `nettop` every 5 seconds otherwise.
        if demand.network, networkReader == nil { networkReader = NetworkStatisticsReader() ?? NetworkRateReader() }
        if !demand.network { networkReader = nil }

        #if TWEAKLY_AUTOMATION
            var mark = DispatchTime.now().uptimeNanoseconds
            func lap(_ name: String) {
                let now = DispatchTime.now().uptimeNanoseconds
                let spent = now - mark
                mark = now
                Task { @MainActor in TaskManagerTiming.shared.add(name, nanoseconds: spent) }
            }
        #endif
        let readings = reader.read(includingThreads: demand.threads)
        #if TWEAKLY_AUTOMATION
            lap("  read processes")
        #endif
        // Other users' processes, through the helper where it is installed.
        var helperState = await helper.state()
        var figures: [Int32: SystemProcessHelper.Figures] = [:]
        if helperState == .working {
            let unreadable = readings.lazy.filter { $0.memory == nil }.map(\.pid)
            if let answer = await helper.figures(of: Array(unreadable)) {
                figures = answer
                for (pid, figure) in answer { helperStarts[pid] = figure.start }
            } else {
                helperState = .failing
            }
        }
        #if TWEAKLY_AUTOMATION
            lap("  helper")
        #endif
        let gpuTimes = gpuReader?.read() ?? [:]
        #if TWEAKLY_AUTOMATION
            lap("  read gpu")
        #endif
        let network = networkReader?.rates() ?? [:]
        var unreadable = 0
        var responsibleNow: [Int32: Int32] = [:]
        var seen: Set<ProcessKey> = []
        seen.reserveCapacity(readings.count)
        let counters = readings.map { reading -> ProcessCounters in
            if userNames[reading.userID] == nil {
                userNames[reading.userID] = ProcessCounterReader.userName(of: reading.userID) ?? String(reading.userID)
            }
            let rates = network[reading.pid]
            let lent = reading.memory == nil ? figures[reading.pid] : nil
            if reading.memory == nil, lent == nil { unreadable += 1 }
            let start = lent?.start ?? (reading.memory == nil ? helperStarts[reading.pid] : nil) ?? reading.start
            let key = ProcessKey(pid: reading.pid, start: start)
            seen.insert(key)
            if let owner = responsibleApp(of: key) { responsibleNow[reading.pid] = owner }
            // A process the GPU has never served has used none of it, and a process the network source did not list
            // sent nothing, but only where those sources are working at all.
            return ProcessCounters(
                key: key, parentPID: reading.parentPID, userID: reading.userID, name: displayName(of: reading),
                path: reading.path, cpuTime: reading.cpuTime ?? lent?.cpuTime, memory: reading.memory ?? lent?.memory,
                diskRead: reading.diskRead ?? lent?.diskRead, diskWritten: reading.diskWritten ?? lent?.diskWritten,
                threads: reading.threads ?? (demand.threads ? lent?.threads : nil),
                gpuTime: gpuReader == nil ? nil : gpuTimes[reading.pid] ?? 0,
                receiveRate: networkReader == nil ? nil : rates?.receive ?? 0,
                sendRate: networkReader == nil ? nil : rates?.send ?? 0,
                isTranslated: reading.isTranslated)
        }
        if responsible.count > seen.count * 2 { responsible = responsible.filter { seen.contains($0.key) } }
        if helperStarts.count > readings.count {
            let alive = Set(readings.map(\.pid))
            helperStarts = helperStarts.filter { alive.contains($0.key) }
        }
        let usages = tracker.update(counters, at: uptime())
        if displayNames.count > readings.count * 2 { displayNames = [:] }
        #if TWEAKLY_AUTOMATION
            lap("  counters")
        #endif
        let groups = ProcessGrouping.groups(of: usages, apps: apps, responsible: responsibleNow, user: getuid())
        #if TWEAKLY_AUTOMATION
            lap("  grouping")
        #endif
        return ProcessSnapshot(
            groups: groups, processCount: readings.count, userNames: userNames, unreadableCount: unreadable,
            helper: helperState, appPIDs: Set(apps.keys))
    }

    private func responsibleApp(of key: ProcessKey) -> Int32? {
        if let known = responsible[key] { return known == 0 ? nil : known }
        let owner = ResponsibleProcess.pid(responsibleFor: key.pid)
        responsible[key] = owner ?? 0
        return owner
    }

    /// A helper app's own name, as Finder shows it, such as Google Chrome Helper (Renderer), and a plain executable's
    /// file name otherwise. A program that only lives in an app's folder, as Firefox's crash helper does, keeps its own
    /// name rather than taking the app's.
    private func displayName(of reading: ProcessReading) -> String {
        guard let path = reading.path else { return reading.name }
        if let known = displayNames[path] { return known }
        var name = reading.name
        if let bundle = ProcessGrouping.innermostBundle(of: path),
            URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(reading.name) == .orderedSame
        {
            name = FileManager.default.displayName(atPath: bundle)
        }
        displayNames[path] = name
        return name
    }

    private func uptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

#if TWEAKLY_AUTOMATION
    /// Where a tick's time goes, for measuring.
    final class TaskManagerTiming {
        static let shared = TaskManagerTiming()
        private var totals: [String: (nanoseconds: UInt64, count: Int)] = [:]

        func add(_ name: String, since start: UInt64) {
            add(name, nanoseconds: DispatchTime.now().uptimeNanoseconds - start)
        }

        func add(_ name: String, nanoseconds: UInt64) {
            let old = totals[name] ?? (0, 0)
            totals[name] = (old.nanoseconds + nanoseconds, old.count + 1)
        }

        func report() -> String {
            defer { totals = [:] }
            return totals.sorted { $0.key < $1.key }.map {
                "\($0.key): \(Double($0.value.nanoseconds) / Double(max($0.value.count, 1)) / 1_000_000) ms x \($0.value.count)"
            }.joined(separator: "\n") + "\n"
        }
    }
#endif
