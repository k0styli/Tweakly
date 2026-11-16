import AppKit
import AudioMixerCore
import CoreAudio
import SwiftUI
import notify

/// The volume mixer's page: the switch, each app given a volume, output or equalizer of its own, changed right here as in
/// the popover, each output's equalizer, how devices are chosen as they come and go, and what the popover offers. Laid
/// out as System Settings lays out one app's settings: a group per app.
struct VolumeMixerPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router
    @State private var rules = AudioRuleStore.load()
    /// Every app shown since the page appeared. An app dragged to 100 % loses its rule, and its group must not vanish
    /// from under the pointer.
    @State private var shownApps: [String] = []
    @State private var hasStopped = AudioRuleStore.hasStopped
    @State private var outputs: [AudioDevice] = []
    @State private var tokens: [Int32] = []
    /// Outputs come and go, headphones above all, while the page is open.
    @State private var deviceListener: AudioListener?
    @State private var custom = AudioRuleStore.customPresets()
    @State private var editing: EqualizerTarget?
    @State private var isOrdering = false
    @State private var isListingPresets = false

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.volumeMixer.symbol, title: Text("Volume Mixer"),
                    detail: Text(
                        "In the menu bar: the volume, the output, and a volume, output and equalizer for each app."),
                    isOn: $settings.volumeMixerEnabled)
            }
            if settings.volumeMixerEnabled, hasStopped {
                Section {
                    Label {
                        Text("App Volumes Do Not Work")
                        Text(
                            "The part of Tweakly that changes them stopped twice. Turn the mixer off and on to try again."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                    }
                }
            } else if settings.volumeMixerEnabled, access.audioRecording == .notAllowed {
                Section {
                    MissingAccessRow(
                        title: Text("System Audio Recording"),
                        detail: Text(
                            "macOS changes an app’s volume only through it. Until then apps play as they are."),
                        open: { router.open(.permissions) })
                }
            }
            if shownApps.isEmpty {
                Section {
                    Text("Apps you give a volume, output or equalizer of their own in the popover appear here.")
                        .foregroundStyle(.secondary)
                } header: {
                    appsTitle
                }
            } else {
                ForEach(Array(sortedApps.enumerated()), id: \.element) { index, bundleID in
                    AppRuleSection(
                        bundleID: bundleID, rule: rules.rule(for: bundleID), outputs: outputs,
                        highest: AudioRuleBook.highestVolume(boosting: settings.volumeMixerBoosts), custom: custom,
                        change: { change(bundleID, $0) },
                        edit: { editing = .app(bundleID: bundleID, name: AppIdentity.of(bundleID).name) }
                    ) {
                        if index == 0 { appsTitle }
                    }
                    // As the popover's section below: rules wait while the mixer is off, and nothing says so here.
                    .disabled(!settings.volumeMixerEnabled)
                }
            }
            equalizerSection
                .disabled(!settings.volumeMixerEnabled)
            devicesSection
                .disabled(!settings.volumeMixerEnabled)
            Section {
                Toggle(isOn: $settings.volumeMixerShowsInput) {
                    Text("Show the Microphone")
                    Text("The input device and its volume, below the apps.")
                }
                Toggle(isOn: $settings.volumeMixerBoosts) {
                    Text("Boost Up to 200 %")
                    Text("For quiet videos and calls. Loud sound is softened so it does not crackle.")
                }
                Toggle(isOn: $settings.volumeMixerScrolls) {
                    Text("Scroll Over the Icon")
                    Text("Changes the volume in the same steps as the volume keys.")
                }
            } header: {
                SectionTitle(title: Text("Popover"), detail: Text("Click the speaker in the menu bar to open it."))
            }
            .disabled(!settings.volumeMixerEnabled)
            .sectionActions {
                if !rules.rules.isEmpty {
                    Button("Reset All Apps") {
                        // The apps only: the outputs' equalizers are not theirs.
                        AudioRuleStore.save(AudioRuleBook(outputs: AudioRuleStore.load().outputs))
                        shownApps = []
                        reload()
                    }
                }
                Button("Permissions…") { router.open(.permissions) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            EqualizerEditor(target: target)
        }
        .sheet(isPresented: $isOrdering) {
            DeviceOrderSheet()
        }
        .sheet(isPresented: $isListingPresets) {
            EqualizerPresetList()
        }
        .onAppear {
            reload()
            outputs = AudioSystem.devices(input: false)
            openRequestedEqualizer()
            tokens = [
                ProcessEvents.observe(.audioRulesChanged) { reload() },
                ProcessEvents.observe(.volumeMixerStateChanged) { reload() },
                // The popover's Customize… brings the window here with the equalizer it was asked for.
                ProcessEvents.observe(.showVolumeMixer) { openRequestedEqualizer() },
            ]
            let listener = AudioListener()
            listener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyDevices]) {
                outputs = AudioSystem.devices(input: false)
            }
            deviceListener = listener
        }
        .onDisappear {
            tokens.forEach { notify_cancel($0) }
            tokens = []
            deviceListener?.stop()
            deviceListener = nil
        }
    }

    // MARK: Equalizer

    /// Every output connected now, and any other with an equalizer kept for when it comes back.
    private var equalizerOutputs:
        [(uid: String, name: String, kind: AudioDeviceKind, isConnected: Bool, isStereo: Bool)]
    {
        let connected = outputs.map { ($0.uid, $0.name, $0.kind, true, $0.isStereo) }
        let remembered = rules.outputs
            .filter { uid, _ in !outputs.contains { $0.uid == uid } }
            .sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
            .map { ($0.key, $0.value.name, $0.value.deviceKind ?? .other, false, true) }
        return connected + remembered
    }

    private var equalizerSection: some View {
        Section {
            ForEach(equalizerOutputs, id: \.uid) { output in
                let target = EqualizerTarget.output(uid: output.uid, name: output.name)
                LabeledContent {
                    EqualizerPicker(
                        title: Text(verbatim: output.name), settings: rules.equalizer(forOutput: output.uid),
                        custom: custom, choose: { target.save($0) }, customize: { editing = target }
                    )
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!output.isStereo)
                } label: {
                    Label {
                        Text(verbatim: output.name)
                        if !output.isConnected {
                            Text("Not Connected")
                        } else if !output.isStereo {
                            Text("For stereo outputs only, so surround sound stays as it is.")
                        }
                    } icon: {
                        Image(systemName: output.kind.symbolName)
                            .foregroundStyle(output.isConnected ? .secondary : .tertiary)
                    }
                }
            }
        } header: {
            SectionTitle(
                title: Text("Equalizer"),
                detail: Text(
                    "For everything an output plays, with Music’s presets. An app’s own equalizer is in its group above."
                ))
        }
        .sectionActions {
            if !custom.isEmpty {
                Button("Edit List…") { isListingPresets = true }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section {
            Toggle(isOn: $settings.volumeMixerKeepsMicrophone) {
                Text("Keep the Microphone When Headphones Connect")
                Text(
                    "AirPods and other Bluetooth headphones don’t take over the microphone, so their sound stays at full quality instead of dropping to call quality. Their microphone can still be chosen by hand."
                )
            }
            Toggle(isOn: $settings.volumeMixerOrdersDevices) {
                Text("Choose Devices in Order")
                Text(
                    "As devices connect and disconnect, the first connected output and input in your order are chosen. A device chosen by hand stays until the next one connects."
                )
            }
        } header: {
            SectionTitle(
                title: Text("Devices"),
                detail: Text("What the Mac uses as headphones, speakers and microphones come and go."))
        }
        .sectionActions {
            if settings.volumeMixerOrdersDevices {
                Button("Device Order…") { isOrdering = true }
            }
        }
    }

    /// The equalizer the popover asked to customize, once.
    private func openRequestedEqualizer() {
        guard let request = AudioRuleStore.takeEditorRequest() else { return }
        if request.hasPrefix("output:") {
            let uid = String(request.dropFirst("output:".count))
            let name =
                outputs.first { $0.uid == uid }?.name ?? AudioSystem.devices(input: false).first { $0.uid == uid }?.name
                ?? rules.outputs[uid]?.name ?? uid
            editing = .output(uid: uid, name: name)
        } else if request.hasPrefix("app:") {
            let bundleID = String(request.dropFirst("app:".count))
            editing = .app(bundleID: bundleID, name: AppIdentity.of(bundleID).name)
        }
    }

    private var sortedApps: [String] {
        shownApps.sorted {
            AppIdentity.of($0).name.localizedStandardCompare(AppIdentity.of($1).name) == .orderedAscending
        }
    }

    private var appsTitle: some View {
        SectionTitle(
            title: Text("Apps"),
            detail: Text(
                "An app’s volume is a share of the Mac’s volume. A right click on an app in the popover changes it too."
            ))
    }

    /// From the rules as stored, not as last heard: the popover may have changed another app a moment ago.
    private func change(_ bundleID: String, _ edit: (inout AppAudioRule) -> Void) {
        // A slider moves many times a second: what was saved shows at once, and the page's own notice of it finds
        // nothing new.
        let saved = AudioRuleStore.update(bundleID, edit)
        if saved != rules { rules = saved }
    }

    private func reload() {
        let stored = AudioRuleStore.load()
        if stored != rules { rules = stored }
        let added = stored.rules.keys.filter { !shownApps.contains($0) }
        if !added.isEmpty { shownApps += added }
        hasStopped = AudioRuleStore.hasStopped
        let presets = AudioRuleStore.customPresets()
        if presets != custom { custom = presets }
    }
}

/// One app's group: its icon and name with a way back to how it plays by itself, then its volume against its own, its
/// sound on or off, the output it plays on, and its equalizer.
private struct AppRuleSection<Header: View>: View {
    let bundleID: String
    let rule: AppAudioRule
    let outputs: [AudioDevice]
    let highest: Double
    let custom: [CustomEqualizerPreset]
    let change: ((inout AppAudioRule) -> Void) -> Void
    let edit: () -> Void
    @ViewBuilder let header: () -> Header

    var body: some View {
        let identity = AppIdentity.of(bundleID)
        Section {
            LabeledContent {
                Button("Reset") { change { $0 = .standard } }
            } label: {
                Label {
                    Text(identity.name)
                } icon: {
                    Image(nsImage: identity.icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
            }
            LabeledContent("Volume") {
                HStack(spacing: 10) {
                    Slider(
                        value: volume, in: 0...highest,
                        label: { Text("Volume") },
                        minimumValueLabel: { Image(systemName: "speaker.fill").foregroundStyle(.secondary) },
                        maximumValueLabel: { Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary) },
                        ticks: {
                            SliderTickContentForEach(marks, id: \.self) { SliderTick($0) }
                        }
                    )
                    .labelsHidden()
                    .accessibilityValue(Text(verbatim: VolumeLevel.shown(min(rule.volume, highest))))
                    // Always the share, so every app's slider is as long; whether it is muted is the switch below.
                    Text(verbatim: VolumeLevel.shown(min(rule.volume, highest)))
                        .monospacedDigit()
                        .foregroundStyle(rule.isMuted ? .tertiary : .secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: 300)
            }
            Toggle("Muted", isOn: muted)
            Picker("Output", selection: output) {
                Text("System Output").tag(String?.none)
                Divider()
                ForEach(outputs) { device in
                    Label(device.name, systemImage: device.kind.symbolName).tag(Optional(device.uid))
                }
                if let uid = rule.outputUID, !outputs.contains(where: { $0.uid == uid }) {
                    Text("Another Output").tag(Optional(uid))
                }
            }
            EqualizerPicker(
                title: Text("Equalizer"), settings: rule.equalizer ?? .flat, custom: custom,
                choose: { settings in change { $0.equalizer = settings.isFlat ? nil : settings } }, customize: edit)
        } header: {
            header()
        }
    }

    /// 0, 50 and 100 %, and 150 and 200 % while boosting, which the knob is drawn to.
    private var marks: [Double] { Array(stride(from: 0, through: highest, by: 0.5)) }

    private var volume: Binding<Double> {
        Binding(
            get: { min(rule.volume, highest) },
            set: { newValue in
                change {
                    $0.volume = newValue
                    $0.isMuted = false
                }
            })
    }

    private var muted: Binding<Bool> {
        Binding(get: { rule.isMuted }, set: { newValue in change { $0.isMuted = newValue } })
    }

    private var output: Binding<String?> {
        Binding(get: { rule.outputUID }, set: { newValue in change { $0.outputUID = newValue } })
    }
}

/// An app's name and icon from its bundle ID, or a process's name for one with no app. Looked up once: the page is
/// drawn again as a slider moves, and finding an app and its icon goes through Launch Services each time.
private struct AppIdentity {
    let name: String
    let icon: NSImage

    private static var known: [String: AppIdentity] = [:]

    static func of(_ bundleID: String) -> AppIdentity {
        if let identity = known[bundleID] { return identity }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name: String =
            if bundleID.hasPrefix("process:") {
                String(bundleID.dropFirst("process:".count))
            } else if let url {
                (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            } else {
                bundleID
            }
        let icon =
            url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let identity = AppIdentity(name: name, icon: icon)
        known[bundleID] = identity
        return identity
    }
}
