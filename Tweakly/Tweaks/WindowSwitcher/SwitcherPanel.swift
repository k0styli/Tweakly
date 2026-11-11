import AppKit
import WindowSwitcherCore

/// The panel never takes the keyboard. Keys come from the event tap, and the app in front stays in front,
/// so nothing about the person's work changes until they choose a window.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Everything on screen during a session. It is built for one session and released with it, so no window or view
/// stays in memory while the panel is hidden.
final class SwitcherPanelController {
    /// The system's own Command-Tab panel, measured on macOS 27.2, has a corner radius of about 44 pt and a neutral
    /// 6 pt highlight around the selected icon. Tiles are concentric with that glass: 44 less the padding of 24 is
    /// 20, the highlight adds its 6 back, and the label sits 6 inside the tile with half its height of 28 as radius.
    private enum Shape {
        static let panelRadius = SwitcherLayout.Metrics().cornerRadius
        static let tiles = WindowTileShape(
            tileRadius: panelRadius - SwitcherLayout.Metrics().padding, highlightInset: 6, labelInset: 6)
    }

    var onHover: ((Int) -> Void)? {
        didSet { content.onHover = onHover }
    }
    var onClick: ((Int) -> Void)? {
        didSet { content.onClick = onClick }
    }

    private let panel: SwitcherPanel
    private let content: WindowTilesView
    private let layout: SwitcherLayout
    /// What VoiceOver hears for each tile.
    private let labels: [String]
    private var current = 0
    private var isShown = false

    init(tiles: [WindowTile], layout: SwitcherLayout, selected: Int, screen: NSScreen, willHavePictures: Bool) {
        labels = tiles.map(\.accessibilityLabel)
        self.layout = layout
        let size = layout.panelSize
        let origin = NSPoint(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (screen.frame.midY - size.height / 2).rounded())
        panel = SwitcherPanel(
            contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        // Above everything the system's own switcher is above, in every Space, over full-screen apps and in
        // Mission Control, which hides a window marked `.transient`.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        content = WindowTilesView(
            tiles: tiles, frames: layout.tileFrames, shape: Shape.tiles, scale: screen.backingScaleFactor,
            willHavePictures: willHavePictures)
        content.frame = NSRect(origin: .zero, size: size)
        let root = NSView(frame: content.frame)
        root.addSubview(Self.background(for: layout))
        root.addSubview(content)
        panel.contentView = root
        current = selected
        highlight(selected)
    }

    /// A glass view can only be a rounded rectangle and a mask would cut off its edge, so any other shape comes from
    /// pieces the system merges, with its own curve where a narrower one meets a wider one and a shadow that follows.
    /// The radius of that curve is about half the spacing. Tiles go on top, since each piece is behind only some of them.
    private static func background(for layout: SwitcherLayout) -> NSView {
        let pieces = layout.backgroundFrames.map { frame in
            let piece = NSGlassEffectView(frame: frame)
            piece.cornerRadius = Shape.panelRadius
            return piece
        }
        if pieces.count == 1 { return pieces[0] }
        let holder = FlippedView(frame: NSRect(origin: .zero, size: layout.panelSize))
        for piece in pieces { holder.addSubview(piece) }
        let container = NSGlassEffectContainerView(frame: holder.frame)
        container.spacing = Shape.panelRadius
        container.contentView = holder
        return container
    }

    #if TWEAKLY_AUTOMATION
        var frame: CGRect { panel.frame }
        var windowNumber: Int { panel.windowNumber }
    #endif

    func show(announcing: Bool = true) {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        isShown = true
        if announcing { announce(current) }
    }

    func announceSelection() {
        announce(current)
    }

    func close() {
        panel.orderOut(nil)
    }

    func select(_ index: Int) {
        guard layout.tileFrames.indices.contains(index) else { return }
        current = index
        highlight(index)
        // The panel is built ahead of its showing, and a press that ends before then switches without it, so VoiceOver
        // hears about a window only once the panel is there.
        if isShown { announce(index) }
    }

    private func highlight(_ index: Int) {
        guard layout.tileFrames.indices.contains(index) else { return }
        content.highlight(index)
    }

    private func announce(_ index: Int) {
        guard labels.indices.contains(index) else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: labels[index],
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// - Parameter animated: a picture arriving fades in; one already known from before just appears.
    func setPicture(_ picture: SwitcherPicture, at index: Int, animated: Bool) {
        content.setPicture(picture, at: index, animated: animated)
    }

    /// A kept picture, unpacked: may be out of date, but there from the first frame, until a real picture fades in
    /// over it.
    func setKeptImage(_ image: CGImage, labelBackdropBrightness: CGFloat?, at index: Int) {
        content.setImage(image, labelBackdropBrightness: labelBackdropBrightness, at: index, animated: false)
    }

    /// For a window that gave no picture, whose tile would otherwise stay plain.
    func showIcon(at index: Int) {
        content.showIcon(at: index)
    }

}
