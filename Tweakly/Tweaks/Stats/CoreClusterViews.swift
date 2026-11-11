import AppKit
import SystemMetrics

extension SystemInfo.CoreCluster.Kind {
    var title: String {
        switch self {
        case .performance: String(localized: "Performance")
        case .efficiency: String(localized: "Efficiency")
        case .other: String(localized: "Cores")
        }
    }

    /// Green reads as saving and orange as power, and neither repeats the blue and red of the user and
    /// system split in the same popover.
    var color: NSColor {
        switch self {
        case .performance: .systemOrange
        case .efficiency: .systemGreen
        case .other: .controlAccentColor
        }
    }

    /// Efficiency first, the order the cores are numbered in.
    var displayOrder: Int {
        switch self {
        case .efficiency: 0
        case .performance: 1
        case .other: 2
        }
    }
}

/// One vertical bar per value, such as a CPU core: a solid colour on a neutral track, like the strips in
/// the other popovers. Drawn with layers, so the bars glide to each new value on the render server instead
/// of redrawing a view every second.
final class CoreBarsView: NSView {
    private struct Bar {
        let track = CALayer()
        let level = CALayer()
    }

    static let gap: CGFloat = 4
    static let cornerRadius: CGFloat = 4
    private static let minimumVisibleLevel: CGFloat = 2
    private static let animationDuration: CFTimeInterval = 0.35
    /// A smaller move cannot be seen, and animating it still redraws the popover for a third of a second.
    private static let smallestVisibleMove: CGFloat = 1

    private let bars: [Bar]
    private let color: NSColor
    private var values: [Double] = []

    var barCount: Int { bars.count }

    /// - Parameter title: What a screen reader announces, followed by each core's load.
    init(coreCount: Int, color: NSColor, title: String, height: CGFloat = 34) {
        bars = (0..<coreCount).map { _ in Bar() }
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let noAnimation: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
        ]
        for bar in bars {
            bar.track.cornerRadius = Self.cornerRadius
            bar.track.cornerCurve = .continuous
            bar.track.masksToBounds = true
            bar.track.actions = noAnimation
            bar.level.actions = ["backgroundColor": NSNull()]
            bar.track.addSublayer(bar.level)
            layer?.addSublayer(bar.track)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ newValues: [Double]) {
        let isLaidOut = bounds.height > 0 && newValues.count == values.count
        if isLaidOut, zip(newValues, values).allSatisfy({ abs($0 - $1) * bounds.height < Self.smallestVisibleMove }) {
            return
        }
        values = newValues
        CATransaction.begin()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.setAnimationDuration(reduceMotion ? 0 : Self.animationDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        positionLevels()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard !bars.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = (bounds.width - Self.gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        for (index, bar) in bars.enumerated() {
            bar.track.frame = CGRect(x: CGFloat(index) * (width + Self.gap), y: 0, width: width, height: bounds.height)
        }
        positionLevels()
        CATransaction.commit()
    }

    /// Worked out only when something asks, so no one pays for it every second otherwise.
    override func accessibilityValue() -> Any? {
        values.map { Format.percent($0) }.joined(separator: ", ")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func positionLevels() {
        for (index, bar) in bars.enumerated() {
            let value = index < values.count ? min(max(values[index], 0), 1) : 0
            let height = value > 0.005 ? max(CGFloat(value) * bounds.height, Self.minimumVisibleLevel) : 0
            bar.level.frame = CGRect(x: 0, y: 0, width: bar.track.bounds.width, height: height)
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for bar in bars {
                bar.track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                bar.level.backgroundColor = color.cgColor
            }
        }
    }
}

/// Groups of bars on one row, each kept apart from the next by a line. The line is placed over the gap
/// rather than arranged in the row, so the bars keep their proportions.
func barGroupRow(_ groups: [CoreBarsView]) -> NSStackView {
    let spacing: CGFloat = 14
    let row = NSStackView(views: groups)
    row.orientation = .horizontal
    row.spacing = spacing
    row.edgeInsets = NSEdgeInsetsZero
    // Worked out from the bars themselves, so every bar is the same width whatever the mix of clusters.
    let barCount = groups.reduce(0) { $0 + $1.barCount }
    let innerGaps = CGFloat(barCount - groups.count) * CoreBarsView.gap
    let groupGaps = CGFloat(groups.count - 1) * spacing
    let contentWidth = DetailLayout.width - DetailLayout.padding * 2
    let barWidth = (contentWidth - innerGaps - groupGaps) / CGFloat(max(barCount, 1))
    for group in groups {
        let count = CGFloat(group.barCount)
        group.widthAnchor.constraint(equalToConstant: barWidth * count + CoreBarsView.gap * (count - 1)).isActive = true
    }
    for (left, right) in zip(groups, groups.dropFirst()) {
        let divider = RowDivider()
        row.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.centerXAnchor.constraint(equalTo: left.trailingAnchor, constant: spacing / 2),
            // Spans only the straight part of the neighbouring bars' sides.
            divider.topAnchor.constraint(equalTo: right.topAnchor, constant: CoreBarsView.cornerRadius),
            divider.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -CoreBarsView.cornerRadius),
        ])
    }
    return row
}

/// Only a hot chip draws attention to its temperature.
func chipTemperatureColor(_ temperature: Double?) -> NSColor {
    switch temperature ?? 0 {
    case 95...: .systemRed
    case 85...: .systemOrange
    default: .secondaryLabelColor
    }
}

/// A ring on a neutral track that fills clockwise from the top, as the strips in other popovers fill from the left.
/// AppKit has no such control, so it is drawn with layers.
final class RingShapeView: NSView {
    private static let animationDuration: CFTimeInterval = 0.35

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let circumference: CGFloat
    private var color: NSColor
    private var fraction: CGFloat = 0

    init(diameter: CGFloat, lineWidth: CGFloat, color: NSColor) {
        self.color = color
        let radius = (diameter - lineWidth) / 2
        circumference = 2 * .pi * radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
        // A quarter turn back and clockwise, so the ring fills from the top. Layer coordinates start at the bottom.
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let path = CGMutablePath()
        path.addArc(
            center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for layer in [track, progress] {
            layer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.path = path
            layer.fillColor = nil
            layer.lineWidth = lineWidth
            layer.actions = ["strokeColor": NSNull(), "hidden": NSNull()]
            self.layer?.addSublayer(layer)
        }
        progress.lineCap = .round
        progress.strokeEnd = 0
        progress.isHidden = true
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// - Parameter animated: Whether it glides there, on the render server. Reduce Motion always wins.
    func set(fraction newValue: Double, color newColor: NSColor? = nil, animated: Bool) {
        let new = CGFloat(min(max(newValue, 0), 1))
        if let newColor, newColor != color {
            color = newColor
            applyColors()
        }
        // A smaller move cannot be seen, and animating it still redraws the popover for a third of a second.
        guard new != fraction, !animated || new == 0 || abs(new - fraction) * circumference >= 1 else { return }
        fraction = new
        CATransaction.begin()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(Self.animationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        progress.strokeEnd = new
        // A round cap could otherwise leave a dot on an empty ring.
        progress.isHidden = new == 0
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.quaternaryLabelColor.cgColor
            progress.strokeColor = color.cgColor
        }
    }
}

/// A share shown as a ring, with the figure inside and a caption below, like the Batteries widget.
/// It does not animate: gliding keeps the screen redrawing, which would raise the frame rate shown beside it.
final class RingGaugeView: NSView {
    static let diameter: CGFloat = 54
    private static let lineWidth: CGFloat = 6
    private static let captionSpacing: CGFloat = 3

    private let ring: RingShapeView
    private let valueLabel = NSTextField.detailLabel(
        "—",
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        alignment: .center
    )
    private var value: Double?

    var ringCenterYAnchor: NSLayoutYAxisAnchor { ring.centerYAnchor }

    init(caption: String, color: NSColor) {
        ring = RingShapeView(diameter: Self.diameter, lineWidth: Self.lineWidth, color: color)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let captionLabel = NSTextField.detailLabel(
            caption, font: .systemFont(ofSize: 10), color: .secondaryLabelColor, alignment: .center)
        [ring, valueLabel, captionLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            captionLabel.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: Self.captionSpacing),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Nil means the figure is not known, which shows as a dash and an empty ring.
    func update(_ newValue: Double?) {
        guard newValue != value else { return }
        value = newValue
        let text = newValue.map { Format.percent($0) } ?? "—"
        valueLabel.setIfChanged(text)
        setAccessibilityValue(text)
        ring.set(fraction: newValue ?? 0, animated: false)
    }
}

/// Rings side by side across the popover, with a line between the last one and the others, which belong
/// together.
func ringGaugeRow(_ gauges: [RingGaugeView]) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    let dividerWidth: CGFloat = 1
    let dividerInset: CGFloat = 8
    let contentWidth = DetailLayout.width - DetailLayout.padding * 2
    let gaps = CGFloat(gauges.count)
    let spacing = (contentWidth - RingGaugeView.diameter * CGFloat(gauges.count) - dividerWidth) / gaps
    gauges.forEach(row.addSubview)
    var constraints: [NSLayoutConstraint] = []
    var previous: NSLayoutXAxisAnchor = row.leadingAnchor
    var offset: CGFloat = 0
    for (index, gauge) in gauges.enumerated() {
        if index == gauges.count - 1, index > 0 {
            let divider = RowDivider()
            row.addSubview(divider)
            constraints += [
                divider.leadingAnchor.constraint(equalTo: previous, constant: spacing),
                divider.widthAnchor.constraint(equalToConstant: dividerWidth),
                divider.centerYAnchor.constraint(equalTo: gauge.ringCenterYAnchor),
                divider.heightAnchor.constraint(equalToConstant: RingGaugeView.diameter - dividerInset * 2),
            ]
            previous = divider.trailingAnchor
            offset = spacing
        }
        constraints += [
            gauge.leadingAnchor.constraint(equalTo: previous, constant: offset),
            gauge.topAnchor.constraint(equalTo: row.topAnchor),
            gauge.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ]
        previous = gauge.trailingAnchor
        offset = spacing
    }
    NSLayoutConstraint.activate(constraints)
    return row
}
