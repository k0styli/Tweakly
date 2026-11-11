import AppKit
import AudioMixerCore
import CoreAudio
import SwiftUI
import notify

/// The volume mixer's page: the switch, each app given a volume or output of its own, changed right here as in the
/// popover, and what the popover offers. Laid out as System Settings lays out one app's settings: a group per app.
struct VolumeMixerPageView: View {
    @Bindable var settings: AppSettings
    @State private var rules = AudioRuleStore.load()
    /// Every app shown since the page appeared. An app dragged to 100 % loses its rule, and its group must not vanish
    /// from under the pointer.
    @State private var shownApps: [String] = []
    @State private var isPermitted = AudioRuleStore.isPermitted
    @State private var hasStopped = AudioRuleStore.hasStopped
    @State private var outputs: [AudioDevice] = []
    @State private var tokens: [Int32] = []
    /// Outputs come and go, headphones above all, while the page is open.
    @State private var deviceListener: AudioListener?

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.volumeMixer.symbol, title: Text("Volume Mixer"),
                    detail: Text("In the menu bar: the volume, the output, and a volume and output for each app."),
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
            } else if settings.volumeMixerEnabled, !isPermitted {
                Section {
                    MissingPermissionRow(
                        title: Text("System Audio Recording"),
                        detail: Text(
                            "macOS changes an app’s volume only through it. Until then apps play as they are."),
                        ask: openPrivacy)
                }
            }
            if shownApps.isEmpty {
                Section {
                    Text("Apps you give a volume or output of their own in the popover appear here.")
                        .foregroundStyle(.secondary)
                } header: {
                    appsTitle
                }
            } else {
                ForEach(Array(sortedApps.enumerated()), id: \.element) { index, bundleID in
                    AppRuleSection(
                        bundleID: bundleID, rule: rules.rule(for: bundleID), outputs: outputs,
                        highest: AudioRuleBook.highestVolume(boosting: settings.volumeMixerBoosts),
                        change: { change(bundleID, $0) }
                    ) {
                        if index == 0 { appsTitle }
                    }
                }
            }
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
                        AudioRuleStore.save(AudioRuleBook())
                        shownApps = []
                        reload()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            outputs = AudioSystem.devices(input: false)
            tokens = [
                ProcessEvents.observe(.audioRulesChanged) { reload() },
                ProcessEvents.observe(.volumeMixerStateChanged) { reload() },
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
        isPermitted = AudioRuleStore.isPermitted
        hasStopped = AudioRuleStore.hasStopped
    }

    private func openPrivacy() {
        if let url = URL(string: AudioRuleStore.privacySettingsURL) { NSWorkspace.shared.open(url) }
    }
}

/// One app's group: its icon and name with a way back to how it plays by itself, then its volume against its own, its
/// sound on or off, and the output it plays on.
private struct AppRuleSection<Header: View>: View {
    let bundleID: String
    let rule: AppAudioRule
    let outputs: [AudioDevice]
    let highest: Double
    let change: ((inout AppAudioRule) -> Void) -> Void
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
                    // Always the share, so every app's slider is as long; whether it is muted is the switch below.
                    Text(verbatim: "\(VolumeLevel.percent(min(rule.volume, highest))) %")
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
