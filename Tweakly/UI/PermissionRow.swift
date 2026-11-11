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

/// One permission on a tweak's page: what it is for, and either that it is allowed or a way to allow it.
struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isGranted: Bool
    let ask: () -> Void

    var body: some View {
        LabeledContent {
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: ask)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// A permission a feature that is on cannot work without. It stays out of sight until then, as System Settings names
/// what is missing only where something does not work because of it.
struct MissingPermissionRow: View {
    let title: Text
    let detail: Text
    let ask: () -> Void

    var body: some View {
        LabeledContent {
            Button("Allow…", action: ask)
        } label: {
            Label {
                title
                detail
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
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

/// The one permission of a page with nothing else to put in its Advanced sheet.
struct PermissionSheet: View {
    private static var height: CGFloat { 140 }

    let detail: LocalizedStringKey
    let isGranted: Bool

    var body: some View {
        DetailsSheet(height: Self.height) {
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility", detail: detail, isGranted: isGranted,
                    ask: SystemPermission.accessibility.ask)
            }
        }
    }
}

extension View {
    /// There is no public event for a permission changing, so a page asks for as long as it can be seen and something
    /// on it depends on the answer. Coming back into view asks at once.
    /// - Parameter seconds: how often. A person waiting for a permission to arrive wants to see it at once, while one
    ///   that is there only needs noticing if it goes.
    func pollingPermissions(
        whileVisible isVisible: Bool, every seconds: Int = 1, _ refresh: @escaping () -> Void
    ) -> some View {
        task(id: isVisible ? seconds : 0) {
            guard isVisible else { return }
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(seconds * 200))
            }
        }
    }
}
