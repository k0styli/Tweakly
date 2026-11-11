import FanControlCore
import Foundation
import os

private let log = Logger(subsystem: "me.tweakly.Tweakly.fanhelper", category: "fans")

/// What the helper does for the app, and all of it: the fans, and reading and ending processes for the task manager
/// (`ProcessService`). It holds the fans only on a lease: when the app stops renewing it or goes
/// away, the fans go back to the system without anyone asking. If a sensor stays over the emergency line, they run at full
/// speed whatever the app asks for, because a system taking over stops them first.
///
/// `@unchecked Sendable`: every piece of state is touched only on `queue`, including from the calls NSXPC makes on queues of
/// its own, which all hop onto it first.
final class FanService: NSObject, FanHelperProtocol, @unchecked Sendable {
    /// How long it stays around with nothing to do, so that a burst of calls does not restart it each time.
    private static let idleExit: TimeInterval = 20
    /// A last line of defence: the app watches the same temperature every few seconds, and the Mac protects itself too.
    /// Reading every sensor takes several milliseconds, so this is not done often.
    private static let watchInterval: TimeInterval = 20
    /// Checks in a row over the line before it counts, as one sensor can jump for a moment.
    private static let hotChecksNeeded = 2
    private static let shortestLease: TimeInterval = 5
    private static let longestLease: TimeInterval = 60
    /// Above this no setting counts, whatever the app asks for.
    private static let highestEmergency = 105.0
    private static let plausibleTemperature: ClosedRange<Float> = 5...125

    private struct Fan {
        let mode: UInt32
        let target: UInt32
        let minimum: Float
        let maximum: Float
    }

    private let queue = DispatchQueue(label: "fans")
    private let smc: FanSMC?
    private var fans: [Fan] = []
    /// What each mode key held before this helper touched it, which is what giving it back means.
    private var found: [Int: UInt8] = [:]
    private var temperatureKeys: [UInt32] = []
    private var emergency = 95.0
    private var hotChecks = 0
    private var isHot = false
    private var holder: ObjectIdentifier?
    private var leaseEnd: DispatchWorkItem?
    private var watch: DispatchSourceTimer?
    private var idle: DispatchWorkItem?
    private var signals: [DispatchSourceSignal] = []

    override init() {
        smc = FanSMC()
        super.init()
        if let smc {
            fans = Self.readFans(smc)
            clearLeftovers(smc)
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.giveBack(because: "a signal")
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
        queue.async { self.scheduleIdleExit() }
    }

    private static func readFans(_ smc: FanSMC) -> [Fan] {
        let count = min(Int(smc.readByte(FanSMC.code("FNum")) ?? 0), 8)
        return (0..<count).compactMap { index in
            guard let minimum = smc.readFloat(FanSMC.code("F\(index)Mn")),
                let maximum = smc.readFloat(FanSMC.code("F\(index)Mx")), maximum > minimum,
                let mode = ["F\(index)Md", "F\(index)md"].map(FanSMC.code).first(where: smc.exists)
            else { return nil }
            return Fan(mode: mode, target: FanSMC.code("F\(index)Tg"), minimum: minimum, maximum: maximum)
        }
    }

    /// launchd starts this again after a crash, which may have left a fan on the last speed it was given with nobody
    /// watching it. Nothing here has taken a fan yet, so a fan set by hand is for the system to have back.
    private func clearLeftovers(_ smc: FanSMC) {
        for fan in fans where smc.readByte(fan.mode) == FanHelperWrite.manualMode {
            log.notice("Found a fan set by hand, and gave it to the system")
            _ = smc.write(fan.mode, byte: FanHelperWrite.systemMode)
            _ = smc.write(fan.target, float: 0)
        }
    }

    /// A connection going away is only news if it is the one that holds the fans: the window also asks for the version.
    func connectionEnded(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        queue.async {
            if self.holder == id { self.giveBack(because: "the app went away") }
            self.scheduleIdleExit()
        }
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(FanHelper.currentVersion)
    }

    func setFans(_ targets: [NSNumber], lease: Double, emergency: Double, reply: @escaping @Sendable (String?) -> Void)
    {
        let caller = NSXPCConnection.current().map(ObjectIdentifier.init)
        let wanted = targets.map(\.doubleValue)
        queue.async {
            reply(self.apply(wanted, lease: lease, emergency: emergency, caller: caller))
        }
    }

    func returnToSystem(reply: @escaping @Sendable () -> Void) {
        queue.async {
            self.giveBack(because: "the app asked")
            reply()
        }
    }

    /// Each call puts off leaving, so the helper stays while the task manager asks every second or so, and goes 20
    /// seconds after it stops.
    func processFigures(_ pids: [NSNumber], reply: @escaping @Sendable ([NSNumber]) -> Void) {
        let numbers = pids.map(\.int32Value)
        queue.async {
            self.scheduleIdleExit()
            reply(ProcessService.figures(of: numbers))
        }
    }

    func endProcess(_ pid: Int32, start: UInt64, force: Bool, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.scheduleIdleExit()
            reply(ProcessService.end(pid, start: start, force: force))
        }
    }

    private func apply(_ targets: [Double], lease: Double, emergency: Double, caller: ObjectIdentifier?) -> String? {
        guard let smc else { return "no connection to the SMC" }
        guard !fans.isEmpty else { return "no fans" }
        guard lease.isFinite, emergency.isFinite else { return "bad request" }
        self.emergency = min(emergency, Self.highestEmergency)
        holder = caller
        idle?.cancel()
        if temperatureKeys.isEmpty {
            temperatureKeys = smc.temperatureKeys()
            checkHeat()
        }
        for (index, fan) in fans.enumerated() {
            let target = index < targets.count ? targets[index] : -1
            guard target >= 0, target.isFinite else {
                giveBackFan(index, fan)
                continue
            }
            let current = smc.readByte(fan.mode)
            // A fan already set by hand has no system value to go back to, and the system understands this one.
            if found[index] == nil, let current {
                found[index] = current == FanHelperWrite.manualMode ? FanHelperWrite.systemMode : current
            }
            let rpm = isHot ? fan.maximum : min(max(Float(target), fan.minimum), fan.maximum)
            let isManual = current == FanHelperWrite.manualMode || smc.write(fan.mode, byte: FanHelperWrite.manualMode)
            guard isManual, smc.write(fan.target, float: rpm) else {
                log.error("A fan refused a write")
                giveBack(because: "a fan refused a write")
                return "a fan refused a write"
            }
        }
        if found.isEmpty {
            finishHolding()
        } else {
            renewLease(min(max(lease, Self.shortestLease), Self.longestLease))
            startWatching()
        }
        return isHot ? "emergency" : nil
    }

    private func renewLease(_ seconds: TimeInterval) {
        leaseEnd?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.giveBack(because: "the lease ran out") }
        leaseEnd = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func startWatching() {
        guard watch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchInterval, repeating: Self.watchInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkHeat()
            if self.isHot { self.runHeldFansFlatOut() }
        }
        timer.resume()
        watch = timer
    }

    private func checkHeat() {
        guard let hottest = hottestTemperature() else { return }
        if hottest >= emergency {
            hotChecks += 1
            if hotChecks >= Self.hotChecksNeeded {
                if !isHot { log.notice("Too hot, at \(hottest, privacy: .public) °C: full speed") }
                isHot = true
            }
        } else {
            hotChecks = 0
            if hottest <= emergency - FanController.emergencyRecovery { isHot = false }
        }
    }

    private func runHeldFansFlatOut() {
        guard let smc else { return }
        for (index, fan) in fans.enumerated() where found[index] != nil {
            _ = smc.write(fan.target, float: fan.maximum)
        }
    }

    private func hottestTemperature() -> Double? {
        guard let smc else { return nil }
        return temperatureKeys.compactMap(smc.readFloat).filter(Self.plausibleTemperature.contains).max().map(
            Double.init)
    }

    private func giveBack(because reason: String) {
        if !found.isEmpty { log.notice("Giving the fans back: \(reason, privacy: .public)") }
        for (index, fan) in fans.enumerated() { giveBackFan(index, fan) }
        finishHolding()
    }

    private func giveBackFan(_ index: Int, _ fan: Fan) {
        guard let smc, let mode = found[index] else { return }
        let restored = smc.write(fan.mode, byte: mode)
        _ = smc.write(fan.target, float: 0)
        if restored { found[index] = nil } else { log.error("A fan could not be given back") }
    }

    private func finishHolding() {
        leaseEnd?.cancel()
        leaseEnd = nil
        watch?.cancel()
        watch = nil
        holder = nil
        hotChecks = 0
        isHot = false
        scheduleIdleExit()
    }

    /// launchd starts it again when the app next asks, so with nothing to do it costs nothing at all.
    private func scheduleIdleExit() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.found.isEmpty else { return }
            exit(0)
        }
        idle = item
        queue.asyncAfter(deadline: .now() + Self.idleExit, execute: item)
    }
}

enum FanHelperWrite {
    /// What the mode key holds while something other than the system sets the speed.
    static let manualMode: UInt8 = 1
    /// What asks the system to take a fan. On an M1 Pro it turns this into its own 3 within a second or two.
    static let systemMode: UInt8 = 0
}
