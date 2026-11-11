import AppKit
import SystemMetrics

/// The simple view's second look, for more than the rings say: the top of each chosen metric's details, one under
/// another. There are no charts, because nothing records a history while the list is closed: a chart would start empty
/// on every click, while a bar means something from its first value.
final class SimpleListView: NSStackView, MetricDetailContent {
    private static let blockSpacing: CGFloat = 12

    private var blocks: [MetricKind: SimpleBlock] = [:]

    init(kinds: [MetricKind], info: SystemInfo) {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: Self.blockSpacing)
        for kind in kinds {
            let block = Self.makeBlock(kind, info: info)
            if !blocks.isEmpty { addFullWidth(Self.makeSeparator()) }
            blocks[kind] = block
            addFullWidth(block)
        }
        if kinds.isEmpty {
            addFullWidth(
                NSTextField.detailLabel(String(localized: "Nothing is chosen to show."), color: .secondaryLabelColor))
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        blocks[update.kind]?.update(update)
    }

    private static func makeBlock(_ kind: MetricKind, info: SystemInfo) -> SimpleBlock {
        switch kind {
        case .cpu: CPUBlock(info: info)
        case .gpu: GPUBlock(info: info)
        case .memory: MemoryBlock()
        case .disk: DiskBlock()
        case .network: NetworkBlock()
        case .battery: BatteryBlock()
        case .fans: FanBlock()
        }
    }

    /// The system's own line, the one menus and lists use.
    private static func makeSeparator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }
}

/// A metric's header and bar. What follows them is up to each metric.
private class SimpleBlock: NSStackView, MetricDetailContent {
    private static let rowSpacing: CGFloat = 8

    let header: DetailHeaderView
    let bar = SegmentBarView(height: 6, gap: 1.5)

    init(title: String, widestValue: String? = nil, hasBar: Bool = true) {
        header = DetailHeaderView(title: title, widestValue: widestValue)
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: Self.rowSpacing)
        addFullWidth(header)
        if hasBar { addFullWidth(bar) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {}
}

/// Keeps a column free, so that the columns of every metric line up.
private func emptyStatColumn() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

private final class CPUBlock: SimpleBlock {
    private let userCell = StatCell(caption: String(localized: "User"), key: .controlAccentColor)
    private let systemCell = StatCell(caption: String(localized: "System"), key: .systemRed)
    private let idleCell = StatCell(caption: String(localized: "Idle"), key: .tertiaryLabelColor)
    private let subtitle: String

    init(info: SystemInfo) {
        subtitle = info.chipName
        super.init(title: MetricKind.cpu.title)
        addFullWidth(statRow([userCell, systemCell, idleCell]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .cpu(let cpu) = update else { return }
        header.update(subtitle: subtitle, value: Format.percent(cpu.usage))
        header.setSide(cpu.temperature.map(Format.temperature(celsius:)), color: chipTemperatureColor(cpu.temperature))
        bar.update([
            .init(fraction: cpu.user, color: .controlAccentColor),
            .init(fraction: cpu.system, color: .systemRed),
        ])
        userCell.set(Format.percent(cpu.user))
        systemCell.set(Format.percent(cpu.system))
        idleCell.set(Format.percent(max(1 - cpu.usage, 0)))
    }
}

private final class GPUBlock: SimpleBlock {
    private let rendererCell = StatCell(caption: String(localized: "gpu.renderer", defaultValue: "Render"))
    private let tilerCell = StatCell(caption: String(localized: "Tiler"))
    private let memoryCell = StatCell(caption: String(localized: "Memory"))
    private let subtitle: String

    init(info: SystemInfo) {
        subtitle = info.gpuName ?? info.chipName
        super.init(title: MetricKind.gpu.title)
        addFullWidth(statRow([rendererCell, tilerCell, memoryCell]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .gpu(let gpu) = update else { return }
        header.update(subtitle: subtitle, value: gpu.usage.map { Format.percent($0) } ?? "—")
        header.setSide(gpu.temperature.map(Format.temperature(celsius:)), color: chipTemperatureColor(gpu.temperature))
        bar.update([.init(fraction: gpu.usage ?? 0, color: .controlAccentColor)])
        rendererCell.set(gpu.renderer.map { Format.percent($0) } ?? "—")
        tilerCell.set(gpu.tiler.map { Format.percent($0) } ?? "—")
        memoryCell.set(gpu.memoryInUse.map(Format.memorySize) ?? "—")
    }
}

private final class MemoryBlock: SimpleBlock {
    private let appCell = StatCell(caption: String(localized: "App memory"), key: MemoryDetailView.appColor)
    private let wiredCell = StatCell(
        caption: String(localized: "memory.wired.short", defaultValue: "Wired"), key: MemoryDetailView.wiredColor)
    private let compressedCell = StatCell(
        caption: String(localized: "Compressed"), key: MemoryDetailView.compressedColor)

    init() {
        super.init(title: MetricKind.memory.title)
        addFullWidth(statRow([appCell, wiredCell, compressedCell]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .memory(let memory) = update else { return }
        header.update(subtitle: MemoryDetailView.capacity(of: memory), value: Format.percent(memory.usedFraction))
        header.setSide(Format.memorySize(memory.used), color: MemoryDetailView.color(for: memory.pressure))
        bar.update([
            .init(fraction: memory.share(of: memory.app), color: MemoryDetailView.appColor),
            .init(fraction: memory.share(of: memory.wired), color: MemoryDetailView.wiredColor),
            .init(fraction: memory.share(of: memory.compressed), color: MemoryDetailView.compressedColor),
        ])
        appCell.set(Format.memorySize(memory.app))
        wiredCell.set(Format.memorySize(memory.wired))
        compressedCell.set(Format.memorySize(memory.compressed))
    }
}

private final class DiskBlock: SimpleBlock {
    private let usedCell = StatCell(caption: String(localized: "Used"))
    private let freeCell = StatCell(caption: String(localized: "Free"))
    private let purgeableCell = StatCell(caption: String(localized: "Can be cleared"))

    init() {
        super.init(title: MetricKind.disk.title)
        addFullWidth(statRow([usedCell, freeCell, purgeableCell]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .disk(let disk) = update, let main = disk.main else { return }
        header.update(subtitle: main.name, value: Format.percent(main.usedFraction))
        bar.update([.init(fraction: main.usedFraction, color: DiskDetailView.color(forUsedFraction: main.usedFraction))]
        )
        usedCell.set(Format.fileSize(main.total > main.available ? main.total - main.available : 0))
        freeCell.set(Format.fileSize(main.available))
        // Too little to mention most of the time, though it can reach many gigabytes.
        purgeableCell.set(main.purgeable >= 100_000_000 ? Format.fileSize(main.purgeable) : "—")
    }
}

/// Speed has no natural top, so there is nothing for a bar to fill.
private final class NetworkBlock: SimpleBlock {
    private let receivedCell = StatCell(caption: String(localized: "Received"))
    private let sentCell = StatCell(caption: String(localized: "Sent"))

    init() {
        super.init(title: MetricKind.network.title, widestValue: "↓ " + Format.rate(92_000_000), hasBar: false)
        addFullWidth(statRow([receivedCell, sentCell, emptyStatColumn()]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .network(let network) = update else { return }
        NetworkDetailView.showRates(of: network, in: header)
        receivedCell.set(Format.fileSize(network.totalDown))
        sentCell.set(Format.fileSize(network.totalUp))
    }
}

private final class FanBlock: SimpleBlock {
    private let firstCell = StatCell(caption: FanSnapshot.fanName(0))
    private let secondCell = StatCell(caption: FanSnapshot.fanName(1))
    private let modeCell = StatCell(caption: String(localized: "Mode"))

    init() {
        super.init(title: MetricKind.fans.title, widestValue: Format.rpm(8_880))
        addFullWidth(statRow([firstCell, secondCell, modeCell]))
    }

    override func update(_ update: MetricUpdate) {
        guard case .fans(let fans) = update, !fans.fans.isEmpty else { return }
        header.update(subtitle: FanModeText.current(), value: fans.speedText)
        header.setSide(
            fans.temperatures.hottest.map(Format.temperature(celsius:)),
            color: chipTemperatureColor(fans.temperatures.hottest))
        bar.update([.init(fraction: fans.averageShare, color: .controlAccentColor)])
        firstCell.set(Self.text(of: fans.fans.first))
        secondCell.set(Self.text(of: fans.fans.dropFirst().first))
        modeCell.set(FanModeText.short())
    }

    private static func text(of fan: FanReading?) -> String {
        guard let fan else { return "—" }
        return fan.actual < 1 ? String(localized: "Stopped") : Format.rpm(fan.actual)
    }
}

private final class BatteryBlock: SimpleBlock {
    private let timeCell = StatCell(caption: String(localized: "Time to empty"))
    private let powerCell = StatCell(caption: String(localized: "Power draw"))
    private let healthCell = StatCell(caption: String(localized: "Battery health"))

    init() {
        super.init(title: MetricKind.battery.title)
        addFullWidth(statRow([timeCell, powerCell, healthCell]))
    }

    override func update(_ update: MetricUpdate) {
        // Right after login the power sources can take a while to appear, and that is not an empty battery.
        guard case .battery(let battery) = update, battery.isPresent else { return }
        BatteryDetailView.showCharge(
            of: battery, isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, header: header, bar: bar,
            time: timeCell, power: powerCell, health: healthCell)
    }
}
