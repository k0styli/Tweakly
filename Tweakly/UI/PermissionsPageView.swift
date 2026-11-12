import ServiceManagement
import SwiftUI
import SystemMetrics

/// Everything Tweakly asks macOS for, in one place, as Privacy & Security is for the whole Mac: each permission with
/// how it stands, the features that use it, and a button that gives it or opens where it is given.
struct PermissionsPageView: View {
    let access: SystemAccess
    @Bindable var settings: AppSettings
    @State private var helperError: String?

    var body: some View {
        Form {
            Section {
                FeatureLabel(
                    symbol: MainPage.permissions.symbol, title: Text("Permissions"),
                    detail: Text(
                        "What macOS allows Tweakly to do. Tweakly asks for a permission only when you turn on a feature that needs it."
                    ))
            }
            Section {
                AccessRow(
                    symbol: "accessibility", title: Text("Accessibility"),
                    uses: [.windowSwitcher, .dock, .mouse, .finderCut, .languageSwitch, .keyboardCleaning],
                    waiting: access.accessibility ? [] : waitingForAccessibility
                ) {
                    grant(access.accessibility ? .allowed : .notAllowed, ask: SystemPermission.accessibility.ask)
                }
                AccessRow(
                    symbol: "rectangle.dashed.badge.record", title: Text("Screen & System Audio Recording"),
                    note: Text("Pictures of windows. Without it, the tiles show app icons."),
                    uses: [.windowSwitcher, .dock],
                    waiting: access.screenRecording ? [] : waitingForScreenRecording
                ) {
                    grant(access.screenRecording ? .allowed : .notAllowed, ask: SystemPermission.screenRecording.ask)
                }
                if access.screenRecordingArrived {
                    RestartForPicturesRow()
                }
                AccessRow(
                    symbol: "waveform", title: Text("System Audio Recording Only"),
                    note: Text("The volume of each app."),
                    uses: [.volumeMixer],
                    waiting: access.audioRecording == .notAllowed && settings.volumeMixerEnabled ? [.volumeMixer] : []
                ) {
                    grant(access.audioRecording) { open(AudioRuleStore.privacySettingsURL) }
                }
                AccessRow(
                    symbol: "internaldrive", title: Text("Full Disk Access"),
                    note: Text("Finds the data of apps from the App Store. Optional."),
                    uses: [.uninstaller], waiting: []
                ) {
                    grant(access.fullDiskAccess ? .allowed : .notAllowed, ask: FullDiskAccess.openSettings)
                }
                AccessRow(
                    symbol: "folder", title: Text("Files & Folders"),
                    note: Text("New File on the desktop and in Documents and Downloads."),
                    uses: [.finderMenu],
                    waiting: access.filesAndFolders == .notAllowed && settings.finderMenuEnabled ? [.finderMenu] : []
                ) {
                    grant(access.filesAndFolders) { open(Self.filesAndFoldersURL) }
                }
            } header: {
                Text("Privacy & Security")
            } footer: {
                if !access.accessibility || !access.screenRecording {
                    PermissionAdvice()
                }
            }
            Section("Login Items & Extensions") {
                AccessRow(
                    symbol: "power", title: Text("Open at Login"),
                    note: Text("Starts Tweakly in the menu bar when you log in."), uses: [], waiting: []
                ) {
                    loginItem
                }
                if let error = access.loginItemError {
                    Text(error).foregroundStyle(.secondary)
                }
                AccessRow(
                    symbol: "puzzlepiece.extension", title: Text("Finder Extension"),
                    uses: [.finderMenu],
                    waiting: !access.finderExtension && settings.finderMenuEnabled ? [.finderMenu] : []
                ) {
                    finderExtension
                }
            }
            Section {
                AccessRow(
                    symbol: "lock.shield", title: Text("Tweakly Helper"),
                    note: Text("Installed once, with an administrator’s password."),
                    uses: MetricKind.available.contains(.fans) ? [.metric(.fans), .taskManager] : [.taskManager],
                    waiting: []
                ) {
                    helper
                }
                if let helperError {
                    Label(helperError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Administrator Rights")
            } footer: {
                Text(
                    MetricKind.available.contains(.fans)
                        ? "It sets the speed of the fans and lets Task Manager show and quit other users’ processes."
                        : "It lets Task Manager show and quit other users’ processes."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { access.refresh(includingHelper: true) }
    }

    private static let filesAndFoldersURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"

    @ViewBuilder private func grant(_ grant: SystemAccess.Grant, ask: @escaping () -> Void) -> some View {
        switch grant {
        case .allowed:
            AllowedLabel(title: "Allowed")
        case .notAllowed:
            Button("Allow…", action: ask)
        case .askedOnFirstUse:
            Text("Asked on First Use").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var loginItem: some View {
        switch access.loginItem {
        case .requiresApproval:
            Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
        default:
            Toggle(
                "Open at Login",
                isOn: Binding(get: { access.loginItem == .enabled }, set: access.setOpenAtLogin)
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    @ViewBuilder private var finderExtension: some View {
        if access.finderExtension {
            AllowedLabel(title: "On")
        } else if settings.finderMenuEnabled {
            Button("Turn On", action: access.turnOnFinderExtension)
        } else {
            // Finder Menu turns its extension on and off itself, so that Finder does not keep it running for nothing.
            Text("Off").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var helper: some View {
        switch access.helper {
        case .installed:
            AllowedLabel(title: "Installed")
        case .checking:
            ProgressView().controlSize(.small)
        case .outdated:
            Button("Update…") { helperError = access.installHelper() }
        case .notInstalled:
            Button("Install…") { helperError = access.installHelper() }
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The features that are on and do nothing for want of Accessibility.
    private var waitingForAccessibility: [MainPage] {
        let pages: [(Bool, MainPage)] = [
            (settings.windowSwitcherEnabled, .windowSwitcher), (settings.dockEnabled, .dock),
            (settings.mouseEnabled, .mouse), (settings.finderCutEnabled, .finderCut),
            (settings.languageSwitchEnabled, .languageSwitch),
        ]
        return pages.filter(\.0).map(\.1)
    }

    private var waitingForScreenRecording: [MainPage] {
        let pages: [(Bool, MainPage)] = [
            (settings.windowSwitcherEnabled && settings.switcherTuning.showsPreviews, .windowSwitcher),
            (settings.dockEnabled && settings.dockTuning.showsPanel, .dock),
        ]
        return pages.filter(\.0).map(\.1)
    }
}

/// One thing asked of macOS: what it is, what it does for whom, and at the end of the row how it stands.
private struct AccessRow<Standing: View>: View {
    let symbol: String
    let title: Text
    var note: Text?
    /// The features that use it, whether they are on or not.
    let uses: [MainPage]
    /// Those of them that are on and do not work until it is given.
    let waiting: [MainPage]
    @ViewBuilder let standing: () -> Standing

    var body: some View {
        LabeledContent {
            standing()
        } label: {
            Label {
                title
                // The features by their page names, which need no declension in any language.
                if !uses.isEmpty { Text(uses.map(\.title).formatted(.list(type: .and))) }
                if let note { note }
                if !waiting.isEmpty {
                    Label {
                        Text("Turned on and waiting for it: \(waiting.map(\.title).formatted(.list(type: .and)))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.primary)
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: LinkRow<EmptyView>.symbolWidth)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Given, on or installed: nothing to do, as Allowed reads on the tweaks' own pages.
private struct AllowedLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
    }
}
