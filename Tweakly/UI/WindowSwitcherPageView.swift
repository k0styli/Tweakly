import AppKit
import SwiftUI
import WindowSwitcherCore

/// The switcher's page: the switch, what a person notices about the panel, and below a button everything else.
struct WindowSwitcherPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router
    @State private var isShowingAdvanced = false

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.windowSwitcher.symbol, title: Text("Replace Command-Tab"),
                    detail: Text("Shows a preview of every window. Release Command to switch to the selected one."),
                    isOn: isEnabled)
            }
            if settings.windowSwitcherEnabled,
                !access.accessibility || needsScreenRecording || access.screenRecordingArrived
            {
                Section {
                    if !access.accessibility {
                        MissingAccessRow(
                            title: Text("Accessibility"),
                            detail: Text("Off until Accessibility is allowed. Command-Tab works as usual until then."),
                            open: { router.open(.permissions) })
                    }
                    if needsScreenRecording {
                        MissingAccessRow(
                            title: Text("Screen & System Audio Recording"),
                            detail: Text("Without Screen Recording the tiles show app icons instead of previews."),
                            open: { router.open(.permissions) })
                    }
                    if access.screenRecordingArrived, settings.switcherTuning.showsPreviews {
                        RestartForPicturesRow()
                    }
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
        .sheet(isPresented: $isShowingAdvanced) {
            SwitcherAdvancedSheet(settings: settings)
        }
    }

    private var needsScreenRecording: Bool {
        settings.switcherTuning.showsPreviews && !access.screenRecording
    }

    /// Permissions are asked for at the moment the feature is turned on, one at a time.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.windowSwitcherEnabled },
            set: { isOn in
                settings.windowSwitcherEnabled = isOn
                if isOn { access.askOnTurningOn(screenRecording: settings.switcherTuning.showsPreviews) }
            })
    }

    private func askForScreenRecording() {
        access.askOnTurningOn(accessibility: false, screenRecording: true)
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

/// How the pictures are kept. Few people will ever need any of it; the permissions are on their own page.
private struct SwitcherAdvancedSheet: View {
    @Bindable var settings: AppSettings

    var body: some View {
        DetailsSheet(
            resetTitle: "Restore Defaults",
            canReset: settings.switcherTuning != SwitcherTuning() && settings.windowSwitcherEnabled,
            reset: { settings.switcherTuning = SwitcherTuning() }
        ) {
            SwitcherPictureSettings(tuning: $settings.switcherTuning)
                .disabled(!settings.windowSwitcherEnabled || !settings.switcherTuning.showsPreviews)
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
