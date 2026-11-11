#if TWEAKLY_AUTOMATION
    import Foundation

    /// Test copies only, for pictures that will be published: a made-up Mac in place of this one. Each panel's headline
    /// figure is fixed, its graph is drawn ahead of time and ends on that figure, and its list names ordinary apps every
    /// Mac has. So a label in the menu bar, its panel, Home and the task manager agree in every picture, whatever the
    /// Mac taking them is doing, and nothing of its own shows: no processes, addresses or volume names. Only figures
    /// that say nothing about anyone, such as Wi-Fi quality or the drive's model, stay as measured. On with the
    /// `demoData` preference, which only automation builds read.
    public enum DemoData {
        public static let isOn = UserDefaults.standard.bool(forKey: "demoData")

        // MARK: The made-up Mac's figures

        public static let cpu = 0.18
        public static let gpu = 0.12
        public static let memory = 0.62
        public static let disk = 0.58
        /// Bytes a second.
        public static let down = 48_000.0
        public static let up = 12_400.0
        public static let battery = 84
        /// The 13-inch MacBook Pro with M2 has one fan.
        public static let fanSpeeds = [2_160.0]

        /// What the menu bar shows for each metric with these figures, for drawing the labels a picture hangs from.
        public static func menuValue(of kind: MetricKind) -> MenuValue {
            switch kind {
            case .cpu: MetricUpdate.cpu(disguised(CPUSnapshot())).menuValue
            case .gpu: .percent(Int((gpu * 100).rounded()))
            case .memory: .percent(Int((memory * 100).rounded()))
            case .disk: .percent(Int((disk * 100).rounded()))
            case .network: .rates(up: CompactRate(bytesPerSecond: up), down: CompactRate(bytesPerSecond: down))
            case .battery: .battery(percent: battery, isCharging: false, isPluggedIn: false)
            case .fans: MetricUpdate.fans(fans()).menuValue
            }
        }

        // MARK: Graphs

        /// A calm graph over the last two minutes that ends exactly on `value`: two slow waves and a few short peaks,
        /// different for each `seed`. A share stays below one; a rate has no `ceiling`.
        static func graph(ending value: Double, spread: Double, seed: Double, ceiling: Double = 1) -> [Float] {
            (0..<historyCapacity).map { index in
                let x = Double(index)
                let remaining = Double(historyCapacity - 1 - index)
                let wave =
                    0.55 * sin(x / 7.3 + seed) + 0.3 * sin(x / 2.9 + seed * 1.7)
                    + 1.8 * max(0, sin(x / 11 + seed * 0.4) - 0.7)
                // Settles onto the current figure over the last few seconds.
                let settle = min(remaining / 6, 1)
                return Float(max(0, min(ceiling, value + spread * wave * settle)))
            }
        }

        // MARK: Lists

        private struct App {
            let name: String
            let path: String?
        }

        private static let safari = App(name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")
        private static let windowServer = App(
            name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        private static let music = App(name: "Music", path: "/System/Applications/Music.app/Contents/MacOS/Music")
        private static let photos = App(name: "Photos", path: "/System/Applications/Photos.app/Contents/MacOS/Photos")
        private static let mail = App(name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail")
        private static let notes = App(name: "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes")
        private static let maps = App(name: "Maps", path: "/System/Applications/Maps.app/Contents/MacOS/Maps")
        private static let messages = App(
            name: "Messages", path: "/System/Applications/Messages.app/Contents/MacOS/Messages")
        private static let kernel = App(name: "kernel_task", path: nil)

        /// The app's name as Finder shows it, in the language the copy runs in.
        private static func shown(_ app: App) -> String {
            guard let path = app.path, let range = path.range(of: ".app/") else { return app.name }
            let name = FileManager.default.displayName(atPath: String(path[..<range.lowerBound]) + ".app")
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }

        private static func entry(
            _ app: App, _ pid: Int32, cpu: Double = 0, memory: Double = 0, gpu: Double = 0, down: Double = 0,
            up: Double = 0, read: Double = 0, write: Double = 0
        ) -> ProcessEntry {
            ProcessEntry(
                pid: pid, name: shown(app), path: app.path, cpu: cpu, memory: UInt64(memory * 1_048_576), gpu: gpu,
                downRate: down, upRate: up, diskRead: read, diskWrite: write)
        }

        // MARK: Each metric

        private static func disguised(_ snapshot: CPUSnapshot) -> CPUSnapshot {
            var value = snapshot
            value.usage = cpu
            value.user = cpu * 0.62
            value.system = cpu * 0.38
            let shape = [1.5, 1.2, 0.9, 0.7, 1.3, 0.8, 0.6, 1.0]
            value.cores = value.cores.indices.map { min(1, cpu * shape[$0 % shape.count]) }
            value.temperature = value.temperature.map { _ in 46 }
            value.averages = CPUAverages(oneMinute: 0.21, fiveMinutes: 0.19, fifteenMinutes: 0.17)
            value.history = graph(ending: cpu, spread: 0.07, seed: 0.4)
            value.topProcesses = [
                entry(safari, 4_101, cpu: 0.142, memory: 412), entry(windowServer, 4_102, cpu: 0.112, memory: 214),
                entry(music, 4_103, cpu: 0.064, memory: 248), entry(photos, 4_104, cpu: 0.047, memory: 538),
                entry(mail, 4_105, cpu: 0.021, memory: 296),
            ]
            return value
        }

        public static func disguise(_ update: MetricUpdate) -> MetricUpdate {
            switch update {
            case .cpu(let value):
                return .cpu(disguised(value))
            case .gpu(var value):
                value.usage = gpu
                value.renderer = gpu * 0.84
                value.tiler = gpu * 0.31
                value.temperature = value.temperature.map { _ in 41 }
                value.history = graph(ending: gpu, spread: 0.05, seed: 2.1)
                value.topProcesses = [
                    entry(windowServer, 4_102, gpu: 0.064), entry(safari, 4_101, gpu: 0.031),
                    entry(photos, 4_104, gpu: 0.012), entry(music, 4_103, gpu: 0.004), entry(maps, 4_106, gpu: 0.002),
                ]
                return .gpu(value)
            case .memory(var value):
                let whole = Double(value.usable > 0 ? value.usable : value.total)
                func part(_ share: Double) -> UInt64 { UInt64(whole * share) }
                value.app = part(0.40)
                value.wired = part(0.14)
                value.compressed = part(memory - 0.54)
                value.used = value.app + value.wired + value.compressed
                value.cached = part(0.22)
                value.free = UInt64(max(0, Int64(whole) - Int64(value.used) - Int64(value.cached)))
                value.swapUsed = 0
                value.pressure = .normal
                value.history = graph(ending: memory, spread: 0.015, seed: 1.2)
                value.topProcesses = [
                    entry(safari, 4_101, memory: 1_210), entry(photos, 4_104, memory: 742),
                    entry(mail, 4_105, memory: 486), entry(music, 4_103, memory: 412),
                    entry(messages, 4_107, memory: 268),
                ]
                return .memory(value)
            case .disk(var value):
                if let main = value.main {
                    var volume = VolumeInfo(
                        name: main.name, path: main.path, total: main.total,
                        available: UInt64(Double(main.total) * (1 - disk)))
                    volume.purgeable = UInt64(Double(main.total) * 0.03)
                    value.main = volume
                }
                // Other volumes carry names their owner chose.
                value.others = []
                value.readRate = 2_400_000
                value.writeRate = 610_000
                value.readHistory = graph(ending: 2_400_000, spread: 1_300_000, seed: 3.3, ceiling: .infinity)
                value.writeHistory = graph(ending: 610_000, spread: 380_000, seed: 4.6, ceiling: .infinity)
                if value.drive?.temperature != nil { value.drive?.temperature = 36 }
                value.topProcesses = [
                    entry(photos, 4_104, read: 1_420_000, write: 310_000),
                    entry(kernel, 0, read: 520_000, write: 180_000), entry(safari, 4_101, read: 260_000, write: 64_000),
                    entry(mail, 4_105, read: 120_000, write: 41_000), entry(music, 4_103, read: 80_000, write: 15_000),
                ]
                return .disk(value)
            case .network(var value):
                value.downRate = down
                value.upRate = up
                value.downHistory = graph(ending: down, spread: down * 0.55, seed: 5.2, ceiling: .infinity)
                value.upHistory = graph(ending: up, spread: up * 0.5, seed: 6.4, ceiling: .infinity)
                if let interface = value.interface {
                    // A private address, a made-up hardware address, and a public one from the range kept for examples.
                    value.interface = NetworkInterfaceInfo(
                        bsdName: interface.bsdName, displayName: interface.displayName,
                        address: interface.address == nil ? nil : "192.168.1.24",
                        hardwareAddress: interface.hardwareAddress == nil ? nil : "8c:85:90:4b:2e:17")
                }
                // From the first update on, so the row can be pressed open before the real one would arrive.
                value.publicAddress = PublicAddress(address: "203.0.113.42", countryCode: nil)
                value.topProcesses = [
                    entry(safari, 4_101, down: 31_000, up: 6_200), entry(music, 4_103, down: 11_200, up: 900),
                    entry(mail, 4_105, down: 3_100, up: 2_600), entry(messages, 4_107, down: 1_800, up: 1_900),
                    entry(maps, 4_106, down: 900, up: 800),
                ]
                return .network(value)
            case .battery(var value):
                guard value.isPresent else { return update }
                value.percent = battery
                value.state = .discharging
                value.minutesRemaining = 312
                value.powerDraw = 5.8
                value.adapterPower = nil
                if value.health != nil {
                    value.health?.maximumCapacityPercent = 92
                    value.health?.temperature = 31
                    value.health?.adapterWatts = nil
                    value.health?.current = -446
                }
                value.topProcesses = [
                    entry(safari, 4_101, cpu: 0.142), entry(music, 4_103, cpu: 0.064), entry(photos, 4_104, cpu: 0.047),
                    entry(mail, 4_105, cpu: 0.021), entry(notes, 4_108, cpu: 0.008),
                ]
                return .battery(value)
            case .fans:
                return .fans(fans())
            }
        }

        /// The fan turning slowly, as on a MacBook Pro doing light work.
        public static func fans() -> FanSnapshot {
            var snapshot = FanSnapshot(
                fans: fanSpeeds.enumerated().map { index, speed in
                    FanReading(
                        index: index, actual: speed, target: speed, minimum: 1_200, maximum: 5_800, isManual: false)
                },
                temperatures: FanTemperatures(hottestCPU: 51, typicalCPU: 47, hottestGPU: 45, battery: 31))
            snapshot.history = graph(ending: snapshot.averageShare, spread: 0.06, seed: 7.1)
            return snapshot
        }
    }

    /// The made-up Mac's fan, for a Mac that has none.
    final class DemoFanSampler: MetricSampler {
        func reset() {}

        func sample(level: SamplingLevel) -> MetricUpdate? { .fans(DemoData.fans()) }
    }
#endif
