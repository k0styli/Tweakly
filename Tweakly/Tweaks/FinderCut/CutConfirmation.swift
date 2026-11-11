import AppKit

/// Finder cannot be made to dim files the way Explorer does, so this says that the keys did something. A small
/// glass capsule that appears for a moment, built when needed and released right after.
final class CutConfirmation {
    private static let height: CGFloat = 44
    private static let bottomGap: CGFloat = 96
    private static let visibleFor: TimeInterval = 1.4

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String) {
        close()
        guard let screen = NSScreen.main else { return }

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.symbolConfiguration = .init(textStyle: .body, scale: .medium)
        image.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .labelColor
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 20)
        row.setFrameSize(NSSize(width: row.fittingSize.width, height: Self.height))

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.height / 2
        glass.contentView = row

        let size = NSSize(width: row.frame.width, height: Self.height)
        let origin = NSPoint(
            x: (screen.visibleFrame.midX - size.width / 2).rounded(), y: screen.visibleFrame.minY + Self.bottomGap)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = AppSettings.savedTheme.appearance
        panel.contentView = glass
        panel.orderFrontRegardless()
        self.panel = panel

        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    func close() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let panel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            close()
            return
        }
        NSAnimationContext.runAnimationGroup { _ in
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.panel === panel { self?.close() }
            }
        }
    }
}
