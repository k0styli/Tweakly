/// One point of a curve: at this temperature, this share of the range between a fan's lowest and highest speed.
public struct FanCurvePoint: Codable, Equatable, Hashable, Sendable {
    public var temperature: Double
    public var percent: Double

    public init(temperature: Double, percent: Double) {
        self.temperature = temperature
        self.percent = percent
    }
}

/// How fast a fan should run at each temperature. It is written in percent rather than rpm, because two fans of one Mac
/// can have different limits: on an M1 Pro one reaches 4296 rpm and the other 4744.
///
/// Below the first point the system keeps the fan, which on many Macs means standing still. Above the last it stays at the
/// last point's speed.
public struct FanCurve: Codable, Equatable, Hashable, Sendable {
    public static let temperatures: ClosedRange<Double> = 30...100
    public static let percents: ClosedRange<Double> = 0...100
    public static let fewestPoints = 2
    public static let mostPoints = 8
    /// Points closer than this would make a jump that no fan can follow, and could not be told apart under a finger.
    public static let smallestGap = 1.0

    public private(set) var points: [FanCurvePoint]

    public init(points: [FanCurvePoint]) {
        self.points = Self.tidied(points)
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }

    /// What comes from preferences, which anyone can edit, is kept within what makes sense like anything else.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try values.decode([FanCurvePoint].self, forKey: .points))
    }

    /// Too few points means no curve.
    public var isUsable: Bool { points.count >= Self.fewestPoints }

    /// Where the curve takes over from the system.
    public var start: Double { points.first?.temperature ?? Self.temperatures.upperBound }

    /// The share of the range at a temperature, or nil below the first point, where the system keeps the fan.
    public func percent(at temperature: Double) -> Double? {
        guard let first = points.first, let last = points.last, temperature.isFinite, temperature >= first.temperature
        else { return nil }
        guard temperature < last.temperature else { return last.percent }
        guard let upper = points.firstIndex(where: { $0.temperature > temperature }), upper > 0 else {
            return last.percent
        }
        let (a, b) = (points[upper - 1], points[upper])
        return a.percent + (b.percent - a.percent) * (temperature - a.temperature) / (b.temperature - a.temperature)
    }

    /// Moves a point as far as its neighbours let it, so that a curve never goes back in temperature or down in speed:
    /// a fan that slows down as things get hotter is never what anyone means.
    public mutating func move(pointAt index: Int, to point: FanCurvePoint) {
        guard points.indices.contains(index) else { return }
        let lowestTemperature =
            index > 0 ? points[index - 1].temperature + Self.smallestGap : Self.temperatures.lowerBound
        let highestTemperature =
            index < points.count - 1 ? points[index + 1].temperature - Self.smallestGap : Self.temperatures.upperBound
        let lowestPercent = index > 0 ? points[index - 1].percent : Self.percents.lowerBound
        let highestPercent = index < points.count - 1 ? points[index + 1].percent : Self.percents.upperBound
        points[index] = FanCurvePoint(
            temperature: Self.clamp(point.temperature, lowestTemperature, highestTemperature),
            percent: Self.clamp(point.percent, lowestPercent, highestPercent))
    }

    /// Adds a point where it falls, on the line between its neighbours' speeds at most. Nil when there is no room for one.
    @discardableResult
    public mutating func add(_ point: FanCurvePoint) -> Int? {
        guard points.count < Self.mostPoints, point.temperature.isFinite, point.percent.isFinite else { return nil }
        let temperature = Self.clamp(point.temperature, Self.temperatures.lowerBound, Self.temperatures.upperBound)
        guard !points.contains(where: { abs($0.temperature - temperature) < Self.smallestGap }) else { return nil }
        let index = points.firstIndex { $0.temperature > temperature } ?? points.count
        points.insert(FanCurvePoint(temperature: temperature, percent: point.percent), at: index)
        move(pointAt: index, to: points[index])
        return index
    }

    /// The curve always keeps enough points to be one.
    public mutating func remove(pointAt index: Int) {
        guard points.indices.contains(index), points.count > Self.fewestPoints else { return }
        points.remove(at: index)
    }

    /// Whatever was given, in order, within the limits, never falling, with no points on top of each other.
    private static func tidied(_ given: [FanCurvePoint]) -> [FanCurvePoint] {
        var result: [FanCurvePoint] = []
        let usable = given.filter { $0.temperature.isFinite && $0.percent.isFinite }
        for point in usable.sorted(by: { $0.temperature < $1.temperature }).prefix(mostPoints) {
            let temperature = clamp(point.temperature, temperatures.lowerBound, temperatures.upperBound)
            let percent = clamp(point.percent, percents.lowerBound, percents.upperBound)
            if let last = result.last, temperature - last.temperature < smallestGap { continue }
            result.append(FanCurvePoint(temperature: temperature, percent: max(percent, result.last?.percent ?? 0)))
        }
        return result
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), max(low, high))
    }
}

/// The ready curves. Their numbers are a starting point for someone's own, not measurements.
public enum FanPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Leaves the fans to the system for as long as it is safe, and rises late.
    case quiet
    case balanced
    /// Starts early, for long loads where staying cool matters more than noise.
    case performance

    public var id: String { rawValue }

    public var curve: FanCurve {
        switch self {
        case .quiet:
            FanCurve(points: [
                .init(temperature: 70, percent: 0), .init(temperature: 85, percent: 30),
                .init(temperature: 95, percent: 70),
            ])
        case .balanced:
            FanCurve(points: [
                .init(temperature: 60, percent: 0), .init(temperature: 75, percent: 35),
                .init(temperature: 90, percent: 100),
            ])
        case .performance:
            FanCurve(points: [
                .init(temperature: 45, percent: 15), .init(temperature: 60, percent: 50),
                .init(temperature: 80, percent: 100),
            ])
        }
    }
}
