import AudioMixerCore
import CoreAudio
import os

/// Runs what `TapPlan` asks for: for each output, one private aggregate device holding that output, a process tap for
/// each app routed there, and with an equalizer on the output, a tap of everything else it plays. The taps mute the
/// sound they take only while they are read, so if this process stops for any reason, everything sounds as before.
/// Only public API: process taps since macOS 14.2, and the Swift classes for them since macOS 15.
final class TapEngine {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer")

    /// Every private aggregate device this makes starts so, which tells them from real outputs.
    static let deviceUIDPrefix = "me.tweakly.Tweakly.mixer."

    private var running: [String: TapGroupRunner] = [:]
    /// Groups that could not be run, by output: refused by the system or failed to build. Each try mutes their apps
    /// for a moment, and making and dropping a device is itself heard as the devices changing, which would try again at
    /// once. So one is tried again only once its apps' processes change, or when `retryFailed` says it is time.
    private var failed: [String: TapGroup] = [:]
    /// False once the system refused to let a tap be read, which the popover shows as a permission to give.
    private(set) var isPermitted = true

    /// Brings what runs in line with the plan. A group whose apps are the same only takes the new gains; anything
    /// else is built again, which interrupts that output's tapped sound for a moment.
    func apply(_ groups: [TapGroup]) {
        let wanted = Dictionary(uniqueKeysWithValues: groups.map { ($0.outputUID, $0) })
        for (output, runner) in running where wanted[output] == nil {
            runner.stop()
            running[output] = nil
            // Named as it was when taken: an output let go of has often just been disconnected.
            Self.log.notice("Let go of the sound on \(runner.outputDescription, privacy: .public)")
        }
        failed = failed.filter { output, group in wanted[output]?.hasSameSound(as: group) == true }
        for group in groups {
            if let runner = running[group.outputUID], runner.group.hasSameSound(as: group) {
                runner.update(group)
                continue
            }
            running[group.outputUID]?.stop()
            running[group.outputUID] = nil
            guard failed[group.outputUID] == nil else { continue }
            do {
                let runner = try TapGroupRunner(group)
                running[group.outputUID] = runner
                // What this process takes and where, so a question about sound going astray can be answered later.
                Self.log.notice(
                    "Took \(group.taps.count, privacy: .public) apps\(group.output == nil ? "" : " and the whole output", privacy: .public) on \(Self.describe(group.outputUID), privacy: .public)"
                )
                if runner.isPermitted {
                    isPermitted = true
                } else {
                    refuse(group)
                }
            } catch {
                failed[group.outputUID] = group
                Self.log.error(
                    "Could not take the sound on \(Self.describe(group.outputUID), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Lets the groups that could not run be tried again: a rule or an app's playing changed, which may follow someone
    /// allowing the recording, and a moment's interruption then is expected.
    func retryFailed() {
        failed = [:]
    }

    /// Asks again whether the running taps may be read, as permission can be taken away while they run: the apps
    /// would stay silent, read as silence and muted by their taps.
    func checkPermission() {
        for runner in running.values where !runner.isPermitted {
            refuse(runner.group)
        }
    }

    /// Read silence and keep the apps muted: better to let them play as they are and say why.
    private func refuse(_ group: TapGroup) {
        Self.log.error("System audio recording is not allowed, so no app's sound is taken")
        isPermitted = false
        running[group.outputUID]?.stop()
        running[group.outputUID] = nil
        failed[group.outputUID] = group
    }

    func stop() {
        running.values.forEach { $0.stop() }
        running = [:]
    }

    /// An output as the log names it: its kind, never its name or UID, which can carry a person's or a device's.
    fileprivate static func describe(_ uid: String) -> String {
        let kind = AudioSystem.devices(input: false).first { $0.uid == uid }?.kind.rawValue ?? "unknown"
        return "an output of kind \(kind)"
    }

    #if TWEAKLY_AUTOMATION
        /// For tests: each output, its apps and gains, and how loud what came in and what went out was.
        var state: [[String: Any]] {
            running.values.map { $0.state }
        }
    #endif
}

/// One output's aggregate device, its taps and its IO.
private final class TapGroupRunner {
    private(set) var group: TapGroup
    private var taps: [AudioHardwareTap] = []
    private var aggregate: AudioHardwareAggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private let mixer: TapMixer
    /// The output's kind as the log names it, kept from when it was taken.
    let outputDescription: String
    /// The output's rate can change while it runs, a Bluetooth headset going over to a call say, and every filter is
    /// drawn for a rate.
    private let rateListener = AudioListener()

    init(_ group: TapGroup) throws {
        self.group = group
        outputDescription = TapEngine.describe(group.outputUID)
        let system = AudioHardwareSystem.shared
        guard let output = AudioSystem.device(withUID: group.outputUID) else {
            throw AudioHardwareError(kAudioHardwareBadDeviceError)
        }
        // The output's whole sound, when taken, is the last tap, at its own level.
        let gains = group.taps.map(\.gain) + (group.output == nil ? [] : [1])
        let rate: Float64 = AudioSystem.value(output, kAudioDevicePropertyNominalSampleRate) ?? 48_000
        #if TWEAKLY_AUTOMATION
            mixer = TapMixer(gains: gains, sampleRate: rate, meters: true)
        #else
            mixer = TapMixer(gains: gains, sampleRate: rate)
        #endif
        applyEqualizers(of: group, after: nil)
        do {
            for item in group.taps {
                let description = CATapDescription(stereoMixdownOfProcesses: item.objectIDs)
                description.uuid = UUID()
                description.name = "Tweakly \(item.bundleID)"
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                guard let tap = try system.makeProcessTap(description: description) else {
                    throw AudioHardwareError(kAudioHardwareUnspecifiedError)
                }
                taps.append(tap)
            }
            if let whole = group.output {
                // Everything that plays on the output but this process and the apps taken above, for its equalizer.
                let description = CATapDescription(
                    excludingProcesses: whole.excluded, deviceUID: group.outputUID, stream: 0)
                // As one interleaved stereo stream, as the apps' taps are, whatever channels the output's own has.
                description.isMixdown = true
                description.isMono = false
                description.uuid = UUID()
                description.name = "Tweakly output"
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                guard let tap = try system.makeProcessTap(description: description) else {
                    throw AudioHardwareError(kAudioHardwareUnspecifiedError)
                }
                taps.append(tap)
            }
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Tweakly Mixer",
                kAudioAggregateDeviceUIDKey: TapEngine.deviceUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: group.outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: group.outputUID]],
                kAudioAggregateDeviceTapListKey: try taps.map {
                    [kAudioSubTapUIDKey: try $0.uid, kAudioSubTapDriftCompensationKey: true]
                },
            ]
            guard let aggregate = try system.makeAggregateDevice(description: description) else {
                throw AudioHardwareError(kAudioHardwareUnspecifiedError)
            }
            self.aggregate = aggregate
            followRate(of: aggregate.id)
            var created: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&created, aggregate.id, nil, mixer.ioBlock())
            guard status == noErr, let created else { throw AudioHardwareError(status) }
            procID = created
            Self.useTapStreamsOnly(
                of: aggregate.id, procID: created, ownStreams: AudioSystem.streamCount(of: output, input: true))
            try aggregate.start(IOProcID: created)
        } catch {
            stop()
            throw error
        }
    }

    /// The aggregate runs at its output's rate.
    private func followRate(of aggregate: AudioObjectID) {
        let read = { [mixer] in
            if let rate: Float64 = AudioSystem.value(aggregate, kAudioDevicePropertyNominalSampleRate), rate > 0 {
                mixer.setSampleRate(rate)
            }
        }
        read()
        rateListener.listen(to: aggregate, [kAudioDevicePropertyNominalSampleRate]) { read() }
    }

    /// Each app's equalizer and the output's, solved again only where they changed: a slider sends a new rule many
    /// times a second, most of them for the volume.
    private func applyEqualizers(of newGroup: TapGroup, after old: TapGroup?) {
        for (index, item) in newGroup.taps.enumerated() where index < mixer.equalizers.count {
            if old.map({ index < $0.taps.count && $0.taps[index].equalizer == item.equalizer }) != true {
                mixer.equalizers[index].set(item.equalizer)
            }
        }
        let equalizer = newGroup.output?.equalizer ?? .flat
        if old.map({ ($0.output?.equalizer ?? .flat) == equalizer }) != true {
            mixer.outputEqualizer.set(equalizer)
        }
    }

    /// Keeps the output's own input streams, a headset's microphone say, off for this IO. Started, they would turn the
    /// microphone on, with its indicator and a permission this app does not have, and AirPods over to their call
    /// profile. The taps' streams come after them and stay on; an IO sees an empty buffer for a stream that is off.
    private static func useTapStreamsOnly(of aggregate: AudioObjectID, procID: AudioDeviceIOProcID, ownStreams: Int) {
        let streams = AudioSystem.streamCount(of: aggregate, input: true)
        guard ownStreams > 0, streams > ownStreams else { return }
        // `AudioHardwareIOProcStreamUsage`: the IOProc, the number of streams, then a flag for each.
        let flags = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let size = flags + MemoryLayout<UInt32>.size * streams
        let usage = UnsafeMutableRawPointer.allocate(
            byteCount: max(size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(streams), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for stream in 0..<streams {
            usage.storeBytes(of: stream < ownStreams ? 0 : 1, toByteOffset: flags + 4 * stream, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), usage)
        if status != noErr {
            Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer").error(
                "Could not keep the output's own inputs off: \(status, privacy: .public)")
        }
    }

    /// Whether the system lets the taps be read. It refuses quietly, with silence; setting a tap's own description
    /// again is what reports the refusal.
    var isPermitted: Bool {
        guard let tap = taps.first, let description = try? tap.description else { return true }
        do {
            try tap.setDescription(description)
            return true
        } catch let error as AudioHardwareError {
            return error.error != kAudioDevicePermissionsError
        } catch {
            return true
        }
    }

    func update(_ newGroup: TapGroup) {
        let old = group
        group = newGroup
        for (index, item) in newGroup.taps.enumerated() { mixer.gains.set(index, item.gain) }
        applyEqualizers(of: newGroup, after: old)
    }

    func stop() {
        rateListener.stop()
        let system = AudioHardwareSystem.shared
        if let aggregate, let procID {
            try? aggregate.stop(IOProcID: procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        procID = nil
        if let aggregate { try? system.destroyAggregateDevice(aggregate) }
        aggregate = nil
        for tap in taps { try? system.destroyProcessTap(tap) }
        taps = []
    }

    #if TWEAKLY_AUTOMATION
        var state: [String: Any] {
            [
                "output": group.outputUID, "apps": group.taps.map(\.bundleID), "gains": group.taps.map(\.gain),
                "inputPeak": mixer.inputPeak, "outputPeak": mixer.outputPeak,
                "equalizers": group.taps.map { $0.equalizer.presetID ?? ($0.equalizer.isFlat ? "flat" : "manual") },
                "outputTaken": group.output != nil, "excluded": group.output?.excluded ?? [],
                "outputEqualizer": group.output.map { $0.equalizer.presetID ?? "manual" } ?? "",
                "sampleRate": mixer.outputEqualizer.sampleRate,
                "outputEqualizing": !mixer.outputEqualizer.isBypassed,
            ]
        }
    #endif
}
