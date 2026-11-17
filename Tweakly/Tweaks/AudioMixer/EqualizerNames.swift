import AudioMixerCore
import Foundation

/// What the equalizer's choices are called, in the words Music uses for the same presets.
enum EqualizerNames {
    /// Music's presets but Flat, which is the same as Off here, in the order of their names, as Music lists them.
    static var presets: [EqualizerPreset] {
        EqualizerPreset.builtIn.filter { $0.id != EqualizerPreset.flatID }
            .sorted { name(of: $0.id).localizedStandardCompare(name(of: $1.id)) == .orderedAscending }
    }

    static func name(of presetID: String) -> String {
        switch presetID {
        case "acoustic": String(localized: "Acoustic", comment: "Equalizer preset, as in Music")
        case "bassBooster": String(localized: "Bass Booster", comment: "Equalizer preset, as in Music")
        case "bassReducer": String(localized: "Bass Reducer", comment: "Equalizer preset, as in Music")
        case "classical": String(localized: "Classical", comment: "Equalizer preset, as in Music")
        case "dance": String(localized: "Dance", comment: "Equalizer preset, as in Music")
        case "deep": String(localized: "Deep", comment: "Equalizer preset, as in Music")
        case "electronic": String(localized: "Electronic", comment: "Equalizer preset, as in Music")
        case "flat": String(localized: "Flat", comment: "Equalizer preset, as in Music")
        case "hipHop": String(localized: "Hip Hop", comment: "Equalizer preset, as in Music")
        case "jazz": String(localized: "Jazz", comment: "Equalizer preset, as in Music")
        case "latin": String(localized: "Latin", comment: "Equalizer preset, as in Music")
        case "loudness": String(localized: "Loudness", comment: "Equalizer preset, as in Music")
        case "lounge": String(localized: "Lounge", comment: "Equalizer preset, as in Music")
        case "piano": String(localized: "Piano", comment: "Equalizer preset, as in Music")
        case "pop": String(localized: "Pop", comment: "Equalizer preset, as in Music")
        case "rnb": String(localized: "R&B", comment: "Equalizer preset, as in Music")
        case "rock": String(localized: "Rock", comment: "Equalizer preset, as in Music")
        case "smallSpeakers": String(localized: "Small Speakers", comment: "Equalizer preset, as in Music")
        case "spokenWord": String(localized: "Spoken Word", comment: "Equalizer preset, as in Music")
        case "trebleBooster": String(localized: "Treble Booster", comment: "Equalizer preset, as in Music")
        case "trebleReducer": String(localized: "Treble Reducer", comment: "Equalizer preset, as in Music")
        case "vocalBooster": String(localized: "Vocal Booster", comment: "Equalizer preset, as in Music")
        default: AudioRuleStore.customPresets().first { $0.id == presetID }?.name ?? presetID
        }
    }

    /// What an equalizer is set to, in a word: Off, a preset's name, or Manual once its sliders were moved.
    static func describe(_ settings: EqualizerSettings, custom: [CustomEqualizerPreset]) -> String {
        if settings.isFlat { return String(localized: "Off", comment: "The equalizer, as in Music") }
        return choice(of: settings, custom: custom).map { name(of: $0, custom: custom) }
            ?? String(localized: "Manual", comment: "An equalizer whose sliders were moved by hand, as in Music")
    }

    /// The preset the settings still are, or nil once they were moved by hand or their preset was deleted.
    static func choice(of settings: EqualizerSettings, custom: [CustomEqualizerPreset]) -> String? {
        guard let id = settings.presetID else { return nil }
        if EqualizerPreset.builtIn(id) != nil || custom.contains(where: { $0.id == id }) { return id }
        return nil
    }

    static func name(of presetID: String, custom: [CustomEqualizerPreset]) -> String {
        custom.first { $0.id == presetID }?.name ?? name(of: presetID)
    }

    /// The settings a choice stands for.
    static func settings(for presetID: String, custom: [CustomEqualizerPreset]) -> EqualizerSettings? {
        custom.first { $0.id == presetID }?.settings ?? EqualizerPreset.builtIn(presetID)?.settings
    }

    /// A band's frequency as Music writes it under its slider: 500, 1K, 16K.
    static func shortLabel(_ frequency: Double) -> String {
        // Rounded, not cut: a frequency come back from a logarithm is 63.99… for 64.
        frequency >= 999.5 ? "\(Int((frequency / 1000).rounded()))K" : "\(Int(frequency.rounded()))"
    }

    /// A band's frequency spoken out, for VoiceOver.
    static func spokenFrequency(_ frequency: Double) -> String {
        String(localized: "\(number(frequency)) Hz", comment: "A frequency in hertz")
    }

    /// A gain in decibels with its sign, as the equalizer's scale writes it.
    static func decibels(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let digits = number(abs(rounded))
        let signed = rounded > 0 ? "+\(digits)" : rounded < 0 ? "−\(digits)" : digits
        return String(localized: "\(signed) dB", comment: "A gain in decibels")
    }

    /// Shown only in the window and in menus, never on a path that runs every second.
    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
