import SwiftUI
import TipKit
import os

/// The mini tour after the welcome: tips where a thing is done, through TipKit, as Apple's own apps show them. Each
/// shows only to someone who has not done what it teaches, and no more than one a day, as the guidelines on offering
/// help ask. They live in the window's process alone, so the agent never loads TipKit.
enum TweaklyTips {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "tips")

    static func configure(settings: AppSettings) {
        #if TWEAKLY_AUTOMATION
            // Test copies start with fresh settings, where every tip would be due and cover the page in a picture.
            // Testing calls have to come before `configure`.
            switch UserDefaults.standard.string(forKey: "tipsForTesting") {
            case "show": Tips.showAllTipsForTesting()
            case "hide", nil: Tips.hideAllTipsForTesting()
            // Without TipKit at all, to measure what it costs.
            case "off": return
            default: break
            }
        #endif
        do {
            try Tips.configure([.displayFrequency(.daily), .datastoreLocation(.url(try storeFolder()))])
        } catch {
            // Without its store TipKit shows nothing, which leaves the app as it was before tips.
            log.error("Tips are off: \(error.localizedDescription, privacy: .public)")
        }
        isWelcomeDone = !Welcome.isDue
        update(settings)
    }

    /// Kept with the app's other files, where removing the app finds it, rather than wherever TipKit would choose.
    private static func storeFolder() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appending(path: Bundle.main.bundleIdentifier ?? "me.tweakly.Tweakly")
            .appending(path: "Tips", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var isWelcomeDone: Bool {
        get { StartTip.isWelcomeDone }
        set { StartTip.isWelcomeDone = newValue }
    }

    /// The first tip is for someone with every tweak still off.
    static func update(_ settings: AppSettings) {
        let isAnyTweakOn =
            settings.windowSwitcherEnabled || settings.dockEnabled || settings.mouseEnabled
            || settings.finderCutEnabled || settings.finderMenuEnabled || settings.languageSwitchEnabled
            || settings.liveWallpaperEnabled || settings.volumeMixerEnabled || settings.simpleViewEnabled
        if StartTip.isAnyTweakOn != isAnyTweakOn { StartTip.isAnyTweakOn = isAnyTweakOn }
    }

    /// The task manager came up from outside the window, by its shortcut or the menu bar's menu: the tip about the
    /// shortcut has nothing left to teach.
    static func taskManagerOpenedFromOutside() {
        Task { await TaskManagerShortcutTip.openedFromOutside.donate() }
    }
}

/// On Home, under this Mac, until any tweak is on.
nonisolated struct StartTip: Tip {
    @Parameter static var isWelcomeDone: Bool = false
    @Parameter static var isAnyTweakOn: Bool = false

    var title: Text { Text("Turn on your first tweak") }
    var message: Text? {
        Text("Every tweak starts off. Pick one in the sidebar to see what it does and turn it on.")
    }
    var image: Image? { Image(systemName: "switch.2") }

    var rules: [Rule] {
        [
            #Rule(Self.$isWelcomeDone) { $0 },
            #Rule(Self.$isAnyTweakOn) { !$0 },
        ]
    }
}

/// Beside the task manager in the sidebar, until it has been opened from outside the window once.
nonisolated struct TaskManagerShortcutTip: Tip {
    static let openedFromOutside = Tips.Event(id: "taskManagerOpenedFromOutside")

    let shortcut: String

    var id: String { "taskManagerShortcut" }
    var title: Text { Text("Open it from any app") }
    var message: Text? { Text("Press \(shortcut) wherever you are to see what is slowing your Mac down.") }
    var image: Image? { Image(systemName: "keyboard") }

    var rules: [Rule] {
        [
            #Rule(StartTip.$isWelcomeDone) { $0 },
            #Rule(Self.openedFromOutside) { $0.donations.count == 0 },
        ]
    }
}
