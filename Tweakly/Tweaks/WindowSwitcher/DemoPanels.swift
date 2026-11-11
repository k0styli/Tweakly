#if TWEAKLY_AUTOMATION
    import AppKit
    import WindowSwitcherCore

    /// The real Command-Tab and Dock panels, with tiles handed to them from files, for the site's pictures.
    ///
    /// They show on the invisible test display only and refuse without it, so they can never cover the person's screen.
    /// Nothing is watched or tapped and no permission is used: the switcher's tap, the Dock's watcher and window
    /// captures all stay off, and the person's own Command-Tab and Dock are untouched.
    final class DemoPanels {
        static let shared = DemoPanels()

        /// `{"selected": 1, "tiles": [{"label": "Tweakly", "app": "self", "picture": "/tmp/a.png"}], "dock": [...]}`.
        /// An app is a bundle identifier or `self`; an icon file may stand in for it.
        private struct Manifest: Decodable {
            struct Tile: Decodable {
                let label: String
                var accessibilityLabel: String?
                var app: String?
                var icon: String?
                let picture: String
            }

            var selected: Int?
            let tiles: [Tile]
            /// Bundle identifiers or `self` for the drawn Dock, left to right, and which of them the pointer is on.
            var dock: [String]?
            var hovered: Int?
            var largestTileHeight: Int?
        }

        /// A row of icons on glass at the bottom of the test display, standing in for the Dock, which lives on the
        /// person's display only. Measured on the Dock of macOS 27.2 at its default size: Accessibility gives each item a
        /// frame of 68 by 84 points, and the glass the eye sees is exactly that tall, 5 points above the screen's edge;
        /// the icons look 52 points, the 64 of their picture less its own margin, 9 points below the glass's top, with
        /// the dot under a running app 7 points above its bottom. The panel is placed from the item's frame, as for the
        /// real Dock, so it stands 9 points above the glass and its drop hangs just short of it.
        private enum Bar {
            static let cell = CGSize(width: 68, height: 84)
            static let icon: CGFloat = 64
            static let iconTop: CGFloat = 9
            static let inset: CGFloat = 8
            static let bottom: CGFloat = 5
            static let radius: CGFloat = 26
            static let dot: CGFloat = 4
            static let dotBottom: CGFloat = 5
        }

        private var switcher: SwitcherPanelController?
        private var dockPanel: DockPreviewPanel?
        private var dockWindow: DockPreviewWindow?
        private var dockBar: NSPanel?

        // MARK: Command-Tab

        /// Writes the panel's window number and frame to `state` once it is on screen.
        func showSwitcher(manifestAt path: String, state: String?) {
            closeSwitcher()
            guard let screen = QuietScreen.screen, let manifest = Self.read(path) else { return }
            let pictures = manifest.tiles.map { Self.image(at: $0.picture) }
            var tuning = SwitcherTuning()
            if let height = manifest.largestTileHeight { tuning.largestTileHeight = height }
            var metrics = SwitcherLayout.Metrics()
            metrics.fitsBackgroundToRows = tuning.fitsBackgroundToRows
            metrics.maximumTileHeight = CGFloat(tuning.largestTileHeight)
            let visible = screen.visibleFrame.size
            let layout = SwitcherLayout(
                aspects: pictures.map(Self.aspect),
                available: CGSize(
                    width: visible.width * WindowSwitcherTweak.panelWidthShare,
                    height: visible.height * WindowSwitcherTweak.panelHeightShare),
                overflow: CGSize(
                    width: visible.width * WindowSwitcherTweak.panelWidthShare,
                    height: visible.height * WindowSwitcherTweak.panelMaximumHeightShare),
                metrics: metrics)
            let selected = min(manifest.selected ?? 0, max(layout.tileFrames.count - 1, 0))
            let panel = SwitcherPanelController(
                tiles: manifest.tiles.map(Self.tile), layout: layout, selected: selected, screen: screen,
                willHavePictures: true)
            fill(pictures, count: layout.tileFrames.count) { image, brightness, index in
                panel.setKeptImage(image, labelBackdropBrightness: brightness, at: index)
            }
            panel.show(announcing: false)
            switcher = panel
            Self.write(["panel": panel.frame, "screen": screen.frame], window: panel.windowNumber, to: state)
        }

        func closeSwitcher() {
            switcher?.close()
            switcher = nil
        }

        // MARK: Dock

        /// Writes the panel's window number and frame, its drop included, to `state` once it is on screen.
        func showDock(manifestAt path: String, state: String?) {
            closeDock()
            guard let screen = QuietScreen.screen, let manifest = Self.read(path) else { return }
            let apps = manifest.dock ?? ["self"]
            let hovered = min(max(manifest.hovered ?? 0, 0), apps.count - 1)
            let bar = Self.barFrame(count: apps.count, on: screen.frame)
            let icon = Self.cellFrame(hovered, in: bar)
            dockBar = Self.makeBar(apps: apps, running: hovered, frame: bar)

            var tuning = DockTuning()
            if let height = manifest.largestTileHeight { tuning.largestTileHeight = height }
            tuning = tuning.validated
            let metrics = tuning.layoutMetrics
            let visible = screen.visibleFrame
            let edge = DockGeometry.edge(ofDock: bar, on: screen.frame)
            let room = DockGeometry.room(for: edge, visible: visible)
            let pictures = manifest.tiles.map { Self.image(at: $0.picture) }
            let layout = SwitcherLayout(
                aspects: pictures.map(Self.aspect), available: room.available, overflow: room.overflow,
                metrics: metrics)
            guard !layout.tileFrames.isEmpty else { return }
            let origin = DockGeometry.panelOrigin(size: layout.panelSize, icon: icon, edge: edge, visible: visible)
            let tailOffset = DockGeometry.tailOffset(
                icon: icon, panel: CGRect(origin: origin, size: layout.panelSize), edge: edge,
                cornerRadius: metrics.cornerRadius)
            let window = DockPreviewWindow.make()
            let panel = DockPreviewPanel(
                in: window, tiles: manifest.tiles.map(Self.tile), layout: layout, metrics: metrics, origin: origin,
                edge: edge, tailOffset: tailOffset, scale: screen.backingScaleFactor, willHavePictures: true)
            fill(pictures, count: layout.tileFrames.count) { image, brightness, index in
                panel.setKeptImage(image, labelBackdropBrightness: brightness, at: index)
            }
            panel.show()
            if let selected = manifest.selected { panel.highlightForTesting(selected) }
            dockWindow = window
            dockPanel = panel
            Self.write(
                ["panel": panel.frame, "bar": bar, "screen": screen.frame], window: panel.windowNumber, to: state)
        }

        func closeDock() {
            dockPanel?.close()
            dockPanel = nil
            dockWindow = nil
            dockBar?.orderOut(nil)
            dockBar = nil
        }

        // MARK: Parts

        private func fill(
            _ pictures: [CGImage?], count: Int, into set: (CGImage, CGFloat?, Int) -> Void
        ) {
            for (index, picture) in pictures.prefix(count).enumerated() {
                guard let picture else { continue }
                set(picture, WindowThumbnailer.brightnessOfBottomLeft(picture), index)
            }
        }

        private static func read(_ path: String) -> Manifest? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }

        private static func image(at path: String) -> CGImage? {
            NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        private static func aspect(of image: CGImage?) -> CGFloat {
            guard let image, image.height > 0 else { return 1.6 }
            return CGFloat(image.width) / CGFloat(image.height)
        }

        private static func icon(for app: String?) -> NSImage? {
            guard let app else { return nil }
            if app == "self" { return NSApp.applicationIconImage }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        private static func tile(_ tile: Manifest.Tile) -> WindowTile {
            let icon = tile.icon.flatMap { NSImage(contentsOfFile: $0) } ?? Self.icon(for: tile.app)
            return WindowTile(
                icon: icon, label: tile.label, accessibilityLabel: tile.accessibilityLabel ?? tile.label,
                hasWindow: true)
        }

        private static func barFrame(count: Int, on screen: CGRect) -> CGRect {
            let width = Bar.inset * 2 + Bar.cell.width * CGFloat(count)
            return CGRect(
                x: (screen.midX - width / 2).rounded(), y: screen.minY + Bar.bottom, width: width,
                height: Bar.cell.height)
        }

        /// An item's frame as Accessibility would give it: the full height of the glass.
        private static func cellFrame(_ index: Int, in bar: CGRect) -> CGRect {
            CGRect(
                x: bar.minX + Bar.inset + CGFloat(index) * Bar.cell.width, y: bar.minY, width: Bar.cell.width,
                height: Bar.cell.height)
        }

        /// The glass row with the icons and the dot under the running app, at the Dock's own level.
        private static func makeBar(apps: [String], running: Int, frame: CGRect) -> NSPanel {
            let panel = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .dock
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none

            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
            glass.cornerRadius = Bar.radius
            let holder = NSView(frame: glass.bounds)
            for (index, app) in apps.enumerated() {
                let cell = cellFrame(index, in: frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
                let view = NSImageView(
                    frame: NSRect(
                        x: cell.midX - Bar.icon / 2, y: cell.maxY - Bar.iconTop - Bar.icon, width: Bar.icon,
                        height: Bar.icon))
                view.image = icon(for: app)
                view.imageScaling = .scaleProportionallyUpOrDown
                holder.addSubview(view)
                if index == running {
                    let dot = NSView(
                        frame: NSRect(x: cell.midX - Bar.dot / 2, y: Bar.dotBottom, width: Bar.dot, height: Bar.dot))
                    dot.wantsLayer = true
                    dot.layer?.cornerRadius = Bar.dot / 2
                    dot.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.7).cgColor
                    holder.addSubview(dot)
                }
            }
            glass.contentView = holder
            panel.contentView = glass
            panel.orderFrontRegardless()
            return panel
        }

        /// Frames in the coordinates `screencapture -R` takes: points from the top left of the primary display.
        private static func write(_ frames: [String: CGRect], window: Int, to path: String?) {
            guard let path, let primary = NSScreen.screens.first?.frame else { return }
            var object: [String: Any] = ["window": window]
            for (name, frame) in frames {
                object[name] = [frame.minX, primary.maxY - frame.maxY, frame.width, frame.height]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
#endif
