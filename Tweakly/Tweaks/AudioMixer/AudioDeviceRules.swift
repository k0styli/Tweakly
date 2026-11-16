import AudioMixerCore
import CoreAudio
import Foundation
import os

/// The order outputs and inputs are chosen in, shared by the agent, which adds devices as they are first seen, and the
/// window, where the person reorders them.
enum AudioDeviceStore {
    private static let key = "volumeMixerDeviceOrder"

    /// Fresh from the disk, as another process may have written it.
    static func load() -> AudioDeviceOrder {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else { return AudioDeviceOrder() }
        return (try? JSONDecoder().decode(AudioDeviceOrder.self, from: data)) ?? AudioDeviceOrder()
    }

    static func save(_ order: AudioDeviceOrder) {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(order) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
        ProcessEvents.post(.audioDevicesChanged)
    }

    /// The devices connected now, as the order remembers them.
    static func known(_ devices: [AudioDevice]) -> [KnownAudioDevice] {
        devices.map { KnownAudioDevice(uid: $0.uid, name: $0.name, kind: $0.kind) }
    }
}

/// Chooses the system's output and input as devices come and go, as the person asked: a Bluetooth headset's
/// microphone only by hand, and devices in their order. It lives in the agent while the mixer is on and either rule is,
/// hears devices come and go and the system's choices change, and does nothing in between.
///
/// macOS makes its own choice a moment after a device comes, the output first, the input after. So everything that
/// changes within `settleTime` of a device coming or going is taken as the system's doing and weighed at once, while a
/// change at any other time is the person's own and stands until the next device comes or the one in use goes.
final class AudioDeviceRules {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer")
    static let settleTime: TimeInterval = 4

    private struct Side {
        let isInput: Bool
        var connected: [AudioDevice] = []
        /// In use before the devices last came or went, chosen by the person or by this.
        var settled: String?
        /// Came since then.
        var arrived: Set<String> = []
        /// Chosen by this a moment ago, so that hearing it is not taken as the person's choice.
        var expected: String?
        /// What macOS itself last chose while devices came or went: where a new device goes in the order.
        var systemChoice: String?
    }

    private var keepsMicrophone: Bool
    private var ordersDevices: Bool
    private var sides = [Side(isInput: false), Side(isInput: true)]
    private let listener = AudioListener()
    private var settleEnd: DispatchWorkItem?
    /// After the sound server starts again its devices come back one by one: none of them is new.
    private var restartGraceEnd: Date?
    #if TWEAKLY_AUTOMATION
        /// What was chosen and why, for tests.
        private(set) var history: [String] = []
    #endif

    init(keepsMicrophone: Bool, ordersDevices: Bool) {
        self.keepsMicrophone = keepsMicrophone
        self.ordersDevices = ordersDevices
        for index in sides.indices {
            sides[index].connected = Self.devices(input: sides[index].isInput)
            sides[index].settled = Self.current(input: sides[index].isInput)
        }
        listener.listen(
            to: AudioObjectID(kAudioObjectSystemObject),
            [
                kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultInputDevice,
            ]
        ) { [weak self] in self?.changed() }
        // Every device is new to a sound server that started again: what is in use then is where things stand.
        listener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]) {
            [weak self] in self?.restarted()
        }
        if ordersDevices { learnConnected() }
    }

    func update(keepsMicrophone: Bool, ordersDevices: Bool) {
        let startsOrdering = ordersDevices && !self.ordersDevices
        self.keepsMicrophone = keepsMicrophone
        self.ordersDevices = ordersDevices
        if startsOrdering { learnConnected() }
    }

    func stop() {
        listener.stop()
        settleEnd?.cancel()
        settleEnd = nil
    }

    // MARK: Hearing changes

    private func changed() {
        if let end = restartGraceEnd {
            if Date.now < end {
                takeAsTheyAre()
                return
            }
            restartGraceEnd = nil
        }
        var startsSettling = false
        for index in sides.indices {
            let isInput = sides[index].isInput
            let devices = Self.devices(input: isInput)
            let uids = devices.map(\.uid)
            let before = Set(sides[index].connected.map(\.uid))
            let arrived = Set(uids).subtracting(before)
            let lostSettled = sides[index].settled.map { !uids.contains($0) } ?? !uids.isEmpty
            if !arrived.isEmpty || lostSettled { startsSettling = true }
            sides[index].arrived.formUnion(arrived)
            sides[index].connected = devices
        }
        if startsSettling { settle() }
        for index in sides.indices {
            let current = Self.current(input: sides[index].isInput)
            if let expected = sides[index].expected, current == expected {
                sides[index].expected = nil
                if settleEnd == nil { sides[index].settled = current }
            } else if settleEnd == nil, current != sides[index].settled {
                // Nothing came or went: the person chose this, and it stands.
                sides[index].settled = current
                sides[index].expected = nil
                note("\(sides[index].isInput ? "input" : "output") chosen by hand")
            } else if settleEnd != nil, current != sides[index].settled, current != sides[index].expected {
                sides[index].systemChoice = current
            }
            if settleEnd != nil { decide(index) }
        }
    }

    private func settle() {
        settleEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        settleEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime, execute: work)
    }

    /// The system has made its choices: one last look, the new devices take their places, and what is in use now is
    /// where things stand.
    private func settled() {
        settleEnd = nil
        var order = AudioDeviceStore.load()
        let orderBefore = order
        for index in sides.indices {
            decide(index)
            let side = sides[index]
            // A choice made a moment ago may not read back yet.
            let current = side.expected ?? Self.current(input: side.isInput)
            if ordersDevices {
                // A new device goes first only if macOS itself chose it, never because this did.
                order.setList(
                    AudioDeviceChoice.learning(
                        order.list(input: side.isInput), connected: AudioDeviceStore.known(side.connected),
                        chosenBySystem: side.systemChoice.flatMap { side.arrived.contains($0) ? $0 : nil },
                        isInput: side.isInput),
                    input: side.isInput)
            }
            sides[index].settled = current
            sides[index].arrived = []
            sides[index].expected = nil
            sides[index].systemChoice = nil
        }
        if order != orderBefore { AudioDeviceStore.save(order) }
    }

    private func restarted() {
        settleEnd?.cancel()
        settleEnd = nil
        restartGraceEnd = Date.now.addingTimeInterval(Self.settleTime)
        takeAsTheyAre()
    }

    /// Whatever is connected and chosen now is where things stand, with nothing come or gone.
    private func takeAsTheyAre() {
        for index in sides.indices {
            sides[index].connected = Self.devices(input: sides[index].isInput)
            sides[index].settled = Self.current(input: sides[index].isInput)
            sides[index].arrived = []
            sides[index].expected = nil
            sides[index].systemChoice = nil
        }
    }

    // MARK: Choosing

    private func decide(_ index: Int) {
        let side = sides[index]
        let keepsMicrophone = keepsMicrophone && side.isInput
        guard ordersDevices || keepsMicrophone else { return }
        let current = Self.current(input: side.isInput)
        let manualOnly =
            keepsMicrophone
            ? Set(side.connected.filter { AudioDeviceChoice.isHeadsetMicrophone($0.kind) }.map(\.uid)) : []
        // A device seen for the first time already has the place it will be given: first if macOS chose it.
        let order: [String]? =
            ordersDevices
            ? AudioDeviceChoice.learning(
                AudioDeviceStore.load().list(input: side.isInput), connected: AudioDeviceStore.known(side.connected),
                chosenBySystem: side.systemChoice.flatMap { side.arrived.contains($0) ? $0 : nil },
                isInput: side.isInput
            ).map(\.uid) : nil
        guard
            let target = AudioDeviceChoice.choice(
                connected: side.connected.map(\.uid), current: current, settled: side.settled, arrived: side.arrived,
                order: order, manualOnly: manualOnly),
            let device = side.connected.first(where: { $0.uid == target })
        else { return }
        sides[index].expected = target
        guard AudioSystem.setDefaultDevice(device.id, input: side.isInput) else {
            sides[index].expected = nil
            Self.log.error("Could not choose a device as the \(side.isInput ? "input" : "output", privacy: .public)")
            return
        }
        Self.log.notice(
            "Chose \(device.name, privacy: .private) as the \(side.isInput ? "input" : "output", privacy: .public)")
        note("\(side.isInput ? "input" : "output") -> \(target)")
    }

    /// Every device connected now takes its place in the order, the first time with the one in use first.
    private func learnConnected() {
        var order = AudioDeviceStore.load()
        let before = order
        for side in sides {
            let connected = AudioDeviceStore.known(Self.devices(input: side.isInput))
            let list = order.list(input: side.isInput)
            order.setList(
                list.isEmpty
                    ? AudioDeviceChoice.initial(
                        connected: connected, current: Self.current(input: side.isInput), isInput: side.isInput)
                    : AudioDeviceChoice.learning(
                        list, connected: connected, chosenBySystem: nil, isInput: side.isInput),
                input: side.isInput)
        }
        if order != before { AudioDeviceStore.save(order) }
    }

    // MARK: Devices

    /// Real devices only: the private ones the process that plays makes come and go with every group it builds.
    private static func devices(input: Bool) -> [AudioDevice] {
        AudioSystem.devices(input: input).filter { !$0.uid.hasPrefix(TapEngine.deviceUIDPrefix) }
    }

    private static func current(input: Bool) -> String? {
        AudioSystem.defaultDevice(input: input).flatMap(AudioSystem.uid(of:))
    }

    private func note(_ line: String) {
        #if TWEAKLY_AUTOMATION
            history.append("\(Date.now.timeIntervalSince1970) \(line)")
            if history.count > 50 { history.removeFirst(history.count - 50) }
        #endif
    }

    #if TWEAKLY_AUTOMATION
        /// For tests: each side's devices, what stands, what came, and what was chosen.
        var automationDescription: [String: Any] {
            [
                "keepsMicrophone": keepsMicrophone, "ordersDevices": ordersDevices, "settling": settleEnd != nil,
                "sides": sides.map { side in
                    [
                        "input": side.isInput, "connected": side.connected.map(\.uid),
                        "settled": side.settled ?? "", "arrived": side.arrived.sorted(),
                        "current": Self.current(input: side.isInput) ?? "",
                    ] as [String: Any]
                },
                "history": history,
            ]
        }
    #endif
}
