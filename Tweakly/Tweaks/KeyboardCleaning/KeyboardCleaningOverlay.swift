import AppKit
import KeyboardCleaningCore

/// What is on screen while the keyboard is off: the system's own alert, so it looks and changes as macOS does, over a
/// soft dim that takes stray clicks. A touch on the trackpad while wiping reaches nothing behind it.
///
/// Every screen gets an alert, so the way back is in plain sight wherever the person looks.
final class KeyboardCleaningOverlay {
    private static let dimOpacity: CGFloat = 0.25

    private let onTurnOn: () -> Void
    private let onAddTime: () -> Void
    private var shields: [NSPanel] = []
    private var alerts: [KeyboardCleaningAlert] = []

    init(onTurnOn: @escaping () -> Void, onAddTime: @escaping () -> Void) {
        self.onTurnOn = onTurnOn
        self.onAddTime = onAddTime
    }

    /// Also called when screens change, to cover them all again.
    func show() {
        show(on: NSScreen.screens, takesKey: true)
    }

    private func show(on screens: [NSScreen], takesKey: Bool) {
        close()
        for screen in screens {
            shields.append(Self.makeShield(on: screen))
            let alert = KeyboardCleaningAlert(onTurnOn: onTurnOn, onAddTime: onAddTime)
            alert.show(on: screen)
            alerts.append(alert)
        }
        guard takesKey else { return }
        // Key, so its buttons look active and the first click on them counts. Under the pointer, as that is the one
        // about to be used.
        let mouse = NSEvent.mouseLocation
        (alerts.first { $0.screenFrame.contains(mouse) } ?? alerts.first)?.makeKey()
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "Keyboard Off"), .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    #if TWEAKLY_AUTOMATION
        /// A quiet test copy shows the alert on its own display alone, and leaves the key window where it is, so the
        /// person using the Mac sees nothing of it.
        /// Without the dim, for a picture of the alert by itself.
        func showForTesting(dims: Bool = true) {
            if let screen = QuietScreen.isActive ? QuietScreen.screen : nil {
                show(on: [screen], takesKey: false)
            } else {
                show()
            }
            if !dims { shields.forEach { $0.orderOut(nil) } }
        }
    #endif

    func update(remaining: Double, total: Double, secureInputOn: Bool) {
        for alert in alerts {
            alert.update(remaining: remaining, total: total, secureInputOn: secureInputOn)
        }
    }

    func close() {
        shields.forEach { $0.orderOut(nil) }
        shields = []
        alerts.forEach { $0.close() }
        alerts = []
    }

    private static func makeShield(on screen: NSScreen) -> NSPanel {
        let dim = ClickShieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimOpacity).cgColor
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = dim
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        return panel
    }

    #if TWEAKLY_AUTOMATION
        var buttonFrameOnScreen: CGRect { alerts.first?.buttonFrame(at: 0) ?? .zero }
        var addButtonFrameOnScreen: CGRect { alerts.first?.buttonFrame(at: 1) ?? .zero }
        var panelCount: Int { shields.count + alerts.count }
    #endif
}

/// Takes the clicks that miss the alert, so they reach nothing behind it.
private final class ClickShieldView: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// A real `NSAlert`, shown as a window rather than run modally, because the countdown and the ways back must go on
/// while it is up. Everything about how it looks is the system's: only the words and the countdown are this app's.
private final class KeyboardCleaningAlert: NSObject {
    private static let countdownWidth: CGFloat = 220

    private let alert = NSAlert()
    private let bar = NSProgressIndicator()
    private let countdown = NSTextField(labelWithString: "")
    private let onTurnOn: () -> Void
    private let onAddTime: () -> Void
    private var showsPasswordWarning = false
    private(set) var screenFrame = CGRect.zero

    init(onTurnOn: @escaping () -> Void, onAddTime: @escaping () -> Void) {
        self.onTurnOn = onTurnOn
        self.onAddTime = onAddTime
        super.init()
        alert.icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        alert.messageText = String(localized: "Keyboard Off")
        alert.informativeText = Self.message(passwordWarning: false)
        alert.accessoryView = makeCountdown()

        let turnOn = alert.addButton(withTitle: String(localized: "Turn Keyboard On"))
        turnOn.target = self
        turnOn.action = #selector(turnOnPressed)
        let addTime = alert.addButton(withTitle: String(localized: "Add a Minute"))
        addTime.target = self
        addTime.action = #selector(addTimePressed)
        alert.layout()

        let window = alert.window
        window.appearance = AppSettings.savedTheme.appearance
        window.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.hidesOnDeactivate = false
    }

    private static func message(passwordWarning: Bool) -> String {
        passwordWarning
            ? String(
                localized:
                    "You can wipe it now, but a password field in another app may still get keys. To turn it on without a mouse, hold both Command keys for 3 seconds."
            )
            : String(
                localized: "You can wipe it now. To turn it on without a mouse, hold both Command keys for 3 seconds.")
    }

    private func makeCountdown() -> NSView {
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: Self.countdownWidth).isActive = true
        // Monospaced digits, or the line shifts a little with every second.
        countdown.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [bar, countdown])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: Self.countdownWidth, height: stack.fittingSize.height)
        return stack
    }

    func show(on screen: NSScreen) {
        screenFrame = screen.frame
        place(on: screen)
        alert.window.orderFrontRegardless()
    }

    /// Where the system puts its own alerts: centred, and somewhat above the middle.
    private func place(on screen: NSScreen) {
        let window = alert.window
        let area = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: (area.midX - window.frame.width / 2).rounded(),
                y: (area.minY + (area.height - window.frame.height) * 0.6).rounded()))
    }

    func makeKey() {
        alert.window.makeKeyAndOrderFront(nil)
    }

    func update(remaining: Double, total: Double, secureInputOn: Bool) {
        bar.doubleValue = total > 0 ? remaining / total : 0
        countdown.stringValue = String(localized: "Turns back on in \(CleaningClock.text(remaining: remaining))")
        guard secureInputOn != showsPasswordWarning else { return }
        showsPasswordWarning = secureInputOn
        alert.informativeText = Self.message(passwordWarning: secureInputOn)
        alert.layout()
        if let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) { place(on: screen) }
    }

    func close() {
        alert.window.orderOut(nil)
    }

    @objc private func turnOnPressed() { onTurnOn() }
    @objc private func addTimePressed() { onAddTime() }

    #if TWEAKLY_AUTOMATION
        func buttonFrame(at index: Int) -> CGRect {
            let button = alert.buttons[index]
            guard let window = button.window else { return .zero }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
    #endif
}
