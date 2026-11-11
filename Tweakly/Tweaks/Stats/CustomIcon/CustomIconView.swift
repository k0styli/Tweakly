import AppKit
import CustomIconCore

/// A custom icon, in the menu bar and in the settings alike, so that a preview cannot differ from the real thing.
///
/// The frames play on the render server as a keyframe animation. The app is not woken for them: on macOS 27.2 with 12
/// frames a second it stayed at 0.02 % CPU and under 1 wakeup a second, against 0.3 % and 12 to 15 with a timer swapping
/// the same frames, and `MenuBarAgent` did not notice either.
final class CustomIconView: NSView {
    private static let noAnimation: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
    ]
    private static let animationKey = "frames"
    /// More than a display needs to show the fastest icon, and a limit on how often the render server has to look.
    private static let highestFrameRate: Float = 30
    private static let lowestFrameRate: Float = 1
    /// What shows of an icon where it is not filled. The same as the filled symbols of the menu bar's other items.
    private static let emptyOpacity: CGFloat = 0.3
    /// As long as the simple view's rings take to move.
    private static let fillSeconds: CFTimeInterval = 0.35

    private let tintLayer = CALayer()
    private let imageLayer = CALayer()
    private var icon: LoadedIcon?
    private(set) var usesOwnColours = false
    private(set) var speed: Double?
    private(set) var fillLevel: Double?
    /// The full-strength part of a filling icon, growing from the bottom edge. There is only one image layer, playing the
    /// frames, so that the two cannot drift apart: a tinted icon has this among the layers its mask cuts out, and one in
    /// its own colours has this inside a mask of its own. It exists only while the icon fills.
    private var levelLayer: CALayer?
    private var levelMask: CALayer?

    var shownIcon: LoadedIcon? { icon }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        tintLayer.actions = Self.noAnimation
        imageLayer.actions = Self.noAnimation
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = CGFloat(IconFit.pixelsPerPoint)
        imageLayer.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks must reach the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        placeLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    func show(_ icon: LoadedIcon, usesOwnColours: Bool) {
        stop()
        self.icon = icon
        self.usesOwnColours = usesOwnColours
        tintLayer.removeFromSuperlayer()
        imageLayer.removeFromSuperlayer()
        tintLayer.mask = nil
        if usesOwnColours {
            layer?.addSublayer(imageLayer)
        } else {
            tintLayer.mask = imageLayer
            layer?.addSublayer(tintLayer)
            updateTint()
        }
        imageLayer.contents = icon.frames.first
        removeFillLayers()
        applyFillLayers()
        placeLayers()
    }

    /// How full the icon looks from the bottom up, from 0 to 1, or nil for the whole of it as usual. The change plays on
    /// the render server, like the frames.
    func setFill(_ level: Double?, animated: Bool) {
        guard level != fillLevel else { return }
        fillLevel = level
        guard level != nil else {
            removeFillLayers()
            return
        }
        let isNew = levelLayer == nil
        applyFillLayers()
        placeFill(animated: animated && !isNew)
    }

    /// Starts playing, or moves to this speed without a jump if it already is.
    func play(speed newSpeed: Double) {
        guard let icon, icon.manifest.isAnimated else { return }
        guard let speed else {
            start(icon, speed: newSpeed)
            return
        }
        guard speed != newSpeed else { return }
        self.speed = newSpeed
        // A layer's time runs from a point at its own speed. Moving that point to now keeps the frame it is on.
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.timeOffset = imageLayer.convertTime(now, from: nil)
        imageLayer.beginTime = now
        imageLayer.speed = Float(newSpeed)
        CATransaction.commit()
    }

    /// Back to the first frame, with nothing left playing.
    func stop() {
        guard speed != nil else { return }
        speed = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAnimation(forKey: Self.animationKey)
        imageLayer.speed = 1
        imageLayer.timeOffset = 0
        imageLayer.beginTime = 0
        imageLayer.contents = icon?.frames.first
        CATransaction.commit()
    }

    private func start(_ icon: LoadedIcon, speed newSpeed: Double) {
        speed = newSpeed
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = icon.frames
        animation.calculationMode = .discrete
        animation.duration = icon.manifest.cycleSeconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: Self.lowestFrameRate, maximum: Self.highestFrameRate,
            preferred: IconFit.preferredFrameRate(
                frameCount: icon.manifest.frameCount, cycleSeconds: icon.manifest.cycleSeconds,
                fastestSpeed: IconMotion.speeds.upperBound, within: Self.lowestFrameRate...Self.highestFrameRate))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.speed = Float(newSpeed)
        imageLayer.timeOffset = 0
        imageLayer.beginTime = 0
        imageLayer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            tintLayer.backgroundColor =
                (levelLayer == nil ? label : label.withAlphaComponent(Self.emptyOpacity)).cgColor
            if !usesOwnColours { levelLayer?.backgroundColor = label.cgColor }
        }
    }

    /// Makes what is missing for the current level.
    private func applyFillLayers() {
        guard fillLevel != nil, levelLayer == nil, icon != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let level = CALayer()
        // Its colour changes with the appearance at once, as the rest of the icon's does; only its height moves.
        level.actions = ["backgroundColor": NSNull()]
        levelLayer = level
        if usesOwnColours {
            // A mask counts only by how opaque it is, so these two say how much of the picture shows.
            let mask = CALayer()
            mask.actions = Self.noAnimation
            mask.backgroundColor = CGColor(gray: 1, alpha: Self.emptyOpacity)
            level.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.addSublayer(level)
            imageLayer.mask = mask
            levelMask = mask
        } else {
            tintLayer.addSublayer(level)
        }
        updateTint()
        CATransaction.commit()
    }

    private func removeFillLayers() {
        guard levelLayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelLayer?.removeFromSuperlayer()
        levelLayer = nil
        levelMask = nil
        imageLayer.mask = nil
        updateTint()
        CATransaction.commit()
    }

    /// The level grows from the icon's bottom edge, on whole pixels.
    private func placeFill(animated: Bool) {
        guard let levelLayer, let fillLevel else { return }
        let size = imageLayer.bounds.size
        let scale = CGFloat(IconFit.pixelsPerPoint)
        let height = (size.height * fillLevel * scale).rounded() / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelMask?.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Self.fillSeconds)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        levelLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
        CATransaction.commit()
    }

    /// In the middle of the view, on whole pixels, so that a frame's pixels land on the display's.
    private func placeLayers() {
        guard let manifest = icon?.manifest else { return }
        let width = CGFloat(manifest.frameWidth) / CGFloat(IconFit.pixelsPerPoint)
        let height = CGFloat(manifest.frameHeight) / CGFloat(IconFit.pixelsPerPoint)
        let x = ((bounds.width - width) / 2 * 2).rounded() / 2
        let y = ((bounds.height - height) / 2 * 2).rounded() / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if usesOwnColours {
            imageLayer.frame = frame
        } else {
            tintLayer.frame = frame
            imageLayer.frame = tintLayer.bounds
        }
        CATransaction.commit()
        placeFill(animated: false)
    }
}

extension LoadedIcon {
    static let gearID = "gear"

    /// The app's gear as frames, for when it has to fill, trimmed to what it draws so that empty and full mean what they
    /// say. Made on first use. Otherwise the gear stays a template image in the button, which costs nothing.
    static let gear: LoadedIcon? = {
        guard let image = NSImage(named: "MenuBarIcon"), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let width = Int(image.size.width) * IconFit.pixelsPerPoint
        let height = Int(image.size.height) * IconFit.pixelsPerPoint
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }
        guard let box = IconPixels(bytes: bytes, width: width, height: height).contentBox,
            let frame = drawn?.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
        else { return nil }
        let manifest = IconManifest(
            id: gearID, name: "", frameCount: 1, frameWidth: box.width, frameHeight: box.height, cycleSeconds: 1,
            hasColours: false, added: .distantPast)
        return LoadedIcon(manifest: manifest, frames: [frame])
    }()
}
