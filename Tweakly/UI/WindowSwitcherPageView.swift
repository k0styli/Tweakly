import AppKit
import SwiftUI
import WindowSwitcherCore

/// The switcher's page: the switch, what a person notices about the panel, and below a button everything else.
struct WindowSwitcherPageView: View {
    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    @State private var hasAccessibility = AXIsProcessTrusted()
    /// Asked as the page appears, not in the initial value, which SwiftUI works out again each time the window's content
    /// is rebuilt: the question takes 12 to 37 ms.
    @State private var hasScreenRecording = true
    @State private var screenRecordingArrivedNow = false
    @State private var isShowingAdvanced = false

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.windowSwitcher.symbol, title: Text("Replace Command-Tab"),
                    detail: Text("Shows a preview of every window. Release Command to switch to the selected one."),
                    isOn: isEnabled)
            }
            if settings.windowSwitcherEnabled, !hasAccessibility || needsScreenRecording || screenRecordingArrivedNow {
                Section {
                    if !hasAccessibility {
                        MissingPermissionRow(
                            title: Text("Accessibility"),
                            detail: Text("Off until Accessibility is allowed. Command-Tab works as usual until then."),
                            ask: SystemPermission.accessibility.ask)
                    }
                    if needsScreenRecording {
                        MissingPermissionRow(
                            title: Text("Screen & System Audio Recording"),
                            detail: Text("Without Screen Recording the tiles show app icons instead of previews."),
                            ask: SystemPermission.screenRecording.ask)
                    }
                    if screenRecordingArrivedNow {
                        LabeledContent("Previews appear after a restart") {
                            Button("Restart Now") { WindowProcess.relaunchAll() }
                        }
                    }
                } footer: {
                    if !hasAccessibility || needsScreenRecording { PermissionAdvice() }
                }
            }
            SwitcherPanelSettings(tuning: $settings.switcherTuning)
                .disabled(!settings.windowSwitcherEnabled)
            SwitcherShownSettings(tuning: $settings.switcherTuning, previewsTurnedOn: askForScreenRecording)
                .disabled(!settings.windowSwitcherEnabled)
                .sectionActions {
                    Button("Advanced…") { isShowingAdvanced = true }
                }
        }
        .formStyle(.grouped)
        .onAppear { hasScreenRecording = CGPreflightScreenCaptureAccess() }
        .sheet(isPresented: $isShowingAdvanced) {
            SwitcherAdvancedSheet(
                settings: settings, hasAccessibility: hasAccessibility, hasScreenRecording: hasScreenRecording)
        }
        .pollingPermissions(
            whileVisible: isWindowVisible && (settings.windowSwitcherEnabled || isShowingAdvanced),
            every: isShowingAdvanced || !hasAccessibility || needsScreenRecording ? 1 : 5,
            refreshPermissions)
    }

    private var needsScreenRecording: Bool {
        settings.switcherTuning.showsPreviews && !hasScreenRecording
    }

    /// Permissions are asked for at the moment the feature is turned on, one at a time.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.windowSwitcherEnabled },
            set: { isOn in
                settings.windowSwitcherEnabled = isOn
                guard isOn else { return }
                refreshPermissions()
                if !hasAccessibility {
                    SystemPermission.accessibility.ask()
                } else {
                    askForScreenRecording()
                }
            })
    }

    private func askForScreenRecording() {
        if needsScreenRecording { SystemPermission.screenRecording.ask() }
    }

    private func refreshPermissions() {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibilityArrived = accessibility && !hasAccessibility
        if screenRecording && !hasScreenRecording { screenRecordingArrivedNow = true }
        guard accessibility != hasAccessibility || screenRecording != hasScreenRecording else { return }
        hasAccessibility = accessibility
        hasScreenRecording = screenRecording
        // The agent goes by its own check, and this tells it the moment to make that check.
        ProcessEvents.post(.settingsChanged)
        if accessibilityArrived, settings.windowSwitcherEnabled { askForScreenRecording() }
    }
}

/// What the panel looks like and when it comes up.
private struct SwitcherPanelSettings: View {
    @Binding var tuning: SwitcherTuning

    var body: some View {
        Section {
            ScaleRow(
                title: Text("Panel Delay"),
                detail: Text("A shorter press just switches, without the panel."),
                stops: SwitcherTuning.panelDelayChoices.count, stop: delayStop,
                lowest: Text("No Delay"), highest: Text("Long"),
                spoken: String(localized: "\(tuning.panelDelayMilliseconds) ms")
            )
            .help(
                "How long to hold Command-Tab before the panel appears. With a shorter delay, quick switches may light the recording indicator."
            )
            Picker("Tile Size", selection: $tuning.largestTileHeight) {
                Text("Small").tag(SwitcherTuning.tileHeightChoices[0])
                Text("Medium").tag(SwitcherTuning.tileHeightChoices[1])
                Text("Large").tag(SwitcherTuning.tileHeightChoices[2])
            }
            .help("The largest size. With many windows, tiles get smaller to fit.")
            Toggle(isOn: $tuning.fitsBackgroundToRows) {
                Text("Fit Background to Rows")
                Text("The glass narrows around shorter rows, so every row keeps the same margin.")
            }
            .help(
                "The glass narrows around shorter rows, so every row keeps the same margin. Rows of nearly equal width line up, which crops their previews slightly."
            )
        }
    }

    private var delayStop: Binding<Int> {
        Binding(
            get: { SwitcherTuning.panelDelayChoices.firstIndex(of: tuning.panelDelayMilliseconds) ?? 0 },
            set: { tuning.panelDelayMilliseconds = SwitcherTuning.panelDelayChoices[$0] })
    }
}

/// What gets a tile, and whether the tile has a picture.
private struct SwitcherShownSettings: View {
    @Binding var tuning: SwitcherTuning
    let previewsTurnedOn: () -> Void

    var body: some View {
        Section("What to Show") {
            Toggle(isOn: showsPreviews) {
                Text("Window Previews")
                Text("Without them, tiles show app icons and macOS does not light its recording indicator.")
            }
            Toggle("Windows on Other Desktops", isOn: $tuning.showsWindowsOnOtherDesktops)
            Toggle("Minimized and Hidden Windows", isOn: $tuning.showsMinimizedWindows)
            Toggle(isOn: $tuning.showsAppsWithoutWindows) {
                Text("Apps with No Open Windows")
            }
        }
    }

    private var showsPreviews: Binding<Bool> {
        Binding(
            get: { tuning.showsPreviews },
            set: { isOn in
                tuning.showsPreviews = isOn
                if isOn { previewsTurnedOn() }
            })
    }
}

/// How the pictures are kept, and which permissions the switcher has. Few people will ever need any of it.
private struct SwitcherAdvancedSheet: View {
    @Bindable var settings: AppSettings
    let hasAccessibility: Bool
    let hasScreenRecording: Bool

    var body: some View {
        DetailsSheet(
            resetTitle: "Restore Defaults",
            canReset: settings.switcherTuning != SwitcherTuning() && settings.windowSwitcherEnabled,
            reset: { settings.switcherTuning = SwitcherTuning() }
        ) {
            SwitcherPictureSettings(tuning: $settings.switcherTuning)
                .disabled(!settings.windowSwitcherEnabled || !settings.switcherTuning.showsPreviews)
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "To take over Command-Tab and bring the chosen window forward.",
                    isGranted: hasAccessibility, ask: SystemPermission.accessibility.ask)
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail:
                        "To show what each window looks like. macOS lights its recording indicator for a few seconds after the panel opens.",
                    isGranted: hasScreenRecording, ask: SystemPermission.screenRecording.ask)
            }
        }
    }
}

private struct SwitcherPictureSettings: View {
    @Binding var tuning: SwitcherTuning

    var body: some View {
        Section("Previews") {
            Picker(selection: $tuning.retakeAfterSeconds) {
                ForEach(SwitcherTuning.retakeChoices, id: \.self) { seconds in
                    if seconds == 0 { Text("Every Time").tag(seconds) } else { Text("\(seconds) s").tag(seconds) }
                }
            } label: {
                Text("Picture Refresh")
                Text("A picture newer than this is not taken again, except of the window in use.")
            }
            Picker(selection: $tuning.keepSharpPicturesSeconds) {
                ForEach(SwitcherTuning.keepSharpChoices, id: \.self) { seconds in
                    if seconds < 60 {
                        Text("\(seconds) s").tag(seconds)
                    } else {
                        Text("\(seconds / 60) min").tag(seconds)
                    }
                }
            } label: {
                Text("Keep Sharp Pictures")
                Text(
                    "A panel opened again within this time shows them at once. They take about 800 KB of memory per window."
                )
            }
            Toggle(isOn: $tuning.savesCompressedPictures) {
                Text("Save Compressed Pictures")
                Text("Windows seen before appear at once, even after a long break. About 50 KB per window.")
            }
            Picker("Compression Quality", selection: $tuning.compressionQuality) {
                Text("Standard").tag(SwitcherTuning.compressionChoices[0])
                Text("High").tag(SwitcherTuning.compressionChoices[1])
                Text("Best").tag(SwitcherTuning.compressionChoices[2])
            }
            .disabled(!tuning.savesCompressedPictures)
            LabeledContent {
                HStack {
                    Text(tuning.capturesAtOnce, format: .number).monospacedDigit()
                    Stepper("Captures at Once", value: $tuning.capturesAtOnce, in: SwitcherTuning.capturesAtOnceRange)
                        .labelsHidden()
                }
            } label: {
                Text("Captures at Once")
                Text("More than four rarely helps, as macOS takes them nearly one at a time.")
            }
        }
    }
}
