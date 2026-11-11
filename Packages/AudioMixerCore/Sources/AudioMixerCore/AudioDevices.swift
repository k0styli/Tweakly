import Foundation

/// What a sound device is, for its symbol and for telling headphones from speakers.
public enum AudioDeviceKind: String, Equatable, Sendable {
    case builtInSpeakers, builtInHeadphones, builtInMicrophone
    case airPods, airPodsPro, airPodsMax, bluetoothHeadphones, bluetoothSpeaker
    case usbHeadphones, display, usb, airPlay, virtual, other

    /// The SF Symbol that macOS's own sound menu shows for such a device, as near as it can be told.
    public var symbolName: String {
        switch self {
        case .builtInSpeakers: "laptopcomputer"
        case .builtInHeadphones: "headphones"
        case .builtInMicrophone: "mic"
        case .airPods: "airpods"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .bluetoothHeadphones: "headphones"
        case .bluetoothSpeaker: "hifispeaker"
        case .usbHeadphones: "headphones"
        case .display: "display"
        case .usb: "hifispeaker"
        case .airPlay: "airplay.audio"
        case .virtual: "waveform"
        case .other: "speaker.wave.2"
        }
    }

    /// Tells a device apart by how it connects, as Core Audio reports it in four letters (`bltn`, `blue`, `usb `, …),
    /// the source a built-in device plays through (`ispk`, `hdpn`), and its name.
    public static func of(transport: String, dataSource: String?, name: String, isInput: Bool) -> AudioDeviceKind {
        let lowered = name.lowercased()
        switch transport {
        case "bltn":
            if isInput { return .builtInMicrophone }
            return dataSource == "hdpn" || lowered.contains("headphone") ? .builtInHeadphones : .builtInSpeakers
        case "blue", "bleo":
            if lowered.contains("airpods max") { return .airPodsMax }
            if lowered.contains("airpods pro") { return .airPodsPro }
            if lowered.contains("airpods") { return .airPods }
            let speakerWords = ["speaker", "soundbar", "boom", "homepod", "колонк"]
            return speakerWords.contains { lowered.contains($0) } ? .bluetoothSpeaker : .bluetoothHeadphones
        case "hdmi", "dprt", "thun":
            return .display
        case "usb ":
            return lowered.contains("headset") || lowered.contains("headphone") ? .usbHeadphones : .usb
        case "airp":
            return .airPlay
        case "virt", "grup":
            return .virtual
        default:
            return .other
        }
    }

    /// Four bytes as Core Audio's codes read, such as 'bltn'.
    public static func code(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The sound menu's view of the volume: the speaker's symbol and steps.
public enum VolumeLevel {
    /// One step of the keyboard's volume keys, which macOS divides into sixteen.
    public static let step = 1.0 / 16

    /// The waves of the menu bar's speaker as a fraction for the symbol's variable value: none for silence, then a
    /// third, two thirds or all of them, as Control Center draws it.
    public static func waves(volume: Double, isMuted: Bool) -> Double? {
        guard !isMuted, volume > 0.001 else { return nil }
        return min(1, (volume * 3).rounded(.up) / 3)
    }

    /// The nearest of the keyboard's steps, where a scroll over the item starts from, so it and the keys land on the
    /// same values.
    public static func onStep(_ volume: Double) -> Double {
        min(1, max(0, (volume / step).rounded() * step))
    }

    /// The volume a scroll of so many steps leads to, snapped to the keyboard's steps.
    public static func stepped(_ volume: Double, by steps: Int) -> Double {
        min(1, max(0, onStep(volume) + Double(steps) * step))
    }

    /// A driver may report anything, and a volume that is not a number must not stop the app.
    public static func percent(_ volume: Double) -> Int {
        guard volume.isFinite else { return 0 }
        return Int((min(max(volume, -10), 10) * 100).rounded())
    }
}
