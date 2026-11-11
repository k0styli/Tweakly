import AppKit
import SwiftUI
import WindowSwitcherCore

/// The Dock's page: the switch, the previews over its icons, and what a click on an icon does.
struct DockPageView: View {
    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    @State private var hasAccessibility = AXIsProcessTrusted()
    /// Asked as the page appears, not in the initial value, which SwiftUI works out again each time the window's content
    /// is rebuilt: the question takes 12 to 37 ms.
    @State private var hasScreenRecording = true
    @State private var isShowingPermissions = false

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.dock.symbol, title: Text("Dock Previews"),
                    detail: Text(
                        "Hold the pointer on an app in the Dock to see its windows. A click on the app in front minimizes it."
                    ),
                    isOn: isEnabled)
            }
            if settings.dockEnabled, !hasAccessibility || needsScreenRecording {
                Section {
                    if !hasAccessibility {
                        MissingPermissionRow(
                            title: Text("Accessibility"),
                            detail: Text("Off until Accessibility is allowed. The Dock works as usual until then."),
                            ask: SystemPermission.accessibility.ask)
                    }
                    if needsScreenRecording {
                        MissingPermissionRow(
                            title: Text("Screen & System Audio Recording"),
                            detail: Text("Without Screen Recording the previews show app icons and window titles."),
                            ask: SystemPermission.screenRecording.ask)
                    }
                } footer: {
                    PermissionAdvice()
                }
            }
            Section {
                Toggle(isOn: showsPanel) {
                    Text("Show Previews on Hover")
                    Text("Pictures are shared with Command-Tab, so a window seen in one appears at once in the other.")
                }
                Picker("Delay", selection: $settings.dockTuning.delayMilliseconds) {
                    Text("No Delay").tag(DockTuning.delayChoices[0])
                    Text("Short").tag(DockTuning.delayChoices[1])
                    Text("Normal").tag(DockTuning.delayChoices[2])
                    Text("Long").tag(DockTuning.delayChoices[3])
                }
                .help("How long the pointer rests on an icon before its windows appear.")
                .disabled(!settings.dockTuning.showsPanel)
                Picker("Tile Size", selection: $settings.dockTuning.largestTileHeight) {
                    Text("Small").tag(DockTuning.tileHeightChoices[0])
                    Text("Medium").tag(DockTuning.tileHeightChoices[1])
                    Text("Large").tag(DockTuning.tileHeightChoices[2])
                }
                .help("The largest size. With many windows, tiles get smaller to fit.")
                .disabled(!settings.dockTuning.showsPanel)
            } header: {
                SectionTitle(
                    title: Text("Window Previews"),
                    detail: Text("Click a preview to switch to its window. Move along the Dock to see other apps."))
            }
            .disabled(!settings.dockEnabled)
            Section {
                Picker(selection: $settings.dockTuning.clickAction) {
                    Text("Do Nothing").tag(DockTuning.ClickAction.nothing)
                    Text("Minimize Windows").tag(DockTuning.ClickAction.minimize)
                    Text("Hide App").tag(DockTuning.ClickAction.hide)
                } label: {
                    Text("Click on the Icon")
                    Text("Of the app in front, while one of its windows is in sight. Other clicks work as usual.")
                }
            }
            .disabled(!settings.dockEnabled)
            .sectionActions {
                Button("Permissions…") { isShowingPermissions = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { hasScreenRecording = CGPreflightScreenCaptureAccess() }
        .sheet(isPresented: $isShowingPermissions) {
            DetailsSheet(height: 300) {
                Section("Permissions") {
                    PermissionRow(
                        title: "Accessibility",
                        detail: "To hear which Dock icon the pointer is on, and to switch to or minimize windows.",
                        isGranted: hasAccessibility, ask: SystemPermission.accessibility.ask)
                    PermissionRow(
                        title: "Screen & System Audio Recording",
                        detail:
                            "To show what each window looks like. macOS lights its recording indicator for a few seconds after a preview opens.",
                        isGranted: hasScreenRecording, ask: SystemPermission.screenRecording.ask)
                }
            }
        }
        .pollingPermissions(
            whileVisible: isWindowVisible && (settings.dockEnabled || isShowingPermissions),
            every: isShowingPermissions || !hasAccessibility || needsScreenRecording ? 1 : 5, refreshPermissions)
    }

    private var needsScreenRecording: Bool {
        settings.dockTuning.showsPanel && !hasScreenRecording
    }

    /// Permissions are asked for at the moment the feature is turned on, one at a time.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.dockEnabled },
            set: { isOn in
                settings.dockEnabled = isOn
                guard isOn else { return }
                refreshPermissions()
                if !hasAccessibility {
                    SystemPermission.accessibility.ask()
                } else if needsScreenRecording {
                    SystemPermission.screenRecording.ask()
                }
            })
    }

    private var showsPanel: Binding<Bool> {
        Binding(
            get: { settings.dockTuning.showsPanel },
            set: { isOn in
                settings.dockTuning.showsPanel = isOn
                if isOn, needsScreenRecording { SystemPermission.screenRecording.ask() }
            })
    }

    private func refreshPermissions() {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibilityArrived = accessibility && !hasAccessibility
        guard accessibility != hasAccessibility || screenRecording != hasScreenRecording else { return }
        hasAccessibility = accessibility
        hasScreenRecording = screenRecording
        // The agent goes by its own check, and this tells it the moment to make that check.
        ProcessEvents.post(.settingsChanged)
        if accessibilityArrived, settings.dockEnabled, needsScreenRecording { SystemPermission.screenRecording.ask() }
    }
}
