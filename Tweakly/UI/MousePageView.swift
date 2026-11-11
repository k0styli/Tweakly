import AppKit
import MouseCore
import SwiftUI
import SystemMetrics

/// The mouse's page: the switch, the pointer, the wheel and the side buttons. Laid out as the Mouse pane of System
/// Settings is, with what that pane cannot do added where it belongs.
struct MousePageView: View {
    private static let canSetPointer = HIDEventSystemClients.canMakePassive

    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    @State private var hasAccessibility = Self.isTrusted

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.mouse.symbol, title: Text("Mouse"),
                    detail: Text(
                        "The pointer without acceleration, the wheel as on Windows, and the side buttons. The trackpad stays as it is."
                    ),
                    isOn: isEnabled)
            }
            if settings.mouseEnabled, !hasAccessibility {
                Section {
                    MissingPermissionRow(
                        title: Text("Accessibility"),
                        detail: Text(
                            "The pointer already works. The wheel and the side buttons wait for Accessibility."),
                        ask: SystemPermission.accessibility.ask)
                } footer: {
                    PermissionAdvice()
                }
            }
            Section {
                Toggle(isOn: $settings.mouseSettings.acceleration) {
                    Text("Pointer Acceleration")
                    Text(
                        "Off, the pointer moves exactly as far as the mouse, however fast. Best for games and drawing.")
                }
                ScaleRow(
                    title: Text("Pointer Speed"), detail: Text("In the middle, the speed macOS gives the mouse."),
                    stops: MouseSettings.speedChoices.count, stop: speedStop, lowest: Text("Slow"),
                    highest: Text("Fast"), spoken: speedSpoken)
            } header: {
                SectionTitle(
                    title: Text("Pointer"),
                    detail: Text("Set on the mouse itself, so the pointer moves with no delay at any polling rate."))
            } footer: {
                if !Self.canSetPointer {
                    Text(
                        "This version of macOS does not let Tweakly set the pointer. System Settings › Mouse still can."
                    )
                }
            }
            .disabled(!settings.mouseEnabled || !Self.canSetPointer)
            Section {
                Picker(selection: $settings.mouseSettings.scrollDirection) {
                    Text("As on Windows").tag(MouseSettings.ScrollDirection.standard)
                    Text("Natural").tag(MouseSettings.ScrollDirection.natural)
                } label: {
                    Text("Scroll Direction")
                    Text("The trackpad keeps the direction set in System Settings.")
                }
                Toggle(isOn: $settings.mouseSettings.scrollAcceleration) {
                    Text("Scroll Acceleration")
                    Text("Off, every notch scrolls the same distance, however fast the wheel turns.")
                }
                LabeledContent {
                    HStack {
                        Text(settings.mouseSettings.linesPerNotch, format: .number).monospacedDigit()
                        Stepper(
                            "Lines per Notch", value: $settings.mouseSettings.linesPerNotch,
                            in: MouseSettings.linesRange
                        )
                        .labelsHidden()
                    }
                } label: {
                    Text("Lines per Notch")
                }
                .disabled(settings.mouseSettings.scrollAcceleration && !settings.mouseSettings.smoothScrolling)
                Toggle(isOn: $settings.mouseSettings.smoothScrolling) {
                    Text("Smooth Scrolling")
                    Text("The page glides to each notch instead of jumping. Games get the wheel as it is.")
                }
            } header: {
                Text("Scrolling")
            }
            .disabled(!settings.mouseEnabled)
            Section {
                Toggle(isOn: $settings.mouseSettings.sideButtonSwipes) {
                    Text("Back and Forward Everywhere")
                    Text(
                        "Safari, Finder and Firefox do not know the side buttons, so they get the trackpad's swipe instead. Other apps and games get the buttons as they are."
                    )
                }
            } header: {
                Text("Side Buttons")
            }
            .disabled(!settings.mouseEnabled)
        }
        .formStyle(.grouped)
        .pollingPermissions(
            whileVisible: isWindowVisible && settings.mouseEnabled, every: hasAccessibility ? 5 : 1, refreshPermission)
    }

    private var speedStop: Binding<Int> {
        Binding(
            get: {
                MouseSettings.speedChoices.firstIndex(of: settings.mouseSettings.speed)
                    ?? MouseSettings.speedChoices.firstIndex(of: 1) ?? 0
            },
            set: { settings.mouseSettings.speed = MouseSettings.speedChoices[$0] })
    }

    private var speedSpoken: String {
        let percent = Int((settings.mouseSettings.speed * 100).rounded())
        return String(localized: "\(percent) % of the system's speed")
    }

    /// Accessibility is asked for at the moment the feature is turned on.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { settings.mouseEnabled },
            set: { isOn in
                settings.mouseEnabled = isOn
                if isOn, !AXIsProcessTrusted() { SystemPermission.accessibility.ask() }
            })
    }

    /// A test copy showing made-up data draws the page as it looks with the permission given, as its agent leaves the
    /// mouse alone then.
    private static var isTrusted: Bool {
        #if TWEAKLY_AUTOMATION
            if DemoData.isOn { return true }
        #endif
        return AXIsProcessTrusted()
    }

    private func refreshPermission() {
        let accessibility = Self.isTrusted
        guard accessibility != hasAccessibility else { return }
        hasAccessibility = accessibility
        // The agent goes by its own check, and this tells it the moment to make that check.
        ProcessEvents.post(.settingsChanged)
    }
}
