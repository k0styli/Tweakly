import AppKit
import CustomIconCore
import SystemMetrics

/// The simple view's one item: the app's gear, or an icon someone added, standing still or on the move.
final class SimpleStatusItem: PopoverStatusItem {
    private var iconView: CustomIconView?
    private var iconID: String?
    private var usesOwnColours = false
    private var motion = IconMotion()
    private var follower = IconSpeedFollower()
    private var fillFollower = IconFillFollower()
    private var loads: [MetricKind: Double] = [:]
    private var isSlowed = false
    private var isSeen = false
    private var reducesMotion = false
    private var isLoaded = false
    private var isGear = true

    init(
        popover: StatsPopover,
        onOpen: @escaping (PopoverStatusItem) -> Void,
        onToggle: @escaping (PopoverStatusItem) -> Void,
        onDismiss: @escaping (PopoverStatusItem) -> Void
    ) {
        // The app's own gear under the name it has elsewhere, so that it keeps its place in the menu bar.
        super.init(
            length: NSStatusItem.squareLength, autosaveName: "tweakly.app", popover: popover, onOpen: onOpen,
            onToggle: onToggle, onDismiss: onDismiss)
        button?.setAccessibilityLabel("Tweakly")
        showGear()
    }

    /// Whether anything here needs to go on running, and so needs to hear about sleep and being covered.
    var isLive: Bool { shownMode != .still || motion.fills }

    /// The metrics to sample while the icon follows the load. Empty when it does not, or cannot be seen doing so. Filling
    /// goes on under Reduce Motion, as it says something and only its easing is motion.
    var loadKinds: [MetricKind] {
        var kinds: [MetricKind] = []
        if motion.fills, isSeen { kinds += Self.kinds(of: motion.fillSource) }
        if shownMode == .load, canMove { kinds += Self.kinds(of: motion.source) }
        return kinds
    }

    private static func kinds(of source: IconLoadSource) -> [MetricKind] {
        switch source {
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .busiest: [.cpu, .gpu]
        }
    }

    /// A nil id, or an icon that cannot be read, means the gear.
    func setIcon(id: String?, usesOwnColours: Bool) {
        guard !isLoaded || id != iconID || usesOwnColours != self.usesOwnColours else { return }
        isLoaded = true
        iconID = id
        self.usesOwnColours = usesOwnColours
        if let icon = id.flatMap(IconLibrary.load(id:)) {
            isGear = false
            show(icon)
        } else {
            isGear = true
            showGear()
        }
    }

    func setMotion(_ motion: IconMotion, isSeen: Bool, reducesMotion: Bool, isSlowed: Bool) {
        let isSame =
            motion == self.motion && isSeen == self.isSeen && reducesMotion == self.reducesMotion
            && isSlowed == self.isSlowed
        let gearChanges = isGear && motion.fills != self.motion.fills
        self.motion = motion
        self.isSeen = isSeen
        self.reducesMotion = reducesMotion
        self.isSlowed = isSlowed
        if gearChanges { showGear() }
        if !isSame { applyMotion() }
    }

    /// Hears about every metric in one delivery, and only uses those it is following. Each follower steps once a
    /// delivery: the busiest of the processor and the graphics comes as two updates at once, and stepping on each
    /// counted one reading twice, moving the icon three quarters of the way to the load rather than half.
    func noteLoads(_ updates: [MetricUpdate]) {
        note(updates.lazy.map { ($0.kind, $0.menuValue) })
    }

    #if TWEAKLY_AUTOMATION
        func noteLoad(of kind: MetricKind, value: MenuValue) { note([(kind, value)]) }
    #endif

    private func note<Readings: Sequence>(_ readings: Readings) where Readings.Element == (MetricKind, MenuValue) {
        var fillHeard = false
        var speedHeard = false
        for (kind, value) in readings {
            guard loadKinds.contains(kind), case .percent(let percent) = value else { continue }
            loads[kind] = Double(percent) / 100
            // Each follows its own source. A reading from the other's must not count as a reading of its own.
            if Self.kinds(of: motion.fillSource).contains(kind) { fillHeard = true }
            if Self.kinds(of: motion.source).contains(kind) { speedHeard = true }
        }
        if motion.fills, fillHeard, let load = load(of: motion.fillSource), let level = fillFollower.next(load: load) {
            iconView?.setFill(level, animated: !reducesMotion)
            button?.setAccessibilityValue(Format.percent(level))
        }
        if shownMode == .load, canMove, speedHeard, let load = load(of: motion.source),
            let speed = follower.next(load: load, motion: motion)
        {
            iconView?.play(speed: slowed(speed))
        }
    }

    #if TWEAKLY_AUTOMATION
        var automationDescription: String {
            let speed = iconView?.speed.map { String($0) } ?? "none"
            let fill = iconView?.fillLevel.map { String($0) } ?? "none"
            return "icon=\(iconID ?? "gear") shown=\(iconView != nil) speed=\(speed) fill=\(fill) canMove=\(canMove)"
        }
    #endif

    private var canMove: Bool { isSeen && !reducesMotion }

    private var shownMode: IconMotionMode {
        motion.shownMode(isAnimated: iconView?.isAnimated == true)
    }

    private func load(of source: IconLoadSource) -> Double? {
        Self.kinds(of: source).compactMap { loads[$0] }.max()
    }

    private func slowed(_ speed: Double) -> Double {
        // Low Power Mode slows everything down, because the person has asked the Mac to save energy.
        isSlowed ? speed / 2 : speed
    }

    private func applyMotion() {
        guard let iconView else { return }
        if motion.fills {
            // Until the first reading it stays as it was, or empty, and it rises from there.
            if iconView.fillLevel == nil { iconView.setFill(load(of: motion.fillSource) ?? 0, animated: false) }
        } else {
            iconView.setFill(nil, animated: false)
            fillFollower.reset()
            button?.setAccessibilityValue(nil)
        }
        guard shownMode != .still, canMove else {
            iconView.stop()
            follower.reset()
            return
        }
        switch motion.mode {
        case .still:
            iconView.stop()
        case .loop:
            follower.reset()
            iconView.play(speed: slowed(motion.loopSpeed))
        case .load:
            // Until the first reading it goes at its calm speed, and after that the next one decides.
            let speed = load(of: motion.source).map(motion.speed(atLoad:)) ?? motion.idleSpeed
            follower.reset()
            iconView.play(speed: slowed(speed))
        }
    }

    private func show(_ icon: LoadedIcon) {
        let view = iconView ?? makeIconView()
        button?.image = nil
        view.show(icon, usesOwnColours: usesOwnColours && icon.manifest.hasColours)
        // The gear keeps the width it has as a template image, so that nothing moves when it starts to fill.
        let width = CGFloat(icon.manifest.frameWidth) / CGFloat(IconFit.pixelsPerPoint)
        let length = isGear ? NSStatusItem.squareLength : width + Self.horizontalPadding * 2
        if item.length != length { item.length = length }
        applyMotion()
    }

    private func showGear() {
        if motion.fills, let gear = LoadedIcon.gear {
            show(gear)
            return
        }
        iconView?.removeFromSuperview()
        iconView = nil
        follower.reset()
        fillFollower.reset()
        button?.setAccessibilityValue(nil)
        button?.image = NSImage(named: "MenuBarIcon")
        if item.length != NSStatusItem.squareLength { item.length = NSStatusItem.squareLength }
    }

    private func makeIconView() -> CustomIconView {
        let view = CustomIconView(frame: .zero)
        iconView = view
        if let button {
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.horizontalPadding),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.horizontalPadding),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        return view
    }
}

extension CustomIconView {
    /// Whether the icon it shows has more than one frame.
    var isAnimated: Bool { shownIcon?.manifest.isAnimated == true }
}
