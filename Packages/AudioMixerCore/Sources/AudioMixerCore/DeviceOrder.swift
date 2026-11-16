import Foundation

/// A sound device the Mac has had, remembered by UID so that its place in the order outlives it being unplugged.
public struct KnownAudioDevice: Codable, Equatable, Identifiable, Sendable {
    public var uid: String
    public var name: String
    /// An `AudioDeviceKind`, for its symbol.
    public var kind: String

    public var id: String { uid }

    public init(uid: String, name: String, kind: AudioDeviceKind) {
        self.uid = uid
        self.name = name
        self.kind = kind.rawValue
    }

    public var deviceKind: AudioDeviceKind { AudioDeviceKind(rawValue: kind) ?? .other }
}

/// The order outputs and inputs are chosen in, first to last.
public struct AudioDeviceOrder: Codable, Equatable, Sendable {
    public var outputs: [KnownAudioDevice]
    public var inputs: [KnownAudioDevice]

    public init(outputs: [KnownAudioDevice] = [], inputs: [KnownAudioDevice] = []) {
        self.outputs = outputs
        self.inputs = inputs
    }

    public func list(input: Bool) -> [KnownAudioDevice] { input ? inputs : outputs }

    public mutating func setList(_ list: [KnownAudioDevice], input: Bool) {
        if input { inputs = list } else { outputs = list }
    }
}

/// Which output or input to use once devices come or go, as the person asked: in their order, and never a Bluetooth
/// headset's microphone unless chosen by hand. A choice made by hand stands until a device comes or the one in use goes.
public enum AudioDeviceChoice {
    /// Using a Bluetooth headset's microphone turns the headset over to its call profile, and what plays in it drops to
    /// a call's sound. AirPods and other headsets are told apart as the sound menu does (`AudioDeviceKind`).
    public static func isHeadsetMicrophone(_ kind: AudioDeviceKind) -> Bool {
        switch kind {
        case .airPods, .airPodsPro, .airPodsMax, .bluetoothHeadphones, .bluetoothSpeaker: true
        default: false
        }
    }

    /// The device to make the system's from now on, or nil to leave it as it is.
    ///
    /// - Parameters:
    ///   - connected: The devices there now, in the system's order.
    ///   - current: The system's device now, which macOS may have just changed by itself.
    ///   - settled: The device in use before these devices came or went, chosen by the person or by this.
    ///   - arrived: The devices that came since then.
    ///   - order: The person's order, first to last, or nil when they keep the system's.
    ///   - manualOnly: Devices only ever chosen by hand.
    public static func choice(
        connected: [String], current: String?, settled: String?, arrived: Set<String>, order: [String]?,
        manualOnly: Set<String>
    ) -> String? {
        let isSettledHere = settled.map(connected.contains) ?? false
        // Nothing came and the device in use is still here: whatever changed was someone's own choice, or a device
        // not in use going away.
        guard !arrived.isEmpty || !isSettledHere else { return nil }
        // While the device in use stays, only a device that came can take its place; once it has gone, any can.
        let candidates =
            if isSettledHere, let settled {
                [settled] + connected.filter { arrived.contains($0) && $0 != settled }
            } else {
                connected
            }
        // A device only chosen by hand is still allowed when the person chose it: it is what stands.
        let allowed = candidates.filter { !manualOnly.contains($0) || $0 == settled }
        // Only a headset's microphone is there, on a Mac without one of its own: better that than none.
        guard let first = allowed.first else { return nil }
        let target: String
        if let order {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            target = allowed.min { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) } ?? first
        } else if let current, allowed.contains(current) {
            // macOS's own choice stands, unless it is one made only by hand.
            target = current
        } else if let settled, allowed.contains(settled) {
            target = settled
        } else {
            target = first
        }
        return target == current ? nil : target
    }

    /// The order with every device now connected in it. A device seen for the first time goes where macOS put it: first
    /// if macOS chose it as it came, as it does with new headphones, otherwise last, as a display's speakers. A
    /// headset's microphone always goes last. A device known already keeps its place and takes its new name.
    public static func learning(
        _ list: [KnownAudioDevice], connected: [KnownAudioDevice], chosenBySystem: String?, isInput: Bool
    ) -> [KnownAudioDevice] {
        var result = list
        for device in connected {
            if let index = result.firstIndex(where: { $0.uid == device.uid }) {
                if result[index] != device { result[index] = device }
                continue
            }
            let goesLast = isInput && isHeadsetMicrophone(device.deviceKind)
            if device.uid == chosenBySystem, !goesLast {
                result.insert(device, at: 0)
            } else {
                result.append(device)
            }
        }
        return result
    }

    /// The order to start from: the devices there now, the one in use first, and a headset's microphone last.
    public static func initial(connected: [KnownAudioDevice], current: String?, isInput: Bool) -> [KnownAudioDevice] {
        let headset = { (device: KnownAudioDevice) in isInput && isHeadsetMicrophone(device.deviceKind) }
        let inUse = connected.filter { $0.uid == current && !headset($0) }
        let others = connected.filter { $0.uid != current && !headset($0) }
        return inUse + others + connected.filter(headset)
    }
}
