import AppKit
import SwiftUI

/// The page of cutting files in Finder: the switch, which keys do what, and the confirmation.
struct FinderCutPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.finderCut.symbol, title: Text("Cut Files with Command-X"),
                    detail: Text("Moves files with the keyboard, as in Windows."), isOn: isEnabled)
            }
            if settings.finderCutEnabled, !access.accessibility {
                Section {
                    MissingAccessRow(
                        title: Text("Accessibility"),
                        detail: Text("Off until Accessibility is allowed. Command-X works as usual until then."),
                        open: { router.open(.permissions) })
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
                Button("Permissions…") { router.open(.permissions) }
            }
        }
        .formStyle(.grouped)
    }

    /// The keys as they are printed on the keyboard, so they read the same in any language. VoiceOver gets their names,
    /// in the words of the language it speaks.
    private func keyRow(_ title: LocalizedStringKey, key: String, spoken: LocalizedStringKey) -> some View {
        LabeledContent(title) {
            Text(verbatim: key)
                .accessibilityLabel(Text(spoken))
        }
    }

    /// The permission is asked for at the moment the feature is turned on.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.finderCutEnabled },
            set: { isOn in
                settings.finderCutEnabled = isOn
                if isOn { access.askOnTurningOn(screenRecording: false) }
            })
    }
}
