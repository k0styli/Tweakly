#if TWEAKLY_AUTOMATION
    import AppKit
    import AudioMixerCore
    import CoreAudio

    /// Test copies with the `demoData` preference only, for pictures that will be published: the mixer of a made-up Mac,
    /// with outputs and playing apps every Mac can have, instead of this Mac's own devices and apps. Nothing here reaches
    /// Core Audio, so choosing a row or moving a slider changes nothing.
    enum DemoMixer {
        static let outputVolume = 0.62
        static let inputVolume = 0.74

        /// Core Audio names the built-in devices in the system's language, not the app's, so the made-up Mac names them
        /// itself, in the language the copy runs in.
        private static var speaks: String { Bundle.main.preferredLocalizations.first ?? "en" }

        /// Built-in speakers, then headphones and a display that any Mac may have.
        static func outputs() -> [AudioDevice] {
            let speakers = speaks == "ru" ? "Динамики MacBook Pro" : "MacBook Pro Speakers"
            return [
                AudioDevice(id: 90_001, uid: "demo.speakers", name: speakers, kind: .builtInSpeakers),
                AudioDevice(id: 90_002, uid: "demo.airpods", name: "AirPods Pro", kind: .airPodsPro),
                AudioDevice(id: 90_003, uid: "demo.display", name: "Studio Display", kind: .display),
            ]
        }

        static func inputs() -> [AudioDevice] {
            let microphone = speaks == "ru" ? "Микрофон MacBook Pro" : "MacBook Pro Microphone"
            return [AudioDevice(id: 90_011, uid: "demo.microphone", name: microphone, kind: .builtInMicrophone)]
        }

        private static let playing: [(bundleID: String, isPlaying: Bool, rule: AppAudioRule)] = [
            ("com.apple.Music", true, AppAudioRule(volume: 0.8)),
            ("com.apple.Safari", true, AppAudioRule(volume: 0.45)),
            ("com.apple.FaceTime", true, AppAudioRule(volume: 1)),
            ("com.apple.podcasts", false, AppAudioRule(volume: 0.6, isMuted: true)),
        ]

        static var rules: AudioRuleBook {
            AudioRuleBook(rules: Dictionary(uniqueKeysWithValues: playing.map { ($0.bundleID, $0.rule) }))
        }

        /// The apps, named as Finder names them in the copy's language. The process numbers are not real; the rows take
        /// their icons from the bundle instead.
        static func apps() -> [MixerApp] {
            playing.enumerated().compactMap { index, entry in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else {
                    return nil
                }
                let shown = FileManager.default.displayName(atPath: url.path)
                let name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
                return MixerApp(
                    owner: AudioOwner(bundleID: entry.bundleID, name: name, pid: -1 - Int32(index)), objectIDs: [],
                    isPlaying: entry.isPlaying)
            }
        }
    }
#endif
