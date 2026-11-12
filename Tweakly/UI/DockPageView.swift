import AppKit
import SwiftUI
import WindowSwitcherCore

/// The Dock's page: the switch, the previews over its icons, and what a click on an icon does.
struct DockPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router

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
            if settings.dockEnabled, !access.accessibility || needsScreenRecording || restartsForPictures {
                Section {
                    if !access.accessibility {
                        MissingAccessRow(
                            title: Text("Accessibility"),
                            detail: Text("Off until Accessibility is allowed. The Dock works as usual until then."),
                            open: { router.open(.permissions) })
                    }
                    if needsScreenRecording {
                        MissingAccessRow(
                            title: Text("Screen & System Audio Recording"),
                            detail: Text("Without Screen Recording the previews show app icons and window titles."),
                            open: { router.open(.permissions) })
                    }
                    if restartsForPictures {
                        RestartForPicturesRow()
                    }
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
                Button("Permissions…") { router.open(.permissions) }
            }
        }
        .formStyle(.grouped)
    }

    private var needsScreenRecording: Bool {
        settings.dockTuning.showsPanel && !access.screenRecording
    }

    private var restartsForPictures: Bool {
        access.screenRecordingArrived && settings.dockTuning.showsPanel
    }

    /// Permissions are asked for at the moment the feature is turned on, one at a time.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.dockEnabled },
            set: { isOn in
                settings.dockEnabled = isOn
                if isOn { access.askOnTurningOn(screenRecording: settings.dockTuning.showsPanel) }
            })
    }

    private var showsPanel: Binding<Bool> {
        Binding(
            get: { settings.dockTuning.showsPanel },
            set: { isOn in
                settings.dockTuning.showsPanel = isOn
                if isOn { access.askOnTurningOn(accessibility: false, screenRecording: true) }
            })
    }
}
