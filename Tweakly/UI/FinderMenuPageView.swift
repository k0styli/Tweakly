import FinderMenuCore
import SwiftUI

/// The page of Finder's shortcut menu: the switch, which items it adds, and the extension that shows them.
struct FinderMenuPageView: View {
    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    /// Assumed on until the system says otherwise, so a page that opens does not flash a warning.
    @State private var isExtensionEnabled = true
    @State private var isShowingExtension = false
    /// The agent turns the extension on a moment after the switch, so until then it reads as off only because it is
    /// still on its way.
    @State private var trustsOffAfter = Date.distantPast

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.finderMenu.symbol, title: Text("More in Finder’s Shortcut Menu"),
                    detail: Text("New File, Copy Path and Open in Terminal with a right click."), isOn: isEnabled)
            }
            if let reason = settings.finderMenuStopReason, !settings.finderMenuEnabled {
                Section {
                    Label {
                        Text(Self.describe(reason))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                    }
                }
            }
            if settings.finderMenuEnabled, !isExtensionEnabled {
                Section {
                    ExtensionOffRow(turnOn: turnExtensionOn)
                }
            }
            Section {
                item(
                    .newFile, title: Text("New File"),
                    detail: Text("In an empty part of a folder or the desktop. Makes an empty text file to name."))
                item(
                    .copyPath, title: Text("Copy Path"),
                    detail: Text("The full path of what you clicked, one a line for several items."))
                item(
                    .openInTerminal, title: Text("Open in Terminal"),
                    detail: Text("A Terminal window in the folder you clicked, or in the one that holds the file."))
            } header: {
                SectionTitle(title: Text("Items"), detail: Text("What a right click in Finder adds to its menu."))
            }
            .disabled(!settings.finderMenuEnabled)
            .sectionActions {
                Button("Finder Extension…") { isShowingExtension = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingExtension) {
            ExtensionSheet(isEnabled: isExtensionEnabled, turnOn: turnExtensionOn)
        }
        .pollingPermissions(
            whileVisible: isWindowVisible && (settings.finderMenuEnabled || isShowingExtension),
            every: isExtensionEnabled ? 5 : 1, refresh)
    }

    private func item(_ item: FinderMenuItems, title: Text, detail: Text) -> some View {
        Toggle(isOn: isShown(item)) {
            title
            detail
        }
        .toggleStyle(.checkbox)
    }

    private func isShown(_ item: FinderMenuItems) -> Binding<Bool> {
        Binding(
            get: { settings.finderMenuItems.contains(item) },
            set: { isOn in
                if isOn { settings.finderMenuItems.insert(item) } else { settings.finderMenuItems.remove(item) }
            })
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.finderMenuEnabled },
            set: { isOn in
                if isOn {
                    settings.finderMenuStopReason = nil
                    trustsOffAfter = .now.addingTimeInterval(Self.extensionStartTime)
                }
                settings.finderMenuEnabled = isOn
            })
    }

    private static var extensionStartTime: TimeInterval { 3 }

    private func turnExtensionOn() {
        trustsOffAfter = .now.addingTimeInterval(Self.extensionStartTime)
        FinderExtension.setEnabled(true) { _ in refresh() }
    }

    private func refresh() {
        let enabled = FinderExtension.isEnabled
        guard enabled != isExtensionEnabled, enabled || Date.now >= trustsOffAfter else { return }
        isExtensionEnabled = enabled
    }

    static func describe(_ reason: FinderMenuStopReason) -> String {
        switch reason {
        case .unavailable:
            String(localized: "Turned off: this version of macOS does not let Tweakly answer the Finder extension.")
        case .extensionDamaged:
            String(
                localized:
                    "Turned off: the Finder extension inside Tweakly is missing or damaged. Install Tweakly again.")
        case .nameTaken:
            String(
                localized: "Turned off: another copy of Tweakly was answering Finder. Quit it and turn this on again.")
        }
    }
}

/// The extension is off in System Settings, so Finder shows none of the items.
private struct ExtensionOffRow: View {
    let turnOn: () -> Void

    var body: some View {
        LabeledContent {
            Button("Turn On", action: turnOn)
        } label: {
            Label {
                Text("Finder Extension")
                Text("Off in Login Items & Extensions, so Finder shows none of these items.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Where the extension can be seen working, as permissions are on other pages.
private struct ExtensionSheet: View {
    private static var height: CGFloat { 220 }

    let isEnabled: Bool
    let turnOn: () -> Void

    var body: some View {
        DetailsSheet(height: Self.height) {
            Section {
                LabeledContent {
                    if isEnabled {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Turn On", action: turnOn)
                    }
                } label: {
                    Text("Finder Extension")
                    Text("Shows the items in Finder. The switch at the top turns it on and off.")
                }
                LabeledContent {
                    Button("Show…") { FinderExtension.showInSystemSettings() }
                } label: {
                    Text("Login Items & Extensions")
                    Text("Where System Settings lists it.")
                }
            } footer: {
                Text(
                    "The first new file on the desktop or in Documents or Downloads makes macOS ask whether Tweakly may use that folder."
                )
            }
        }
    }
}
