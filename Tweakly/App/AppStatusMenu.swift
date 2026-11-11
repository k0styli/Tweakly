import AppKit
import FanControlCore

/// What every Tweakly item in the menu bar offers on a right click, and the gear on any click when it has no list behind
/// it. Popovers have no buttons of their own, so this is the way to the app from the menu bar.
final class AppStatusMenu: NSObject {
    private static let batterySettings = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    private static let soundSettings = "x-apple.systempreferences:com.apple.Sound-Settings.extension"

    var onChooseLook: ((SimpleViewLook) -> Void)?
    var onChooseFanProfile: ((FanProfileChoice) -> Void)?
    private var fanProfiles: [(choice: FanProfileChoice, title: String)] = []

    /// With `simpleLook`, also the choice between the simple view's looks, since its popover has no buttons either.
    func fill(
        _ menu: NSMenu, offersBatterySettings: Bool = false, offersSoundSettings: Bool = false,
        simpleLook: SimpleViewLook? = nil,
        fanProfiles: [(choice: FanProfileChoice, title: String)] = [], currentFanProfile: FanProfileChoice? = nil
    ) {
        menu.removeAllItems()
        menu.appearance = AppSettings.savedTheme.appearance
        self.fanProfiles = fanProfiles
        for (index, profile) in fanProfiles.enumerated() {
            let item = menu.addItem(
                withTitle: profile.title, action: #selector(chooseFanProfile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = profile.choice == currentFanProfile ? .on : .off
        }
        if !fanProfiles.isEmpty { menu.addItem(.separator()) }
        if let simpleLook {
            for look in SimpleViewLook.allCases {
                let item = menu.addItem(withTitle: look.title, action: #selector(chooseLook(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = look.rawValue
                item.state = look == simpleLook ? .on : .off
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Open Tweakly"), action: #selector(open), keyEquivalent: "")
            .target = self
        menu.addItem(
            withTitle: String(localized: "Open Task Manager"), action: #selector(openTaskManager), keyEquivalent: ""
        ).target = self
        if offersSoundSettings {
            menu.addItem(
                withTitle: String(localized: "Sound Settings…"), action: #selector(openSoundSettings), keyEquivalent: ""
            )
            .target = self
        }
        if offersBatterySettings {
            menu.addItem(
                withTitle: String(localized: "Battery Settings…"), action: #selector(openBatterySettings),
                keyEquivalent: ""
            )
            .target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Tweakly"), action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func chooseFanProfile(_ item: NSMenuItem) {
        guard fanProfiles.indices.contains(item.tag) else { return }
        onChooseFanProfile?(fanProfiles[item.tag].choice)
    }

    @objc private func chooseLook(_ item: NSMenuItem) {
        guard let look = (item.representedObject as? String).flatMap(SimpleViewLook.init(rawValue:)) else { return }
        onChooseLook?(look)
    }

    @objc private func open() {
        WindowProcess.open()
    }

    @objc private func openTaskManager() {
        WindowProcess.openTaskManager()
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: Self.soundSettings) { NSWorkspace.shared.open(url) }
    }

    @objc private func openBatterySettings() {
        if let url = URL(string: Self.batterySettings) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        ProcessEvents.quitEverything()
    }
}
