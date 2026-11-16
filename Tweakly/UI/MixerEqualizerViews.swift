import AppKit
import AudioMixerCore
import CoreAudio
import SwiftUI
import notify

/// Whose equalizer: an output's, over everything it plays, or one app's, before its output's.
enum EqualizerTarget: Identifiable, Hashable {
    case output(uid: String, name: String)
    case app(bundleID: String, name: String)

    var id: String {
        switch self {
        case .output(let uid, _): "output:\(uid)"
        case .app(let bundleID, _): "app:\(bundleID)"
        }
    }

    var name: String {
        switch self {
        case .output(_, let name), .app(_, let name): name
        }
    }

    func settings(in book: AudioRuleBook) -> EqualizerSettings {
        switch self {
        case .output(let uid, _): book.equalizer(forOutput: uid)
        case .app(let bundleID, _): book.rule(for: bundleID).equalizer ?? .flat
        }
    }

    func save(_ settings: EqualizerSettings) {
        switch self {
        case .output(let uid, let name):
            AudioRuleStore.setEqualizer(settings, forOutput: uid, name: name)
        case .app(let bundleID, _):
            AudioRuleStore.update(bundleID) { $0.equalizer = settings.isFlat ? nil : settings }
        }
    }
}

/// The equalizer's choice as a pop-up menu, as Music has it: Off, Manual once a slider moved, Music's presets, the
/// person's own, and Customize… for the sliders.
struct EqualizerPicker: View {
    let title: Text
    let settings: EqualizerSettings
    let custom: [CustomEqualizerPreset]
    let choose: (EqualizerSettings) -> Void
    /// Opens the sliders; nil where they are already open.
    var customize: (() -> Void)?

    private static let off = "off"
    private static let manual = "manual"
    private static let customizeTag = "customize"

    var body: some View {
        Picker(selection: selection) {
            Text("Off", comment: "The equalizer, as in Music").tag(Self.off)
            if current == Self.manual {
                Text("Manual", comment: "An equalizer whose sliders were moved by hand, as in Music").tag(Self.manual)
            }
            Divider()
            ForEach(EqualizerNames.presets) { preset in
                Text(verbatim: EqualizerNames.name(of: preset.id)).tag(preset.id)
            }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { preset in
                    Text(verbatim: preset.name).tag(preset.id)
                }
            }
            if customize != nil {
                Divider()
                Text("Customize…").tag(Self.customizeTag)
            }
        } label: {
            title
        }
    }

    private var current: String {
        if settings.isFlat { return Self.off }
        return EqualizerNames.choice(of: settings, custom: custom) ?? Self.manual
    }

    private var selection: Binding<String> {
        Binding(
            get: { current },
            set: { tag in
                switch tag {
                case Self.off: choose(.flat)
                case Self.manual: break
                case Self.customizeTag: customize?()
                default:
                    if let settings = EqualizerNames.settings(for: tag, custom: custom) { choose(settings) }
                }
            })
    }
}

/// The sliders of one equalizer, as Music's window has them: the preamp, then a slider for each band, every change
/// heard at once.
struct EqualizerEditor: View {
    let target: EqualizerTarget
    @State private var settings: EqualizerSettings
    @State private var custom = AudioRuleStore.customPresets()
    @State private var isNaming = false
    @State private var newName = ""

    init(target: EqualizerTarget) {
        self.target = target
        _settings = State(initialValue: target.settings(in: AudioRuleStore.load()))
    }

    var body: some View {
        DetailsSheet(
            height: 392, resetTitle: "Reset", canReset: !settings.isFlat, reset: { apply(.flat) }
        ) {
            Section {
                EqualizerPicker(
                    title: Text("Preset", comment: "An equalizer preset, as in Music"), settings: settings,
                    custom: custom, choose: apply)
            } header: {
                SectionTitle(title: Text(verbatim: target.name), detail: explanation)
            }
            Section {
                EqualizerBands(settings: settings) { changed in
                    var moved = changed
                    moved.presetID = nil
                    apply(moved)
                }
            }
            .sectionActions {
                Button("Make Preset…") {
                    newName = ""
                    isNaming = true
                }
                .disabled(settings.isFlat)
            }
        }
        .alert("Make Preset", isPresented: $isNaming) {
            TextField("New Preset Name:", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("OK") { makePreset() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var explanation: Text {
        switch target {
        case .output:
            Text("Everything this output plays. An app’s own equalizer comes before it.")
        case .app:
            Text("This app’s sound alone, before its output’s equalizer.")
        }
    }

    private func apply(_ newSettings: EqualizerSettings) {
        settings = newSettings
        target.save(newSettings)
    }

    private func makePreset() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = CustomEqualizerPreset(name: name, from: settings)
        custom.append(preset)
        AudioRuleStore.saveCustomPresets(custom)
        apply(preset.settings)
    }
}

/// The preamp and ten bands, each a vertical slider from −12 to +12 dB, with the scale beside them.
struct EqualizerBands: View {
    let settings: EqualizerSettings
    let change: (EqualizerSettings) -> Void

    private static let sliderHeight: CGFloat = 150
    private static let bandWidth: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            scale
            column(
                value: settings.preamp, label: Text("Preamp", comment: "The equalizer's preamp, as in Music"),
                spoken: String(localized: "Preamp", comment: "The equalizer's preamp, as in Music"), width: 80
            ) { value in
                var copy = settings
                copy.preamp = value
                change(copy)
            }
            Divider()
                .frame(height: Self.sliderHeight)
                .padding(.horizontal, 6)
            ForEach(EqualizerSettings.frequencies.indices, id: \.self) { index in
                let frequency = EqualizerSettings.frequencies[index]
                column(
                    value: settings.bands[index], label: Text(verbatim: EqualizerNames.shortLabel(frequency)),
                    spoken: EqualizerNames.spokenFrequency(frequency), width: Self.bandWidth
                ) { value in
                    var copy = settings
                    copy.bands[index] = value
                    change(copy)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// +12, 0 and −12 dB beside the sliders' track, as Music's scale.
    private var scale: some View {
        VStack(alignment: .trailing) {
            Text(verbatim: EqualizerNames.decibels(12))
            Spacer()
            Text(verbatim: EqualizerNames.decibels(0))
            Spacer()
            Text(verbatim: EqualizerNames.decibels(-12))
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Self.sliderHeight - 8)
        .padding(.top, 4)
        .padding(.trailing, 6)
        .accessibilityHidden(true)
    }

    private func column(
        value: Double, label: Text, spoken: String, width: CGFloat, set: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 4) {
            VerticalGainSlider(value: value, spoken: spoken, set: set)
                .frame(width: 22, height: Self.sliderHeight)
            label
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
        .frame(width: width)
    }
}

/// A vertical `NSSlider`, which SwiftUI does not have on the Mac: the control Music's equalizer is made of. It stops at
/// 0 dB on the way through, with a tap on the trackpad, so a band is easy to put back.
struct VerticalGainSlider: NSViewRepresentable {
    let value: Double
    let spoken: String
    let set: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let range = EqualizerSettings.range
        let slider = NSSlider(
            value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator,
            action: #selector(Coordinator.moved(_:)))
        slider.isVertical = true
        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .leading
        slider.isContinuous = true
        slider.setAccessibilityLabel(spoken)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.set = set
        if abs(slider.doubleValue - value) > 0.01 { slider.doubleValue = value }
        slider.setAccessibilityLabel(spoken)
        slider.setAccessibilityValueDescription(EqualizerNames.decibels(value))
    }

    func makeCoordinator() -> Coordinator { Coordinator(set: set) }

    final class Coordinator: NSObject {
        var set: (Double) -> Void
        private var isAtZero = false

        init(set: @escaping (Double) -> Void) {
            self.set = set
        }

        @objc func moved(_ slider: NSSlider) {
            // Quarter decibels, and 0 dB catches the knob within half a decibel.
            var value = (slider.doubleValue * 4).rounded() / 4
            let atZero = abs(value) < 0.5
            if atZero {
                value = 0
                if !isAtZero { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            isAtZero = atZero
            set(value)
        }
    }
}

/// The order outputs and inputs are chosen in, as Network's Set Service Order: drag a device up or down, or use its
/// menu.
struct DeviceOrderSheet: View {
    @State private var order = AudioDeviceStore.load()
    @State private var isInput = false
    @State private var connected: Set<String> = []
    @State private var tokens: [Int32] = []
    @State private var listener: AudioListener?

    var body: some View {
        DetailsSheet(height: 440) {
            Section {
                Picker(selection: $isInput) {
                    Text("Output").tag(false)
                    Text("Input").tag(true)
                } label: {
                    Text("Devices")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                SectionTitle(
                    title: Text("Device Order"),
                    detail: Text(
                        "As devices come and go, the first one connected is chosen. Drag a device to move it."))
            }
            Section {
                let list = order.list(input: isInput)
                if list.isEmpty {
                    Text("Devices appear here as they connect.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(list.enumerated()), id: \.element.uid) { index, device in
                    row(device, index: index, count: list.count)
                }
                .onMove { from, to in
                    var moved = order.list(input: isInput)
                    moved.move(fromOffsets: from, toOffset: to)
                    store(moved)
                }
            }
        }
        .onAppear {
            refreshConnected()
            tokens = [ProcessEvents.observe(.audioDevicesChanged) { order = AudioDeviceStore.load() }]
            let listener = AudioListener()
            listener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyDevices]) {
                refreshConnected()
            }
            self.listener = listener
        }
        .onDisappear {
            tokens.forEach { notify_cancel($0) }
            tokens = []
            listener?.stop()
            listener = nil
        }
    }

    private func row(_ device: KnownAudioDevice, index: Int, count: Int) -> some View {
        let isConnected = connected.contains(device.uid)
        return Label {
            Text(verbatim: device.name)
            if !isConnected {
                Text("Not Connected")
            }
        } icon: {
            Image(systemName: device.deviceKind.symbolName)
                .foregroundStyle(isConnected ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .contextMenu {
            Button("Move Up") { move(index, by: -1) }
                .disabled(index == 0)
            Button("Move Down") { move(index, by: 1) }
                .disabled(index == count - 1)
            if !isConnected {
                Divider()
                Button("Forget This Device") { forget(device) }
            }
        }
        .accessibilityValue(isConnected ? Text(verbatim: "") : Text("Not Connected"))
        .accessibilityAction(named: Text("Move Up")) { move(index, by: -1) }
        .accessibilityAction(named: Text("Move Down")) { move(index, by: 1) }
    }

    private func move(_ index: Int, by step: Int) {
        var list = order.list(input: isInput)
        let target = index + step
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        store(list)
    }

    private func forget(_ device: KnownAudioDevice) {
        store(order.list(input: isInput).filter { $0.uid != device.uid })
    }

    private func store(_ list: [KnownAudioDevice]) {
        order = AudioDeviceStore.load()
        order.setList(list, input: isInput)
        AudioDeviceStore.save(order)
    }

    private func refreshConnected() {
        connected = Set(
            (AudioSystem.devices(input: false) + AudioSystem.devices(input: true)).map(\.uid))
    }
}

/// The person's own presets, renamed or deleted, as Music's Edit List.
struct EqualizerPresetList: View {
    @State private var presets = AudioRuleStore.customPresets()

    var body: some View {
        DetailsSheet(height: 420) {
            Section {
                if presets.isEmpty {
                    Text("Presets you make from the equalizer’s sliders appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach($presets) { $preset in
                    LabeledContent {
                        Button("Delete", role: .destructive) { delete(preset.id) }
                            .buttonStyle(.borderless)
                    } label: {
                        TextField(text: $preset.name) {
                            Text("New Preset Name:")
                        }
                        .textFieldStyle(.plain)
                        .onSubmit { save() }
                    }
                }
            } header: {
                SectionTitle(
                    title: Text("Presets", comment: "Equalizer presets, as in Music"),
                    detail: Text("Click a name to rename it."))
            }
        }
        .onDisappear { save() }
    }

    private func delete(_ id: String) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let named = presets.map { preset in
            var copy = preset
            let trimmed = preset.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, let old = AudioRuleStore.customPresets().first(where: { $0.id == preset.id }) {
                copy.name = old.name
            } else {
                copy.name = trimmed
            }
            return copy
        }
        if named != AudioRuleStore.customPresets() { AudioRuleStore.saveCustomPresets(named) }
    }
}
