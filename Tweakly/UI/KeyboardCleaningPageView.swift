import AppKit
import KeyboardCleaningCore
import SwiftUI

/// The page of cleaning the keyboard: a button to start, how long, and how to get back. There is nothing to leave on, so
/// the button stands where other pages have their main switch.
struct KeyboardCleaningPageView: View {
    @Bindable var settings: AppSettings
    let cleaning: KeyboardCleaningController
    let isWindowVisible: Bool
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var isShowingPermission = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Start Cleaning", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasAccessibility || cleaning.isActive)
                } label: {
                    FeatureLabel(
                        symbol: MainPage.keyboardCleaning.symbol, title: Text("Keyboard Cleaning"),
                        detail: Text(
                            "Turns the keyboard off for a while so you can wipe it. The trackpad and mouse keep working."
                        ))
                }
                if cleaning.couldNotStart {
                    Text("The system did not let the keyboard be turned off, so it stayed on.")
                        .foregroundStyle(.secondary)
                }
            }
            if !hasAccessibility {
                Section {
                    MissingPermissionRow(
                        title: Text("Accessibility"),
                        detail: Text("To turn the keyboard off for the time you choose."),
                        ask: SystemPermission.accessibility.ask)
                } footer: {
                    PermissionAdvice()
                }
            }
            Section {
                Picker("Turn Back On After", selection: length) {
                    ForEach(CleaningLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
            }
            Section {
                Label("Click the button on the screen", systemImage: "cursorarrow.click")
                Label("Or wait: it turns back on by itself", systemImage: "timer")
                Label("Or hold both Command keys for 3 seconds", systemImage: "command")
                Label("Sleep, locking the screen or a restart also bring it back", systemImage: "lock")
            } header: {
                SectionTitle(
                    title: Text("How to Turn It Back On"),
                    detail: Text("The power button and Touch ID cannot be turned off, so try not to press them."))
            }
            .sectionActions {
                Button("Permissions…") { isShowingPermission = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingPermission) {
            PermissionSheet(
                detail: "To turn the keyboard off for the time you choose.", isGranted: hasAccessibility)
        }
        .pollingPermissions(whileVisible: isWindowVisible, every: hasAccessibility && !isShowingPermission ? 5 : 1) {
            hasAccessibility = AXIsProcessTrusted()
        }
    }

    private var length: Binding<CleaningLength> {
        Binding(
            get: { CleaningLength(rawValue: settings.keyboardCleaningSeconds) ?? .minute },
            set: { settings.keyboardCleaningSeconds = $0.rawValue })
    }

    private func start() {
        cleaning.start(seconds: length.wrappedValue.seconds)
    }
}

extension CleaningLength {
    fileprivate var title: String {
        switch self {
        case .halfMinute: String(localized: "30 seconds")
        case .minute: String(localized: "1 minute")
        case .twoMinutes: String(localized: "2 minutes")
        case .fiveMinutes: String(localized: "5 minutes")
        }
    }
}
