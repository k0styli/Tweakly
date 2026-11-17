import AppKit
import AudioMixerCore
import AudioToolbox
import CoreAudio
import notify
import os

#if TWEAKLY_AUTOMATION
    import SystemMetrics
#endif

/// What the popover needs from the settings, read as it opens.
struct MixerOptions {
    var showsInput: Bool
    var boosts: Bool
}

/// Shows the mixer's popover beneath its item and releases all of it when it closes, as the stats popovers do.
final class MixerPopoverPresenter {
    private let popover = MenuBarPopover()
    private var lastClosed: TimeInterval = 0
    var options: () -> MixerOptions = { MixerOptions(showsInput: true, boosts: false) }

    var isShown: Bool { popover.isShown }

    #if TWEAKLY_AUTOMATION
        var contentView: NSView? { popover.controller?.view }
    #endif

    func toggle(for item: MixerStatusItem) {
        if isShown {
            close()
            return
        }
        guard ProcessInfo.processInfo.systemUptime - lastClosed > MenuBarPopover.reopenGuard else { return }
        show(for: item)
    }

    /// Does nothing when it is showing already: macOS 27 begins a session of its own as the popover appears.
    func show(for item: MixerStatusItem) {
        guard !isShown else { return }
        let controller = MixerViewController(options: options())
        controller.onResize = { [weak self] in self?.popover.resize() }
        controller.onClose = { [weak self] in self?.close() }
        popover.show(
            controller, under: item, setsSizeFirst: true,
            fittingSize: { [weak controller] in controller?.fittingContentSize ?? .zero }
        ) { [weak self] in
            // Held until here, so its listeners always go with the popover.
            controller.stop()
            self?.lastClosed = ProcessInfo.processInfo.systemUptime
        }
    }

    func updateAppearance() {
        popover.updateAppearance()
    }

    func close() {
        popover.close()
    }
}

/// The popover: the output's volume, the outputs to choose from with the one in use's equalizer, each app with its own
/// volume, and the input.
/// It listens to Core Audio only while open and changes nothing until something is moved.
final class MixerViewController: NSViewController {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer")
    private static let screenMargin: CGFloat = 60
    private static let soundURL = "x-apple.systempreferences:com.apple.Sound-Settings.extension"

    private let options: MixerOptions
    var onResize: (() -> Void)?
    /// Closes the popover, before the window opens on top of it.
    var onClose: (() -> Void)?

    private let header = DetailHeaderView(title: String(localized: "Sound"), widestValue: "100 %")
    private let outputVolume = MixerVolumeRow(
        name: String(localized: "Volume"), symbol: "speaker.wave.3.fill", mutedSymbol: "speaker.slash.fill")
    private let outputsColumn = NSStackView.detailColumn(spacing: 0)
    /// The output in use's equalizer, as the input's menu is shown below: seen at a glance, changed in one click.
    private let equalizerMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var equalizerRow: NSStackView = {
        let label = NSTextField.detailLabel(String(localized: "Equalizer"), font: .systemFont(ofSize: 13))
        let row = NSStackView(views: [label, NSView(), equalizerMenu])
        row.orientation = .horizontal
        row.distribution = .fill
        return row
    }()
    private let appsColumn = NSStackView.detailColumn(spacing: 8)
    private let appsNote = NSTextField.detailLabel(color: .secondaryLabelColor)
    private lazy var permissionButton = NSButton(
        title: String(localized: "Allow Recording System Audio…"), target: self, action: #selector(openPrivacy))
    private let inputSection = NSStackView.detailColumn(spacing: 6)
    private let inputMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputVolume = MixerVolumeRow(
        name: String(localized: "Input Volume"), symbol: "mic.fill", mutedSymbol: "mic.slash.fill")
    private var root: DetailScrollRoot?

    private var outputs: [AudioDevice] = []
    private var inputs: [AudioDevice] = []
    private var outputID: AudioObjectID?
    private var inputID: AudioObjectID?
    private var shownApps: [String] = []
    private var appRows: [String: MixerAppRow] = [:]
    /// Core Audio's clients as apps, read again only when they change, not as a slider moves a rule.
    private var apps: [MixerApp]?
    private var ruledApps: Set<String> = []
    private let systemListener = AudioListener()
    private var deviceListener = AudioListener()
    private var clientListener = AudioListener()
    private var listenedClients: Set<AudioObjectID> = []
    private var eventTokens: [Int32] = []
    private var lastHeight: CGFloat = 0

    init(options: MixerOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        outputVolume.onChange = { volume in
            if let id = AudioSystem.defaultDevice(input: false) { AudioSystem.setVolume(volume, of: id, input: false) }
        }
        outputVolume.onToggleMute = { [weak self] in self?.toggleMute(input: false) }
        inputVolume.onChange = { volume in
            if let id = AudioSystem.defaultDevice(input: true) { AudioSystem.setVolume(volume, of: id, input: true) }
        }
        inputVolume.onToggleMute = { [weak self] in self?.toggleMute(input: true) }
        inputMenu.controlSize = .small
        inputMenu.target = self
        inputMenu.action = #selector(chooseInput)
        equalizerMenu.controlSize = .small
        equalizerMenu.setAccessibilityLabel(String(localized: "Equalizer"))
        appsNote.lineBreakMode = .byWordWrapping
        appsNote.maximumNumberOfLines = 0
        permissionButton.bezelStyle = .accessoryBar
        permissionButton.controlSize = .small

        let settingsButton = NSButton(
            title: String(localized: "Sound Settings…"), target: self, action: #selector(openSoundSettings))
        let mixerButton = NSButton(
            title: String(localized: "Mixer Settings…"), target: self, action: #selector(openMixerSettings))
        for button in [settingsButton, mixerButton] {
            button.bezelStyle = .accessoryBar
            button.controlSize = .small
        }
        let footer = NSStackView(views: [settingsButton, NSView(), mixerButton])
        footer.orientation = .horizontal
        footer.distribution = .fill

        inputSection.addFullWidth(detailSectionTitle(String(localized: "Input")))
        inputSection.addFullWidth(inputMenu)
        inputSection.addFullWidth(inputVolume)
        inputSection.isHidden = !options.showsInput

        let column = NSStackView.detailColumn(
            spacing: DetailLayout.sectionSpacing,
            [
                NSStackView.detailColumn(spacing: 8, [header, outputVolume]),
                NSStackView.detailColumn(
                    spacing: 4, [detailSectionTitle(String(localized: "Output")), outputsColumn, equalizerRow]),
                NSStackView.detailColumn(
                    spacing: 6,
                    [detailSectionTitle(String(localized: "Apps")), appsColumn, appsNote, permissionButton]),
                inputSection,
                footer,
            ])
        let root = DetailScrollRoot(column: column, width: DetailLayout.width)
        self.root = root
        view = root
        start()
    }

    // MARK: Listening

    private func start() {
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject),
            [
                kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultInputDevice,
            ]
        ) { [weak self] in self?.refreshDevices() }
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyProcessObjectList]
        ) { [weak self] in self?.refreshApps(readingClients: true) }
        // After the sound server starts again, every listener on a device or a client has to be made again.
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]
        ) { [weak self] in
            guard let self else { return }
            outputID = nil
            inputID = nil
            listenedClients = []
            refreshDevices()
            refreshApps(readingClients: true)
        }
        eventTokens = [
            ProcessEvents.observe(.audioRulesChanged) { [weak self] in self?.refreshApps(readingClients: false) },
            ProcessEvents.observe(.volumeMixerStateChanged) { [weak self] in self?.refreshApps(readingClients: false) },
        ]
        refreshDevices()
        refreshApps(readingClients: true)
    }

    func stop() {
        systemListener.stop()
        deviceListener.stop()
        clientListener.stop()
        for token in eventTokens { notify_cancel(token) }
        eventTokens = []
    }

    // MARK: Devices

    private func refreshDevices() {
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn {
                outputs = DemoMixer.outputs()
                inputs = DemoMixer.inputs()
                outputID = outputs.first?.id
                inputID = inputs.first?.id
                inputSection.isHidden = !options.showsInput || inputs.isEmpty
                showOutputs()
                showInputs()
                refreshVolumes()
                resize()
                return
            }
        #endif
        outputs = AudioSystem.devices(input: false)
        inputs = AudioSystem.devices(input: true)
        let newOutput = AudioSystem.defaultDevice(input: false)
        let newInput = AudioSystem.defaultDevice(input: true)
        // A Mac with no microphone at all, such as a Mac mini without one plugged in, has nothing to show there.
        inputSection.isHidden = !options.showsInput || inputs.isEmpty
        if newOutput != outputID || newInput != inputID {
            outputID = newOutput
            inputID = newInput
            // The volume and mute of the devices in use now, heard as they change, the keys included.
            deviceListener.stop()
            deviceListener = AudioListener()
            for (id, input) in [(newOutput, false), (newInput, true)] {
                guard let id else { continue }
                deviceListener.listen(
                    to: id, [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute],
                    scope: AudioSystem.scope(input)
                ) { [weak self] in self?.refreshVolumes() }
            }
        }
        showOutputs()
        showInputs()
        refreshVolumes()
        resize()
    }

    private func showOutputs() {
        outputsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let book = AudioRuleStore.load()
        let custom = AudioRuleStore.customPresets()
        shownEqualizers = [:]
        shownPresets = custom.map(\.id) + custom.map(\.name)
        for device in outputs {
            let settings = book.equalizer(forOutput: device.uid)
            let described = settings.isFlat ? nil : EqualizerNames.describe(settings, custom: custom)
            shownEqualizers[device.uid] = described
            // The output in use has its equalizer in the row below the list; the others say theirs beside the name.
            let row = MixerDeviceRow(
                device: device, isCurrent: device.id == outputID, equalizer: device.id == outputID ? nil : described)
            row.onChoose = { [weak self] in
                Self.log.notice("Output of kind \(device.kind.rawValue, privacy: .public) chosen in the popover")
                AudioSystem.setDefaultDevice(device.id, input: false)
                self?.refreshDevices()
            }
            row.makeMenu = { [weak self] in self?.equalizerMenu(for: device) ?? NSMenu() }
            outputsColumn.addFullWidth(row)
        }
        showEqualizer(book: book, custom: custom)
    }

    /// The output in use's equalizer in its menu, the one chosen checked and shown.
    private func showEqualizer(book: AudioRuleBook, custom: [CustomEqualizerPreset]) {
        let menu = NSMenu()
        guard let device = outputs.first(where: { $0.id == outputID }) else {
            equalizerRow.isHidden = true
            return
        }
        equalizerRow.isHidden = false
        if device.isStereo {
            for item in EqualizerMenu.items(
                settings: book.equalizer(forOutput: device.uid), custom: custom,
                choose: { AudioRuleStore.setEqualizer($0, forOutput: device.uid, name: device.name) },
                customize: { [weak self] in
                    self?.onClose?()
                    EqualizerMenu.customize("output:\(device.uid)")
                })
            {
                menu.addItem(item)
            }
        } else {
            menu.addItem(withTitle: String(localized: "For Stereo Outputs Only"), action: nil, keyEquivalent: "")
        }
        equalizerMenu.menu = menu
        if let chosen = menu.items.first(where: { $0.state == .on }) { equalizerMenu.select(chosen) }
        equalizerMenu.isEnabled = device.isStereo
    }

    /// An output's equalizer as a menu, from the rules as they are now.
    private func equalizerMenu(for device: AudioDevice) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Equalizer")))
        guard device.isStereo else {
            // The mixer's sound is stereo: a surround output is left as it is.
            let note = menu.addItem(
                withTitle: String(localized: "For Stereo Outputs Only"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            return menu
        }
        let settings = AudioRuleStore.load().equalizer(forOutput: device.uid)
        for item in EqualizerMenu.items(
            settings: settings, custom: AudioRuleStore.customPresets(),
            choose: { AudioRuleStore.setEqualizer($0, forOutput: device.uid, name: device.name) },
            customize: { [weak self] in
                self?.onClose?()
                EqualizerMenu.customize("output:\(device.uid)")
            })
        {
            menu.addItem(item)
        }
        return menu
    }

    /// Each output's equalizer as last shown, and the person's presets, so a rule moving a slider many times a second
    /// does not lay the rows out again.
    private var shownEqualizers: [String: String] = [:]
    private var shownPresets: [String] = []

    private func equalizersChanged() -> Bool {
        let book = AudioRuleStore.load()
        let custom = AudioRuleStore.customPresets()
        // A preset saved or renamed belongs in the equalizer's menu too.
        if custom.map(\.id) + custom.map(\.name) != shownPresets { return true }
        for device in outputs {
            let settings = book.equalizer(forOutput: device.uid)
            let described = settings.isFlat ? nil : EqualizerNames.describe(settings, custom: custom)
            if shownEqualizers[device.uid] != described { return true }
        }
        return false
    }

    private func showInputs() {
        inputMenu.removeAllItems()
        for device in inputs {
            inputMenu.addItem(withTitle: device.name)
            inputMenu.lastItem?.representedObject = device.id
            inputMenu.lastItem?.image = NSImage(systemSymbolName: device.kind.symbolName, accessibilityDescription: nil)
        }
        if let index = inputs.firstIndex(where: { $0.id == inputID }) { inputMenu.selectItem(at: index) }
        inputMenu.isEnabled = inputs.count > 1
    }

    private func refreshVolumes() {
        let name = outputs.first { $0.id == outputID }?.name ?? String(localized: "No Output")
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn {
                header.update(subtitle: name, value: VolumeLevel.shown(DemoMixer.outputVolume))
                outputVolume.show(volume: DemoMixer.outputVolume, isMuted: false, canChange: true)
                inputVolume.show(volume: DemoMixer.inputVolume, isMuted: false, canChange: true)
                return
            }
        #endif
        if let id = outputID {
            let volume = AudioSystem.volume(of: id, input: false)
            let muted = AudioSystem.isMuted(id, input: false) ?? false
            header.update(
                subtitle: name,
                value: muted ? String(localized: "Muted") : volume.map(VolumeLevel.shown) ?? "—")
            outputVolume.show(
                volume: volume ?? 1, isMuted: muted, canChange: AudioSystem.canSetVolume(of: id, input: false))
        } else {
            header.update(subtitle: name, value: "—")
            outputVolume.show(volume: 0, isMuted: true, canChange: false)
        }
        if let id = inputID {
            inputVolume.show(
                volume: AudioSystem.volume(of: id, input: true) ?? 1,
                isMuted: AudioSystem.isMuted(id, input: true) ?? false,
                canChange: AudioSystem.canSetVolume(of: id, input: true))
        } else {
            inputVolume.show(volume: 0, isMuted: true, canChange: false)
        }
    }

    private func toggleMute(input: Bool) {
        guard let id = AudioSystem.defaultDevice(input: input) else { return }
        AudioSystem.setMuted(!(AudioSystem.isMuted(id, input: input) ?? false), of: id, input: input)
        refreshVolumes()
    }

    @objc private func chooseInput() {
        guard let id = inputMenu.selectedItem?.representedObject as? AudioObjectID else { return }
        Self.log.notice("Input chosen in the popover")
        AudioSystem.setDefaultDevice(id, input: true)
        refreshDevices()
    }

    // MARK: Apps

    private func refreshApps(readingClients: Bool) {
        #if TWEAKLY_AUTOMATION
            let isDemo = DemoData.isOn
            if isDemo { apps = DemoMixer.apps() }
            let rules = isDemo ? DemoMixer.rules : AudioRuleStore.load()
            let permitted = isDemo || AudioRuleStore.isPermitted
            let stopped = !isDemo && AudioRuleStore.hasStopped
        #else
            let isDemo = false
            let rules = AudioRuleStore.load()
            let permitted = AudioRuleStore.isPermitted
            let stopped = AudioRuleStore.hasStopped
        #endif
        let ruled = Set(rules.rules.keys)
        // An app given its first rule may have gone quiet unheard, so the clients are read again for it too.
        if !isDemo, readingClients || apps == nil || ruled != ruledApps {
            apps = AudioAppGrouping.apps(clients: AudioSystem.clients(), owner: AudioSystem.owner(of:))
        }
        ruledApps = ruled
        let apps = self.apps ?? []
        listenToPlaying(apps)
        let shown = AudioAppGrouping.shown(apps, ruled: ruled, alreadyShown: shownApps)
        shownApps = shown.map(\.id)
        let highest = AudioRuleBook.highestVolume(boosting: options.boosts)
        var rows: [MixerAppRow] = []
        for app in shown {
            let row = appRows[app.id] ?? makeRow(for: app)
            appRows[app.id] = row
            row.show(
                app: app, rule: rules.rule(for: app.id), highest: highest, outputs: outputs,
                outputName: rules.rule(for: app.id).outputUID.flatMap { uid in outputs.first { $0.uid == uid }?.name })
            rows.append(row)
        }
        var changed = false
        if appsColumn.arrangedSubviews != rows {
            appsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows.forEach(appsColumn.addFullWidth)
            changed = true
        }
        let note =
            if stopped {
                String(
                    localized:
                        "Apps play at their own volume: the part of Tweakly that changes it stopped twice. Turn the mixer off and on to try again."
                )
            } else if !permitted {
                String(
                    localized: "macOS has not allowed Tweakly to record system audio, so apps play at their own volume."
                )
            } else {
                String(localized: "Nothing is playing now.")
            }
        let noteHidden = permitted && !stopped && !rows.isEmpty
        if permissionButton.isHidden != permitted || appsNote.stringValue != note || appsNote.isHidden != noteHidden {
            permissionButton.isHidden = permitted
            appsNote.stringValue = note
            appsNote.isHidden = noteHidden
            changed = true
        }
        if equalizersChanged() {
            showOutputs()
            changed = true
        }
        // Solving the layout as a slider moves, just to find the same height, would be the costliest thing here.
        if changed { resize() }
    }

    private func makeRow(for app: MixerApp) -> MixerAppRow {
        let row = MixerAppRow(bundleID: app.id)
        row.onChange = { bundleID, change in AudioRuleStore.update(bundleID, change) }
        row.onCustomize = { [weak self] bundleID in
            self?.onClose?()
            EqualizerMenu.customize("app:\(bundleID)")
        }
        return row
    }

    /// Whether each app plays is a property of its processes, heard while the popover is open.
    private func listenToPlaying(_ apps: [MixerApp]) {
        let objects = Set(apps.flatMap(\.objectIDs))
        guard objects != listenedClients else { return }
        clientListener.stop()
        clientListener = AudioListener()
        for object in objects {
            clientListener.listen(to: object, [kAudioProcessPropertyIsRunningOutput]) { [weak self] in
                self?.refreshApps(readingClients: true)
            }
        }
        listenedClients = objects
    }

    // MARK: Size and actions

    var fittingContentSize: NSSize {
        loadViewIfNeeded()
        return root?.fittingContentSize(screenMargin: Self.screenMargin) ?? .zero
    }

    private func resize() {
        guard isViewLoaded else { return }
        let height = fittingContentSize.height
        guard height != lastHeight else { return }
        lastHeight = height
        onResize?()
    }

    @objc private func openPrivacy() {
        if let url = URL(string: AudioRuleStore.privacySettingsURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: Self.soundURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openMixerSettings() {
        WindowProcess.openVolumeMixer()
    }
}

// MARK: - Rows

/// The centre of the icons down the popover's left edge, which the sliders and names start after.
private enum MixerColumn {
    static let iconCentre: CGFloat = 11
    static let textStart: CGFloat = 28
}

/// A slider marked at 0, 50 and 100 %, and at 150 and 200 % while boosting, that catches the knob as it passes near a
/// mark, with the trackpad's light tap, as System Settings' sliders with marks do. Between the marks it moves by whole
/// percents. The volume keys' sixteenths were tried for the output; whole percents read better.
final class SnappingSlider: NSSlider {
    /// How near a mark, as a share of the range, the knob is caught.
    private static let reach = 0.025
    private var caught: Double?
    /// The values it takes between the marks: whole percents.
    private let step = 0.01

    convenience init(highest: Double, size: NSControl.ControlSize) {
        self.init(value: 0, minValue: 0, maxValue: highest, target: nil, action: nil)
        controlSize = size
        isContinuous = true
        tickMarkPosition = .below
        allowsTickMarkValuesOnly = false
        numberOfTickMarks = Self.marks(upTo: highest)
        translatesAutoresizingMaskIntoConstraints = false
    }

    private static func marks(upTo highest: Double) -> Int { Int((highest / 0.5).rounded()) + 1 }

    func setHighest(_ highest: Double) {
        guard maxValue != highest else { return }
        maxValue = highest
        numberOfTickMarks = Self.marks(upTo: highest)
    }

    /// Where the knob is after a move: on a step, and caught by a mark within reach.
    func snappedValue() -> Double {
        let value = (doubleValue / step).rounded() * step
        if doubleValue != value { doubleValue = value }
        let mark = closestTickMarkValue(toValue: value)
        guard numberOfTickMarks > 0, abs(value - mark) <= (maxValue - minValue) * Self.reach else {
            caught = nil
            return value
        }
        if caught != mark {
            caught = mark
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if doubleValue != mark { doubleValue = mark }
        return mark
    }

    // VoiceOver says the share as the row shows it, not the slider's own 0 to 2. It asks on the main thread.
    nonisolated override func accessibilityValue() -> Any? {
        MainActor.assumeIsolated { VolumeLevel.shown(doubleValue) }
    }

    /// Not while the knob is held, or the echo of the change would fight the pointer. This slider's own, so that a
    /// click elsewhere in the popover, on an output say, still lets the others follow.
    private(set) var isHeld = false

    override func mouseDown(with event: NSEvent) {
        // The slider follows the pointer inside this call until the button goes up.
        isHeld = true
        defer { isHeld = false }
        super.mouseDown(with: event)
    }
}

/// A mute button and a slider, for the output's or the input's volume.
final class MixerVolumeRow: NSView {
    private let button = MuteButton.make()
    private let slider = SnappingSlider(highest: 1, size: .regular)
    private let symbol: String
    private let mutedSymbol: String
    var onChange: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?

    /// - Parameter name: What VoiceOver calls the slider, which has no title of its own on screen.
    init(name: String, symbol: String, mutedSymbol: String) {
        self.symbol = symbol
        self.mutedSymbol = mutedSymbol
        super.init(frame: .zero)
        slider.setAccessibilityLabel(name)
        translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(toggle)
        slider.target = self
        slider.action = #selector(moved)
        addSubview(button)
        addSubview(slider)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.iconCentre),
            button.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.textStart),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(volume: Double, isMuted: Bool, canChange: Bool) {
        if !slider.isHeld, abs(slider.doubleValue - volume) > 0.001 { slider.doubleValue = volume }
        slider.isEnabled = canChange
        button.show(symbol: isMuted || volume < 0.001 ? mutedSymbol : symbol, isMuted: isMuted)
    }

    @objc private func moved() {
        onChange?(slider.snappedValue())
    }

    @objc private func toggle() {
        onToggleMute?()
    }
}

/// An output to choose: its symbol, its name, its equalizer while it has one, and a check on the one in use. The whole
/// row is the button, as in the system's sound menu, and the pointer lights it as it lights a menu's row, a little past
/// the row on both sides so the symbols stay in line with the apps'. A right click opens its equalizer's menu.
final class MixerDeviceRow: NSControl {
    var onChoose: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private let highlight = RowHighlight()

    init(device: AudioDevice, isCurrent: Bool, equalizer: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(
            image: NSImage(systemSymbolName: device.kind.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField.detailLabel(device.name, font: .systemFont(ofSize: 13))
        let check = NSImageView(
            image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        check.contentTintColor = .controlAccentColor
        check.isHidden = !isCurrent
        check.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField.detailLabel(
            equalizer ?? "", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        [highlight, icon, name, detail, check].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 6),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.iconCentre),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.textStart),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            // Where the check is, so the equalizer of every output lines up whether it is in use or not.
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            check.trailingAnchor.constraint(equalTo: trailingAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(device.name)
        let state = [isCurrent ? String(localized: "Selected") : nil, equalizer].compactMap { $0 }
        setAccessibilityValue(state.isEmpty ? nil : state.joined(separator: ", "))
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) { highlight.isHidden = false }
    override func mouseExited(with event: NSEvent) { highlight.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        onChoose?()
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: MixerColumn.textStart, y: bounds.minY), in: self)
        return true
    }
}

/// What a menu item made afresh each time its menu opens runs. The item holds it as its represented object, since an
/// item's target is not kept.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    static func item(_ title: String, state: NSControl.StateValue = .off, _ handler: @escaping () -> Void)
        -> NSMenuItem
    {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.state = state
        return item
    }
}

/// An equalizer's choices for a menu, as its pop-up in the window: Off, Manual while the sliders were moved, Music's
/// presets and the person's own with a check on the one in use, and Customize… for the sliders.
enum EqualizerMenu {
    static func items(
        settings: EqualizerSettings, custom: [CustomEqualizerPreset], choose: @escaping (EqualizerSettings) -> Void,
        customize: @escaping () -> Void
    ) -> [NSMenuItem] {
        let current = settings.isFlat ? nil : EqualizerNames.choice(of: settings, custom: custom)
        var items: [NSMenuItem] = [
            MenuAction.item(
                String(localized: "Off", comment: "The equalizer, as in Music"), state: settings.isFlat ? .on : .off
            ) { choose(.flat) }
        ]
        if !settings.isFlat, current == nil {
            let manual = NSMenuItem(
                title: String(
                    localized: "Manual", comment: "An equalizer whose sliders were moved by hand, as in Music"),
                action: nil, keyEquivalent: "")
            manual.state = .on
            items.append(manual)
        }
        items.append(.separator())
        for preset in EqualizerNames.presets() {
            items.append(
                MenuAction.item(EqualizerNames.name(of: preset.id), state: current == preset.id ? .on : .off) {
                    choose(preset.settings)
                })
        }
        if !custom.isEmpty {
            items.append(.separator())
            for preset in custom {
                items.append(
                    MenuAction.item(preset.name, state: current == preset.id ? .on : .off) { choose(preset.settings) })
            }
        }
        items.append(.separator())
        items.append(MenuAction.item(String(localized: "Customize…")) { customize() })
        return items
    }

    /// Opens the window's sliders for this equalizer.
    static func customize(_ target: String) {
        AudioRuleStore.askToEdit(target)
        WindowProcess.openVolumeMixer()
    }
}

/// The light rounded fill under the pointer, in the system's colour for it.
private final class RowHighlight: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// One app: its icon and name, how loud it plays against its own volume, a mute button, and a slider. A right click
/// chooses its own output and equalizer or puts it back as it plays by itself, as a context menu does anywhere in macOS.
final class MixerAppRow: NSView {
    let bundleID: String
    var onChange: ((String, (inout AppAudioRule) -> Void) -> Void)?
    var onCustomize: ((String) -> Void)?

    private let icon = NSImageView()
    private let name = NSTextField.detailLabel(font: .systemFont(ofSize: 13))
    private let detail = NSTextField.detailLabel(font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let percent = NSTextField.detailLabel(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor,
        alignment: .right)
    private let muteButton = MuteButton.make()
    // The same size as the output's, whose knob is round: a small slider with marks has a tall, narrow one.
    private let slider = SnappingSlider(highest: 1, size: .regular)
    private var outputs: [AudioDevice] = []
    private var rule = AppAudioRule.standard

    init(bundleID: String) {
        self.bundleID = bundleID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        // The name beside it says the same.
        icon.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        slider.target = self
        slider.action = #selector(moved)
        percent.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [icon, name, detail, percent, muteButton, slider].forEach(addSubview)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.iconCentre),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.textStart),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: percent.leadingAnchor, constant: -6),
            percent.trailingAnchor.constraint(equalTo: trailingAnchor),
            percent.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            percent.widthAnchor.constraint(greaterThanOrEqualToConstant: percent.requiredWidth(for: "200 %")),
            muteButton.centerXAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.iconCentre),
            muteButton.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            slider.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MixerColumn.textStart),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(app: MixerApp, rule: AppAudioRule, highest: Double, outputs: [AudioDevice], outputName: String?) {
        self.rule = rule
        self.outputs = outputs
        if icon.image == nil { icon.image = Self.icon(of: app.owner) }
        name.setIfChanged(app.owner.name)
        detail.setIfChanged(outputName ?? "")
        let shown = min(rule.volume, highest)
        slider.setHighest(highest)
        if !slider.isHeld, abs(slider.doubleValue - shown) > 0.001 { slider.doubleValue = shown }
        percent.setIfChanged(rule.isMuted ? String(localized: "Muted") : VolumeLevel.shown(shown))
        icon.alphaValue = app.isPlaying ? 1 : 0.5
        muteButton.show(
            symbol: rule.isMuted || shown < 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill", isMuted: rule.isMuted,
            of: app.owner.name)
        slider.setAccessibilityLabel(app.owner.name)
        // The row is where VoiceOver finds the app's menu of outputs, as a right click does.
        setAccessibilityLabel(app.owner.name)
    }

    /// The app's icon, or for a process with no app, such as a command-line player, its file's, as Activity Monitor
    /// shows it.
    private static func icon(of owner: AudioOwner) -> NSImage? {
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner.bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        #endif
        if let app = NSRunningApplication(processIdentifier: owner.pid), let icon = app.icon { return icon }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(owner.pid, &path, UInt32(path.count)) > 0 else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(
            forFile: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    override func accessibilityPerformShowMenu() -> Bool {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: MixerColumn.textStart, y: bounds.minY), in: self)
        return true
    }

    /// The output for this app alone, the system's by default, its sound on or off, and a way back to how it plays by
    /// itself.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Output")))
        let system = menu.addItem(
            withTitle: String(localized: "System Output"), action: #selector(chooseOutput(_:)), keyEquivalent: "")
        system.target = self
        system.state = rule.outputUID == nil ? .on : .off
        for (index, device) in outputs.enumerated() {
            let item = menu.addItem(withTitle: device.name, action: #selector(chooseOutput(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index + 1
            item.image = NSImage(systemSymbolName: device.kind.symbolName, accessibilityDescription: nil)
            item.state = rule.outputUID == device.uid ? .on : .off
        }
        menu.addItem(.separator())
        let equalizer = NSMenuItem(title: String(localized: "Equalizer"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let bundleID = bundleID
        for item in EqualizerMenu.items(
            settings: rule.equalizer ?? .flat, custom: AudioRuleStore.customPresets(),
            choose: { [weak self] settings in
                self?.onChange?(bundleID) { $0.equalizer = settings.isFlat ? nil : settings }
            },
            customize: { [weak self] in self?.onCustomize?(bundleID) })
        {
            submenu.addItem(item)
        }
        equalizer.submenu = submenu
        menu.addItem(equalizer)
        menu.addItem(.separator())
        let mute = menu.addItem(
            withTitle: rule.isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
            action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        let reset = menu.addItem(withTitle: String(localized: "Reset"), action: #selector(reset), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !rule.isStandard
        return menu
    }

    @objc private func moved() {
        let volume = slider.snappedValue()
        percent.setIfChanged(VolumeLevel.shown(volume))
        onChange?(bundleID) {
            $0.volume = volume
            $0.isMuted = false
        }
    }

    @objc private func toggleMute() {
        let muted = !rule.isMuted
        onChange?(bundleID) { $0.isMuted = muted }
    }

    @objc private func chooseOutput(_ item: NSMenuItem) {
        let uid = item.tag == 0 ? nil : outputs.indices.contains(item.tag - 1) ? outputs[item.tag - 1].uid : nil
        onChange?(bundleID) { $0.outputUID = uid }
    }

    @objc private func reset() {
        onChange?(bundleID) { $0 = .standard }
    }
}

/// The speaker or microphone before a slider, which turns the sound off and on.
private final class MuteButton: NSButton {
    private var shown: (symbol: String, isMuted: Bool, app: String?)?

    static func make() -> MuteButton {
        let button = MuteButton(image: NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Makes the picture only when it changes: a system symbol costs about 2M instructions, and the rows are shown
    /// again each time a slider moves.
    /// - Parameter app: whose sound it is, for VoiceOver, where a row of apps has a button each.
    func show(symbol: String, isMuted: Bool, of app: String? = nil) {
        guard shown?.symbol != symbol || shown?.isMuted != isMuted || shown?.app != app else { return }
        shown = (symbol, isMuted, app)
        let label =
            switch (isMuted, app) {
            case (true, let app?): String(localized: "Unmute \(app)")
            case (false, let app?): String(localized: "Mute \(app)")
            case (true, nil): String(localized: "Unmute")
            case (false, nil): String(localized: "Mute")
            }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        setAccessibilityLabel(label)
    }
}

extension VolumeLevel {
    /// A volume as the region writes a percentage, "50 %" in Russian and German, "50%" in English, up to 200 %.
    static func shown(_ volume: Double) -> String {
        Format.percent(Double(percent(volume)) / 100)
    }
}
