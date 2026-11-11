import AppKit
import SystemMetrics

/// How the person wants their labels drawn.
struct StatusLabelOptions: Equatable {
    var style: MenuBarStyle
    var alignment: CaptionAlignment
    var batteryStyle: BatteryBarStyle
    var colorsBatteryWhileCharging = true
    /// The fans' item can show how hot it is rather than how fast they spin.
    var fanShowsTemperature = false
}

/// Recent readings for the styles that draw a chart, scaled to 0...1 and oldest first.
struct StatusLabelHistory: Equatable {
    /// Also the number of steps a chart in the menu bar is drawn on, so the two cannot drift apart.
    static let capacity = 24

    /// The percentage, or the download speed.
    private(set) var primary: [Float] = []
    /// The upload speed.
    private(set) var secondary: [Float] = []

    mutating func record(_ value: MenuValue) {
        switch value {
        case .rates(let up, let down):
            append(&primary, Float(StatusLabelContent.level(of: down)))
            append(&secondary, Float(StatusLabelContent.level(of: up)))
        default:
            append(&primary, Float(StatusLabelContent.level(of: value)))
        }
    }

    private func append(_ values: inout [Float], _ value: Float) {
        values.append(value)
        if values.count > Self.capacity { values.removeFirst() }
    }
}

/// What a status item's label shows, independent of how it is drawn.
struct StatusLabelContent: Equatable {
    enum Layout: Equatable {
        case stacked(caption: String, value: String, alignment: CaptionAlignment)
        case icon(symbol: String, value: String)
        case value(String)
        case rates(up: String, down: String)
        case symbol(String)
        case filledSymbol(String, level: Double)
        case arrows(up: Double, down: Double)
        case ring(symbol: String, level: Double)
        case ringValue(String, level: Double)
        case dualRing(up: Double, down: Double)
        case column(symbol: String, level: Double)
        case dualColumn(up: Double, down: Double)
        case signal(symbol: String, level: Double)
        case line(symbol: String, values: [Float])
        case dualLine(up: [Float], down: [Float])
        case bars(symbol: String, values: [Float])
        case captionBar(caption: String, level: Double, alignment: CaptionAlignment)
        case dualBar(caption: String, up: Double, down: Double, alignment: CaptionAlignment)
        case battery(BatteryGlyph)
        case batterySide(BatteryGlyph, value: String)
    }

    let layout: Layout
    let accessibilityText: String
    var accent: StatusAccent?

    /// Which edge stays put when the label is wider than its item.
    var overflowAlignment: CaptionAlignment {
        if case .stacked(_, _, let alignment) = layout { alignment } else { .left }
    }

    static func make(
        kind: MetricKind,
        value: MenuValue,
        options: StatusLabelOptions,
        history: StatusLabelHistory = StatusLabelHistory(),
        isLowPower: Bool = false
    ) -> StatusLabelContent {
        switch value {
        case .rates(let up, let down):
            return network(kind: kind, up: up, down: down, options: options, history: history)
        case .battery(let percent, let isCharging, let isPluggedIn) where options.batteryStyle != .sameAsOthers:
            return battery(
                percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn, isLowPower: isLowPower,
                options: options)
        default:
            break
        }
        let text: String
        var spoken: String?
        var symbol = kind.menuSymbol
        var filled = kind.filledMenuSymbol
        switch value {
        case .percent(let percent):
            text = Format.percent(percent)
        case .battery(let percent, let isCharging, _):
            // The icon style already says "charging" through its symbol.
            text = (isCharging && options.style != .icon ? chargingMark : "") + Format.percent(percent)
            symbol = batterySymbol(percent: percent, isCharging: isCharging)
            filled = symbol
            spoken = batterySpoken(percent: percent, isCharging: isCharging)
        case .fan(let rpm, _, let temperature):
            if options.fanShowsTemperature {
                text = temperature.map { "\($0)°" } ?? "—"
            } else {
                text = String(rpm)
                spoken = fanSpoken(rpm: rpm)
            }
        default:
            text = "—"
        }
        let level = level(of: value)
        let layout: Layout =
            switch options.style {
            case .stacked: .stacked(caption: kind.menuBarShortTitle, value: text, alignment: options.alignment)
            case .icon: .icon(symbol: symbol, value: text)
            case .value: .value(text)
            case .symbol: .symbol(filled)
            case .filledSymbol: .filledSymbol(filled, level: level)
            case .ring: .ring(symbol: filled, level: level)
            case .ringValue: .ringValue(text.hasSuffix("%") ? String(text.dropLast()) : text, level: level)
            case .column: .column(symbol: filled, level: level)
            // Its bars only show which of a few steps the level is on, so a change within a step redraws nothing.
            case .signal: .signal(symbol: filled, level: StatusLabelRenderer.signalStep(level))
            case .line: .line(symbol: filled, values: history.primary)
            case .bars: .bars(symbol: filled, values: history.primary)
            case .captionBar: .captionBar(caption: kind.menuBarShortTitle, level: level, alignment: options.alignment)
            }
        return StatusLabelContent(layout: layout, accessibilityText: "\(kind.menuBarTitle) \(spoken ?? text)")
    }

    private static func network(
        kind: MetricKind, up: CompactRate, down: CompactRate, options: StatusLabelOptions, history: StatusLabelHistory
    ) -> StatusLabelContent {
        let upLevel = level(of: up)
        let downLevel = level(of: down)
        let layout: Layout =
            switch options.style {
            case .stacked, .icon, .value:
                .rates(
                    up: Format.menuBarRate(up, separator: thinSpace),
                    down: Format.menuBarRate(down, separator: thinSpace))
            case .symbol: .symbol(kind.filledMenuSymbol)
            case .filledSymbol: .arrows(up: upLevel, down: downLevel)
            case .ring, .ringValue: .dualRing(up: upLevel, down: downLevel)
            case .column, .signal: .dualColumn(up: upLevel, down: downLevel)
            case .line, .bars: .dualLine(up: history.secondary, down: history.primary)
            case .captionBar:
                .dualBar(caption: kind.menuBarShortTitle, up: upLevel, down: downLevel, alignment: options.alignment)
            }
        return StatusLabelContent(
            layout: layout,
            accessibilityText: ratesTemplate.filled(up: Format.menuBarRate(up), down: Format.menuBarRate(down))
        )
    }

    /// The spoken form of two rates, split around its values. Looking up a localized string with values in it costs
    /// more than the rest of an update put together, and with any traffic at all that happens on every update.
    private struct RatesTemplate {
        private let parts: [String]
        private let upComesFirst: Bool

        init() {
            let (upMark, downMark) = ("\u{1}", "\u{2}")
            let text = String(localized: "Upload \(upMark), download \(downMark)", bundle: AppLanguage.menuBarBundle)
            parts = text.split(omittingEmptySubsequences: false) { $0 == "\u{1}" || $0 == "\u{2}" }.map(String.init)
            upComesFirst =
                (text.range(of: upMark)?.lowerBound ?? text.startIndex)
                <= (text.range(of: downMark)?.lowerBound ?? text.endIndex)
        }

        func filled(up: String, down: String) -> String {
            guard parts.count == 3 else {
                return String(localized: "Upload \(up), download \(down)", bundle: AppLanguage.menuBarBundle)
            }
            return parts[0] + (upComesFirst ? up : down) + parts[1] + (upComesFirst ? down : up) + parts[2]
        }
    }

    private static let ratesTemplate = RatesTemplate()

    private static func battery(
        percent: Int, isCharging: Bool, isPluggedIn: Bool, isLowPower: Bool, options: StatusLabelOptions
    ) -> StatusLabelContent {
        let glyph = BatteryGlyph(
            percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn, isLowPower: isLowPower,
            showsNumber: options.batteryStyle == .number, colorsWhileCharging: options.colorsBatteryWhileCharging)
        let layout: Layout =
            options.batteryStyle == .side ? .batterySide(glyph, value: Format.percent(percent)) : .battery(glyph)
        return StatusLabelContent(
            layout: layout,
            accessibilityText:
                "\(MetricKind.battery.menuBarTitle) \(batterySpoken(percent: percent, isCharging: isCharging))",
            accent: glyph.accent)
    }

    /// A screen reader should say the word rather than try to name the lightning symbol.
    /// The fans item comes with the hottest temperature too, which moves on almost every update while the speed holds,
    /// often at 0 rpm. A localized string with a value in it costs more than the rest of an update, so the last one is
    /// kept.
    private static var lastFanSpoken: (rpm: Int, text: String)?

    private static func fanSpoken(rpm: Int) -> String {
        if let lastFanSpoken, lastFanSpoken.rpm == rpm { return lastFanSpoken.text }
        let text = String(localized: "\(String(rpm)) rpm", bundle: AppLanguage.menuBarBundle)
        lastFanSpoken = (rpm, text)
        return text
    }

    private static func batterySpoken(percent: Int, isCharging: Bool) -> String {
        Format.percent(percent)
            + (isCharging ? ", " + String(localized: "Charging", bundle: AppLanguage.menuBarBundle) : "")
    }

    /// How full a gauge should be for this value.
    static func level(of value: MenuValue) -> Double {
        switch value {
        case .percent(let percent), .battery(let percent, _, _), .fan(_, let percent, _): Double(percent) / 100
        case .rates(_, let down): level(of: down)
        case .unavailable: 0
        }
    }

    /// On a logarithmic scale, because speeds span five orders of magnitude: 1 KB/s reads empty and 100 MB/s full.
    static func level(of rate: CompactRate) -> Double {
        let unit: Double =
            switch rate.unit {
            case .kilobytes: 1e3
            case .megabytes: 1e6
            case .gigabytes: 1e9
            }
        let bytes = Double(rate.tenths) / 10 * unit
        return min(max(log10(max(bytes, 1e3) / 1e3) / 5, 0), 1)
    }

    private static let chargingMark = "\u{26A1}\u{FE0E}"
    /// Takes less room than the ordinary space between a number and its unit.
    private static let thinSpace = "\u{2009}"

    private static func batterySymbol(percent: Int, isCharging: Bool) -> String {
        if isCharging { return "battery.100percent.bolt" }
        return switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Made-up readings to show what a style looks like, before it is chosen or without any sampling.
enum StatusLabelSample {
    static func content(kind: MetricKind, options: StatusLabelOptions) -> StatusLabelContent {
        let value: MenuValue =
            switch kind {
            case .cpu: .percent(58)
            case .gpu: .percent(32)
            case .memory: .percent(76)
            case .disk: .percent(64)
            case .network: rates(up: 34, down: 1_240)
            case .battery: .battery(percent: 62, isCharging: false, isPluggedIn: false)
            case .fans: .fan(rpm: 2_400, percent: 32, temperature: 52)
            }
        return StatusLabelContent.make(kind: kind, value: value, options: options, history: history(kind: kind))
    }

    private static func rates(up: Double, down: Double) -> MenuValue {
        .rates(up: CompactRate(bytesPerSecond: up * 1_000), down: CompactRate(bytesPerSecond: down * 1_000))
    }

    private static func history(kind: MetricKind) -> StatusLabelHistory {
        var history = StatusLabelHistory()
        if kind == .network {
            let readings: [(Double, Double)] = [
                (2, 40), (3, 120), (2, 300), (5, 90), (4, 800), (9, 1_400), (6, 2_100), (3, 600), (2, 200), (2, 70),
                (8, 300), (20, 900), (34, 1_240), (12, 700), (5, 240), (3, 80), (2, 40), (4, 500), (7, 1_600),
                (9, 2_400), (6, 1_800), (5, 1_300), (34, 1_000), (34, 1_240),
            ]
            for (up, down) in readings { history.record(rates(up: up, down: down)) }
        } else {
            let readings = [
                34, 38, 30, 42, 55, 48, 62, 58, 40, 36, 44, 70, 66, 52, 46, 60, 72, 64, 50, 56, 68, 74, 60, 58,
            ]
            for reading in readings { history.record(.percent(reading)) }
        }
        return history
    }
}

/// What a label draws: a mask for the label's own colour, which follows the menu bar, and what has colours of its own.
struct StatusLabelBitmaps {
    var mask: CGImage?
    var colored: CGImage?
}

/// Draws label content into bitmaps. All sizes are in points, in a canvas whose origin is at the bottom left.
enum StatusLabelRenderer {
    private static let captionFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    private static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let stackedPercentFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let valuePercentFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let ringFont = roundedFont(size: 8.5)
    private static let rateArrowPointSize: CGFloat = 7.5
    private static let iconPointSize: CGFloat = 15
    private static let smallIconPointSize: CGFloat = 13
    private static let ringIconPointSize: CGFloat = 8
    private static let iconSpacing: CGFloat = 3
    private static let arrowSpacing: CGFloat = 1.5
    /// How far apart the baselines of two stacked lines are, and where the lower one sits.
    private static let stackedBaselineGap: CGFloat = 10.5
    private static let stackedLowerBaseline: CGFloat = 2.5
    /// Where a single line of text sits, which is where the menu bar's clock has its own.
    private static let valueBaseline: CGFloat = 6.5
    private static let ratesBaselineGap: CGFloat = 9.5
    private static let ratesLowerBaseline: CGFloat = 3.5
    private static let trackAlpha: CGFloat = 0.3
    private static let ringDiameter: CGFloat = 18
    private static let ringStroke: CGFloat = 2
    private static let valueRingDiameter: CGFloat = 20
    private static let valueRingStroke: CGFloat = 2
    private static let columnSize = CGSize(width: 5, height: 16)
    private static let columnRadius: CGFloat = 1.75
    private static let dualColumnSpacing: CGFloat = 1.5
    private static let signalHeights: [CGFloat] = [5, 8, 11, 14]
    private static let signalBarWidth: CGFloat = 3
    private static let signalSpacing: CGFloat = 1
    private static let chartSize = CGSize(width: 26, height: 14)
    private static let chartLineWidth: CGFloat = 1.25
    private static let chartAreaAlpha: CGFloat = 0.25
    /// How much of the upload line shows, so it can be told from the download line on top of it.
    private static let secondaryLineAlpha: CGFloat = 0.55
    private static let historyBars = 7
    private static let historyBarWidth: CGFloat = 2
    private static let historyBarSpacing: CGFloat = 1
    /// A reading this low still draws, so the chart never looks switched off.
    private static let historyBarMinimum: CGFloat = 1.5
    private static let captionBarWidth: CGFloat = 26
    private static let captionBarHeight: CGFloat = 4
    private static let dualBarHeight: CGFloat = 2
    /// Bars under a caption stand on this line, which keeps their edges on whole pixels.
    private static let captionBarBottom: CGFloat = 3
    private static let historySlots = StatusLabelHistory.capacity

    private static let tightRingFont = roundedFont(size: 7)
    /// How much room a symbol's bitmap leaves around its image, because the ink of some reaches past those bounds.
    private static let symbolMargin: CGFloat = 4
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private static let networkSymbol = "arrow.up.arrow.down"
    /// Enough for every percentage in one style, as those keep coming back. Rates rarely repeat, and only churn this.
    private static let textLineLimit = 128

    private static var symbols: [SymbolKey: Symbol?] = [:]
    private static var textLines: [TextKey: TextLine] = [:]
    private static var textHeights: [TextStyle: CGFloat] = [:]
    /// The pixel grid of the bitmap being drawn.
    private static var scale: CGFloat = 2

    private enum TextStyle {
        case caption, stackedValue, plainValue, rate, ring, tightRing
    }

    private struct TextKey: Hashable {
        let string: String
        let style: TextStyle
    }

    /// Text laid out once. Setting a line of type is what costs, and the same few strings keep coming back.
    private struct TextLine {
        let line: CTLine
        let size: CGSize
        /// The room below the baseline in whole points, as AppKit rounds it when it draws a string, and which
        /// the positions of every style were tuned against pixel by pixel.
        let descent: CGFloat
        /// How far that rounding moves the baseline.
        let baselineShift: CGFloat
    }

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
    }

    /// A symbol and where its ink lies, kept with its pixels. Making an `NSImage` from a symbol and drawing it costs
    /// about 2M instructions, against some 10K for drawing the same pixels from a bitmap, and these never change.
    /// The image itself is let go, because it holds on to the symbol's vector data.
    private final class Symbol {
        let key: SymbolKey
        let size: CGSize
        let ink: CGRect
        private var bitmap: CGImage?
        private var bitmapScale: CGFloat

        init(key: SymbolKey, image: NSImage, scale: CGFloat) {
            self.key = key
            size = image.size
            ink = StatusLabelRenderer.measureInk(of: image)
            bitmap = StatusLabelRenderer.makeBitmap(of: image, scale: scale)
            bitmapScale = scale
        }

        func bitmap(scale: CGFloat) -> CGImage? {
            if bitmapScale != scale, let image = StatusLabelRenderer.makeImage(key) {
                bitmapScale = scale
                bitmap = StatusLabelRenderer.makeBitmap(of: image, scale: scale)
            }
            return bitmap
        }
    }

    /// Everything here can be made again. With nothing in the menu bar, none of it should stay in memory.
    static func releaseCaches() {
        symbols = [:]
        textLines = [:]
    }

    private static func roundedFont(size: CGFloat) -> NSFont {
        let plain = NSFont.systemFont(ofSize: size, weight: .semibold)
        return plain.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? plain
    }

    private static func textLine(_ string: String, _ style: TextStyle) -> TextLine {
        let key = TextKey(string: string, style: style)
        if let known = textLines[key] { return known }
        let text = attributedText(string, style)
        let line = CTLineCreateWithAttributedString(text)
        var descent: CGFloat = 0
        // The width AppKit would measure, to the last digit. Measuring through AppKit was a third of the cost of a
        // new string, which the network rates are on every tick. Height depends on the fonts, so once per style.
        let width = CTLineGetTypographicBounds(line, nil, &descent, nil)
        let height: CGFloat
        if let known = textHeights[style] {
            height = known
        } else {
            height = text.size().height
            textHeights[style] = height
        }
        let made = TextLine(
            line: line, size: CGSize(width: width, height: height), descent: ceil(descent),
            baselineShift: ceil(descent) - descent)
        if textLines.count >= textLineLimit { textLines.removeAll(keepingCapacity: true) }
        textLines[key] = made
        return made
    }

    private static func attributedText(_ string: String, _ style: TextStyle) -> NSAttributedString {
        switch style {
        case .caption: text(string, captionFont)
        case .stackedValue: valueText(string, font: stackedValueFont, percentFont: stackedPercentFont)
        case .plainValue: valueText(string, font: valueFont, percentFont: valuePercentFont)
        case .rate: text(string, rateFont)
        case .ring: text(string, ringFont)
        case .tightRing: text(string, tightRingFont)
        }
    }

    private static func text(_ string: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    /// A value whose percent sign is smaller than its digits, which saves width and is easier on the eye.
    private static func valueText(_ string: String, font: NSFont, percentFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text(string, font))
        if string.hasSuffix("%") {
            result.addAttribute(.font, value: percentFont, range: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static func textWidth(_ string: String, _ style: TextStyle) -> CGFloat {
        textLine(string, style).size.width
    }

    private static func symbolWidth(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        symbol(name, pointSize: pointSize, weight: weight)?.ink.width ?? 0
    }

    static func width(of content: StatusLabelContent) -> CGFloat {
        let small = smallIconPointSize
        let width: CGFloat =
            switch content.layout {
            case .stacked(let caption, let value, _):
                max(textWidth(caption, .caption), textWidth(value, .stackedValue))
            case .icon(let symbol, let value):
                symbolWidth(symbol, pointSize: small) + iconSpacing + textWidth(value, .plainValue)
            case .value(let value):
                textWidth(value, .plainValue)
            case .rates(let up, let down):
                rateArrowWidth + arrowSpacing + max(textWidth(up, .rate), textWidth(down, .rate))
            case .symbol(let symbol), .filledSymbol(let symbol, _):
                symbolWidth(symbol, pointSize: iconPointSize)
            case .arrows:
                symbolWidth("arrow.up", pointSize: small) + symbolWidth("arrow.down", pointSize: small)
            case .ring, .dualRing:
                ringDiameter
            case .ringValue:
                valueRingDiameter
            case .column(let symbol, _):
                symbolWidth(symbol, pointSize: small) + iconSpacing + columnSize.width
            case .dualColumn:
                columnSize.width * 2 + dualColumnSpacing + iconSpacing + symbolWidth(networkSymbol, pointSize: small)
            case .signal(let symbol, _):
                symbolWidth(symbol, pointSize: small) + iconSpacing + signalWidth
            case .line(let symbol, _):
                symbolWidth(symbol, pointSize: small) + iconSpacing + chartSize.width
            case .dualLine:
                symbolWidth(networkSymbol, pointSize: small) + iconSpacing + chartSize.width
            case .bars(let symbol, _):
                symbolWidth(symbol, pointSize: small) + iconSpacing + historyWidth
            case .captionBar(let caption, _, _), .dualBar(let caption, _, _, _):
                max(textWidth(caption, .caption), captionBarWidth)
            case .battery:
                BatteryGlyph.width
            case .batterySide(_, let value):
                textWidth(value, .plainValue) + iconSpacing + BatteryGlyph.width
            }
        return ceil(width)
    }

    private static var rateArrowWidth: CGFloat {
        max(
            symbolWidth("arrow.up", pointSize: rateArrowPointSize, weight: .semibold),
            symbolWidth("arrow.down", pointSize: rateArrowPointSize, weight: .semibold))
    }

    private static var signalWidth: CGFloat {
        CGFloat(signalHeights.count) * signalBarWidth + CGFloat(signalHeights.count - 1) * signalSpacing
    }

    private static var historyWidth: CGFloat {
        CGFloat(historyBars) * historyBarWidth + CGFloat(historyBars - 1) * historyBarSpacing
    }

    static func render(
        _ content: StatusLabelContent, size: CGSize, scale: CGFloat, accentColor: CGColor?
    ) -> StatusLabelBitmaps {
        Self.scale = scale
        var bitmaps = StatusLabelBitmaps()
        bitmaps.mask = maskBitmap(size: size, scale: scale) { draw(content.layout, in: $0, size: size) }
        if let accentColor {
            bitmaps.colored = bitmap(size: size, scale: scale) { context in
                switch content.layout {
                case .battery(let glyph):
                    glyph.drawColored(in: context, x: 0, height: size.height, color: accentColor)
                case .batterySide(let glyph, _):
                    glyph.drawColored(
                        in: context, x: pixelAligned(size.width - BatteryGlyph.width), height: size.height,
                        color: accentColor)
                default:
                    break
                }
            }
        }
        return bitmaps
    }

    /// A mask only has an alpha channel to speak of, so that is all it stores. It takes a quarter of the memory, and
    /// spares Core Animation matching the colours of pixels that have none.
    private static func maskBitmap(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }

    private static func bitmap(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        guard let colorSpace,
            let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }

    private static func draw(_ layout: StatusLabelContent.Layout, in context: CGContext, size: CGSize) {
        let small = smallIconPointSize
        let middle = size.height / 2
        switch layout {
        case .stacked(let caption, let value, let alignment):
            let lower = stackedLowerBaseline + (size.height - 22) / 2
            drawAligned(
                textLine(caption, .caption), baseline: lower + stackedBaselineGap, alignment: alignment,
                width: size.width, in: context)
            drawAligned(
                textLine(value, .stackedValue), baseline: lower, alignment: alignment, width: size.width, in: context)
        case .icon(let symbol, let value):
            let x = drawSymbol(symbol, pointSize: small, x: 0, middle: middle, in: context)
            draw(textLine(value, .plainValue), x: x + iconSpacing, baseline: singleBaseline(size), in: context)
        case .value(let value):
            let label = textLine(value, .plainValue)
            draw(label, x: size.width - label.size.width, baseline: singleBaseline(size), in: context)
        case .rates(let up, let down):
            let lower = ratesLowerBaseline + (size.height - 22) / 2
            drawRate(arrow: "arrow.up", value: up, size: size, baseline: lower + ratesBaselineGap, in: context)
            drawRate(arrow: "arrow.down", value: down, size: size, baseline: lower, in: context)
        case .symbol(let symbol):
            drawSymbol(symbol, pointSize: iconPointSize, x: 0, middle: middle, in: context)
        case .filledSymbol(let symbol, let level):
            drawFilling(symbol, level: level, in: context, middle: middle)
        case .arrows(let up, let down):
            let x = drawSymbol("arrow.up", pointSize: small, x: 0, middle: middle, alpha: arrowAlpha(up), in: context)
            drawSymbol("arrow.down", pointSize: small, x: x, middle: middle, alpha: arrowAlpha(down), in: context)
        case .ring(let symbol, let level):
            let center = CGPoint(x: ringDiameter / 2, y: middle)
            drawRing(level: level, center: center, diameter: ringDiameter, stroke: ringStroke, in: context)
            drawCentredSymbol(symbol, at: center, in: context)
        case .ringValue(let value, let level):
            let center = CGPoint(x: valueRingDiameter / 2, y: middle)
            drawRing(level: level, center: center, diameter: valueRingDiameter, stroke: valueRingStroke, in: context)
            let label = textLine(value, value.count > 2 ? .tightRing : .ring)
            let bottom = pixelAligned(center.y - label.size.height / 2)
            draw(
                label, x: center.x - label.size.width / 2, baseline: bottom + label.descent - label.baselineShift,
                in: context)
        case .dualRing(let up, let down):
            let center = CGPoint(x: ringDiameter / 2, y: middle)
            drawDualRing(up: up, down: down, center: center, in: context)
            drawCentredSymbol(networkSymbol, at: center, in: context)
        case .column(let symbol, let level):
            let x = drawSymbol(symbol, pointSize: small, x: 0, middle: middle, in: context)
            drawColumn(level: level, x: x + iconSpacing, middle: middle, in: context)
        case .dualColumn(let up, let down):
            let x = drawSymbol(networkSymbol, pointSize: small, x: 0, middle: middle, in: context) + iconSpacing
            drawColumn(level: up, x: x, middle: middle, in: context)
            drawColumn(level: down, x: x + columnSize.width + dualColumnSpacing, middle: middle, in: context)
        case .signal(let symbol, let level):
            let x = drawSymbol(symbol, pointSize: small, x: 0, middle: middle, in: context)
            drawSignal(level: level, x: x + iconSpacing, middle: middle, in: context)
        case .line(let symbol, let values):
            let x = drawSymbol(symbol, pointSize: small, x: 0, middle: middle, in: context) + iconSpacing
            drawChart(values, x: x, middle: middle, showsArea: true, alpha: 1, in: context)
        case .dualLine(let up, let down):
            let x = drawSymbol(networkSymbol, pointSize: small, x: 0, middle: middle, in: context) + iconSpacing
            drawChart(up, x: x, middle: middle, showsArea: false, alpha: secondaryLineAlpha, in: context)
            drawChart(down, x: x, middle: middle, showsArea: true, alpha: 1, in: context)
        case .bars(let symbol, let values):
            let x = drawSymbol(symbol, pointSize: small, x: 0, middle: middle, in: context) + iconSpacing
            drawHistoryBars(values, x: x, middle: middle, in: context)
        case .captionBar(let caption, let level, let alignment):
            let lower = stackedLowerBaseline + (size.height - 22) / 2
            drawAligned(
                textLine(caption, .caption), baseline: lower + stackedBaselineGap, alignment: alignment,
                width: size.width, in: context)
            let bottom = captionBarBottom + (size.height - 22) / 2
            drawBar(
                level: level, rect: CGRect(x: 0, y: bottom, width: size.width, height: captionBarHeight), in: context)
        case .dualBar(let caption, let up, let down, let alignment):
            let lower = stackedLowerBaseline + (size.height - 22) / 2
            drawAligned(
                textLine(caption, .caption), baseline: lower + stackedBaselineGap, alignment: alignment,
                width: size.width, in: context)
            let bottom = captionBarBottom + (size.height - 22) / 2
            drawBar(
                level: up, rect: CGRect(x: 0, y: bottom + dualBarHeight + 1, width: size.width, height: dualBarHeight),
                in: context)
            drawBar(level: down, rect: CGRect(x: 0, y: bottom, width: size.width, height: dualBarHeight), in: context)
        case .battery(let glyph):
            glyph.drawPrimary(in: context, x: 0, height: size.height)
        case .batterySide(let glyph, let value):
            draw(textLine(value, .plainValue), x: 0, baseline: singleBaseline(size), in: context)
            glyph.drawPrimary(in: context, x: pixelAligned(size.width - BatteryGlyph.width), height: size.height)
        }
    }

    private static func singleBaseline(_ size: CGSize) -> CGFloat {
        valueBaseline + (size.height - 22) / 2
    }

    /// Moves a coordinate onto the screen's pixel grid, so that straight edges stay sharp.
    private static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private static func draw(_ text: TextLine, x: CGFloat, baseline: CGFloat, in context: CGContext) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline + text.baselineShift)
        CTLineDraw(text.line, context)
    }

    private static func drawAligned(
        _ text: TextLine, baseline: CGFloat, alignment: CaptionAlignment, width: CGFloat, in context: CGContext
    ) {
        let x: CGFloat =
            switch alignment {
            case .left: 0
            case .center: (width - text.size.width) / 2
            case .right: width - text.size.width
            }
        draw(text, x: x, baseline: baseline, in: context)
    }

    private static func drawRate(
        arrow: String, value: String, size: CGSize, baseline: CGFloat, in context: CGContext
    ) {
        let arrowMiddle = baseline + rateFont.capHeight / 2
        drawSymbol(arrow, pointSize: rateArrowPointSize, x: 0, middle: arrowMiddle, weight: .semibold, in: context)
        let label = textLine(value, .rate)
        draw(label, x: size.width - label.size.width, baseline: baseline, in: context)
    }

    /// Draws a symbol centred on `middle`, and returns where its right edge ended up.
    @discardableResult
    private static func drawSymbol(
        _ name: String, pointSize: CGFloat, x: CGFloat, middle: CGFloat, alpha: CGFloat = 1,
        weight: NSFont.Weight = .regular, in context: CGContext
    ) -> CGFloat {
        guard let symbol = symbol(name, pointSize: pointSize, weight: weight) else { return x }
        let origin = CGPoint(x: pixelAligned(x - symbol.ink.minX), y: pixelAligned(middle - symbol.ink.midY))
        draw(symbol, at: origin, alpha: alpha, in: context)
        return pixelAligned(x + symbol.ink.width)
    }

    /// Draws a symbol's pixels with its image's origin at a point that lies on the pixel grid.
    private static func draw(_ symbol: Symbol, at origin: CGPoint, alpha: CGFloat = 1, in context: CGContext) {
        guard let bitmap = symbol.bitmap(scale: scale) else { return }
        let rect = CGRect(
            x: origin.x - symbolMargin, y: origin.y - symbolMargin, width: CGFloat(bitmap.width) / scale,
            height: CGFloat(bitmap.height) / scale)
        guard alpha < 1 else {
            context.draw(bitmap, in: rect)
            return
        }
        context.saveGState()
        context.setAlpha(alpha)
        context.draw(bitmap, in: rect)
        context.restoreGState()
    }

    private static func makeBitmap(of image: NSImage, scale: CGFloat) -> CGImage? {
        let size = image.size
        let canvas = CGSize(width: ceil(size.width) + symbolMargin * 2, height: ceil(size.height) + symbolMargin * 2)
        return bitmap(size: canvas, scale: scale) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: symbolMargin, y: symbolMargin, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where a symbol's ink lies relative to its image, measured from its pixels. Each symbol has different room
    /// around its glyph, some spill out of their image, and even `alignmentRect` is a pixel off, so icons would
    /// neither line up with each other nor sit tight in their item without this.
    private static func measureInk(of image: NSImage) -> CGRect {
        let size = image.size
        let scale: CGFloat = 4
        let margin = symbolMargin
        let width = Int(((size.width + margin * 2) * scale).rounded(.up))
        let height = Int(((size.height + margin * 2) * scale).rounded(.up))
        guard let colorSpace,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { return CGRect(origin: .zero, size: size) }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var top = height
        var bottom = -1
        var left = width
        var right = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 96 {
                top = min(top, y)
                bottom = max(bottom, y)
                left = min(left, x)
                right = max(right, x)
            }
        }
        guard bottom >= 0 else { return CGRect(origin: .zero, size: size) }
        // The bitmap's first row is the top of the canvas.
        return CGRect(
            x: CGFloat(left) / scale - margin, y: CGFloat(height) / scale - CGFloat(bottom + 1) / scale - margin,
            width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> Symbol? {
        let key = SymbolKey(name: name, pointSize: pointSize, weight: weight.rawValue)
        if let known = symbols[key] { return known }
        let symbol = makeImage(key).map { Symbol(key: key, image: $0, scale: scale) }
        // Remembered even when missing, because a symbol this system lacks will not appear by asking again.
        symbols[key] = .some(symbol)
        return symbol
    }

    private static func makeImage(_ key: SymbolKey) -> NSImage? {
        NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: NSFont.Weight(key.weight)))
    }

    private static func drawCentredSymbol(_ name: String, at center: CGPoint, in context: CGContext) {
        guard let symbol = symbol(name, pointSize: ringIconPointSize, weight: .semibold) else { return }
        let origin = CGPoint(x: pixelAligned(center.x - symbol.ink.midX), y: pixelAligned(center.y - symbol.ink.midY))
        draw(symbol, at: origin, in: context)
    }

    /// The symbol stays faintly visible and solidly fills from the bottom up, as the battery does sideways.
    private static func drawFilling(_ name: String, level: Double, in context: CGContext, middle: CGFloat) {
        guard let symbol = symbol(name, pointSize: iconPointSize) else { return }
        let ink = symbol.ink
        let origin = CGPoint(x: pixelAligned(-ink.minX), y: pixelAligned(middle - ink.midY))
        draw(symbol, at: origin, alpha: trackAlpha, in: context)
        // Measured on the glyph itself, because the image has room around it that would read as extra charge.
        context.saveGState()
        context.clip(
            to: CGRect(
                x: origin.x, y: origin.y + ink.minY, width: symbol.size.width, height: ink.height * CGFloat(level)))
        draw(symbol, at: origin, in: context)
        context.restoreGState()
    }

    private static func arrowAlpha(_ level: Double) -> CGFloat {
        trackAlpha + (1 - trackAlpha) * CGFloat(level)
    }

    private static func drawRing(
        level: Double, center: CGPoint, diameter: CGFloat, stroke: CGFloat, in context: CGContext
    ) {
        let radius = (diameter - stroke) / 2
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setStrokeColor(gray: 0, alpha: trackAlpha)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()
        guard level > 0 else { return }
        context.setStrokeColor(gray: 0, alpha: 1)
        context.addArc(
            center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * CGFloat(level),
            clockwise: true)
        context.strokePath()
    }

    /// Upload rises on the left and download on the right, both from the bottom.
    private static func drawDualRing(up: Double, down: Double, center: CGPoint, in context: CGContext) {
        let radius = (ringDiameter - ringStroke) / 2
        context.setLineWidth(ringStroke)
        context.setLineCap(.round)
        context.setStrokeColor(gray: 0, alpha: trackAlpha)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()
        context.setStrokeColor(gray: 0, alpha: 1)
        if up > 0 {
            context.addArc(
                center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 - .pi * CGFloat(up),
                clockwise: true)
            context.strokePath()
        }
        if down > 0 {
            context.addArc(
                center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * CGFloat(down),
                clockwise: false)
            context.strokePath()
        }
    }

    private static func drawColumn(level: Double, x: CGFloat, middle: CGFloat, in context: CGContext) {
        let rect = CGRect(
            x: x, y: middle - columnSize.height / 2, width: columnSize.width, height: columnSize.height)
        let path = continuousRoundedRect(rect, radius: columnRadius)
        context.setFillColor(gray: 0, alpha: trackAlpha)
        context.addPath(path)
        context.fillPath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * CGFloat(level)))
        context.restoreGState()
    }

    /// Rising bars like the cellular signal on an iPhone, lit from the left as the load grows.
    static func signalStep(_ level: Double) -> Double {
        (level * Double(signalHeights.count)).rounded(.up) / Double(signalHeights.count)
    }

    private static func drawSignal(level: Double, x: CGFloat, middle: CGFloat, in context: CGContext) {
        let lit = Int((level * Double(signalHeights.count)).rounded(.up))
        let bottom = middle - (signalHeights.last ?? 0) / 2
        for (index, height) in signalHeights.enumerated() {
            let rect = CGRect(
                x: x + CGFloat(index) * (signalBarWidth + signalSpacing), y: bottom, width: signalBarWidth,
                height: height)
            context.setFillColor(gray: 0, alpha: index < lit ? 1 : trackAlpha)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.fillPath()
        }
    }

    private static func drawChart(
        _ values: [Float], x: CGFloat, middle: CGFloat, showsArea: Bool, alpha: CGFloat, in context: CGContext
    ) {
        let bottom = middle - chartSize.height / 2
        let step = chartSize.width / CGFloat(historySlots - 1)
        let right = x + chartSize.width
        func point(_ index: Int) -> CGPoint {
            CGPoint(
                x: right - CGFloat(values.count - 1 - index) * step,
                y: bottom + chartSize.height * CGFloat(values[index]))
        }
        // A thin baseline keeps the chart readable until it has data, and at rest.
        context.setFillColor(gray: 0, alpha: trackAlpha)
        context.fill(CGRect(x: x, y: bottom, width: chartSize.width, height: 1))
        guard values.count > 1 else { return }
        let line = CGMutablePath()
        line.addLines(between: values.indices.map(point))
        if showsArea {
            let area = CGMutablePath()
            area.addPath(line)
            area.addLine(to: CGPoint(x: right, y: bottom))
            area.addLine(to: CGPoint(x: point(0).x, y: bottom))
            area.closeSubpath()
            context.setFillColor(gray: 0, alpha: chartAreaAlpha)
            context.addPath(area)
            context.fillPath()
        }
        context.setStrokeColor(gray: 0, alpha: alpha)
        context.setLineWidth(chartLineWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(line)
        context.strokePath()
    }

    private static func drawHistoryBars(_ values: [Float], x: CGFloat, middle: CGFloat, in context: CGContext) {
        let bottom = middle - chartSize.height / 2
        let recent = values.suffix(historyBars)
        let start = historyBars - recent.count
        for slot in 0..<historyBars {
            let isEmpty = slot < start
            let value = isEmpty ? 0 : CGFloat(recent[recent.startIndex + slot - start])
            let bar = CGRect(
                x: x + CGFloat(slot) * (historyBarWidth + historyBarSpacing), y: bottom, width: historyBarWidth,
                height: max(chartSize.height * value, historyBarMinimum))
            let radius = min(0.75, bar.height / 2)
            context.setFillColor(gray: 0, alpha: isEmpty ? trackAlpha : 1)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
    }

    private static func drawBar(level: Double, rect: CGRect, in context: CGContext) {
        let radius = rect.height / 2
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setFillColor(gray: 0, alpha: trackAlpha)
        context.addPath(path)
        context.fillPath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(level), height: rect.height))
        context.restoreGState()
    }
}

/// Shows a label by swapping the contents of a layer, without any AppKit view display pass.
///
/// This is the app's hottest visible path. Measured at one update per second on macOS 27.2, setting
/// `button.image` or redrawing a subview costs about 20M instructions and 9 wakeups per second, and an
/// `NSTextField` subview costs 27 % CPU. This approach costs 1.5M instructions and 1 wakeup per second.
final class StatusLabelView: NSView {
    private static let noAnimation: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
    ]

    private let tintLayer = CALayer()
    private let maskLayer = CALayer()
    /// Exists only while the label has colours of its own.
    private var coloredLayer: CALayer?
    private var content: StatusLabelContent?
    private var renderedSize: CGSize = .zero
    private var canvas: CGRect = .zero
    /// How far past its bounds this label can reach before its item's window cuts it off.
    var overflowRoom: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        tintLayer.actions = Self.noAnimation
        maskLayer.actions = Self.noAnimation
        tintLayer.mask = maskLayer
        layer?.addSublayer(tintLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks must reach the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ content: StatusLabelContent) {
        guard content != self.content else { return }
        // What VoiceOver reads is not drawn, and the plain symbol style draws no value, so this is often all that moved.
        let looksTheSame = content.layout == self.content?.layout && content.accent == self.content?.accent
        self.content = content
        if !looksTheSame { renderContent() }
    }

    override func layout() {
        super.layout()
        if bounds.size != renderedSize { renderContent() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An item being removed leaves its window, and drawing it then would be thrown away.
        guard window != nil else { return }
        updateTint()
        renderContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
        if content?.accent != nil { renderContent() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderContent()
    }

    #if TWEAKLY_AUTOMATION
        private(set) var renderCount = 0
        var automationDescription: String {
            let image = maskLayer.contents != nil
            return
                "label=\(frame.size) layer=\(tintLayer.frame.size) image=\(image) tint=\(tintLayer.backgroundColor != nil) renders=\(renderCount)"
        }
    #endif

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintLayer.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    private func renderContent() {
        guard let content, bounds.width > 0, bounds.height > 0 else { return }
        #if TWEAKLY_AUTOMATION
            renderCount += 1
        #endif
        let scale = window?.backingScaleFactor ?? 2
        renderedSize = bounds.size
        let newCanvas = canvasFrame(for: content)
        if newCanvas != canvas {
            canvas = newCanvas
            tintLayer.frame = newCanvas
            maskLayer.frame = tintLayer.bounds
            coloredLayer?.frame = newCanvas
        }
        var accentColor: CGColor?
        if let accent = content.accent {
            effectiveAppearance.performAsCurrentDrawingAppearance { accentColor = accent.color.cgColor }
        }
        let bitmaps = StatusLabelRenderer.render(content, size: canvas.size, scale: scale, accentColor: accentColor)
        if maskLayer.contentsScale != scale { maskLayer.contentsScale = scale }
        maskLayer.contents = bitmaps.mask
        if let colored = bitmaps.colored {
            showColored(colored, scale: scale)
        } else if let coloredLayer {
            coloredLayer.removeFromSuperlayer()
            self.coloredLayer = nil
        }
    }

    private func canvasFrame(for content: StatusLabelContent) -> CGRect {
        Self.canvasFrame(for: content, in: bounds.size, overflowRoom: overflowRoom)
    }

    /// The item keeps one width, and a wider value reaches into the free space the system leaves around it, on the
    /// side away from where its name lines up. What would be cut off on one side goes to the other.
    static func canvasFrame(for content: StatusLabelContent, in size: CGSize, overflowRoom: CGFloat) -> CGRect {
        let width = max(size.width, StatusLabelRenderer.width(of: content))
        let extra = width - size.width
        let wanted: CGFloat =
            switch content.overflowAlignment {
            case .left: 0
            case .center: extra / 2
            case .right: extra
            }
        let left = min(max(wanted, extra - overflowRoom), overflowRoom).rounded(.down)
        return CGRect(x: -left, y: 0, width: width, height: size.height)
    }

    private func showColored(_ image: CGImage, scale: CGFloat) {
        if coloredLayer == nil {
            let created = CALayer()
            created.actions = Self.noAnimation
            created.frame = canvas
            layer?.addSublayer(created)
            coloredLayer = created
        }
        coloredLayer?.contentsScale = scale
        coloredLayer?.contents = image
    }
}
