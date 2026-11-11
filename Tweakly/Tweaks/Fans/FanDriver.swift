import FanControlCore
import Foundation
import IOKit.ps
import SystemMetrics
import os

private let log = Logger(subsystem: "me.tweakly.Tweakly", category: "fans")

/// Why the fans are not doing what was chosen. The window reads this too, from preferences.
enum FanDriverStatus: String {
    case fine, noHelper, refused, emergency, noTemperature, noReading

    /// Where the window finds it. Written only when it changes.
    static let key = "fanDriverStatus"

    /// Nothing is trying to run the fans, so nothing can be wrong with that. What was last said would otherwise stay on the
    /// page, even across launches: that the Mac is very hot, days after someone went back to the system.
    static func forget() {
        guard UserDefaults.standard.object(forKey: key) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    var message: String? {
        switch self {
        case .fine: nil
        case .noHelper:
            String(localized: "The fan helper is not installed or does not answer, so the system runs the fans.")
        case .refused: String(localized: "A fan refused the change, so the system runs the fans.")
        case .emergency: String(localized: "The Mac is very hot, so the fans run at full speed until it cools down.")
        case .noTemperature: String(localized: "The temperature cannot be read, so the system runs the fans.")
        case .noReading: String(localized: "The fans cannot be read, so the system runs them.")
        }
    }
}

/// Runs the fans as chosen, one reading at a time, through the root helper. It exists only while something takes a fan from
/// the system. It holds the fans on a lease, so if this process stops for any reason they go back without it.
final class FanDriver {
    /// How long the helper keeps the fans without hearing from here.
    private static let lease: TimeInterval = 15
    /// How often the lease is renewed when nothing has changed.
    private static let renewal: TimeInterval = 5
    /// Readings in a row with no fan in them before saying so: about as long as the lease, which gives them back by itself.
    private static let emptyReadingsAllowed = 5
    /// How long a helper that cannot be reached is left alone: a removed or refused helper stays so, and every try makes
    /// a new connection.
    private static let unreachableRetry: TimeInterval = 60

    private let client = FanHelperClient()
    private var controllers: [FanController] = []
    private var lastSent: [Double]?
    private var lastSentTime: TimeInterval = 0
    /// Whether the helper may hold the fans now, from the first targets sent until they are given back, a failed answer
    /// included: it may have taken them before failing, and keeps them until its lease ends unless told.
    private var mayHoldFans = false
    private var unreachableSince: TimeInterval?
    private var emptyReadings = 0
    private var fanTargets = FanTargets()

    private(set) var status = FanDriverStatus.fine {
        didSet {
            guard status != oldValue else { return }
            log.notice("Status: \(self.status.rawValue, privacy: .public)")
            UserDefaults.standard.set(status.rawValue, forKey: FanDriverStatus.key)
        }
    }

    init() {
        UserDefaults.standard.set(FanDriverStatus.fine.rawValue, forKey: FanDriverStatus.key)
    }

    func follow(_ snapshot: FanSnapshot, settings: FanSettings) {
        // A key that changed its name on a new macOS looks like this, and without a word someone's choice would simply do
        // nothing. One empty reading can be a passing failure, and the lease covers the fans in the meantime.
        guard !snapshot.fans.isEmpty else {
            emptyReadings += 1
            guard emptyReadings >= Self.emptyReadingsAllowed else { return }
            giveBack(because: "no fan can be read")
            status = .noReading
            return
        }
        emptyReadings = 0
        let now = ProcessInfo.processInfo.systemUptime
        let plan = settings.plan(onBattery: settings.battery != nil && Self.isOnBattery)
        let tuning = settings.tuning.validated
        for fan in snapshot.fans where fan.index >= controllers.count {
            controllers.append(contentsOf: repeatElement(FanController(), count: fan.index - controllers.count + 1))
        }

        var decided: [Int: Double] = [:]
        var hold: FanHoldReason?
        for fan in snapshot.fans {
            let setup = plan.setup(ofFan: fan.index)
            let command = controllers[fan.index].next(
                setup: setup, tuning: tuning, limits: FanLimits(minimum: fan.minimum, maximum: fan.maximum),
                temperature: setup.sensor.reading(in: snapshot.temperatures),
                hottest: snapshot.temperatures.hottest, current: fan.actual, now: now)
            hold = hold ?? controllers[fan.index].hold
            switch command {
            case .system: decided[fan.index] = FanTargets.system
            case .rpm(let rpm): decided[fan.index] = rpm
            }
        }

        let targets = fanTargets.merged(decided, last: lastSent)
        let takesNone = targets.allSatisfy { $0 < 0 }
        if takesNone {
            giveBack(because: "nothing takes a fan at \(snapshot.temperatures.hottest ?? -1) °C")
            status = Self.status(for: hold)
            return
        }
        let isDue = now - lastSentTime >= Self.renewal
        guard targets != lastSent || isDue else { return }
        if let unreachableSince, now - unreachableSince < Self.unreachableRetry { return }
        lastSent = targets
        lastSentTime = now
        mayHoldFans = true
        client.setFans(targets, lease: Self.lease, emergency: tuning.emergencyTemperature) { [weak self] error in
            self?.heard(error, hold: hold)
        }
    }

    /// Back to the system now. Called on the way to sleep too: a Mac wakes with its fans reset, and someone else's choice
    /// should not be running while nobody can see it.
    func giveBack(because reason: String) {
        guard mayHoldFans else { return }
        log.notice("Giving the fans back: \(reason, privacy: .public)")
        lastSent = nil
        mayHoldFans = false
        client.returnToSystem()
        client.close()
    }

    private func heard(_ error: String?, hold: FanHoldReason?) {
        unreachableSince = nil
        guard let error else {
            status = Self.status(for: hold)
            return
        }
        let heard: FanDriverStatus =
            switch error {
            case "emergency": .emergency
            case "a fan refused a write": .refused
            default: .noHelper
            }
        // The helper ran the fans at full speed itself: what was sent stands, and the renewal goes on as usual.
        // Otherwise sending again on the next reading is the only recovery there is, and it is what happens, after a
        // while for a helper that cannot be reached at all.
        if heard != .emergency { lastSent = nil }
        if heard == .noHelper { unreachableSince = ProcessInfo.processInfo.systemUptime }
        if heard != status { log.error("The helper: \(error, privacy: .public)") }
        status = heard
    }

    private static func status(for hold: FanHoldReason?) -> FanDriverStatus {
        switch hold {
        case .emergency: .emergency
        case .noTemperature: .noTemperature
        case nil: .fine
        }
    }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }
}

extension FanSensor {
    /// What a curve following this sensor reads, for the driver and for the page alike.
    func reading(in temperatures: FanTemperatures) -> Double? {
        switch self {
        case .hottest: temperatures.hottest
        case .hottestCPU: temperatures.hottestCPU
        case .averageCPU: temperatures.typicalCPU
        case .gpu: temperatures.hottestGPU
        case .battery: temperatures.battery
        }
    }
}

extension FanSettings {
    /// Whether anything here takes a fan from the system, whichever source of power it is on. The most fans a Mac can have
    /// is what is asked about, as this does not know how many there are.
    var takesFans: Bool {
        adapter.usesFans(count: 8) || battery?.usesFans(count: 8) == true
    }
}
