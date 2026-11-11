import SwiftUI
import TipKit

/// Whether the welcome has been seen. Written straight to the defaults rather than through `AppSettings`, whose every
/// change wakes the agent to reload its settings, which this one means nothing to.
enum Welcome {
    /// Raised when the welcome changes enough to be worth showing again to people who have seen it.
    static let version = 1
    private static let key = "welcomeVersion"

    static var isDue: Bool { UserDefaults.standard.integer(forKey: key) < version }

    static func markSeen() {
        UserDefaults.standard.set(version, forKey: key)
        TweaklyTips.isWelcomeDone = true
    }
}

enum WelcomeStep: Hashable {
    case features
    case howItWorks
}

/// What Tweakly is and how it works, once, on first opening the window, in the manner of the welcome Apple's own apps
/// show (Journal, Freeform, Passwords): the app's icon and name, a few features each with a symbol, and a button to go
/// on. Brief, as the guidelines on onboarding ask; what is learnt by doing comes later, as tips where it applies. Help
/// › Welcome to Tweakly brings it back.
struct WelcomeView: View {
    @Bindable var router: MainRouter
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 580
    private static let iconSize: CGFloat = 64
    /// One width for every button, so Back and Get Started stand as a pair and Continue matches them.
    private static let buttonWidth: CGFloat = 160
    /// The buttons' strip under the text, with its margins.
    private static let buttonsHeight: CGFloat = 76
    /// Between the sheet and the window's bottom edge, as the system leaves around a sheet.
    private static let windowMargin: CGFloat = 20

    /// The text's own height, measured as it lays out, so the sheet is as tall as it needs and no taller.
    @State private var textHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls only when the window is too short for it, so the buttons always stay in view.
            ScrollView {
                Group {
                    switch router.welcomeStep {
                    case .features: features
                    case .howItWorks: howItWorks
                    }
                }
                // Forward slides in from the trailing edge and back from the leading one, as pages of a setup do.
                .transition(
                    reduceMotion ? .opacity : .push(from: router.welcomeStep == .features ? .leading : .trailing)
                )
                .padding(.horizontal, 44)
                .padding(.top, 24)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    textHeight = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The system's soft edge where text runs on under the buttons, as in its own sheets.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .frame(
                height: min(textHeight, max(router.windowContentHeight - Self.windowMargin - Self.buttonsHeight, 160)))
            buttons
                .frame(height: Self.buttonsHeight)
        }
        .frame(width: Self.width)
    }

    // MARK: Steps

    private var features: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            Text("Welcome to Tweakly")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text("Useful additions to macOS that feel like they were always there.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                WelcomeRow(
                    symbol: "gauge.with.dots.needle.67percent", title: "Statistics in the Menu Bar",
                    detail: "Processor, memory, disk, network and battery at a glance, with details a click away.")
                WelcomeRow(
                    symbol: "macwindow.on.rectangle", title: "Windows and the Dock",
                    detail: "Command-Tab with a preview of every window, and windows over each Dock icon.")
                WelcomeRow(
                    symbol: "folder.fill", title: "A Handier Finder",
                    detail: "Cut and paste files, plus New File, Copy Path and Open in Terminal in the shortcut menu.")
                WelcomeRow(
                    symbol: "wrench.and.screwdriver.fill",
                    title: LocalizedStringKey("Utilities"),
                    detail: "A task manager, an app uninstaller, a volume mixer and keyboard cleaning.")
                WelcomeRow(
                    symbol: "computermouse.fill", title: "Desktop, Keyboard and Mouse",
                    detail:
                        "Live wallpaper, the Fn key for the input language, and a mouse that points and scrolls your way."
                )
            }
            .padding(.top, 22)
        }
    }

    private var howItWorks: some View {
        VStack(spacing: 0) {
            Text("How Tweakly Works")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                WelcomeRow(
                    symbol: "switch.2", title: "Turn On What You Need",
                    detail: "Every tweak starts off. Turn on the ones you want on their pages; the rest cost nothing.")
                WelcomeRow(
                    symbol: "contextualmenu.and.cursorarrow", title: "At Home in the Menu Bar",
                    detail: "Right-click a Tweakly item in the menu bar, or open Tweakly again, to come back here.")
                WelcomeRow(
                    symbol: "hand.raised.fill", title: "Access Only When Needed",
                    detail: "When a tweak needs a permission, Tweakly says why and asks only then.")
                if settings.taskManagerEnabled {
                    WelcomeRow(
                        symbol: "keyboard", title: "Task Manager in Any App",
                        detail: LocalizedStringKey(
                            "Press \(settings.taskManagerShortcut.displayText) to see what is slowing your Mac down."))
                }
                WelcomeRow(
                    symbol: "magnifyingglass", title: "Find Any Setting",
                    detail: "Search above the sidebar finds pages and the settings on them.")
            }
            .padding(.top, 22)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 12) {
            if router.welcomeStep == .howItWorks {
                Button {
                    go(to: .features)
                } label: {
                    Text("Back").frame(minWidth: Self.buttonWidth)
                }
                .keyboardShortcut(.cancelAction)
            }
            switch router.welcomeStep {
            case .features:
                Button {
                    go(to: .howItWorks)
                } label: {
                    Text("Continue").frame(minWidth: Self.buttonWidth)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            case .howItWorks:
                Button {
                    finish()
                } label: {
                    Text("Get Started").frame(minWidth: Self.buttonWidth)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private func go(to step: WelcomeStep) {
        withAnimation { router.welcomeStep = step }
    }

    private func finish() {
        Welcome.markSeen()
        router.isWelcomeShown = false
    }
}

/// A feature with its symbol, as in the lists of Apple's own welcome screens: the symbol in the accent colour beside a
/// bold title and a line or two under it.
private struct WelcomeRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    private static let symbolWidth: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
