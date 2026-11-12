import AppKit
import SystemMetrics

/// The simple view: a ring for each chosen metric with its symbol inside and its figure below, like the Batteries
/// widget, so that the Mac reads at a glance. One figure each and nothing else: a shortened version of the details,
/// with a header, a bar and three values for each metric, was too much at once.
final class SimpleRingsView: NSStackView, MetricDetailContent {
    private static let rowSpacing: CGFloat = 14
    /// As many as fit one row. Beyond that they go in rows of three, the most that keep their captions apart.
    private static let mostInOneRow = 4
    private static let columnsInRows = 3

    private var cells: [MetricKind: SimpleRingCell] = [:]

    init(kinds: [MetricKind]) {
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: Self.rowSpacing)
        guard !kinds.isEmpty else {
            addFullWidth(
                NSTextField.detailLabel(String(localized: "Nothing is chosen to show."), color: .secondaryLabelColor))
            return
        }
        let made = kinds.map { SimpleRingCell(kind: $0) }
        cells = Dictionary(uniqueKeysWithValues: zip(kinds, made))
        let columns = made.count <= Self.mostInOneRow ? made.count : Self.columnsInRows
        for start in stride(from: 0, to: made.count, by: columns) {
            var row: [NSView] = Array(made[start..<min(start + columns, made.count)])
            // An empty view keeps a short last row in step with the columns above it.
            while row.count < columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                row.append(filler)
            }
            addFullWidth(statRow(row))
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard let reading = SimpleRingReading(update) else { return }
        cells[update.kind]?.show(reading)
    }
}

/// What one ring shows. All of it comes with a sample at the overview level, the cheapest that delivers every reading.
private struct SimpleRingReading {
    /// How full the ring is. A speed has no natural top, so its ring stays empty.
    var fraction: Double = 0
    var text: String
    var color: NSColor = .controlAccentColor
    var symbol: String
    /// What a screen reader says, where that is more than the text.
    var spokenText: String?

    init?(_ update: MetricUpdate) {
        switch update {
        case .cpu(let cpu):
            fraction = cpu.usage
            text = Format.percent(cpu.usage)
            symbol = MetricKind.cpu.simpleSymbol
        case .gpu(let gpu):
            fraction = gpu.usage ?? 0
            text = gpu.usage.map { Format.percent($0) } ?? "—"
            symbol = MetricKind.gpu.simpleSymbol
        case .memory(let memory):
            fraction = memory.usedFraction
            text = Format.percent(memory.usedFraction)
            symbol = MetricKind.memory.simpleSymbol
            // Like a hot chip, memory only draws attention when the system is short of it.
            switch memory.pressure {
            case .normal: break
            case .warning: color = .systemOrange
            case .critical: color = .systemRed
            }
        case .disk(let disk):
            guard let main = disk.main else { return nil }
            fraction = main.usedFraction
            text = Format.percent(main.usedFraction)
            symbol = MetricKind.disk.simpleSymbol
            if main.usedFraction >= 0.9 { color = DiskDetailView.color(forUsedFraction: main.usedFraction) }
        case .network(let network):
            let down = "↓ " + Format.rate(network.downRate)
            text = down
            symbol = MetricKind.network.simpleSymbol
            spokenText = down + ", ↑ " + Format.rate(network.upRate)
        case .battery(let battery):
            // Right after login the power sources can take a while to appear, and that is not an empty battery.
            guard battery.isPresent else { return nil }
            fraction = Double(battery.percent) / 100
            text = Format.percent(fraction)
            color = BatteryDetailView.color(
                forCharge: battery.percent, isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            symbol = battery.state == .charging ? "battery.100percent.bolt" : MetricKind.battery.simpleSymbol
        case .fans(let fans):
            guard !fans.fans.isEmpty else { return nil }
            fraction = fans.averageShare
            // The number alone: the ring's caption already says what it counts, and the unit would not fit under it.
            text =
                fans.averageRPM < 1
                ? FanSnapshot.stoppedText : String((Int(exactly: (fans.averageRPM / 10).rounded()) ?? 0) * 10)
            spokenText = fans.speedText
            symbol = MetricKind.fans.simpleSymbol
        }
    }
}

extension MetricKind {
    /// The symbol inside its ring. Solid ones hold up better at this size, and the globe says more than two arrows.
    fileprivate var simpleSymbol: String {
        self == .network ? symbol : filledMenuSymbol
    }
}

private final class SimpleRingCell: NSView {
    private static let diameter: CGFloat = 46
    private static let lineWidth: CGFloat = 5
    private static let symbolSize: CGFloat = 15
    /// The battery is much wider than the other symbols.
    private static let batterySymbolSize: CGFloat = 10

    private let ring = RingShapeView(diameter: diameter, lineWidth: lineWidth, color: .controlAccentColor)
    private let image = NSImageView()
    private let value = NSTextField.detailLabel(
        "—", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), alignment: .center)
    private var symbol: String?

    init(kind: MetricKind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image.translatesAutoresizingMaskIntoConstraints = false
        // The ring's name says what it is.
        image.setAccessibilityElement(false)
        image.contentTintColor = .labelColor
        let name = NSTextField.detailLabel(
            kind.title, font: .systemFont(ofSize: 10), color: .secondaryLabelColor, alignment: .center)
        [ring, image, value, name].forEach(addSubview)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            value.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 5),
            value.centerXAnchor.constraint(equalTo: centerXAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            value.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            name.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 1),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setSymbol(kind.simpleSymbol)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(kind.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ reading: SimpleRingReading) {
        value.setIfChanged(reading.text)
        setAccessibilityValue(reading.spokenText ?? reading.text)
        setSymbol(reading.symbol)
        ring.set(fraction: reading.fraction, color: reading.color, animated: true)
    }

    /// Asking for a symbol is not cheap, and a ring's only changes when the battery starts or stops charging.
    private func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        let size = name.hasPrefix("battery") ? Self.batterySymbolSize : Self.symbolSize
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
}
