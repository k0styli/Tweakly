import AppKit

/// What a tile shows: a window's picture once it comes, and a label with an icon and a name.
struct WindowTile {
    let icon: NSImage?
    let label: String
    let accessibilityLabel: String
    /// A tile for an app with no window shows its icon for good.
    let hasWindow: Bool
}

/// The corners and insets of the tiles, which follow from the glass they sit on.
struct WindowTileShape {
    let tileRadius: CGFloat
    /// Of the highlight around the tile under the pointer or the keyboard.
    let highlightInset: CGFloat
    let labelInset: CGFloat
}

/// Hosts the tiles of the Command-Tab panel and of the Dock's previews, and answers for all of them, so the mouse needs
/// one tracking area and not one per tile.
final class WindowTilesView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private let frames: [CGRect]
    private let shape: WindowTileShape
    private var tiles: [WindowTileView] = []
    private var labelViews: [WindowLabelView] = []
    private let highlight = CALayer()

    override var isFlipped: Bool { true }

    init(tiles items: [WindowTile], frames: [CGRect], shape: WindowTileShape, scale: CGFloat, willHavePictures: Bool) {
        self.frames = frames
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerCurve = .continuous
        highlight.cornerRadius = shape.tileRadius + shape.highlightInset
        // It jumps, as the system's highlight does, instead of sliding after the keyboard.
        highlight.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        highlight.isHidden = true
        layer?.addSublayer(highlight)
        updateColors()

        // Flipped, so the labels use the same top-left coordinates as the layout.
        let labels = FlippedView()
        for (item, frame) in zip(items, frames) {
            let tile = WindowTileView(
                item: item, showsIcon: !item.hasWindow || !willHavePictures, frame: frame, radius: shape.tileRadius,
                scale: scale)
            addSubview(tile)
            tiles.append(tile)
            let label = WindowLabelView(
                name: item.label, icon: item.icon, maximumWidth: frame.width - shape.labelInset * 2,
                tileHeight: frame.height)
            label.frame.origin = NSPoint(
                x: frame.minX + shape.labelInset, y: frame.maxY - shape.labelInset - WindowLabelView.height)
            labels.addSubview(label)
            labelViews.append(label)
        }
        // A single container lets the system render all the labels' glass together.
        let container = NSGlassEffectContainerView()
        container.contentView = labels
        addSubview(container)
        self.labels = (container, labels)
    }

    private var labels: (container: NSGlassEffectContainerView, view: NSView)?

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        labels?.container.frame = bounds
        labels?.view.frame = bounds
    }

    /// Nil takes the highlight away, as when the pointer leaves the Dock's panel.
    func highlight(_ index: Int?) {
        guard let index, frames.indices.contains(index) else {
            highlight.isHidden = true
            return
        }
        let inset = shape.highlightInset
        highlight.frame = frames[index].insetBy(dx: -inset, dy: -inset)
        highlight.isHidden = false
    }

    func setPicture(_ picture: SwitcherPicture, at index: Int, animated: Bool) {
        setImage(
            picture.image, labelBackdropBrightness: picture.labelBackdropBrightness, at: index, animated: animated)
    }

    func setImage(_ image: CGImage, labelBackdropBrightness: CGFloat?, at index: Int, animated: Bool) {
        guard tiles.indices.contains(index) else { return }
        tiles[index].setPicture(image, animated: animated)
        if let labelBackdropBrightness { labelViews[index].adapt(toBrightness: labelBackdropBrightness) }
    }

    func showIcon(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        tiles[index].showIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        }
    }

    // The labels' glass sits above the tiles but is not something to click on its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // Moved, rather than entered, so that a pointer just resting where the panel appears selects nothing.
    override func mouseMoved(with event: NSEvent) {
        if let index = tileIndex(at: event) { onHover?(index) }
    }

    override func mouseUp(with event: NSEvent) {
        if let index = tileIndex(at: event) { onClick?(index) }
    }

    private func tileIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(point) }
    }
}

/// A window's picture, or its app's icon for a tile that will not get one. A tile waiting for its picture stays
/// plain: the label already names the app, and decoding a large icon for those moments is what made the panel late.
private final class WindowTileView: NSView {
    private static let iconShare: CGFloat = 0.42
    /// Core Animation's own duration, which the picture had before it was set apart from a replacement.
    private static let arrivalFade: CFTimeInterval = 0.25
    private static let replacementFade: CFTimeInterval = 0.2
    private let pictureLayer = CALayer()
    private let icon: NSImage?
    private let scale: CGFloat
    private var iconLayer: CALayer?
    private var hasPicture = false

    override var wantsUpdateLayer: Bool { true }

    init(item: WindowTile, showsIcon: Bool, frame: CGRect, radius: CGFloat, scale: CGFloat) {
        self.icon = item.icon
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = radius
        layer.masksToBounds = true

        pictureLayer.frame = bounds
        pictureLayer.contentsGravity = .resize
        pictureLayer.contentsScale = scale
        layer.addSublayer(pictureLayer)
        if showsIcon { showIcon() }

        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = hasPicture ? nil : NSColor.windowBackgroundColor.cgColor
    }

    /// A picture remembered from the last time is better than the icon, so it stays.
    func showIcon() {
        guard iconLayer == nil, pictureLayer.contents == nil, let icon else { return }
        let side = (bounds.height * Self.iconShare).rounded()
        let iconLayer = CALayer()
        iconLayer.frame = CGRect(
            x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side,
            height: side)
        iconLayer.contents = icon.layerContents(forContentsScale: scale)
        iconLayer.contentsScale = scale
        iconLayer.contentsGravity = .resizeAspect
        layer?.insertSublayer(iconLayer, below: pictureLayer)
        self.iconLayer = iconLayer
    }

    func setPicture(_ image: CGImage, animated: Bool) {
        // A window much smaller than its tile keeps its own larger corners, which then show the panel and not a
        // patch of the tile. The fill goes only once the fade has covered it. Motion can be reduced in Settings.
        let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        // One dissolve of the whole layer: animated one by one, a crop that changed with the window would slide.
        CATransaction.setDisableActions(true)
        if animates {
            let fade = CATransition()
            fade.type = .fade
            // A picture kept from the last time is replaced by the same window, sharper and as it is now. The system's
            // curve does most of that at once and eases out the rest, which reads as the picture settling rather than
            // as a new one appearing, and still as quick. 0.45 s with a slow start felt too slow.
            fade.duration = pictureLayer.contents == nil ? Self.arrivalFade : Self.replacementFade
            fade.timingFunction = CAMediaTimingFunction(name: .default)
            pictureLayer.add(fade, forKey: "picture")
        }
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.hasPicture = true
                self?.needsDisplay = true
            }
        }
        pictureLayer.contents = image
        pictureLayer.contentsRect = Self.topLeftCrop(image: image, tile: bounds.size)
        CATransaction.commit()
    }

    /// A window cropped to fit keeps its top left, where its title bar and toolbar are, which is what makes a
    /// long thin window recognizable. In a layer's unit space the top is at 1.
    private static func topLeftCrop(image: CGImage, tile: CGSize) -> CGRect {
        guard image.height > 0, tile.height > 0, image.width > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let tileAspect = tile.width / tile.height
        if imageAspect > tileAspect {
            return CGRect(x: 0, y: 0, width: tileAspect / imageAspect, height: 1)
        }
        let height = imageAspect / tileAspect
        return CGRect(x: 0, y: 1 - height, width: 1, height: height)
    }
}

/// The app's icon and name, on glass, inside the tile: it floats above the window's content, which is what
/// glass is for, and stays readable over any window.
private final class WindowLabelView: NSGlassEffectView {
    static let height: CGFloat = 28
    private static let iconSide: CGFloat = 18
    private static let iconInset: CGFloat = 5
    private static let gap: CGFloat = 5
    private static let trailing: CGFloat = 11
    /// Below these the name would cover the window or be cut down to a letter, so the icon alone stands for it.
    private static let shortestTileForName: CGFloat = 72
    private static let narrowestRoomForName: CGFloat = 70
    private static let brightThreshold: CGFloat = 0.55

    init(name: String, icon: NSImage?, maximumWidth: CGFloat, tileHeight: CGFloat) {
        super.init(frame: .zero)
        cornerRadius = Self.height / 2

        let image = NSImageView(
            frame: NSRect(
                x: Self.iconInset, y: (Self.height - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown

        guard tileHeight >= Self.shortestTileForName, maximumWidth >= Self.narrowestRoomForName else {
            frame.size = NSSize(width: Self.height, height: Self.height)
            let holder = NSView(frame: bounds)
            holder.addSubview(image)
            contentView = holder
            return
        }

        let text = NSTextField(labelWithString: name)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.sizeToFit()

        let textX = Self.iconInset + Self.iconSide + Self.gap
        let width = min(textX + ceil(text.frame.width) + Self.trailing, maximumWidth)
        frame.size = NSSize(width: width, height: Self.height)

        let holder = NSView(frame: bounds)
        holder.addSubview(image)
        text.frame = NSRect(
            x: textX, y: ((Self.height - text.frame.height) / 2).rounded(), width: width - textX - Self.trailing,
            height: text.frame.height)
        holder.addSubview(text)
        contentView = holder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Glass passes on what is behind it, so white text in dark glass turns grey on grey over a bright window.
    /// The label takes the appearance of what it actually sits on, as the system's own small glass controls do.
    func adapt(toBrightness brightness: CGFloat) {
        appearance = NSAppearance(named: brightness > Self.brightThreshold ? .aqua : .darkAqua)
    }
}
