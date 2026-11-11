import ServiceManagement
import SwiftUI

/// What belongs to the app as a whole. Short enough that nothing needs moving elsewhere.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                // A plain binding, so correcting the switch after a failure does not count as a new request.
                Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if loginItemNeedsApproval {
                    LabeledContent("Allow Tweakly in System Settings to open it at login") {
                        Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.secondary)
                }
                // The simple view lives in this icon, so while that is on the icon stays.
                Toggle(
                    isOn: Binding(
                        get: { settings.showAppIcon || settings.simpleViewEnabled },
                        set: { settings.showAppIcon = $0 })
                ) {
                    Text("Show Tweakly Icon in Menu Bar")
                    if settings.simpleViewEnabled {
                        Text("Simple View opens from this icon, so it stays while that is on.")
                    }
                }
                .disabled(settings.simpleViewEnabled)
            }
            Section {
                Picker("App Theme", selection: $settings.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("Dock Icon", selection: $settings.dockIconTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.iconTitle).tag(theme)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(
                    "The theme applies to this window and to the popovers. The Dock icon shows while this window is open, and Finder and Spotlight use the one chosen in System Settings."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                languagePicker("Main Window", selection: $settings.windowLanguage)
                languagePicker("Popovers", selection: $settings.language)
                languagePicker("Menu Bar Labels", selection: $settings.menuBarLanguage)
                if settings.needsRestartForLanguage {
                    LabeledContent("The new language applies after a restart") {
                        Button("Restart Now") { WindowProcess.relaunchAll() }
                    }
                }
            } header: {
                Text("Language")
            }
        }
        .formStyle(.grouped)
        // The approval happens in System Settings, and this page has to see it on coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<AppLanguage>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = status == .requiresApproval
        launchAtLogin = status == .enabled
    }
}

extension AppTheme {
    var title: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .light: String(localized: "theme.light", defaultValue: "Light")
        case .dark: String(localized: "theme.dark", defaultValue: "Dark")
        }
    }

    /// Apart from `title`, because in Russian a theme and an icon take different endings.
    var iconTitle: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .light: String(localized: "icon.light", defaultValue: "Light")
        case .dark: String(localized: "icon.dark", defaultValue: "Dark")
        }
    }
}

extension AppLanguage {
    var title: String {
        switch self {
        case .system: String(localized: "Same as System")
        // Language names stay in their own language, so people can always find theirs.
        case .en: "English"
        case .de: "Deutsch"
        case .ru: "Русский"
        case .ja: "日本語"
        case .zhHans: "简体中文"
        }
    }
}
