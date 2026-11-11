import AppKit

/// A menu bar item that opens a popover. On macOS 27 the system runs the item's expanded-interface session and says
/// when it begins and ends; before that the app takes the click itself and marks the item open by highlighting it.
/// A right click belongs to Tweakly's menu, see `AppStatusMenu`.
class MenuBarPopoverItem: NSObject {
    let item: NSStatusItem

    var button: NSStatusBarButton? { item.button }

    init(length: CGFloat, autosaveName: String) {
        item = NSStatusBar.system.statusItem(withLength: length)
        super.init()
        item.autosaveName = autosaveName
        if #available(macOS 27.0, *) {
            item.expandedInterfaceDelegate = self
        } else {
            item.button?.target = self
            item.button?.action = #selector(buttonClicked)
            item.button?.sendAction(on: [.leftMouseDown])
        }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    /// macOS 27 began the item's session: show the popover, or nothing if it shows already.
    func sessionDidBegin() {}
    /// A click before macOS 27, where the app itself keeps the item's open state: open or close.
    func clicked() {}
    /// macOS 27 ended the item's session.
    func sessionDidEnd() {}

    /// Before macOS 27 nothing else marks the item whose popover is showing.
    func detailsDidOpen() {
        if #unavailable(macOS 27.0) {
            item.button?.highlight(true)
        }
    }

    /// Ends the system's expanded-interface session when the popover closes some other way.
    func detailsDidClose() {
        if #available(macOS 27.0, *) {
            item.expandedInterfaceSession?.cancel()
        } else {
            item.button?.highlight(false)
        }
    }

    @objc private func buttonClicked() {
        clicked()
    }
}

@available(macOS 27.0, *)
extension MenuBarPopoverItem: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        sessionDidBegin()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        sessionDidEnd()
    }
}

/// One popover beneath a menu bar item: in the app's theme and following it, closed by a click anywhere else, and let
/// go of entirely when it closes, so a closed popover costs nothing. The stats items and the volume mixer show theirs
/// through it.
final class MenuBarPopover: NSObject, NSPopoverDelegate {
    /// A click on an open item closes the popover before the click itself arrives. Without this, that same click would
    /// open it again at once.
    static let reopenGuard: TimeInterval = 0.25

    private var popover: NSPopover?
    private(set) var controller: NSViewController?
    private var item: MenuBarPopoverItem?
    private var clickMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var fittingSize: (() -> NSSize)?
    private var onClose: (() -> Void)?

    var isShown: Bool { popover != nil }

    /// Shows `controller` under the item. `fittingSize` is the size the content needs, applied again once the popover
    /// is on screen, as it ignores a change made while it appears. False when there is nowhere to show it.
    @discardableResult
    func show(
        _ controller: NSViewController, under item: MenuBarPopoverItem, setsSizeFirst: Bool,
        fittingSize: @escaping () -> NSSize, onClose: @escaping () -> Void
    ) -> Bool {
        close()
        guard var anchor: NSView = item.button else { return false }
        #if TWEAKLY_AUTOMATION
            if QuietScreen.isActive {
                // Only the main display's copy of the item has a view here, and a popover there would cover the
                // screen of the person using the Mac. Without a stand-in on the quiet display, nothing opens.
                guard let quietAnchor = QuietScreen.anchor() else {
                    item.detailsDidClose()
                    return false
                }
                anchor = quietAnchor
            }
        #endif
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        #if TWEAKLY_AUTOMATION
            // The person using the Mac clicks elsewhere during a quiet run, and that must not close a test popover.
            if QuietScreen.isActive { popover.behavior = .applicationDefined }
        #endif
        // A status item takes its appearance from the wallpaper behind the menu bar, which can differ from light or
        // dark mode. The popover is ordinary content and should follow the app's theme.
        popover.appearance = Self.contentAppearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        self.popover = popover
        self.controller = controller
        self.item = item
        self.fittingSize = fittingSize
        self.onClose = onClose
        if setsSizeFirst { popover.contentSize = fittingSize() }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        item.detailsDidOpen()
        // The appearance above is a snapshot, and the system can change between light and dark at any time.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        }
        #if TWEAKLY_AUTOMATION
            if QuietScreen.isActive { return true }
        #endif
        // Not being the active app, a transient popover cannot always see clicks in other apps.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        return true
    }

    func close() {
        popover?.close()
        finishClosing()
    }

    /// The content's size changed while it shows.
    func resize() {
        guard let popover, let fittingSize else { return }
        popover.contentSize = fittingSize()
    }

    /// After the app's theme changed.
    func updateAppearance() {
        popover?.appearance = Self.contentAppearance
    }

    private static var contentAppearance: NSAppearance {
        AppSettings.savedTheme.appearance ?? NSApp.effectiveAppearance
    }

    func popoverDidShow(_ notification: Notification) {
        resize()
    }

    func popoverDidClose(_ notification: Notification) {
        finishClosing()
    }

    private func finishClosing() {
        guard popover != nil else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        appearanceObservation = nil
        popover?.delegate = nil
        popover = nil
        controller = nil
        fittingSize = nil
        let closing = item
        let closed = onClose
        item = nil
        onClose = nil
        closing?.detailsDidClose()
        #if TWEAKLY_AUTOMATION
            QuietScreen.hideAnchor()
        #endif
        closed?()
    }
}
