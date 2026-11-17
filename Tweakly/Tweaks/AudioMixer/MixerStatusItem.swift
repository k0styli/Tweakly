import AppKit
import AudioMixerCore

/// The mixer's item in the menu bar: the system's speaker with as many waves as Control Center shows. A click opens the
/// popover, a right click Tweakly's menu, and a scroll over it changes the volume as the keys do.
///
/// The picture changes only when the volume or the output does, so a system symbol in the button is cheap here, unlike
/// a value that changes every second (`StatusLabelView`). The few pictures are made once and kept.
final class MixerStatusItem: MenuBarPopoverItem {
    var onOpen: (() -> Void)?
    var onToggle: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Steps of the keyboard's volume, up or down.
    var onScroll: ((Int) -> Void)?
    var scrolls = true

    private var monitor: Any?
    private var scrollRemainder: CGFloat = 0
    private var images: [String: NSImage] = [:]
    private var shownKey: String?

    /// The size and weight of Control Center's own sound item, measured beside it on the menu bar at 2x: its speaker is
    /// 24 pixels tall and 17 wide, against 22 and 15 for the symbol as it came, and 14 points medium draws it column for
    /// column. A symbol without a weight of its own is drawn medium in the menu bar, one with one as it says.
    #if TWEAKLY_AUTOMATION
        static var symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    #else
        static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    #endif

    init() {
        super.init(length: NSStatusItem.squareLength, autosaveName: "tweakly.volume-mixer")
        item.button?.setAccessibilityLabel(String(localized: "Volume Mixer"))
        // Both arrive in the app, not as the button's action, and only those over this item are taken.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
        }
    }

    override func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.remove()
    }

    /// The speaker for a volume, nil when there is no output at all.
    func show(volume: Double?, isMuted: Bool, outputName: String?) {
        let waves = volume.flatMap { VolumeLevel.waves(volume: $0, isMuted: isMuted) }
        let key = volume == nil ? "none" : waves.map { "\($0)" } ?? "muted"
        if key != shownKey {
            shownKey = key
            item.button?.image = image(for: key, waves: waves)
        }
        let value: String =
            if let volume { isMuted ? String(localized: "Muted") : "\(VolumeLevel.percent(volume)) %" } else {
                String(localized: "No Output")
            }
        item.button?.setAccessibilityValue(value)
        item.button?.toolTip = [outputName, value].compactMap { $0 }.joined(separator: " · ")
    }

    private func image(for key: String, waves: Double?) -> NSImage? {
        if let made = images[key] { return made }
        let description = String(localized: "Volume Mixer")
        let made: NSImage? =
            if let waves {
                NSImage(
                    systemSymbolName: "speaker.wave.3.fill", variableValue: waves, accessibilityDescription: description
                )
            } else {
                NSImage(
                    systemSymbolName: key == "none" ? "speaker.slash" : "speaker.slash.fill",
                    accessibilityDescription: description)
            }
        let sized = made?.withSymbolConfiguration(Self.symbolConfiguration) ?? made
        sized?.isTemplate = true
        images[key] = sized
        return sized
    }

    #if TWEAKLY_AUTOMATION
        /// Draws the speaker again, after a test changed its configuration.
        func redrawForTesting() {
            images = [:]
            let key = shownKey
            shownKey = nil
            if let key {
                let waves: Double? = Double(key)
                shownKey = key
                item.button?.image = image(for: key, waves: waves)
            }
        }
    #endif

    override func sessionDidBegin() {
        onOpen?()
    }

    override func clicked() {
        onToggle?()
    }

    override func sessionDidEnd() {
        onDismiss?()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = item.button?.window, event.window === window else { return false }
        switch event.type {
        case .rightMouseDown:
            onRightClick?(event)
            return true
        case .scrollWheel:
            guard scrolls else { return false }
            // A trackpad sends many small deltas, a wheel a few whole lines: both add up to steps.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            scrollRemainder += event.isDirectionInvertedFromDevice ? -delta : delta
            let steps = Int(scrollRemainder.rounded(.towardZero))
            guard steps != 0 else { return true }
            scrollRemainder -= CGFloat(steps)
            onScroll?(steps)
            return true
        default:
            return false
        }
    }
}
