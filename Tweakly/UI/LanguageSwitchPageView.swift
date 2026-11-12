import AppKit
import SwiftUI

/// The page of switching the input source with Fn: the switch, what the system itself does with the globe key, and the
/// system's label at the cursor.
struct LanguageSwitchPageView: View {
    @Bindable var settings: AppSettings
    @Environment(SystemAccess.self) private var access
    @Environment(MainRouter.self) private var router
    @State private var globeKeyHasAction = SystemTextInput.globeKeyHasAction
    @State private var showsLanguageAtCursor = SystemTextInput.showsLanguageAtCursor

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.languageSwitch.symbol, title: Text("Switch Language with Fn"),
                    detail: Text("A short press of Fn turns on the previous input source at once, without the menu."),
                    isOn: isEnabled)
            }
            if settings.languageSwitchEnabled, !access.accessibility {
                Section {
                    MissingAccessRow(
                        title: Text("Accessibility"),
                        detail: Text("Off until Accessibility is allowed. Fn works as usual until then."),
                        open: { router.open(.permissions) })
                }
            }
            if settings.languageSwitchEnabled, globeKeyHasAction {
                Section {
                    LabeledContent {
                        Button("Open Keyboard Settings…", action: SystemTextInput.openKeyboardSettings)
                    } label: {
                        Label {
                            Text("The 🌐︎ Key Has Its Own Action")
                            Text(
                                "Set “Press 🌐︎ key to” to “Do Nothing” in Keyboard settings, or the system will act on the same press too."
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Previous Input Source") {
                    Text(verbatim: "fn")
                        .accessibilityLabel(Text("Function", comment: "VoiceOver's name of the fn key"))
                }
            } header: {
                SectionTitle(
                    title: Text("Keys"),
                    detail: Text("Held, or pressed with other keys, Fn works as usual: F1–F12, arrows and Delete."))
            }
            Section {
                Toggle(isOn: languageAtCursor) {
                    Text("Show Language at the Cursor")
                    Text("The system’s label next to the text cursor after each change. This applies to the whole Mac.")
                }
            }
            .sectionActions {
                Button("Permissions…") { router.open(.permissions) }
            }
        }
        .formStyle(.grouped)
        // Keyboard settings are changed in System Settings, and coming back from there makes this app active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// The permission is asked for at the moment the feature is turned on.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.languageSwitchEnabled },
            set: { isOn in
                settings.languageSwitchEnabled = isOn
                if isOn { access.askOnTurningOn(screenRecording: false) }
                if isOn { globeKeyHasAction = SystemTextInput.globeKeyHasAction }
            })
    }

    private var languageAtCursor: Binding<Bool> {
        Binding(
            get: { showsLanguageAtCursor },
            set: { shows in
                SystemTextInput.setShowsLanguageAtCursor(shows)
                showsLanguageAtCursor = SystemTextInput.showsLanguageAtCursor
            })
    }

    /// The system's settings can be changed in System Settings while this page is open.
    private func refresh() {
        globeKeyHasAction = SystemTextInput.globeKeyHasAction
        showsLanguageAtCursor = SystemTextInput.showsLanguageAtCursor
    }
}

/// The system's own text input settings that this page shows, read where the system keeps them, so the page is right
/// even after a change in System Settings. Checked on macOS 27.2.
enum SystemTextInput {
    private static let toolbox = "com.apple.HIToolbox" as CFString
    /// "Press 🌐 key to" in Keyboard settings: 0 is Do Nothing, the others change the input source, show emoji or start
    /// dictation. Missing means the system's default, which is one of those.
    private static let globeKeyAction = "AppleFnUsageType" as CFString
    /// Not in System Settings. The system reads it when its input menu agent starts.
    private static let languageIndicator = "TSMLanguageIndicatorEnabled" as CFString
    private static let inputMenuAgent = "com.apple.TextInputMenuAgent"
    private static let keyboardSettings = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    static var globeKeyHasAction: Bool {
        (CFPreferencesCopyAppValue(globeKeyAction, toolbox) as? Int) != 0
    }

    static func openKeyboardSettings() {
        guard let url = URL(string: keyboardSettings) else { return }
        NSWorkspace.shared.open(url)
    }

    static var showsLanguageAtCursor: Bool {
        CFPreferencesCopyAppValue(languageIndicator, kCFPreferencesAnyApplication) as? Bool ?? true
    }

    /// Changes the setting for every app, as `defaults write -g` would, then has the agent that reads it start again.
    /// launchd starts it by itself, as it keeps it running.
    static func setShowsLanguageAtCursor(_ shows: Bool) {
        CFPreferencesSetValue(
            languageIndicator, shows as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: inputMenuAgent) {
            kill(agent.processIdentifier, SIGTERM)
        }
    }
}
