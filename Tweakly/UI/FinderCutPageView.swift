import AppKit
import SwiftUI

/// The page of cutting files in Finder: the switch, which keys do what, and the confirmation.
struct FinderCutPageView: View {
    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var isShowingPermission = false

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.finderCut.symbol, title: Text("Cut Files with Command-X"),
                    detail: Text("Moves files with the keyboard, as in Windows."), isOn: isEnabled)
            }
            if settings.finderCutEnabled, !hasAccessibility {
                Section {
                    MissingPermissionRow(
                        title: Text("Accessibility"),
                        detail: Text("Off until Accessibility is allowed. Command-X works as usual until then."),
                        ask: SystemPermission.accessibility.ask)
                } footer: {
                    PermissionAdvice()
                }
            }
            Section {
                keyRow("Cut the Selected Files", key: "⌘X", spoken: "Command-X")
                keyRow("Move Them to the Current Folder", key: "⌘V", spoken: "Command-V")
                keyRow("Cancel the Cut", key: "esc", spoken: "Escape")
            } header: {
                SectionTitle(title: Text("Keys"), detail: Text("In text, these keys work as usual."))
            }
            Section {
                Toggle(isOn: $settings.finderCutShowsConfirmation) {
                    Text("Show Confirmation")
                    Text("Finder cannot dim cut files, so a small label says how many were cut.")
                }
                .disabled(!settings.finderCutEnabled)
            }
            .sectionActions {
                Button("Permissions…") { isShowingPermission = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingPermission) {
            PermissionSheet(
                detail: "To tell files from text in Finder and to give it the command to move files.",
                isGranted: hasAccessibility)
        }
        .pollingPermissions(
            whileVisible: isWindowVisible && (settings.finderCutEnabled || isShowingPermission),
            every: isShowingPermission || !hasAccessibility ? 1 : 5, refresh)
    }

    /// The keys as they are printed on the keyboard, so they read the same in any language. VoiceOver gets their names.
    private func keyRow(_ title: LocalizedStringKey, key: String, spoken: String) -> some View {
        LabeledContent(title) {
            Text(verbatim: key)
                .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    /// The permission is asked for at the moment the feature is turned on.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.finderCutEnabled },
            set: { isOn in
                settings.finderCutEnabled = isOn
                if isOn, !AXIsProcessTrusted() { SystemPermission.accessibility.ask() }
            })
    }

    private func refresh() {
        let accessibility = AXIsProcessTrusted()
        guard accessibility != hasAccessibility else { return }
        hasAccessibility = accessibility
        // The agent goes by its own check, and this tells it the moment to make that check.
        ProcessEvents.post(.settingsChanged)
    }
}
