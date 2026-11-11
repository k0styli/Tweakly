import AppKit
import os

/// A test copy started by the quiet-tests tool lives on a virtual display of its own,
/// named in its defaults, so the person using the Mac never sees its windows and keeps the front app and the keyboard.
/// In a shipping build `mayActivate` is always true and nothing else here exists.
@MainActor
enum QuietScreen {
    /// Whether this copy may bring itself to the front.
    static var mayActivate: Bool {
        #if TWEAKLY_AUTOMATION
            !isActive && !UserDefaults.standard.bool(forKey: "measureQuietly")
        #else
            true
        #endif
    }

    #if TWEAKLY_AUTOMATION
        private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "quiet")
        /// Read once: the tool sets it before launch and deletes the whole test domain afterwards.
        static let name = UserDefaults.standard.string(forKey: "quietDisplay")
        static var isActive: Bool { name != nil }
        static var screen: NSScreen? { NSScreen.screens.first { $0.localizedName == name } }
        private static var observer: NSObjectProtocol?

        /// First thing in both processes. A copy told to be quiet refuses to run without its display, and quits the
        /// moment the display goes, so the system never moves its windows onto a screen someone is looking at.
        static func start() {
            guard isActive else { return }
            guard screen != nil else { leave("its display is missing") }
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if screen == nil { leave("its display went away") }
                }
            }
        }

        private static func leave(_ reason: String) -> Never {
            log.error("Quiet test copy quits: \(reason, privacy: .public)")
            exit(0)
        }

        /// Puts a window in the middle of the quiet display, keeping its size. Call before it is first shown, so it
        /// never appears anywhere else, not even for a frame.
        static func place(_ window: NSWindow) {
            guard let screen else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            window.setFrame(frame.integral, display: false)
        }

        /// Where this copy's item sits on the quiet display's menu bar, in AppKit's screen coordinates. quiet.py reads
        /// it from MenuBarAgent, as a test copy started with `open -g` has no Accessibility permission of its own.
        static var itemFrame: NSRect?
        private static var anchorPanel: NSPanel?

        /// Takes a frame from the top left of the main display, as Accessibility and CGWindowList give it.
        static func setItemFrame(topLeft frame: CGRect) {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            itemFrame = NSRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        }

        /// A clear stand-in for the item on the quiet display's menu bar, for a popover to point at. The system draws
        /// each display's copy of an item itself, and only the main display's copy has a view in this process.
        static func anchor() -> NSView? {
            guard let itemFrame else { return nil }
            let panel =
                anchorPanel
                ?? NSPanel(
                    contentRect: itemFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                    defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.setFrame(itemFrame, display: false)
            panel.orderFrontRegardless()
            anchorPanel = panel
            return panel.contentView
        }

        static func hideAnchor() {
            anchorPanel?.orderOut(nil)
        }
    #endif
}
