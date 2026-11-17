import AppKit
import AudioMixerCore
import Charts
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

/// The equalizer's choice as a pop-up menu, as Music has it: Off, Manual once a point was moved, Music's presets, the
/// person's own, and, as at the foot of Music's menu, Make Preset… and Edit List….
struct EqualizerPicker: View {
    let title: Text
    let settings: EqualizerSettings
    let custom: [CustomEqualizerPreset]
    let choose: (EqualizerSettings) -> Void
    /// Saves the settings as a preset of the person's; nil where that cannot be done.
    var makePreset: (() -> Void)?
    /// Renames and deletes the person's presets.
    var editList: (() -> Void)?

    private static let off = "off"
    private static let manual = "manual"
    private static let makeTag = "make"
    private static let editTag = "edit"

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
            if makePreset != nil && !settings.isFlat || editList != nil && !custom.isEmpty {
                Divider()
            }
            if makePreset != nil, !settings.isFlat {
                Text("Make Preset…").tag(Self.makeTag)
            }
            if editList != nil, !custom.isEmpty {
                Text("Edit List…").tag(Self.editTag)
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
                case Self.makeTag: makePreset?()
                case Self.editTag: editList?()
                default:
                    if let settings = EqualizerNames.settings(for: tag, custom: custom) { choose(settings) }
                }
            })
    }
}

/// An equalizer that is on, right where it was turned on: its curve with a point on each band to drag, and the
/// preamp, as rows of the group it belongs to. Every change is heard at once.
struct EqualizerRows: View {
    let settings: EqualizerSettings
    let change: (EqualizerSettings) -> Void

    var body: some View {
        EqualizerCurve(settings: settings) { moved in
            var manual = moved
            manual.presetID = nil
            change(manual)
        }
        .frame(height: 190)
        .padding(.vertical, 6)
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: preamp, in: EqualizerSettings.range) {
                    Text("Preamp", comment: "The equalizer's preamp, as in Music")
                } ticks: {
                    SliderTick(0.0)
                }
                .labelsHidden()
                .accessibilityValue(Text(verbatim: EqualizerNames.decibels(settings.preamp)))
                Text(verbatim: EqualizerNames.decibels(settings.preamp))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        } label: {
            Text("Preamp", comment: "The equalizer's preamp, as in Music")
        }
    }

    /// Quarter decibels, caught at 0 dB within half a decibel.
    private var preamp: Binding<Double> {
        Binding(
            get: { settings.preamp },
            set: { value in
                let snapped = abs(value) < 0.5 ? 0 : (value * 4).rounded() / 4
                guard snapped != settings.preamp else { return }
                var copy = settings
                copy.preamp = snapped
                copy.presetID = nil
                change(copy)
            })
    }
}

/// The equalizer as a curve over the audible range, with a point on each of Music's bands to drag up or down. The line
/// is what is heard, worked out from the very filters that play, and it passes through every point. Swift Charts, the
/// system's own charts, as in Health and Stocks.
struct EqualizerCurve: View {
    let settings: EqualizerSettings
    let change: (EqualizerSettings) -> Void
    @State private var dragged: Int?
    @State private var isAtZero = false

    private static let frequencies = EqualizerSettings.frequencies
    /// 20 Hz to 20 kHz, evenly on a logarithmic scale.
    private static let curveFrequencies = (0...160).map { 20 * pow(1000, Double($0) / 160) }
    /// The rate the curve is drawn for; the filters follow each output's own.
    private static let sampleRate = 48_000.0
    private static let scale = 13.0
    /// The chart's series, which no one reads: the chart is hidden from VoiceOver, whose controls are the bands below.
    private static let frequencySeries = String("Frequency")
    private static let gainSeries = String("Gain")
    private static let zeroSeries = String("0 dB")

    private struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    var body: some View {
        let filterGains = EqualizerFilter.filterGains(for: settings.bands, sampleRate: Self.sampleRate)
        let curve = Self.curveFrequencies.enumerated().map { index, frequency in
            Point(
                id: index, x: log10(frequency),
                y: min(
                    max(
                        EqualizerFilter.response(filterGains: filterGains, at: frequency, sampleRate: Self.sampleRate),
                        -Self.scale), Self.scale))
        }
        let bands = Self.frequencies.indices.map {
            Point(id: $0, x: log10(Self.frequencies[$0]), y: settings.bands[$0])
        }
        Chart {
            ForEach(curve) { point in
                AreaMark(
                    x: .value(Self.frequencySeries, point.x), yStart: .value(Self.zeroSeries, 0),
                    yEnd: .value(Self.gainSeries, point.y)
                )
                .foregroundStyle(Color.accentColor.opacity(0.12))
            }
            ForEach(curve) { point in
                LineMark(x: .value(Self.frequencySeries, point.x), y: .value(Self.gainSeries, point.y))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(bands) { band in
                PointMark(x: .value(Self.frequencySeries, band.x), y: .value(Self.gainSeries, band.y))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(dragged == band.id ? 140 : 70)
            }
        }
        .chartXScale(domain: log10(20.0)...log10(20_000.0))
        .chartYScale(domain: -Self.scale...Self.scale)
        .chartXAxis {
            AxisMarks(values: Self.frequencies.map { log10($0) }) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let x = value.as(Double.self) { Text(verbatim: EqualizerNames.shortLabel(pow(10, x))) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [-12.0, -6, 0, 6, 12]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let y = value.as(Double.self) { Text(verbatim: EqualizerNames.decibels(y)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .gesture(drag(proxy: proxy, geometry: geometry))
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { tap in
                            // A double click puts the nearest band back at 0 dB.
                            guard let band = nearestBand(at: tap.location.x, proxy: proxy, geometry: geometry) else {
                                return
                            }
                            set(band, to: 0)
                        })
            }
        }
        .accessibilityHidden(true)
        .overlay {
            // VoiceOver gets each band as a control of its own, adjusted as a slider is.
            HStack(spacing: 0) {
                ForEach(Self.frequencies.indices, id: \.self) { band in
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: EqualizerNames.spokenFrequency(Self.frequencies[band])))
                        .accessibilityValue(Text(verbatim: EqualizerNames.decibels(settings.bands[band])))
                        .accessibilityAdjustableAction { direction in
                            let step = direction == .increment ? 0.5 : -0.5
                            set(band, to: settings.bands[band] + step)
                        }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func drag(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let plot = proxy.plotFrame else { return }
                let origin = geometry[plot].origin
                // The band nearest where the drag began, held until it ends.
                if dragged == nil {
                    dragged = nearestBand(at: drag.startLocation.x, proxy: proxy, geometry: geometry)
                }
                guard let band = dragged, let y: Double = proxy.value(atY: drag.location.y - origin.y) else { return }
                // Quarter decibels, caught at 0 dB within half a decibel with a tap on the trackpad.
                let atZero = abs(y) < 0.5
                if atZero, !isAtZero {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                isAtZero = atZero
                set(band, to: atZero ? 0 : (y * 4).rounded() / 4)
            }
            .onEnded { _ in
                dragged = nil
                isAtZero = false
            }
    }

    private func nearestBand(at x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
        guard let plot = proxy.plotFrame,
            let value: Double = proxy.value(atX: x - geometry[plot].origin.x)
        else { return nil }
        return Self.frequencies.indices.min {
            abs(log10(Self.frequencies[$0]) - value) < abs(log10(Self.frequencies[$1]) - value)
        }
    }

    private func set(_ band: Int, to value: Double) {
        let clamped = min(max(value, EqualizerSettings.range.lowerBound), EqualizerSettings.range.upperBound)
        guard settings.bands.indices.contains(band), clamped != settings.bands[band] else { return }
        var copy = settings
        copy.bands[band] = clamped
        change(copy)
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
