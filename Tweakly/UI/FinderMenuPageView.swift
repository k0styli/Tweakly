import FinderMenuCore
import SwiftUI

/// The page of Finder's shortcut menu: the switch, which items it adds, and the extension that shows them.
struct FinderMenuPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router

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
            if settings.finderMenuEnabled, !access.finderExtension {
                Section {
                    MissingAccessRow(
                        title: Text("Finder Extension"),
                        detail: Text("Off in Login Items & Extensions, so Finder shows none of these items."),
                        status: Text("Off"), open: { router.open(.permissions) })
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
                Button("Permissions…") { router.open(.permissions) }
            }
        }
        .formStyle(.grouped)
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
                    access.expectFinderExtension()
                }
                settings.finderMenuEnabled = isOn
            })
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
