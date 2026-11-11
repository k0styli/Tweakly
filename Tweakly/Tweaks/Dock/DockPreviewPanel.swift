import AppKit
import WindowSwitcherCore

/// Never takes the keyboard or the front: the app in use stays in use until a window is chosen.
///
/// One is made when the tweak starts watching and kept, empty and hidden between panels, with its glass already made:
/// the Dock shows its own bubble about 30 ms after the pointer comes onto an icon, and making a window and its glass on
/// the spot took 20 ms more than that, measured on macOS 27.2. So the glass goes on screen first, at once, and covers
/// the Dock's bubble; the tiles follow a frame later.
final class DockPreviewWindow: NSPanel {
    let root = DockPreviewRoot()
    /// Holds the glass and the tiles, and is what fades: AppKit keeps the layer of a window's content view to itself.
    private let stage = NSView()
    private let container = NSGlassEffectContainerView()
    private let holder = NSView()
    private let body = NSGlassEffectView()
    private let drop = NSGlassEffectView()
    private weak var content: NSView?
    private var shadowFollower: Timer?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make() -> DockPreviewWindow {
        let panel = DockPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        // Above the Dock and the name it shows over an icon, in every Space, over full-screen apps.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.stage.wantsLayer = true
        panel.contentView = panel.root
        panel.holder.addSubview(panel.body)
        panel.holder.addSubview(panel.drop)
        panel.container.contentView = panel.holder
        panel.stage.addSubview(panel.container)
        panel.root.addSubview(panel.stage)
        return panel
    }

    /// The glass alone, at its place and on screen in this very moment, before anything else is made. The system
    /// merges the panel's glass and the drop's into one outline with one edge and one shadow: a glass view can only be
    /// a rounded rectangle, and a mask would cut off its edge.
    func place(frame: CGRect, body bodyFrame: CGRect, drop dropFrame: CGRect, radius: CGFloat, spacing: CGFloat) {
        setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)
        stage.frame = root.bounds
        let box = bodyFrame.union(dropFrame)
        container.spacing = spacing
        container.frame = box
        holder.frame = NSRect(origin: .zero, size: box.size)
        body.frame = bodyFrame.offsetBy(dx: -box.minX, dy: -box.minY)
        body.cornerRadius = radius
        drop.frame = dropFrame.offsetBy(dx: -box.minX, dy: -box.minY)
        drop.cornerRadius = dropFrame.width / 2
        if !isVisible { orderFrontRegardless() }
        // Sent to the screen now, not at the end of this turn of the loop, after the tiles are made.
        CATransaction.flush()
        // The shadow follows the glass once it is drawn; asking for it now would hold up this frame.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    /// Fades everything in the window. Its own alpha would be the way, but the system draws a window with glass at full
    /// strength whatever its alpha, seen in captures mid-fade on macOS 27.2, so the content's layer fades instead.
    func fade(to opacity: Float, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        guard let layer = stage.layer else {
            completion?()
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        // The window's shadow is worked out from what the window shows only when asked, and would stay as a dark
        // outline of a panel no longer there, so it is asked on every frame of the fade, and only then.
        shadowFollower?.invalidate()
        if duration > 0, from != opacity {
            let follower = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateShadow() }
            }
            RunLoop.main.add(follower, forMode: .common)
            shadowFollower = follower
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.shadowFollower?.invalidate()
                self?.shadowFollower = nil
                self?.invalidateShadow()
                completion?()
            }
        }
        layer.removeAnimation(forKey: "fade")
        layer.opacity = opacity
        if duration > 0, from != opacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = opacity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "fade")
        }
        CATransaction.commit()
    }

    /// The first panel after launch took 250 ms against 50 for the next, as glass, text and tiles are made for the first
    /// time. So one is made off every screen, shown for a moment and taken away, before anyone points at the Dock.
    func warmUp() {
        let size = CGSize(width: 180, height: 140)
        let tiles = WindowTilesView(
            tiles: [WindowTile(icon: nil, label: "Tweakly", accessibilityLabel: "", hasWindow: false)],
            frames: [CGRect(x: 12, y: 12, width: 156, height: 116)],
            shape: WindowTileShape(tileRadius: 20, highlightInset: 6, labelInset: 6), scale: 2, willHavePictures: false)
        tiles.frame = CGRect(origin: .zero, size: size)
        place(
            frame: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), body: CGRect(origin: .zero, size: size),
            drop: CGRect(x: 86, y: -4, width: 8, height: 8), radius: 32, spacing: 14)
        setContent(tiles)
        DispatchQueue.main.async { [weak self] in
            self?.orderOut(nil)
            self?.setContent(nil)
        }
    }

    /// Over the glass, in place of whatever was there.
    func setContent(_ view: NSView?) {
        if let content, content !== view { content.removeFromSuperview() }
        if let view, view.superview !== stage { stage.addSubview(view) }
        content = view
    }

    func isShowing(_ view: NSView) -> Bool { content === view }
}

/// The drop under the Dock's bubble with an app's name, which the panel covers: a small round piece of glass that the
/// system merges into the panel's own, as it merges any glass close together. Chosen from 24 tries on macOS 27.2 by
/// comparing outlines row by row with the Dock's, which reaches 6.5 pt and narrows from 18 pt to a point: this one is at
/// least as wide on every row, so none of the Dock's shows, and at most 1 pt wider below the first half point.
struct DockTail: Equatable {
    var diameter: CGFloat = 8
    /// How far the round piece reaches beyond the panel's edge; the rest of it is inside.
    var reach: CGFloat = DockTuning.tailLength
    /// How close glass has to be to merge, which also sets the curve where the drop meets the edge.
    var spacing: CGFloat = 14
}

/// The windows of one app over its Dock icon, on the same glass and tiles as the Command-Tab panel, with a drop towards
/// the icon where the Dock has one under the app's name. Shown as it is made: the glass first, at once, then the tiles.
/// Nothing of it stays in memory between hovers but the window.
final class DockPreviewPanel {
    var onClick: ((Int) -> Void)?
    /// The pointer came into the panel or left it.
    var onPointerInside: ((Bool) -> Void)?

    private let panel: DockPreviewWindow
    private let tiles: WindowTilesView
    /// The window's frame for this content, its drop included.
    let frame: CGRect

    /// Puts the glass on screen in the window, which may still show another app's: moving along the Dock it changes in
    /// place rather than going and coming back. The tiles are made after it.
    ///
    /// - Parameters:
    ///   - origin: of the panel without its drop, in screen coordinates.
    ///   - tailOffset: where along the edge towards the Dock the drop sits, from the panel's origin.
    init(
        in window: DockPreviewWindow, tiles items: [WindowTile], layout: SwitcherLayout,
        metrics: SwitcherLayout.Metrics, origin: CGPoint, edge: DockGeometry.Edge, tailOffset: CGFloat,
        scale: CGFloat, willHavePictures: Bool
    ) {
        let tail = DockTail()
        let size = layout.panelSize
        // Room for the drop, and a point more for its edge.
        let extra = (tail.reach + 1).rounded(.up)
        var frame = NSRect(origin: origin, size: size)
        var body = NSRect(origin: .zero, size: size)
        let drop: NSRect
        switch edge {
        case .bottom:
            frame.origin.y -= extra
            frame.size.height += extra
            body.origin.y = extra
            drop = NSRect(
                x: tailOffset - tail.diameter / 2, y: extra - tail.reach, width: tail.diameter, height: tail.diameter)
        case .left:
            frame.origin.x -= extra
            frame.size.width += extra
            body.origin.x = extra
            drop = NSRect(
                x: extra - tail.reach, y: tailOffset - tail.diameter / 2, width: tail.diameter, height: tail.diameter)
        case .right:
            frame.size.width += extra
            drop = NSRect(
                x: size.width + tail.reach - tail.diameter, y: tailOffset - tail.diameter / 2, width: tail.diameter,
                height: tail.diameter)
        }
        panel = window
        self.frame = frame
        window.place(frame: frame, body: body, drop: drop, radius: metrics.cornerRadius, spacing: tail.spacing)

        let shape = WindowTileShape(
            tileRadius: metrics.cornerRadius - metrics.padding, highlightInset: 6, labelInset: 6)
        tiles = WindowTilesView(
            tiles: items, frames: layout.tileFrames, shape: shape, scale: scale, willHavePictures: willHavePictures)
        tiles.frame = body
        tiles.onHover = { [weak self] index in self?.tiles.highlight(index) }
        tiles.onClick = { [weak self] index in self?.onClick?(index) }
        window.root.onInside = { [weak self] inside in
            if !inside { self?.tiles.highlight(nil) }
            self?.onPointerInside?(inside)
        }
    }

    #if TWEAKLY_AUTOMATION
        var windowNumber: Int { panel.windowNumber }

        /// As if the pointer rested on this tile.
        func highlightForTesting(_ index: Int?) {
            tiles.highlight(index)
        }
    #endif

    /// The tiles, over the glass already on screen.
    func show() {
        panel.setContent(tiles)
    }

    /// Leaves the window empty, and on screen only if more content is coming at once.
    func close(keepingWindow: Bool = false) {
        if !keepingWindow { panel.orderOut(nil) }
        if panel.isShowing(tiles) { panel.setContent(nil) }
    }

    func setPicture(_ picture: SwitcherPicture, at index: Int, animated: Bool) {
        tiles.setPicture(picture, at: index, animated: animated)
    }

    func setKeptImage(_ image: CGImage, labelBackdropBrightness: CGFloat?, at index: Int) {
        tiles.setImage(image, labelBackdropBrightness: labelBackdropBrightness, at: index, animated: false)
    }

    func showIcon(at index: Int) {
        tiles.showIcon(at: index)
    }
}

/// Says when the pointer comes into the panel and leaves it, which is what keeps it up once the pointer is off the Dock.
final class DockPreviewRoot: NSView {
    var onInside: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onInside?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onInside?(false)
    }
}
