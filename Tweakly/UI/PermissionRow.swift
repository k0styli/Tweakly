import AppKit
import SwiftUI

/// The system asks for each permission through a dialog, and only reliably the first time, so after that a press
/// also opens System Settings. It always makes the request too, because that is what puts the app on the list
/// there, and it may not be there: resetting the permissions takes it off.
enum SystemPermission: String {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    func ask() {
        switch self {
        case .accessibility:
            // The value of `kAXTrustedCheckOptionPrompt`, a global that strict concurrency will not let be read.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        let defaults = UserDefaults.standard
        let key = "windowSwitcherAsked.\(rawValue)"
        if defaults.bool(forKey: key),
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
        {
            NSWorkspace.shared.open(url)
        }
        defaults.set(true, forKey: key)
    }
}

/// A permission a feature that is on cannot work without, on that feature's page. It leads to the Permissions page,
/// the one place where every permission is given, as a row of Privacy & Security leads to its own list. It stays out of
/// sight while nothing is missing.
struct MissingAccessRow: View {
    let title: Text
    let detail: Text
    var status = Text("Not Allowed")
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            LabeledContent {
                HStack(spacing: 6) {
                    status
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                Label {
                    title
                    detail
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .frame(width: LinkRow<EmptyView>.symbolWidth)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens Permissions"))
    }
}

/// Screen Recording given while Tweakly runs reaches window pictures only after a restart, as System Settings itself
/// says when the switch is turned on.
struct RestartForPicturesRow: View {
    var body: some View {
        LabeledContent("Previews appear after a restart") {
            Button("Restart Now") { WindowProcess.relaunchAll() }
        }
    }
}

/// Goes under the rows above, once however many of them there are. A switch left on from an earlier signature looks
/// fine and does nothing, and only this helps.
struct PermissionAdvice: View {
    var body: some View {
        Text("If Tweakly already looks on in System Settings, turn it off and on again.")
    }
}
