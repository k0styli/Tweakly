import AppKit
import SystemMetrics

/// The content of a popover: one metric's view or the simple view, as rings or a list.
final class MetricDetailViewController: NSViewController {
    private let popover: StatsPopover
    private let fanActions: FanQuickActions?
    /// Room left between a popover at its tallest and the edge of the screen, for its arrow and shadow.
    private static let screenMargin: CGFloat = 40

    private var content: (any MetricDetailContent)?
    private var root: DetailScrollRoot?
    private var lastVisibleCount = 0

    /// Single figures have no use for the room that charts and tables of details need.
    private var width: CGFloat {
        if case .simple(_, .rings) = popover { return DetailLayout.simpleWidth }
        return DetailLayout.width
    }

    init(popover: StatsPopover, fanActions: FanQuickActions? = nil) {
        self.popover = popover
        self.fanActions = fanActions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let detail: any MetricDetailContent =
            switch popover {
            case .details(.cpu): CPUDetailView(info: .current)
            case .details(.gpu): GPUDetailView(info: .current)
            case .details(.memory): MemoryDetailView()
            case .details(.disk): DiskDetailView()
            case .details(.network): NetworkDetailView()
            case .details(.battery): BatteryDetailView()
            case .details(.fans): FanDetailView(actions: fanActions)
            case .simple(let kinds, .rings): SimpleRingsView(kinds: kinds)
            case .simple(let kinds, .list): SimpleListView(kinds: kinds, info: .current)
            }
        content = detail

        let root = DetailScrollRoot(
            column: NSStackView.detailColumn(spacing: DetailLayout.sectionSpacing, [detail]), width: width)
        self.root = root
        view = root
        updatePreferredSize()
    }

    func update(_ update: MetricUpdate) {
        guard isViewLoaded else { return }
        content?.update(update)
        // Solving the layout every second just to find it unchanged would be the costliest thing here.
        let count = root.map { visibleRowCount(in: $0.column) } ?? 0
        if count != lastVisibleCount {
            lastVisibleCount = count
            updatePreferredSize()
        }
    }

    /// The size the content needs right now.
    var fittingContentSize: NSSize {
        #if TWEAKLY_AUTOMATION
            let limit = Automation.shared.popoverHeightLimit ?? .infinity
        #else
            let limit = CGFloat.infinity
        #endif
        loadViewIfNeeded()
        return root?.fittingContentSize(screenMargin: Self.screenMargin, limit: limit) ?? .zero
    }

    private func updatePreferredSize() {
        preferredContentSize = fittingContentSize
    }

    /// Rows that come and go all live in stack views, so nothing else has to be visited to notice one.
    private func visibleRowCount(in stack: NSStackView) -> Int {
        stack.arrangedSubviews.reduce(1) { count, view in
            guard !view.isHidden else { return count }
            return count + ((view as? NSStackView).map(visibleRowCount) ?? 1)
        }
    }
}

/// One metric's details.
protocol MetricDetailContent: NSView {
    func update(_ update: MetricUpdate)
}

final class CPUDetailView: NSStackView, MetricDetailContent {
    private let header = DetailHeaderView(title: MetricKind.cpu.title)
    private let graph = SparklineView(maximum: 1)
    private let split = SegmentBarView(height: 10, gap: 1.5)
    private let userCell = StatCell(caption: String(localized: "User"), key: .controlAccentColor)
    private let systemCell = StatCell(caption: String(localized: "System"), key: .systemRed)
    private let idleCell = StatCell(caption: String(localized: "Idle"), key: .tertiaryLabelColor)
    private let overallRow = LegendRow(
        title: String(localized: "Overall"), key: .systemGray, widestSecond: Format.frequency(megahertz: 8888))
    private let oneMinuteRow = DetailRow(String(localized: "Last minute"))
    private let fiveMinutesRow = DetailRow(String(localized: "Last 5 minutes"))
    private let fifteenMinutesRow = DetailRow(String(localized: "Last 15 minutes"))
    private let processes = ProcessListView()
    private let uptimeRow = DetailRow(String(localized: "Uptime"))
    private var clusters: [(cluster: SystemInfo.CoreCluster, bars: CoreBarsView, legend: LegendRow)] = []
    private let subtitle: String

    init(info: SystemInfo) {
        subtitle = info.chipName
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        for row in [oneMinuteRow, fiveMinutesRow, fifteenMinutesRow] { row.set("—") }

        clusters = info.clusters.sorted { $0.kind.displayOrder < $1.kind.displayOrder }.map { cluster in
            let legend = LegendRow(
                title: cluster.kind.title, key: cluster.kind.color, widestSecond: Format.frequency(megahertz: 8888))
            let bars = CoreBarsView(
                coreCount: cluster.cores.count, color: cluster.kind.color, title: cluster.kind.title)
            return (cluster, bars, legend)
        }
        let barRow = barGroupRow(clusters.map(\.bars))

        addFullWidth(header)
        addFullWidth(graph)
        addFullWidth(NSStackView.detailColumn(spacing: 8, [split, statRow([userCell, systemCell, idleCell])]))
        if !clusters.isEmpty {
            let legend = NSStackView.detailColumn(clusters.map(\.legend) + [overallRow])
            addFullWidth(NSStackView.detailColumn(spacing: 8, [barRow, legend]))
        }
        addFullWidth(
            NSStackView.detailColumn([
                detailSectionTitle(String(localized: "Average load")), oneMinuteRow, fiveMinutesRow, fifteenMinutesRow,
            ])
        )
        addFullWidth(uptimeRow)
        addFullWidth(
            NSStackView.detailColumn(spacing: 4, [detailSectionTitle(String(localized: "Top processes")), processes]))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .cpu(let cpu) = update else { return }
        header.update(subtitle: subtitle, value: Format.percent(cpu.usage))
        graph.update([.init(values: cpu.history, color: .controlAccentColor)])
        split.update([
            .init(fraction: cpu.user, color: .controlAccentColor),
            .init(fraction: cpu.system, color: .systemRed),
        ])
        userCell.set(Format.percent(cpu.user))
        systemCell.set(Format.percent(cpu.system))
        idleCell.set(Format.percent(max(1 - cpu.usage, 0)))

        header.setSide(cpu.temperature.map(Format.temperature(celsius:)), color: chipTemperatureColor(cpu.temperature))
        overallRow.update(first: Format.percent(cpu.usage), second: Self.frequency(cpu.frequencies?.overall))
        for (cluster, bars, legend) in clusters where !cpu.cores.isEmpty {
            let loads = cluster.cores.map { $0 < cpu.cores.count ? cpu.cores[$0] : 0 }
            bars.update(loads)
            let frequency =
                switch cluster.kind {
                case .performance: cpu.frequencies?.performance
                case .efficiency: cpu.frequencies?.efficiency
                case .other: cpu.frequencies?.overall
                }
            let load = Format.percent(loads.reduce(0, +) / Double(max(loads.count, 1)))
            legend.update(first: load, second: Self.frequency(frequency))
        }

        oneMinuteRow.set(cpu.averages?.oneMinute.map { Format.percent($0) } ?? "—")
        fiveMinutesRow.set(cpu.averages?.fiveMinutes.map { Format.percent($0) } ?? "—")
        fifteenMinutesRow.set(cpu.averages?.fifteenMinutes.map { Format.percent($0) } ?? "—")

        processes.update(cpu.topProcesses) { Format.processLoad($0.cpu) }
        let uptime = SystemInfo.bootDate.map { -$0.timeIntervalSinceNow } ?? ProcessInfo.processInfo.systemUptime
        uptimeRow.set(Format.uptime(uptime))
    }

    private static func frequency(_ megahertz: Double?) -> String {
        megahertz.map(Format.frequency(megahertz:)) ?? "—"
    }
}

final class GPUDetailView: NSStackView, MetricDetailContent {
    private let header = DetailHeaderView(title: MetricKind.gpu.title)
    private let graph = SparklineView(maximum: 1)
    private let deviceGauge = RingGaugeView(
        caption: String(localized: "gpu.core", defaultValue: "Core"), color: .systemBlue)
    private let rendererGauge = RingGaugeView(
        caption: String(localized: "gpu.renderer", defaultValue: "Render"), color: .systemOrange)
    private let tilerGauge = RingGaugeView(caption: String(localized: "Tiler"), color: .systemPink)
    private let neuralEngineGauge = RingGaugeView(
        caption: String(localized: "gpu.neuralEngine", defaultValue: "ANE"), color: .systemGreen)
    private let frameRateRow = DetailRow(String(localized: "Frame rate"))
    // Its own key: in Japanese and Chinese "Cores" reads as the ring's "Core" above it, so the count says so.
    private let coresRow = DetailRow(String(localized: "gpu.cores", defaultValue: "Cores"))
    private let frequencyRow = DetailRow(String(localized: "Frequency"))
    private let powerRow = DetailRow(String(localized: "Power draw"))
    private lazy var memoryColumn = NSStackView.detailColumn([
        detailSectionTitle(String(localized: "Memory")), inUseRow, allocatedRow,
    ])
    private let inUseRow = DetailRow(String(localized: "In use"))
    private let allocatedRow = DetailRow(String(localized: "Allocated"))
    private let processes = ProcessListView()
    private let subtitle: String

    init(info: SystemInfo) {
        subtitle = info.gpuName ?? info.chipName
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        for row in [frameRateRow, frequencyRow, powerRow] { row.set("—") }
        coresRow.set(info.gpuCoreCount.map(String.init))

        addFullWidth(header)
        addFullWidth(graph)
        addFullWidth(ringGaugeRow([deviceGauge, rendererGauge, tilerGauge, neuralEngineGauge]))
        addFullWidth(NSStackView.detailColumn([frameRateRow, coresRow, frequencyRow, powerRow]))
        addFullWidth(memoryColumn)
        addFullWidth(
            NSStackView.detailColumn(spacing: 4, [detailSectionTitle(String(localized: "Top processes")), processes]))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .gpu(let gpu) = update else { return }
        header.update(subtitle: subtitle, value: gpu.usage.map { Format.percent($0) } ?? "—")
        header.setSide(gpu.temperature.map(Format.temperature(celsius:)), color: chipTemperatureColor(gpu.temperature))
        graph.update([.init(values: gpu.history, color: .controlAccentColor)])

        deviceGauge.update(gpu.usage)
        rendererGauge.update(gpu.renderer)
        tilerGauge.update(gpu.tiler)
        neuralEngineGauge.update(gpu.neuralEngine)

        frameRateRow.set(gpu.framesPerSecond.map(Format.framesPerSecond) ?? "—")
        frequencyRow.set(gpu.frequency.map(Format.frequency(megahertz:)) ?? "—")
        powerRow.set(gpu.power.map(Format.watts) ?? "—")
        memoryColumn.isHidden = gpu.memoryInUse == nil && gpu.memoryAllocated == nil
        inUseRow.set(gpu.memoryInUse.map(Format.memorySize))
        allocatedRow.set(gpu.memoryAllocated.map(Format.memorySize))

        processes.update(gpu.topProcesses) { Format.processLoad($0.gpu) }
    }
}

final class MemoryDetailView: NSStackView, MetricDetailContent {
    /// The longest amount a row can show: memory is counted in binary units, so just under 1 GB is still four digits
    /// of megabytes with a decimal, longer than any amount in gigabytes.
    private static let widestAmount = Format.memorySize(1_073_000_000)
    static let appColor = NSColor.systemBlue
    static let wiredColor = NSColor.systemOrange
    static let compressedColor = NSColor.systemPink

    private let header = DetailHeaderView(title: MetricKind.memory.title)
    private let graph = SparklineView(maximum: 1)
    private let bar = SegmentBarView(height: 10, gap: 1.5)
    private let appRow = LegendRow(
        title: String(localized: "App memory"), key: appColor, widestSecond: widestAmount)
    private let wiredRow = LegendRow(title: String(localized: "Wired"), key: wiredColor, widestSecond: widestAmount)
    private let compressedRow = LegendRow(
        title: String(localized: "Compressed"), key: compressedColor, widestSecond: widestAmount)
    private let freeRow = LegendRow(
        title: String(localized: "memory.free", defaultValue: "Free"), key: .tertiaryLabelColor,
        widestSecond: widestAmount)
    private let swapRow = DetailRow(String(localized: "Swap used"))
    private let pressureRow = DetailRow(String(localized: "Memory pressure"))
    private let processes = ProcessListView()

    init() {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        let legend = NSStackView.detailColumn([appRow, wiredRow, compressedRow, freeRow])
        addFullWidth(header)
        addFullWidth(graph)
        addFullWidth(NSStackView.detailColumn(spacing: 8, [bar, legend]))
        addFullWidth(NSStackView.detailColumn([swapRow, pressureRow]))
        addFullWidth(
            NSStackView.detailColumn(spacing: 4, [detailSectionTitle(String(localized: "Top processes")), processes]))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .memory(let memory) = update else { return }
        header.update(subtitle: Self.capacity(of: memory), value: Format.percent(memory.usedFraction))
        header.setSide(Format.memorySize(memory.used), color: Self.color(for: memory.pressure))
        graph.update([.init(values: memory.history, color: .controlAccentColor)])

        bar.update([
            .init(fraction: memory.share(of: memory.app), color: Self.appColor),
            .init(fraction: memory.share(of: memory.wired), color: Self.wiredColor),
            .init(fraction: memory.share(of: memory.compressed), color: Self.compressedColor),
        ])
        let rows = [
            (appRow, memory.app), (wiredRow, memory.wired), (compressedRow, memory.compressed),
            (freeRow, memory.available),
        ]
        for (row, amount) in rows {
            row.update(first: Format.percent(memory.share(of: amount)), second: Format.memorySize(amount))
        }

        swapRow.set(Format.memorySize(memory.swapUsed))
        let pressure =
            switch memory.pressure {
            case .normal: String(localized: "Normal")
            case .warning: String(localized: "Elevated")
            case .critical: String(localized: "Critical")
            }
        pressureRow.set(pressure)
        processes.update(memory.topProcesses) { Format.memorySize($0.memory) }
    }

    /// Says how much of the installed memory macOS gets, which is why the parts add up to less than that.
    static func capacity(of memory: MemorySnapshot) -> String {
        let total = Format.memorySize(memory.total)
        guard memory.usable > 0, memory.usable < memory.total else { return total }
        return String(localized: "\(total), \(Format.memorySize(memory.usable)) for macOS")
    }

    /// Like a hot chip, memory only draws attention when the system is short of it.
    static func color(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: .secondaryLabelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

final class DiskDetailView: NSStackView, MetricDetailContent {
    private static let readColor = NSColor.controlAccentColor
    private static let writeColor = NSColor.systemOrange
    private static let processColumns = ProcessListView.Columns.rates
    private static let widestAmount = Format.fileSize(888_880_000_000)

    private let header = DetailHeaderView(title: MetricKind.disk.title)
    private let graph = SparklineView(maximum: nil)
    private lazy var scaleLabel = graphScaleLabel(on: graph)
    private let readRow = DetailRow(String(localized: "Read"), key: readColor)
    private let writeRow = DetailRow(String(localized: "Write"), key: writeColor)
    private let bar = SegmentBarView(height: 10)
    private let usedRow = LegendRow(title: String(localized: "Used"), key: .systemBlue, widestSecond: widestAmount)
    private let freeRow = LegendRow(
        title: String(localized: "Free"), key: .tertiaryLabelColor, widestSecond: widestAmount)
    private let purgeableRow = DetailRow(String(localized: "Can be cleared"))
    private lazy var driveColumn = NSStackView.detailColumn([
        detailSectionTitle(String(localized: "Drive")), modelRow, wearRow, writtenRow, lifetimeReadRow, warningRow,
    ])
    private let modelRow = DetailRow(String(localized: "Model"))
    private let wearRow = DetailRow(String(localized: "Wear"))
    private let writtenRow = DetailRow(String(localized: "Total written"))
    private let lifetimeReadRow = DetailRow(String(localized: "Total read"))
    private let warningRow = DetailRow(String(localized: "Condition"))
    private let others = NameValueList()
    private lazy var othersColumn = NSStackView.detailColumn([
        detailSectionTitle(String(localized: "Other volumes")), others,
    ])
    private let processes = ProcessListView(columns: processColumns)

    init() {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        for row in [readRow, writeRow] { row.set("—") }
        addFullWidth(header)
        addFullWidth(NSStackView.detailColumn(spacing: 8, [graph, NSStackView.detailColumn([readRow, writeRow])]))
        addFullWidth(
            NSStackView.detailColumn(
                spacing: 8, [bar, NSStackView.detailColumn([usedRow, freeRow, purgeableRow])])
        )
        addFullWidth(driveColumn)
        // Hidden while empty, so it leaves no gap: a stack view keeps the spacing around an empty column.
        othersColumn.isHidden = true
        addFullWidth(othersColumn)
        addFullWidth(
            NSStackView.detailColumn(
                spacing: 4,
                [
                    detailSectionTitle(
                        String(localized: "Top processes"), columns: Self.processColumns,
                        keys: (Self.readColor, Self.writeColor)),
                    processes,
                ]
            )
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .disk(let disk) = update else { return }
        header.update(subtitle: disk.main?.name ?? "", value: disk.main.map { Format.percent($0.usedFraction) } ?? "—")
        header.setSide(
            disk.drive?.temperature.map(Format.temperature(celsius:)),
            color: Self.color(forTemperature: disk.drive?.temperature)
        )

        graph.update([
            .init(values: disk.readHistory, color: Self.readColor),
            .init(values: disk.writeHistory, color: Self.writeColor),
        ])
        // Disk traffic has no natural top, so the graph needs to say what its height stands for.
        let peak = (disk.readHistory + disk.writeHistory).max() ?? 0
        scaleLabel.setIfChanged(peak > 0 ? Format.rate(Double(peak)) : "")
        readRow.set(disk.readRate.map(Format.rate) ?? "—")
        writeRow.set(disk.writeRate.map(Format.rate) ?? "—")

        if let main = disk.main {
            let used = main.total > main.available ? main.total - main.available : 0
            let color = Self.color(forUsedFraction: main.usedFraction)
            bar.update([.init(fraction: main.usedFraction, color: color)])
            usedRow.setKey(color)
            usedRow.update(first: Format.percent(main.usedFraction), second: Format.fileSize(used))
            freeRow.update(first: Format.percent(1 - main.usedFraction), second: Format.fileSize(main.available))
            // Too little to be worth a line most of the time, though it can reach many gigabytes.
            purgeableRow.set(main.purgeable >= 100_000_000 ? Format.fileSize(main.purgeable) : nil)
        }
        updateDrive(disk.drive)

        othersColumn.isHidden = disk.others.isEmpty
        others.update(
            disk.others.map { volume in
                let free = Format.fileSize(volume.available)
                let total = Format.fileSize(volume.total)
                return (volume.name, String(localized: "\(free) free of \(total)"))
            }
        )
        processes.update(
            disk.topProcesses,
            value: { Format.rate($0.diskRead) },
            second: { Format.rate($0.diskWrite) }
        )
    }

    private func updateDrive(_ drive: DriveHealth?) {
        driveColumn.isHidden = drive == nil
        modelRow.set(drive?.model)
        wearRow.set(drive.map { Format.percent($0.wear) })
        writtenRow.set(drive.map { Format.fileSize($0.bytesWritten) })
        lifetimeReadRow.set(drive.map { Format.fileSize($0.bytesRead) })
        warningRow.set(drive?.hasWarning == true ? String(localized: "Needs attention") : nil)
    }

    /// A drive only draws attention when it is nearly full, the moment when macOS starts to struggle.
    static func color(forUsedFraction used: Double) -> NSColor {
        switch used {
        case 0.95...: .systemRed
        case 0.9...: .systemOrange
        default: .systemBlue
        }
    }

    /// Flash storage slows itself down well above this, so it is worth a look before that happens.
    private static func color(forTemperature temperature: Double?) -> NSColor {
        switch temperature ?? 0 {
        case 80...: .systemRed
        case 70...: .systemOrange
        default: .secondaryLabelColor
        }
    }
}

final class NetworkDetailView: NSStackView, MetricDetailContent {
    private static let downColor = NSColor.controlAccentColor
    private static let upColor = NSColor.systemOrange
    private static let processColumns = ProcessListView.Columns.rates

    private let header = DetailHeaderView(
        title: MetricKind.network.title, widestValue: "↓ " + Format.rate(92_000_000))
    private let graph = SparklineView(maximum: nil)
    private lazy var peakLabel = graphScaleLabel(on: graph)
    private let totalDownRow = DetailRow(String(localized: "Received since startup"), key: downColor)
    private let totalUpRow = DetailRow(String(localized: "Sent since startup"), key: upColor)
    private let latencyStrip = LatencyStripView(capacity: NetworkLatency.capacity)
    private let latencyRow = DetailRow(String(localized: "Latency"))
    private let jitterRow = DetailRow(String(localized: "Jitter"))
    private let lossRow = DetailRow(String(localized: "Packet loss"))
    private lazy var wifiColumn = NSStackView.detailColumn([
        detailSectionTitle(String(localized: "Wi-Fi")), signalRow, linkSpeedRow, channelRow,
    ])
    private let signalRow = DetailRow(String(localized: "Signal"))
    private let linkSpeedRow = DetailRow(String(localized: "Link speed"))
    private let channelRow = DetailRow(String(localized: "Channel"))
    private let localAddressRow = DetailRow(String(localized: "Local IP"))
    private let publicAddressRow = ConcealedRow(String(localized: "Public IP"))
    private let hardwareAddressRow = DetailRow(String(localized: "MAC address"))
    private let processes = ProcessListView(columns: processColumns)

    init() {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        for row in [latencyRow, jitterRow, lossRow] { row.set("—") }

        addFullWidth(header)
        addFullWidth(NSStackView.detailColumn(spacing: 8, [graph, Self.column([totalDownRow, totalUpRow])]))
        addFullWidth(
            NSStackView.detailColumn(
                spacing: 6,
                [
                    detailSectionTitle(String(localized: "Internet")), latencyStrip,
                    Self.column([latencyRow, jitterRow, lossRow]),
                ]
            )
        )
        addFullWidth(wifiColumn)
        addFullWidth(
            Self.column([
                detailSectionTitle(String(localized: "Addresses")), localAddressRow, publicAddressRow,
                hardwareAddressRow,
            ])
        )
        addFullWidth(
            NSStackView.detailColumn(
                spacing: 4,
                [
                    detailSectionTitle(
                        String(localized: "Top processes"), columns: Self.processColumns,
                        keys: (Self.downColor, Self.upColor)),
                    processes,
                ]
            )
        )
    }

    private static func column(_ views: [NSView]) -> NSStackView {
        NSStackView.detailColumn(views)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .network(let network) = update else { return }
        Self.showRates(of: network, in: header)

        graph.update([
            .init(values: network.downHistory, color: Self.downColor),
            .init(values: network.upHistory, color: Self.upColor),
        ])
        // Network traffic has no natural top, so the graph needs to say what its height stands for.
        let peak = (network.downHistory + network.upHistory).max() ?? 0
        peakLabel.setIfChanged(peak > 0 ? Format.rate(Double(peak)) : "")
        totalDownRow.set(Format.fileSize(network.totalDown))
        totalUpRow.set(Format.fileSize(network.totalUp))

        updateLatency(network.latency)
        updateWiFi(network.wifi)

        localAddressRow.set(network.interface?.address)
        publicAddressRow.set(
            value: network.publicAddress?.address,
            suffix: network.publicAddress?.countryCode.map(Format.flag(countryCode:))
        )
        hardwareAddressRow.set(network.interface?.hardwareAddress)

        processes.update(
            network.topProcesses,
            value: { Format.rate($0.downRate) },
            second: { Format.rate($0.upRate) }
        )
    }

    /// The speed down as the main value, the speed up beside it, and the connection they go through.
    static func showRates(of network: NetworkSnapshot, in header: DetailHeaderView) {
        let subtitle = network.interface.map { interface in
            interface.displayName.map { "\($0) · \(interface.bsdName)" } ?? interface.bsdName
        }
        header.update(
            subtitle: subtitle ?? String(localized: "Not connected"), value: "↓ " + Format.rate(network.downRate))
        header.setSide("↑ " + Format.rate(network.upRate))
    }

    private func updateLatency(_ latency: NetworkLatency?) {
        latencyStrip.update(latency?.samples ?? [])
        if let latency, !latency.samples.isEmpty, latency.average == nil {
            latencyRow.set(String(localized: "No response"))
        } else {
            latencyRow.set(latency?.average.map(Format.milliseconds) ?? "—")
        }
        jitterRow.set(latency?.jitter.map(Format.milliseconds) ?? "—")
        lossRow.set(latency?.loss.map { Format.percent($0) } ?? "—")
    }

    private func updateWiFi(_ wifi: WiFiDetails?) {
        wifiColumn.isHidden = wifi == nil
        signalRow.set(wifi.map { "\(Self.quality(ofSignal: $0.signal)) · \(Format.decibels($0.signal))" })
        linkSpeedRow.set(wifi.map { Format.megabitsPerSecond($0.transmitRate) })
        channelRow.set(wifi.flatMap(Self.channel))
    }

    /// The usual reading of a signal level: above -50 dBm is as good as it gets, below -70 dBm it struggles.
    private static func quality(ofSignal signal: Int) -> String {
        switch signal {
        case (-50)...: String(localized: "Excellent")
        case (-60)...: String(localized: "Good")
        case (-70)...: String(localized: "Fair")
        default: String(localized: "Weak")
        }
    }

    /// Such as `36 · 5 GHz · Wi-Fi 6`, leaving out whatever is not known.
    private static func channel(_ wifi: WiFiDetails) -> String? {
        var parts: [String] = []
        if let channel = wifi.channel { parts.append(String(channel)) }
        switch wifi.band {
        // With the decimal mark of the Mac's region, as every other number here.
        case .twoPointFour: parts.append(String(localized: "\(Format.decimal(2.4, digits: 1)) GHz"))
        case .five: parts.append(String(localized: "5 GHz"))
        case .six: parts.append(String(localized: "6 GHz"))
        case nil: break
        }
        if let generation = wifi.generation { parts.append("Wi-Fi \(generation)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

final class BatteryDetailView: NSStackView, MetricDetailContent {
    private static let capacityColor = NSColor.systemBlue

    private let header = DetailHeaderView(title: MetricKind.battery.title)
    private let chargeBar = SegmentBarView(height: 6)
    private let timeCell = StatCell(caption: String(localized: "Time to empty"))
    private let powerCell = StatCell(caption: String(localized: "Power draw"))
    private let healthCell = StatCell(caption: String(localized: "Battery health"))
    private let currentRow = DetailRow(String(localized: "Current"))
    private let voltageRow = DetailRow(String(localized: "Voltage"))
    private let chargingRow = DetailRow(String(localized: "Charging power"))
    private let adapterRow = DetailRow(String(localized: "Power adapter"))
    private let lowPowerRow = DetailRow(String(localized: "Low Power Mode"))
    private let capacityBar = SegmentBarView(height: 6)
    private lazy var capacityColumn = NSStackView.detailColumn(
        spacing: 6,
        [
            detailSectionTitle(String(localized: "Capacity")), capacityBar,
            NSStackView.detailColumn([maximumRow, designRow, cyclesRow]),
        ]
    )
    private let maximumRow = DetailRow(String(localized: "Maximum capacity"), key: capacityColor)
    private let designRow = DetailRow(String(localized: "Design capacity"), key: .tertiaryLabelColor)
    private let cyclesRow = DetailRow(String(localized: "Cycle count"))
    private let processes = ProcessListView()

    init() {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)
        addFullWidth(header)
        addFullWidth(NSStackView.detailColumn(spacing: 7, [chargeBar, statRow([timeCell, powerCell, healthCell])]))
        addFullWidth(NSStackView.detailColumn([currentRow, voltageRow, chargingRow, adapterRow, lowPowerRow]))
        addFullWidth(capacityColumn)
        addFullWidth(
            NSStackView.detailColumn(spacing: 4, [detailSectionTitle(String(localized: "Top processes")), processes]))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .battery(let battery) = update else { return }
        // Right after login the power sources can take a while to appear, and that is not an empty battery.
        guard battery.isPresent else {
            header.update(subtitle: "", value: "—")
            return
        }
        let health = battery.health
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        Self.showCharge(
            of: battery, isLowPower: isLowPower, header: header, bar: chargeBar, time: timeCell, power: powerCell,
            health: healthCell)

        currentRow.set(health?.current.map(Format.milliamps))
        voltageRow.set(health?.voltage.map(Format.volts))
        chargingRow.set(battery.state == .charging ? health?.power.map { Format.watts(abs($0)) } : nil)
        adapterRow.set(Self.adapter(battery))
        lowPowerRow.set(isLowPower ? String(localized: "On") : nil)

        if let full = health?.fullChargeCapacity, let design = health?.designCapacity, design > 0 {
            capacityBar.update([.init(fraction: Double(full) / Double(design), color: Self.capacityColor)])
            maximumRow.set(Format.milliampHours(full))
            designRow.set(Format.milliampHours(design))
            capacityColumn.isHidden = false
        } else {
            maximumRow.set(nil)
            designRow.set(nil)
            capacityColumn.isHidden = health?.cycleCount == nil
        }
        capacityBar.isHidden = health?.fullChargeCapacity == nil || health?.designCapacity == nil
        cyclesRow.set(Self.cycles(health))
        processes.update(battery.topProcesses) { Format.processLoad($0.cpu) }
    }

    /// The top of the details, which the simple view's list shows as it is.
    static func showCharge(
        of battery: BatterySnapshot, isLowPower: Bool, header: DetailHeaderView, bar: SegmentBarView, time: StatCell,
        power: StatCell, health: StatCell
    ) {
        let charge = Double(battery.percent) / 100
        header.update(subtitle: stateText(battery.state), value: Format.percent(charge))
        header.setSide(
            battery.health?.temperature.map(Format.temperature(celsius:)),
            color: color(forTemperature: battery.health?.temperature)
        )
        bar.update([.init(fraction: charge, color: color(forCharge: battery.percent, isLowPower: isLowPower))])
        update(time: time, of: battery)
        power.set(battery.powerDraw.map(Format.watts) ?? "—")
        health.set(battery.health?.maximumCapacityPercent.map { Format.percent(Double($0) / 100) } ?? "—")
    }

    private static func update(time cell: StatCell, of battery: BatterySnapshot) {
        let time = battery.minutesRemaining.map(Format.hoursAndMinutes) ?? "—"
        switch battery.state {
        case .discharging:
            cell.setCaption(String(localized: "Time to empty"))
            cell.set(time)
        case .charging:
            cell.setCaption(String(localized: "Time to full"))
            cell.set(time)
        case .charged, .notCharging:
            cell.setCaption(String(localized: "Power source"))
            cell.set(String(localized: "On AC power"))
        }
    }

    private static func stateText(_ state: BatteryState) -> String {
        switch state {
        case .charging: String(localized: "Charging")
        case .charged: String(localized: "Fully charged")
        case .notCharging: String(localized: "Plugged in, not charging")
        case .discharging: String(localized: "On battery")
        }
    }

    /// What comes in now against what the adapter is rated for, as far as those are known.
    private static func adapter(_ battery: BatterySnapshot) -> String? {
        guard battery.state != .discharging else { return nil }
        let rated = battery.health?.adapterWatts.map(Format.wholeWatts)
        guard let current = battery.adapterPower.map(Format.watts) else { return rated }
        return rated.map { String(localized: "\(current) of \($0)") } ?? current
    }

    private static func cycles(_ health: BatteryHealth?) -> String? {
        guard let count = health?.cycleCount else { return nil }
        guard let design = health?.designCycleCount else { return String(count) }
        return String(localized: "\(String(count)) of \(String(design))")
    }

    /// The colours macOS and iOS use for the battery: yellow in Low Power Mode, red when nearly empty.
    static func color(forCharge percent: Int, isLowPower: Bool) -> NSColor {
        if isLowPower { return .systemYellow }
        return percent <= 20 ? .systemRed : .systemGreen
    }

    /// Batteries age faster when warm, well below where a chip would count as hot.
    private static func color(forTemperature temperature: Double?) -> NSColor {
        switch temperature ?? 0 {
        case 45...: .systemRed
        case 40...: .systemOrange
        default: .secondaryLabelColor
        }
    }
}
