import AudioMixerCore
import Foundation

/// Each app's volume, mute and output, shared by the popover, the window and the process that plays them. Apart from
/// `AppSettings`, as a slider writes it many times a second and nothing else needs to hear about it.
enum AudioRuleStore {
    private static let key = "volumeMixerRules"
    /// Set by the process that plays when the system refuses it the apps' sound, see `AudioProcess`.
    static let notPermittedKey = "volumeMixerNotPermitted"

    /// Fresh from the disk, as another process may have written it.
    static func load() -> AudioRuleBook {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else { return AudioRuleBook() }
        return (try? JSONDecoder().decode(AudioRuleBook.self, from: data)) ?? AudioRuleBook()
    }

    static func save(_ book: AudioRuleBook) {
        let defaults = UserDefaults.standard
        if book.rules.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: key)
        }
        defaults.synchronize()
        ProcessEvents.post(.audioRulesChanged)
    }

    /// The rules as saved, for whoever changed them to show without reading them back.
    @discardableResult
    static func update(_ bundleID: String, _ change: (inout AppAudioRule) -> Void) -> AudioRuleBook {
        var book = load()
        var rule = book.rule(for: bundleID)
        change(&rule)
        book.set(rule, for: bundleID)
        save(book)
        return book
    }

    /// Nothing plays through the process that plays any more, so nothing is being refused: a refusal remembered from
    /// before would go on asking for a permission perhaps given since. The process says so again if it still is.
    static func forgetRefusal() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: notPermittedKey) else { return }
        defaults.removeObject(forKey: notPermittedKey)
        defaults.synchronize()
        ProcessEvents.post(.volumeMixerStateChanged)
    }

    static var isPermitted: Bool {
        UserDefaults.standard.synchronize()
        return !UserDefaults.standard.bool(forKey: notPermittedKey)
    }

    /// Set by the agent when the process that plays failed twice in a row and is no longer started, until the mixer
    /// is turned off and on again or the app restarts.
    private static let stoppedKey = "volumeMixerStopped"

    static var hasStopped: Bool {
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.bool(forKey: stoppedKey)
    }

    static func setStopped(_ stopped: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: stoppedKey) != stopped else { return }
        defaults.set(stopped, forKey: stoppedKey)
        defaults.synchronize()
        ProcessEvents.post(.volumeMixerStateChanged)
    }

    /// Privacy & Security › Screen & System Audio Recording, where the recording of the apps' sound is allowed.
    static let privacySettingsURL =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
}
