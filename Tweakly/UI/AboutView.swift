import SwiftUI

/// In the manner of About This Mac: the picture and the name, then what it is in rows of their own.
struct AboutView: View {
    private static var iconSize: CGFloat { 96 }

    private func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .accessibilityHidden(true)
                    Text("Tweakly")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Useful additions to macOS that feel like they were always there.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Version", value: info("CFBundleShortVersionString"))
                LabeledContent("Build", value: info("CFBundleVersion"))
            }
            .textSelection(.enabled)
            .sectionActions {
                Button("Quit Tweakly") { ProcessEvents.quitEverything() }
            }
        }
        .formStyle(.grouped)
    }
}
