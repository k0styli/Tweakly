import BatteryHealthCore
import Foundation
import Observation
import SystemMetrics
import os

/// The Battery Health page: every battery seen on this Mac, read while the page shows and kept afterwards. It lives in
/// the window's process, which exits when the window closes, so nothing here costs the agent anything.
///
/// While the page is on screen: this Mac and accessories whenever the system says a power source changed, and every
/// 5 seconds only while this Mac's own page shows its watts; iPhones and iPads every 30 seconds over a session kept open,
/// about 7 million instructions a read, where setting a session up costs 260 million.
@Observable final class BatteryHealthModel {
    /// A device that is connected but could not be read, under a digest of its identifier.
    struct Unreadable: Equatable {
        var problem: MobileDeviceReport.Problem
        var connection: Connection
    }

    private static let macInterval: TimeInterval = 5
    private static let mobileInterval: TimeInterval = 30
    /// Live figures change with every read, but the file needs them only for a device that goes away.
    private static let saveInterval: TimeInterval = 60

    private(set) var archive = BatteryArchive()
    /// The figures that change with every read, kept apart from the archive so that only the rows showing them are drawn
    /// again: the whole page laid out anew every 5 seconds cost the window about 0.8 % of the processor.
    private(set) var live: [String: BatteryReading] = [:]
    /// Devices connected now, this Mac included while it has a battery.
    private(set) var connected: Set<String> = []
    private(set) var unreadable: [String: Unreadable] = [:]
    /// Watts a Mac with no battery uses; nil on a laptop, which shows its own.
    private(set) var macPowerWithoutBattery: Double?
    private(set) var hasLoaded = false
    /// MobileDevice could not be loaded: iPhones and iPads cannot be read on this system.
    private(set) var readsMobileDevices = true

    /// The page, or one of its devices' pages, is the one chosen in the window: devices are followed as they come and go.
    @ObservationIgnored private var isActive = false
    /// The window can also be seen: only then is anything polled.
    @ObservationIgnored private var isPolling = false
    /// The device whose page is on screen, nil on the list.
    @ObservationIgnored private var focus: String?
    /// When each device was last read. Readings that only moved the clock are not stored, so that the page is not drawn
    /// again for nothing; a device that goes away takes this time as its data's.
    @ObservationIgnored private var lastRead: [String: Date] = [:]
    @ObservationIgnored private let reader = BatteryHealthReader()
    @ObservationIgnored private var mobile: MobileDevices?
    @ObservationIgnored private var changes: PowerSourceChanges?
    @ObservationIgnored private var macTimer: Timer?
    @ObservationIgnored private var mobileTimer: Timer?
    @ObservationIgnored private var lastSave: Date?
    /// Digests of the iPhones and iPads read since the page was chosen, by their own identifiers.
    @ObservationIgnored private var mobileIDs: [String: String] = [:]
    /// False when the archive on disk could not be read or is from a later version: it is then never overwritten.
    @ObservationIgnored private var canSave = true

    /// This Mac reported no battery: a desktop Mac, which shows the power it uses instead.
    private(set) var macHasNoBattery = false

    var mac: KnownDevice? { archive[DeviceIdentity.thisMac] }

    /// Connected devices first, each group in the order they were first seen; this Mac is shown on its own.
    var others: (connected: [KnownDevice], away: [KnownDevice]) {
        let devices = archive.devices.filter { $0.id != DeviceIdentity.thisMac }
        let now = devices.filter { connected.contains($0.id) }
        let away = devices.filter { !connected.contains($0.id) }.sorted { $0.latest.date > $1.latest.date }
        return (now, away)
    }

    func isConnected(_ id: String) -> Bool { connected.contains(id) }

    /// Follows the window: the page chosen or not, the window seen or covered, and which device's page shows. Covering
    /// the window only stops polling, so that iPhones keep their open sessions and rows do not flicker to Not Connected.
    func update(windowVisible: Bool, page: MainPage) {
        let onPage = page.sidebarPage == .batteryHealth
        focus = if case .batteryDevice(let id) = page { id } else { nil }
        if onPage != isActive {
            isActive = onPage
            if onPage { start() } else { stop() }
        }
        setPolling(isActive && windowVisible)
        updateMacTimer()
    }

    private func updateMacTimer() {
        let wanted = isPolling && focus == DeviceIdentity.thisMac && !Self.isDemo
        if wanted, macTimer == nil {
            readMac()
            macTimer = repeating(Self.macInterval) { $0.readMac() }
        } else if !wanted {
            macTimer?.invalidate()
            macTimer = nil
        }
    }

    func forget(_ id: String) {
        live[id] = nil
        archive.forget(id)
        save(now: true)
    }

    // MARK: Reading

    private func start() {
        if !hasLoaded {
            hasLoaded = true
            if !Self.isDemo {
                let loaded = BatteryHealthStore.load()
                archive = loaded.archive
                canSave = loaded.canSave
            }
        }
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn {
                // Every time, as leaving the page forgets what is connected.
                if archive.devices.isEmpty { archive = DemoBatteries.archive() }
                connected = DemoBatteries.connected
                macPowerWithoutBattery = DemoBatteries.powerWithoutBattery
                macHasNoBattery = DemoBatteries.powerWithoutBattery != nil
                readsMobileDevices = DemoBatteries.readsMobileDevices
                unreadable = DemoBatteries.unreadable
                return
            }
        #endif
        if let mobile {
            mobile.resume()
        } else {
            mobile = MobileDevices { [weak self] event in
                // Kept in order on the main queue: a device that went away must not come back from a read before it.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }
            readsMobileDevices = mobile != nil
        }
    }

    private func stop() {
        setPolling(false)
        // Kept for the window's life: see `MobileDevices.pause`.
        mobile?.pause()
        reader.close()
        // A device that comes or goes while the page is away is read afresh when it shows again.
        markRead(connected.subtracting([DeviceIdentity.thisMac]))
        connected = connected.filter { $0 == DeviceIdentity.thisMac }
        unreadable = [:]
        mobileIDs = [:]
        save(now: true)
    }

    private func setPolling(_ polling: Bool) {
        guard polling != isPolling else { return }
        isPolling = polling
        if polling, !Self.isDemo {
            readMac(fresh: true)
            changes = PowerSourceChanges(queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.readMac(fresh: true) }
            }
            mobile?.refresh()
            mobileTimer = repeating(Self.mobileInterval) { $0.mobile?.refresh() }
        } else {
            changes = nil
            mobileTimer?.invalidate()
            mobileTimer = nil
            macTimer?.invalidate()
            macTimer = nil
        }
    }

    private func repeating(_ interval: TimeInterval, _ action: @escaping @MainActor (BatteryHealthModel) -> Void)
        -> Timer
    {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Test copies taking pictures show made-up devices and never read this Mac's own.
    private static var isDemo: Bool {
        #if TWEAKLY_AUTOMATION
            DemoData.isOn
        #else
            false
        #endif
    }

    private func readMac(fresh: Bool = false) {
        guard !Self.isDemo else { return }
        reader.read(fresh: fresh) { [weak self] report, accessories in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(report, accessories: accessories) } }
        }
    }

    private func apply(_ report: BatteryHealthReader.MacReport, accessories: [PowerSourceParser.Accessory]) {
        guard isActive else { return }
        var seen: Set<String> = []
        if let battery = report.battery {
            let info = SystemInfo.current
            record(
                KnownDevice(
                    id: DeviceIdentity.thisMac, kind: .mac, name: info.productName ?? info.modelIdentifier,
                    model: info.modelIdentifier, systemVersion: Self.macOSVersion, connection: .builtIn,
                    reading: battery))
            seen.insert(DeviceIdentity.thisMac)
            if macHasNoBattery { macHasNoBattery = false }
            if macPowerWithoutBattery != nil { macPowerWithoutBattery = nil }
        } else {
            if !macHasNoBattery { macHasNoBattery = true }
            if macPowerWithoutBattery != report.systemPower { macPowerWithoutBattery = report.systemPower }
        }
        for accessory in report.ups + accessories {
            let id = DeviceIdentity.id(kind: accessory.kind == .ups ? "ups" : "accessory", raw: accessory.identifier)
            record(
                KnownDevice(
                    id: id, kind: accessory.kind, name: accessory.name, vendorID: accessory.vendorID,
                    productID: accessory.productID, connection: accessory.kind == .ups ? .usb : .bluetooth,
                    reading: accessory.reading))
            seen.insert(id)
        }
        // Everything read here is connected exactly when it was listed; iPhones and watches keep their own state.
        let mobile = Set(mobileIDs.values).union(watchIDs)
        let now = seen.union(connected.intersection(mobile))
        markRead(connected.subtracting(now))
        if now != connected { connected = now }
    }

    /// Watches are connected while the iPhone they were read through is.
    @ObservationIgnored private var watchesByPhone: [String: Set<String>] = [:]
    private var watchIDs: Set<String> { watchesByPhone.values.reduce(into: []) { $0.formUnion($1) } }

    private func handle(_ event: MobileDevices.Event) {
        guard isActive else { return }
        switch event {
        case .read(let report):
            let id = DeviceIdentity.id(kind: "ios", raw: report.identifier)
            mobileIDs[report.identifier] = id
            // Observed values are set only when they change: each setting draws the page again.
            if !connected.contains(id) { connected.insert(id) }
            let problem = report.problem.map { Unreadable(problem: $0, connection: report.connection) }
            if unreadable[id] != problem { unreadable[id] = problem }
            if let reading = report.reading {
                let kind = MobileDeviceParser.kind(productType: report.productType)
                record(
                    KnownDevice(
                        id: id, kind: kind, name: report.name ?? "", model: report.productType,
                        systemVersion: report.systemVersion, connection: report.connection, reading: reading))
            }
            guard let reported = report.watches else {
                // Not asked this time: the watches known with this iPhone stay as they were, connected with it.
                if report.problem == nil {
                    let now = connected.union(watchesByPhone[id] ?? [])
                    if now != connected { connected = now }
                }
                break
            }
            var watches: Set<String> = []
            for watch in reported {
                let watchID = DeviceIdentity.id(kind: "watch", raw: watch.identifier)
                record(
                    KnownDevice(
                        id: watchID, kind: .watch, name: watch.name ?? "", model: watch.productType,
                        systemVersion: watch.systemVersion, connection: .pairedPhone, reading: watch.reading))
                watches.insert(watchID)
            }
            if report.problem == nil {
                let now = connected.subtracting(watchesByPhone[id] ?? []).union(watches)
                watchesByPhone[id] = watches
                if now != connected { connected = now }
            }
        case .gone(let identifier):
            guard let id = mobileIDs.removeValue(forKey: identifier) else { return }
            markRead(Set([id]).union(watchesByPhone[id] ?? []))
            connected.remove(id)
            unreadable[id] = nil
            connected.subtract(watchesByPhone.removeValue(forKey: id) ?? [])
            save(now: true)
        }
    }

    /// Devices going away carry the time they were last read, which readings that changed nothing did not store.
    private func markRead(_ ids: Set<String>) {
        for id in ids {
            guard let date = lastRead[id], var device = archive[id], device.latest.date < date else { continue }
            device.latest.date = date
            archive.record(device)
        }
    }

    private func record(_ device: KnownDevice) {
        let before = archive[device.id]
        lastRead[device.id] = device.latest.date
        if live[device.id] != device.latest { live[device.id] = device.latest }
        if let before, Self.onlyLiveChanged(from: before, to: device) { return }
        archive.record(device)
        let isNew = before == nil
        let historyGrew = (archive[device.id]?.history.count ?? 0) != (before?.history.count ?? 0)
        save(now: isNew || historyGrew)
    }

    /// The same lasting figures, name and connection as stored, and today's history point already there: only the clock
    /// and the live figures moved.
    private static func onlyLiveChanged(from before: KnownDevice, to device: KnownDevice) -> Bool {
        let today = before.history.last.map { Calendar.current.isDate($0.date, inSameDayAs: device.latest.date) }
        return lasting(BatteryArchive.merged(device.latest, over: before.latest)) == lasting(before.latest)
            && (device.name.isEmpty || device.name == before.name) && device.connection == before.connection
            && device.kind == before.kind && (device.model ?? before.model) == before.model
            && (device.systemVersion ?? before.systemVersion) == before.systemVersion
            && (device.vendorID ?? before.vendorID) == before.vendorID
            && (device.productID ?? before.productID) == before.productID && today ?? true
    }

    /// A reading without what changes from one read to the next.
    private static func lasting(_ reading: BatteryReading) -> BatteryReading {
        var lasting = reading
        lasting.date = .distantPast
        lasting.systemPower = nil
        lasting.batteryPower = nil
        lasting.adapterPower = nil
        lasting.powerToAccessories = nil
        lasting.temperature = nil
        lasting.voltage = nil
        lasting.current = nil
        lasting.cellVoltages = nil
        return lasting
    }

    // MARK: Saving

    private func save(now: Bool) {
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn { return }
        #endif
        guard hasLoaded, canSave else { return }
        let due = lastSave.map { Date().timeIntervalSince($0) >= Self.saveInterval } ?? true
        guard now || due else { return }
        lastSave = Date()
        BatteryHealthStore.save(archive)
    }

    private static let macOSVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }()
}

/// The archive's file, in Application Support under the bundle's name, so that a test copy keeps one of its own. It is a
/// few kilobytes, written at once: the window's process may end right after the page closes.
enum BatteryHealthStore {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "battery-health")

    nonisolated static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tweakly", isDirectory: true)
            .appendingPathComponent("Battery Health.json", isDirectory: false)
    }

    /// An empty archive when there is none yet. A damaged one is moved aside under a name of its own; one that cannot be
    /// read, or that a later version wrote, is left alone and never overwritten.
    static func load() -> (archive: BatteryArchive, canSave: Bool) {
        guard let file else { return (BatteryArchive(), false) }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (BatteryArchive(), true)
        } catch {
            log.error("The battery archive could not be read: \(error.localizedDescription, privacy: .public)")
            return (BatteryArchive(), false)
        }
        if let archive = BatteryArchive.decoded(data) { return (archive, true) }
        if let version = BatteryArchive.version(of: data), version > BatteryArchive.currentVersion {
            log.notice("The battery archive is from a later version and is left as it is")
            return (BatteryArchive(), false)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            log.error("The battery archive was damaged and was set aside")
            return (BatteryArchive(), true)
        } catch {
            return (BatteryArchive(), false)
        }
    }

    static func save(_ archive: BatteryArchive) {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.encoded().write(to: file, options: .atomic)
        } catch {
            log.error("The battery archive could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
