import AppKit

/// A colour that carries meaning in a menu bar label, drawn above the label's own tint.
enum StatusAccent: Equatable {
    case green, red, yellow

    var color: NSColor {
        switch self {
        case .green: .systemGreen
        case .red: .systemRed
        case .yellow: .systemYellow
        }
    }
}

/// The battery from the iOS 27 status bar: no outline, a translucent body and a solid fill, with the charge shown
/// as a number. No system symbol looks like this, because `battery.100percent` keeps the older outline and only
/// has whole quarters. The shape and every state were taken from iOS 27.0 itself.
///
/// The fill follows iOS, in order of priority: yellow in Low Power Mode, red at 20 % or less even while charging,
/// green while charging or full on power, and otherwise the label's colour.
///
/// The number and its bolt differ from iOS on purpose: they are cut through the whole shape in every
/// state, where iOS has them solid over a coloured fill. That needs the pale body throughout to stay readable.
/// Without a number the icon is as iOS draws it, with a darker body behind green and red.
///
/// The person can also turn colour off while on power, leaving the bolt to say that it is charging.
struct BatteryGlyph: Equatable {
    private static let lowPercent = 20
    // As tall as the system's own battery in the menu bar, and sized to land on whole pixels.
    private static let bodyHeight: CGFloat = 14
    private static let bodyWidth: CGFloat = 27
    private static let cornerRadius: CGFloat = 4.4
    private static let nubGap: CGFloat = 0.5
    private static let nubWidth: CGFloat = 2
    private static let nubHeight: CGFloat = 5
    private static let paleBodyAlpha: CGFloat = 0.56
    private static let darkBodyAlpha: CGFloat = 0.36
    /// Close to iOS's proportion, and leaves the same number of pixels above and below the digits at 2x.
    private static let digitSize: CGFloat = 12.4
    private static let digitMargin: CGFloat = 1.2
    /// Beside the bolt the digits keep their height and get narrower and bolder, which leaves room around it. These
    /// come from the battery view of iOS 27.0: the bolt's height to the digits' is 1.066, its width to its height is
    /// 0.634, and between the two is about 1 pt. Its font is narrower by a width trait the Mac's rounded system font
    /// does not offer, so the digits are scaled by what that does to them.
    private static let narrowDigitWidth: CGFloat = 0.875
    private static let smallBoltHeightToDigits: CGFloat = 1.066
    private static let smallBoltAspect: CGFloat = 0.634
    private static let smallBoltGap: CGFloat = 1.05
    /// The lightning bolt's corners, as fractions of its height from its centre and top.
    private static let boltPoints: [CGPoint] = [
        CGPoint(x: 0.143, y: -0.005), CGPoint(x: -0.335, y: 0.576), CGPoint(x: -0.038, y: 0.600),
        CGPoint(x: -0.165, y: 1.005), CGPoint(x: 0.346, y: 0.427), CGPoint(x: 0.052, y: 0.400),
    ]
    private static let boltWidthRatio: CGFloat = 0.681
    private static let boltPointsHeight: CGFloat = 1.01
    private static let boltRounding: CGFloat = 0.05
    /// The gap around the large bolt, on top of its rounding.
    private static let boltRing: CGFloat = 0.075

    static let width = bodyWidth + nubGap + nubWidth

    let percent: Int
    let isPowered: Bool
    let showsNumber: Bool
    let accent: StatusAccent?

    init(
        percent: Int, isCharging: Bool, isPluggedIn: Bool, isLowPower: Bool, showsNumber: Bool,
        colorsWhileCharging: Bool = true
    ) {
        self.percent = min(max(percent, 0), 100)
        self.showsNumber = showsNumber
        isPowered = isCharging || isPluggedIn
        accent =
            if isPowered && !colorsWhileCharging {
                nil
            } else if isLowPower {
                .yellow
            } else if percent <= Self.lowPercent {
                .red
            } else if isCharging || (isPowered && percent >= 100) {
                .green
            } else {
                nil
            }
    }

    private var isFull: Bool { percent >= 100 }
    private var bodyAlpha: CGFloat {
        !showsNumber && (accent == .green || accent == .red) ? Self.darkBodyAlpha : Self.paleBodyAlpha
    }
    /// A full battery has no room beside three digits, and iOS leaves the bolt out.
    private var showsSmallBolt: Bool { showsNumber && isPowered && !isFull }
    private var showsLargeBolt: Bool { !showsNumber && isPowered }

    /// The part in the label's own colour. Assumes a context whose origin is at the bottom left.
    func drawPrimary(in context: CGContext, x: CGFloat, height: CGFloat) {
        let body = bodyRect(x: x, height: height)
        context.setFillColor(gray: 0, alpha: bodyAlpha)
        context.addPath(continuousRoundedRect(body, radius: Self.cornerRadius))
        context.fillPath()
        context.setFillColor(gray: 0, alpha: isFull && accent == nil ? 1 : bodyAlpha)
        context.addPath(nubPath(body))
        context.fillPath()
        if accent == nil {
            context.setFillColor(gray: 0, alpha: 1)
            fillCharge(in: context, body: body)
        }
        if showsNumber {
            eraseMarks(in: context, body: body)
        } else if showsLargeBolt {
            eraseLargeBolt(in: context, body: body)
            drawSolidBolt(in: context, center: CGPoint(x: body.midX, y: body.midY), height: body.height)
        }
    }

    /// The part with colours of its own, which lies above the primary part with holes where that shows through.
    func drawColored(in context: CGContext, x: CGFloat, height: CGFloat, color: CGColor) {
        let body = bodyRect(x: x, height: height)
        context.setFillColor(color)
        fillCharge(in: context, body: body)
        if isFull {
            context.setFillColor(color)
            context.addPath(nubPath(body))
            context.fillPath()
        }
        if showsNumber {
            eraseMarks(in: context, body: body)
        } else if showsLargeBolt {
            eraseLargeBolt(in: context, body: body)
        }
    }

    private func eraseMarks(in context: CGContext, body: CGRect) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        drawMarks(in: context, body: body)
        context.restoreGState()
    }

    private func bodyRect(x: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: (height - Self.bodyHeight) / 2, width: Self.bodyWidth, height: Self.bodyHeight)
    }

    private func fillCharge(in context: CGContext, body: CGRect) {
        context.saveGState()
        context.addPath(continuousRoundedRect(body, radius: Self.cornerRadius))
        context.clip()
        context.fill(
            CGRect(x: body.minX, y: body.minY, width: body.width * CGFloat(max(percent, 2)) / 100, height: body.height))
        context.restoreGState()
    }

    private func nubPath(_ body: CGRect) -> CGPath {
        let path = CGMutablePath()
        let left = body.maxX + Self.nubGap
        let right = left + Self.nubWidth
        let top = body.midY + Self.nubHeight / 2
        let bottom = body.midY - Self.nubHeight / 2
        path.move(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addCurve(
            to: CGPoint(x: right, y: body.midY),
            control1: CGPoint(x: left + Self.nubWidth * 0.55, y: top),
            control2: CGPoint(x: right, y: body.midY + Self.nubHeight * 0.28))
        path.addCurve(
            to: CGPoint(x: left, y: bottom),
            control1: CGPoint(x: right, y: body.midY - Self.nubHeight * 0.28),
            control2: CGPoint(x: left + Self.nubWidth * 0.55, y: bottom))
        path.closeSubpath()
        return path
    }

    private func boltPath(center: CGPoint, height: CGFloat, narrowing: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        let points = Self.boltPoints.map {
            CGPoint(x: center.x + $0.x * height * narrowing, y: center.y + height / 2 - $0.y * height)
        }
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private func eraseLargeBolt(in context: CGContext, body: CGRect) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setLineJoin(.round)
        context.setLineWidth((Self.boltRounding + Self.boltRing * 2) * body.height)
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.addPath(boltPath(center: CGPoint(x: body.midX, y: body.midY), height: body.height))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private func drawSolidBolt(in context: CGContext, center: CGPoint, height: CGFloat, narrowing: CGFloat = 1) {
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineWidth(Self.boltRounding * height)
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.addPath(boltPath(center: center, height: height, narrowing: narrowing))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    /// The number, with a small bolt to its right while on power.
    private func drawMarks(in context: CGContext, body: CGRect) {
        let isNarrow = showsSmallBolt
        // Ink, including the rounding drawn around the bolt's outline.
        let digitHeight = Self.usualFont.capHeight
        let boltInkHeight = digitHeight * Self.smallBoltHeightToDigits
        let boltInkWidth = boltInkHeight * Self.smallBoltAspect
        let boltRoom = isNarrow ? boltInkWidth + Self.smallBoltGap : 0
        let size = digitSize(maxWidth: body.width - Self.digitMargin * 2 - boltRoom, isNarrow: isNarrow)
        let line = Self.line(String(percent), size: size, isNarrow: isNarrow)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // Centred by one digit rather than this number, so the digits do not jump as the charge changes.
        let reference = CTLineGetBoundsWithOptions(Self.line("0", size: size, isNarrow: isNarrow), .useGlyphPathBounds)
        let x = body.midX - (bounds.width + boltRoom) / 2 - bounds.minX
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: body.midY - reference.midY)
        CTLineDraw(line, context)
        context.restoreGState()
        if isNarrow {
            // The outline's own proportions come out wider than iOS's once rounded, and its height has rounding too.
            let extra = Self.boltPointsHeight + Self.boltRounding
            let height = boltInkHeight / extra
            let narrowing = (boltInkWidth / height - Self.boltRounding) / Self.boltWidthRatio
            let boltCentre = x + bounds.maxX + Self.smallBoltGap + boltInkWidth / 2
            drawSolidBolt(
                in: context, center: CGPoint(x: boltCentre, y: body.midY), height: height, narrowing: narrowing)
        }
    }

    private func digitSize(maxWidth: CGFloat, isNarrow: Bool) -> CGFloat {
        let width = CTLineGetBoundsWithOptions(
            Self.line(String(percent), size: Self.digitSize, isNarrow: isNarrow), .useGlyphPathBounds
        ).width
        return width > maxWidth ? Self.digitSize * maxWidth / width : Self.digitSize
    }

    private static let usualFont = font(size: digitSize)
    private static let usualNarrowFont = narrowFont(size: digitSize)

    private static func font(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let plain = NSFont.systemFont(ofSize: size, weight: weight)
        return plain.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? plain
    }

    private static func narrowFont(size: CGFloat) -> CTFont {
        var narrowing = CGAffineTransform(scaleX: narrowDigitWidth, y: 1)
        return CTFontCreateCopyWithAttributes(font(size: size, weight: .bold), size, &narrowing, nil)
    }

    private static func line(_ text: String, size: CGFloat, isNarrow: Bool = false) -> CTLine {
        let chosen: CTFont =
            if isNarrow {
                size == digitSize ? usualNarrowFont : narrowFont(size: size)
            } else {
                size == digitSize ? usualFont : font(size: size)
            }
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: chosen, .foregroundColor: NSColor.black]))
    }
}

/// A rounded rectangle whose corners ease into its sides, as Apple's own shapes do. `CGPath`'s version has plain
/// circular corners, and the only public continuous one lives on `CALayer`, which cannot be used to draw.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let radius = min(radius, min(rect.width, rect.height) / (2 * 1.528665))
    func point(_ corner: (x: CGFloat, y: CGFloat), _ along: CGFloat, _ across: CGFloat, flip: Bool) -> CGPoint {
        // `along` runs on the side leaving the corner, `across` on the side entering it.
        let a = (flip ? across : along) * radius
        let b = (flip ? along : across) * radius
        return CGPoint(
            x: corner.x == rect.minX ? rect.minX + a : rect.maxX - a,
            y: corner.y == rect.minY ? rect.minY + b : rect.maxY - b)
    }
    let corners: [(x: CGFloat, y: CGFloat)] = [
        (rect.maxX, rect.maxY), (rect.maxX, rect.minY), (rect.minX, rect.minY), (rect.minX, rect.maxY),
    ]
    let path = CGMutablePath()
    path.move(to: point((rect.minX, rect.maxY), 1.528665, 0, flip: false))
    for (index, corner) in corners.enumerated() {
        // The two halves of a corner mirror each other, and the sides alternate between level and upright.
        let flip = index % 2 != 0
        path.addLine(to: point(corner, 1.528665, 0, flip: flip))
        path.addCurve(
            to: point(corner, 0.63149379, 0.07491139, flip: flip),
            control1: point(corner, 1.08849296, 0, flip: flip),
            control2: point(corner, 0.86840694, 0, flip: flip))
        path.addCurve(
            to: point(corner, 0.07491139, 0.63149379, flip: flip),
            control1: point(corner, 0.37282392, 0.16905956, flip: flip),
            control2: point(corner, 0.16905956, 0.37282392, flip: flip))
        path.addCurve(
            to: point(corner, 0, 1.528665, flip: flip),
            control1: point(corner, 0, 0.86840694, flip: flip),
            control2: point(corner, 0, 1.08849296, flip: flip))
    }
    path.closeSubpath()
    return path
}
