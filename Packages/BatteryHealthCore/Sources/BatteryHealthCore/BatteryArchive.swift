import Foundation

/// One point of a battery's history: enough to draw how its health went, kept at most once a day.
public struct HistoryPoint: Codable, Equatable, Sendable {
    public var date: Date
    public var fullChargeCapacity: Int?
    public var designCapacity: Int?
    public var cycleCount: Int?
    public var systemMaximumCapacity: Int?

    public init(
        date: Date, fullChargeCapacity: Int? = nil, designCapacity: Int? = nil, cycleCount: Int? = nil,
        systemMaximumCapacity: Int? = nil
    ) {
        self.date = date
        self.fullChargeCapacity = fullChargeCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
        self.systemMaximumCapacity = systemMaximumCapacity
    }

    init?(_ reading: BatteryReading) {
        guard reading.fullChargeCapacity != nil || reading.cycleCount != nil else { return nil }
        self.init(
            date: reading.date, fullChargeCapacity: reading.fullChargeCapacity, designCapacity: reading.designCapacity,
            cycleCount: reading.cycleCount, systemMaximumCapacity: reading.systemMaximumCapacity)
    }

    public var health: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0, full > 0 else { return nil }
        return Double(full) / Double(design)
    }
}

/// A device whose battery was read at least once, kept so that it can be shown after it goes away.
public struct KnownDevice: Codable, Equatable, Identifiable, Sendable {
    /// Stable across connections and never shown: "mac", or a digest of the device's own identifier.
    public var id: String
    public var kind: DeviceKind
    /// The name its owner gave it, or the product's.
    public var name: String
    /// Such as "iPhone16,1" or "Mac14,2": what its picture and model name come from.
    public var model: String?
    /// Apple's numbers for Bluetooth accessories, for their picture.
    public var vendorID: Int?
    public var productID: Int?
    /// "27.2.1"
    public var systemVersion: String?
    public var connection: Connection
    public var firstSeen: Date
    public var latest: BatteryReading
    public var history: [HistoryPoint]

    public init(
        id: String, kind: DeviceKind, name: String, model: String? = nil, vendorID: Int? = nil, productID: Int? = nil,
        systemVersion: String? = nil, connection: Connection, reading: BatteryReading
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.model = model
        self.vendorID = vendorID
        self.productID = productID
        self.systemVersion = systemVersion
        self.connection = connection
        firstSeen = reading.date
        latest = reading
        history = HistoryPoint(reading).map { [$0] } ?? []
    }
}

/// Every battery seen on this Mac, as kept in Application Support. Plain values, so the page can save it whole.
public struct BatteryArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// A year of daily points is kept as it is; older ones thin to one a week, which is plenty for a line over years.
    static let dailyWindow: TimeInterval = 400 * 86_400

    public var version = currentVersion
    public var devices: [KnownDevice] = []

    public init(devices: [KnownDevice] = []) {
        self.devices = devices
    }

    public subscript(id: String) -> KnownDevice? {
        devices.first { $0.id == id }
    }

    /// Takes a new reading of a device, keeping what the device did not report this time from before, so that a
    /// short read (a locked iPhone gives its charge but no registry) does not wipe its health.
    public mutating func record(_ device: KnownDevice, calendar: Calendar = .current) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else {
            devices.append(device)
            return
        }
        var known = devices[index]
        known.kind = device.kind
        if !device.name.isEmpty { known.name = device.name }
        known.model = device.model ?? known.model
        known.vendorID = device.vendorID ?? known.vendorID
        known.productID = device.productID ?? known.productID
        known.systemVersion = device.systemVersion ?? known.systemVersion
        known.connection = device.connection
        known.latest = Self.merged(device.latest, over: known.latest)
        if let point = HistoryPoint(device.latest) {
            Self.add(point, to: &known.history, calendar: calendar)
        }
        devices[index] = known
    }

    public mutating func forget(_ id: String) {
        devices.removeAll { $0.id == id }
    }

    /// The new reading wins, except for figures it did not have, which a battery keeps from one day to the next.
    public static func merged(_ new: BatteryReading, over old: BatteryReading) -> BatteryReading {
        var result = new
        result.designCapacity = new.designCapacity ?? old.designCapacity
        if new.fullChargeCapacity == nil {
            result.fullChargeCapacity = old.fullChargeCapacity
            result.nominalChargeCapacity = old.nominalChargeCapacity
        }
        result.cycleCount = new.cycleCount ?? old.cycleCount
        result.designCycleCount = new.designCycleCount ?? old.designCycleCount
        result.systemMaximumCapacity = new.systemMaximumCapacity ?? old.systemMaximumCapacity
        result.condition = new.condition ?? old.condition
        result.lifetime = new.lifetime ?? old.lifetime
        result.manufactureDate = new.manufactureDate ?? old.manufactureDate
        result.firstUseDate = new.firstUseDate ?? old.firstUseDate
        result.gauge = new.gauge ?? old.gauge
        return result
    }

    /// One point a day, the day's latest, then older points thinned to one a week.
    static func add(_ point: HistoryPoint, to history: inout [HistoryPoint], calendar: Calendar) {
        if let last = history.last, calendar.isDate(last.date, inSameDayAs: point.date) {
            var merged = point
            merged.fullChargeCapacity = point.fullChargeCapacity ?? last.fullChargeCapacity
            merged.designCapacity = point.designCapacity ?? last.designCapacity
            merged.cycleCount = point.cycleCount ?? last.cycleCount
            merged.systemMaximumCapacity = point.systemMaximumCapacity ?? last.systemMaximumCapacity
            history[history.count - 1] = merged
        } else if let last = history.last, point.date < last.date {
            // A clock set back: keep the order rather than drawing a line that goes back in time.
            return
        } else {
            history.append(point)
        }
        thin(&history, now: point.date, calendar: calendar)
    }

    static func thin(_ history: inout [HistoryPoint], now: Date, calendar: Calendar) {
        let cutoff = now.addingTimeInterval(-dailyWindow)
        guard let first = history.first, first.date < cutoff else { return }
        var kept: [HistoryPoint] = []
        var lastWeek: DateComponents?
        for point in history {
            guard point.date < cutoff else {
                kept.append(point)
                continue
            }
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: point.date)
            if week == lastWeek, !kept.isEmpty {
                kept[kept.count - 1] = point
            } else {
                kept.append(point)
            }
            lastWeek = week
        }
        history = kept
    }
}

extension BatteryArchive {
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The version an archive says it is, read even when the rest is not, so that a later version's file is not taken
    /// for a damaged one.
    public static func version(of data: Data) -> Int? {
        struct Header: Decodable { var version: Int }
        return try? JSONDecoder().decode(Header.self, from: data).version
    }

    /// An archive from a later version, or a damaged one, reads as nil: the caller keeps the file and starts empty
    /// rather than overwriting what a newer copy wrote.
    public static func decoded(_ data: Data) -> BatteryArchive? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let archive = try? decoder.decode(BatteryArchive.self, from: data),
            archive.version <= currentVersion
        else { return nil }
        return archive
    }
}
