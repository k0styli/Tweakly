import Observation
import SystemMetrics

/// The latest values for the Home page. Only updated while that page is on screen.
@Observable final class StatsLiveData {
    var cpu: CPUSnapshot?
    /// Apart from the rest of the processor's values, because it changes every two seconds and those every second.
    var topProcesses: [ProcessEntry] = []
    var gpu: GPUSnapshot?
    var memory: MemorySnapshot?
    var disk: DiskSnapshot?
    var network: NetworkSnapshot?
    var battery: BatterySnapshot?

    func apply(_ update: MetricUpdate) {
        switch update {
        case .cpu(var value):
            if topProcesses != value.topProcesses { topProcesses = value.topProcesses }
            value.topProcesses = []
            cpu = value
        case .gpu(let value): gpu = value
        case .memory(let value): memory = value
        case .disk(let value): disk = value
        case .network(let value): network = value
        case .battery(let value): battery = value
        case .fans: break
        }
    }
}
