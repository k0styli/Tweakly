import Accelerate
import AppKit

/// Building blocks for the details popover. Each one skips work when its value did not change.
enum DetailLayout {
    static let width: CGFloat = 320
    static let simpleWidth: CGFloat = 280
    static let padding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 5
}

extension NSTextField {
    static func detailLabel(
        _ text: String = "",
        font: NSFont = .systemFont(ofSize: 12),
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func setIfChanged(_ text: String) {
        if stringValue != text { stringValue = text }
    }

    /// The width this label needs to show some text, for keeping a column steady as values change.
    func requiredWidth(for text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font as Any]
        // Labels add a little padding of their own around the text.
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width) + 4
    }
}

final class DetailHeaderView: NSView {
    private static let sideSpacing: CGFloat = 10

    private let subtitleLabel = NSTextField.detailLabel(font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let valueLabel = NSTextField.detailLabel(
        font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
        alignment: .right
    )
    private let sideLabel = NSTextField.detailLabel(font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
    private let side: NSStackView

    /// - Parameter widestValue: The longest main value to expect, so what sits beside it stays put as it changes.
    init(title: String, widestValue: String? = nil) {
        let divider = RowDivider()
        side = NSStackView(views: [sideLabel, divider])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField.detailLabel(title, font: .systemFont(ofSize: 13, weight: .semibold))
        [titleLabel, subtitleLabel, valueLabel].forEach(addSubview)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        side.orientation = .horizontal
        side.alignment = .centerY
        side.spacing = Self.sideSpacing
        side.isHidden = true
        side.translatesAutoresizingMaskIntoConstraints = false
        sideLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(side)
        let usualWidth = valueLabel.requiredWidth(for: widestValue ?? Format.percent(0.88))
        NSLayoutConstraint.activate([
            side.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -Self.sideSpacing),
            side.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            // Load often crosses between one and two digits, which must not shift what sits beside it.
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: usualWidth),
        ])
        let textLimit = side.leadingAnchor
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textLimit, constant: -8),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textLimit, constant: -8),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(subtitle: String, value: String) {
        subtitleLabel.setIfChanged(subtitle)
        valueLabel.setIfChanged(value)
    }

    /// A nil value hides the reading and its divider, so a Mac without that sensor shows no empty space.
    func setSide(_ value: String?, color: NSColor = .secondaryLabelColor) {
        side.isHidden = value == nil
        guard let value else { return }
        sideLabel.setIfChanged(value)
        if sideLabel.textColor != color { sideLabel.textColor = color }
    }
}

/// A short vertical line between two values.
final class RowDivider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}

/// A title on the left and a value on the right, optionally with a colour key.
final class DetailRow: NSView {
    private let valueLabel = NSTextField.detailLabel(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        alignment: .right
    )
    private let titleLabel: NSTextField

    private static let keySize: CGFloat = 8
    private static let keySpacing: CGFloat = 6

    init(_ title: String, key: NSColor? = nil) {
        titleLabel = .detailLabel(title, color: .secondaryLabelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(valueLabel)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var titleLeading = leadingAnchor
        var titleInset: CGFloat = 0
        if let key {
            let dot = ColorDot(color: key, size: Self.keySize)
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            titleLeading = dot.trailingAnchor
            titleInset = Self.keySpacing
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleLeading, constant: titleInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A nil value hides the row, which is how data this Mac does not report stays out of the way.
    func set(_ value: String?) {
        isHidden = value == nil
        if let value { valueLabel.setIfChanged(value) }
    }

    func setTitle(_ title: String) {
        titleLabel.setIfChanged(title)
    }
}

/// A title and a value that stays blurred until pressed, so it does not end up in a demo or a screen
/// recording by accident. What is blurred is made-up digits, so nothing can be recovered from the picture,
/// and it is always the same length, so that says nothing either. The real value only reaches the view
/// once pressed. A popover is released when it closes, so this always starts hidden.
///
/// The suffix is a view of its own at a fixed place. Were it part of the value's text, the picture's
/// margins and height would move it between the two states.
final class ConcealedRow: NSView {
    private struct Content: Equatable {
        var value: String?
        var suffix: String?
        var isRevealed = false
    }

    private static let placeholder = "888.888.88.888"
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let blurRadius: CGFloat = 2.2
    /// Room around the digits for the blur to fade out in. It lies outside the layout.
    private static let blurMargin: CGFloat = 6
    /// A blur hides the difference on a lower-resolution display, so one picture serves them all.
    private static let blurScale: CGFloat = 2
    private static let suffixSpacing: CGFloat = 2
    /// How far inside a label its text ends, measured, which is where the digits in the picture end too.
    private static let labelInset: CGFloat = 0.7

    private let valueLabel = NSTextField.detailLabel(font: font, alignment: .right)
    private let suffixLabel = NSTextField.detailLabel(font: font, alignment: .right)
    private let blurView = NSImageView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var content = Content()
    private var shown: Content?

    init(_ title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField.detailLabel(title, color: .secondaryLabelColor)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.imageScaling = .scaleNone
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.isTransparent = true
        button.target = self
        button.action = #selector(toggle)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        suffixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        suffixLabel.setContentHuggingPriority(.required, for: .horizontal)
        [titleLabel, blurView, valueLabel, suffixLabel, button].forEach(addSubview)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            suffixLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            suffixLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: suffixLabel.leadingAnchor, constant: -Self.suffixSpacing),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            // The digits in the picture end where the digits of the real value end.
            blurView.trailingAnchor.constraint(
                equalTo: valueLabel.trailingAnchor, constant: Self.blurMargin - Self.labelInset),
            blurView.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),

            button.leadingAnchor.constraint(equalTo: blurView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        blurView.image = Self.renderBlurredDigits(appearance: effectiveAppearance)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// With no value yet the row shows a dash, and there is nothing to press.
    /// - Parameter suffix: Stays readable beside the value at all times, such as a country's flag.
    func set(value: String?, suffix: String?) {
        content.value = value
        content.suffix = suffix
        refresh()
    }

    #if TWEAKLY_AUTOMATION
        func pressForAutomation() {
            button.performClick(nil)
        }
    #endif

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The picture holds a colour for one appearance, unlike text.
        blurView.image = Self.renderBlurredDigits(appearance: effectiveAppearance)
    }

    @objc private func toggle() {
        content.isRevealed.toggle()
        refresh()
    }

    private func refresh() {
        guard content != shown else { return }
        shown = content
        suffixLabel.setIfChanged(content.suffix ?? "")
        let isConcealed = content.value != nil && !content.isRevealed
        blurView.isHidden = !isConcealed
        valueLabel.isHidden = isConcealed
        valueLabel.setIfChanged(isConcealed ? "" : content.value ?? "—")
        let hasValue = content.value != nil
        button.isEnabled = hasValue
        // Only the pointer resting on the value says it can be pressed.
        let hint = content.isRevealed ? String(localized: "Hide address") : String(localized: "Show address")
        button.toolTip = hasValue ? hint : nil
        button.setAccessibilityLabel(hasValue ? hint : nil)
    }

    /// The same blur as Core Image's, to within one level in 255. Core Image's software renderer took 8 MB that it
    /// never gave back and 364M instructions the first time, and 119M on each later popover, against 17M and 5M here.
    private static func renderBlurredDigits(appearance: NSAppearance) -> NSImage? {
        let digits = NSAttributedString(
            string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let textSize = digits.size()
        let size = NSSize(
            width: ceil(textSize.width) + blurMargin * 2, height: ceil(textSize.height) + blurMargin * 2)
        let width = Int(size.width * blurScale)
        let height = Int(size.height * blurScale)
        func makeContext() -> CGContext? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let sharp = makeContext(), let blurred = makeContext(), let sharpData = sharp.data,
            let blurredData = blurred.data
        else { return nil }
        sharp.scaleBy(x: blurScale, y: blurScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: sharp, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            digits.draw(at: NSPoint(x: blurMargin, y: blurMargin))
        }
        NSGraphicsContext.restoreGraphicsState()

        let kernel = gaussianKernel(sigma: Float(blurRadius * blurScale))
        var source = vImage_Buffer(
            data: sharpData, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: sharp.bytesPerRow)
        var destination = vImage_Buffer(
            data: blurredData, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: blurred.bytesPerRow)
        let transparent: [UInt8] = [0, 0, 0, 0]
        let status = vImageSepConvolve_ARGB8888(
            &source, &destination, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count), 0,
            transparent, vImage_Flags(kvImageBackgroundColorFill))
        guard status == kvImageNoError, let result = blurred.makeImage() else { return nil }
        return NSImage(cgImage: result, size: size)
    }

    private static func gaussianKernel(sigma: Float) -> [Float] {
        let reach = Int((sigma * 3).rounded(.up))
        let weights = (-reach...reach).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}

final class ColorDot: NSView {
    var color: NSColor {
        didSet {
            if color != oldValue { needsDisplay = true }
        }
    }

    init(color: NSColor, size: CGFloat = 8) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A history graph. Several series overlap, for example upload and download.
///
/// While the history is still short, a grey line runs along the bottom where there is no data yet and
/// rises into the first value, and the fill fades in, so the graph starts rather than looks cut off.
final class SparklineView: NSView {
    struct Series: Equatable {
        var values: [Float]
        var color: NSColor
    }

    private static let lineWidth: CGFloat = 1.5
    private static let leadInRise: CGFloat = 8
    private static let fillFade: CGFloat = 18

    private var series: [Series] = []
    private let fixedMaximum: Float?
    private let capacity: Int

    /// - Parameter maximum: The value at the top of the graph. Nil scales to the largest value shown.
    init(maximum: Float?, capacity: Int = 120, height: CGFloat = 44) {
        fixedMaximum = maximum
        self.capacity = capacity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ newSeries: [Series]) {
        guard newSeries != series else { return }
        series = newSeries
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        frame.fill()
        frame.addClip()

        let largest = series.flatMap(\.values).max() ?? 0
        let maximum = fixedMaximum ?? max(largest, 1)
        let step = bounds.width / CGFloat(max(capacity - 1, 1))
        let baseline = bounds.minY + 1
        let height = bounds.height - 2

        if !series.contains(where: { $0.values.count >= 2 }) {
            strokeLeadIn(from: NSPoint(x: bounds.maxX, y: baseline), baseline: baseline)
            return
        }
        for line in series where line.values.count >= 2 {
            let startX = bounds.maxX - CGFloat(line.values.count - 1) * step
            let points = line.values.enumerated().map { index, value in
                NSPoint(x: startX + CGFloat(index) * step, y: baseline + CGFloat(min(value / maximum, 1)) * height)
            }
            if startX > bounds.minX { strokeLeadIn(from: points[0], baseline: baseline) }

            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach(path.line(to:))

            let fill = NSBezierPath()
            fill.append(path)
            fill.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
            fill.line(to: NSPoint(x: startX, y: bounds.minY))
            fill.close()
            drawFill(fill, color: line.color, startX: startX)

            line.color.setStroke()
            path.lineWidth = Self.lineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    /// The grey line for the stretch with no data, rising into the first value.
    private func strokeLeadIn(from first: NSPoint, baseline: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: baseline))
        let riseStart = max(first.x - Self.leadInRise, bounds.minX)
        path.line(to: NSPoint(x: riseStart, y: baseline))
        path.line(to: first)
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = Self.lineWidth
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Opaque to clear, the same for every chart and every redraw, so made once.
    private static let fade = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
        locations: [0, 1])

    /// The soft area under a line, faded in at the start so a short history has no hard vertical edge.
    private func drawFill(_ fill: NSBezierPath, color: NSColor, startX: CGFloat) {
        let gradient = NSGradient(
            starting: color.withAlphaComponent(0.32),
            ending: color.withAlphaComponent(0.02)
        )
        guard startX > bounds.minX, let context = NSGraphicsContext.current?.cgContext, let fade = Self.fade else {
            gradient?.draw(in: fill, angle: -90)
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        gradient?.draw(in: fill, angle: -90)
        context.clip(to: NSRect(x: startX, y: bounds.minY, width: Self.fillFade, height: bounds.height))
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            fade,
            start: CGPoint(x: startX, y: 0),
            end: CGPoint(x: startX + Self.fillFade, y: 0),
            options: []
        )
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// A single capsule split into coloured parts.
final class SegmentBarView: NSView {
    struct Segment: Equatable {
        var fraction: Double
        var color: NSColor
    }

    private var segments: [Segment] = []
    private let gap: CGFloat

    /// - Parameter gap: Space after each part, which keeps neighbouring colours apart.
    init(height: CGFloat = 8, gap: CGFloat = 0) {
        self.gap = gap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ newSegments: [Segment]) {
        guard newSegments != segments else { return }
        segments = newSegments
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        capsule.fill()
        capsule.addClip()
        var x = bounds.minX
        for segment in segments {
            let width = bounds.width * CGFloat(min(max(segment.fraction, 0), 1))
            segment.color.setFill()
            NSRect(x: x, y: bounds.minY, width: max(width - gap, 0), height: bounds.height).fill()
            x += width
        }
    }
}

extension NSStackView {
    static func detailColumn(spacing: CGFloat = DetailLayout.rowSpacing, _ views: [NSView] = []) -> NSStackView {
        let stack = NSStackView()
        stack.setUpAsDetailColumn(spacing: spacing)
        stack.detachesHiddenViews = true
        views.forEach(stack.addFullWidth)
        return stack
    }

    /// A column of full-width rows, top to bottom with no insets, for a detail view that is a stack itself.
    func setUpAsDetailColumn(spacing: CGFloat) {
        orientation = .vertical
        alignment = .width
        self.spacing = spacing
        edgeInsets = NSEdgeInsetsZero
        translatesAutoresizingMaskIntoConstraints = false
    }

    /// Adds a row that spans the column. The `.width` alignment alone is weaker than a row's own
    /// preference for its content size, which would leave short rows narrower and off to one side.
    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

/// Lays its subviews out from the top left, as a scroll view's document and hand-placed labels expect.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The root of a popover: `column` padded inside a scroll view of a fixed width. Scrolling only ever comes into play on
/// a small screen or with a long list, and elasticity stays off until then, so a popover that fits does not bounce.
final class DetailScrollRoot: NSView {
    let column: NSStackView
    private let scroll = NSScrollView()
    private let width: CGFloat

    init(column: NSStackView, width: CGFloat) {
        self.column = column
        self.width = width
        super.init(frame: .zero)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalToConstant: width),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: DetailLayout.padding),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: DetailLayout.padding),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -DetailLayout.padding),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -DetailLayout.padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The size the content needs right now, no taller than the screen leaves room for, `screenMargin` kept free for
    /// the arrow and the shadow. Measured on the inner column, because the root view is held at its current size by
    /// the popover and would simply report that back.
    func fittingContentSize(screenMargin: CGFloat, limit: CGFloat = .infinity) -> NSSize {
        // Rows that were just hidden only leave the layout once it has been solved.
        layoutSubtreeIfNeeded()
        let height = column.fittingSize.height + DetailLayout.padding * 2
        let screen = window?.screen ?? NSScreen.main
        let available = min(screen.map { $0.visibleFrame.height - screenMargin } ?? height, limit)
        scroll.verticalScrollElasticity = height > available ? .automatic : .none
        return NSSize(width: width, height: min(height, available))
    }
}

/// A small caption above a group of rows.
func detailSectionTitle(_ text: String) -> NSTextField {
    let label = NSTextField.detailLabel(
        text, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
    // Without this the stack view keeps the label at its natural width and centres it.
    label.setContentHuggingPriority(.init(1), for: .horizontal)
    return label
}

/// A small caption inside a graph saying what its height stands for, for values with no natural top.
func graphScaleLabel(on graph: SparklineView) -> NSTextField {
    let label = NSTextField.detailLabel(font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    graph.addSubview(label)
    NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: graph.topAnchor, constant: 4),
        label.leadingAnchor.constraint(equalTo: graph.leadingAnchor, constant: 7),
    ])
    return label
}

/// A section title with a colour key at the right end of each value column below it.
func detailSectionTitle(_ text: String, columns: ProcessListView.Columns, keys: (NSColor, NSColor)) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    let title = detailSectionTitle(text)
    let second = ColorDot(color: keys.1, size: 7)
    let first = ColorDot(color: keys.0, size: 7)
    [title, first, second].forEach(row.addSubview)
    let firstColumnInset = columns.width + ProcessListView.columnSpacing * 2 + 1
    NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
        title.topAnchor.constraint(equalTo: row.topAnchor),
        title.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        second.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        second.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        first.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -firstColumnInset),
        first.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    return row
}

/// One bar for each recent packet to the internet: the taller the slower, and a full red bar for one that
/// was lost. Slots still waiting for a packet show as a low mark, so the row keeps its shape as it fills.
final class LatencyStripView: NSView {
    private static let gap: CGFloat = 2
    private static let emptyHeight: CGFloat = 3
    /// The share of the height that the fastest possible answer gets.
    private static let lowestBar = 0.4
    /// Anything slower than this looks the same.
    private static let tallestLatency = 200.0

    private var samples: [Double?] = []
    private let capacity: Int

    init(capacity: Int, height: CGFloat = 16) {
        self.capacity = capacity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ newSamples: [Double?]) {
        guard newSamples != samples else { return }
        samples = newSamples
        needsDisplay = true
    }

    /// Green while calls and games would feel fine, then steps towards trouble.
    static func color(forLatency latency: Double?) -> NSColor {
        guard let latency else { return .systemRed }
        switch latency {
        case ..<60: return .systemGreen
        case ..<150: return .systemYellow
        default: return .systemOrange
        }
    }

    /// A packet that came back is always a clear bar, unlike a slot still waiting for one. Above that it
    /// grows on a square root scale, because the difference between 10 and 20 ms matters more than
    /// between 150 and 160 ms, and the usual few milliseconds would barely show on a straight one.
    private func barHeight(forLatency latency: Double) -> CGFloat {
        let share = min(latency / Self.tallestLatency, 1).squareRoot()
        return bounds.height * CGFloat(Self.lowestBar + (1 - Self.lowestBar) * share)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = (bounds.width - Self.gap * CGFloat(capacity - 1)) / CGFloat(capacity)
        guard width > 0 else { return }
        let firstFilled = capacity - samples.count
        for slot in 0..<capacity {
            let x = bounds.minX + CGFloat(slot) * (width + Self.gap)
            let height: CGFloat
            if slot < firstFilled {
                NSColor.quaternaryLabelColor.setFill()
                height = Self.emptyHeight
            } else {
                let sample = samples[slot - firstFilled]
                Self.color(forLatency: sample).setFill()
                height = sample.map(barHeight) ?? bounds.height
            }
            let bar = NSRect(x: x, y: bounds.minY, width: width, height: height)
            let radius = min(width, height) / 2
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        }
    }
}
