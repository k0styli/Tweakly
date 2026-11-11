import Foundation

/// The fans' speeds and the temperatures they can follow. Only reads: changing a fan takes root, in another process.
final class FanSampler: MetricSampler {
    /// How often to try again for a connection the system refused. A person's choice depends on it, and this object can
    /// live for as long as the Mac runs.
    private static let retryInterval: TimeInterval = 30

    private var reader = FanReader()
    private var thermal = FanThermalReader()
    private var lastAttempt = uptimeSeconds()
    private var history = RingBuffer(capacity: historyCapacity)

    func reset() {}

    func sample(level: SamplingLevel) -> MetricUpdate? {
        if reader == nil || thermal == nil, uptimeSeconds() - lastAttempt >= Self.retryInterval {
            lastAttempt = uptimeSeconds()
            reader = reader ?? FanReader()
            thermal = thermal ?? FanThermalReader()
        }
        guard let reader else { return .fans(FanSnapshot()) }
        var snapshot = FanSnapshot(fans: reader.read(isComplete: level >= .overview))
        snapshot.temperatures = thermal?.read(now: uptimeSeconds()) ?? FanTemperatures()
        guard level >= .overview else { return .fans(snapshot) }
        history.append(Float(snapshot.averageShare))
        snapshot.history = history.values
        return .fans(snapshot)
    }
}
