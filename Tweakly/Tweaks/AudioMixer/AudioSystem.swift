import AppKit
import AudioMixerCore
import AudioToolbox
import CoreAudio
import SystemMetrics

/// A sound device as the mixer shows it.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let kind: AudioDeviceKind
}

/// Core Audio's devices, volumes and clients, through public API only. Every call is a property of an audio object,
/// safe from any thread, and fails quietly: a device that went away while it was asked about simply has no answer.
nonisolated enum AudioSystem {
    // MARK: Devices

    static func devices(input: Bool) -> [AudioDevice] {
        let ids: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard streamCount(of: id, input: input) > 0, !isHidden(id),
                let uid = string(id, kAudioDevicePropertyDeviceUID),
                let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            let transport: UInt32 = value(id, kAudioDevicePropertyTransportType) ?? 0
            let source: UInt32? = value(id, kAudioDevicePropertyDataSource, scope: scope(input))
            let kind = AudioDeviceKind.of(
                transport: AudioDeviceKind.code(transport), dataSource: source.map(AudioDeviceKind.code), name: name,
                isInput: input)
            return AudioDevice(id: id, uid: uid, name: name, kind: kind)
        }
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let id: AudioObjectID? = value(
            AudioObjectID(kAudioObjectSystemObject),
            input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    /// The system's output or input from now on, as choosing it in the sound menu does.
    @discardableResult
    static func setDefaultDevice(_ id: AudioObjectID, input: Bool) -> Bool {
        set(
            AudioObjectID(kAudioObjectSystemObject),
            input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    static func uid(of id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    static func device(withUID uid: String) -> AudioObjectID? {
        var translated = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &translated)
        }
        return status == noErr && translated != kAudioObjectUnknown ? translated : nil
    }

    static func streamCount(of id: AudioObjectID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope(input), mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func isHidden(_ id: AudioObjectID) -> Bool {
        (value(id, kAudioDevicePropertyIsHidden) as UInt32?) == 1
    }

    // MARK: Volume

    /// The device's volume as the sound menu and the keys set it, from 0 to 1; nil for a device without one.
    static func volume(of id: AudioObjectID, input: Bool) -> Double? {
        // A driver may answer anything; a volume that is not a number is no answer.
        (value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(input)) as Float32?)
            .map(Double.init).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    static func setVolume(_ volume: Double, of id: AudioObjectID, input: Bool) {
        let clamped = Float32(min(1, max(0, volume)))
        set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, clamped, scope: scope(input))
        // Moving the volume up from silence also turns the sound back on, as the keys do.
        if !input, clamped > 0, isMuted(id, input: false) == true { setMuted(false, of: id, input: false) }
    }

    static func canSetVolume(of id: AudioObjectID, input: Bool) -> Bool {
        isSettable(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope(input))
    }

    static func isMuted(_ id: AudioObjectID, input: Bool) -> Bool? {
        (value(id, kAudioDevicePropertyMute, scope: scope(input)) as UInt32?).map { $0 != 0 }
    }

    static func setMuted(_ muted: Bool, of id: AudioObjectID, input: Bool) {
        set(id, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), scope: scope(input))
    }

    // MARK: Clients

    /// Every process connected to the sound server, and whether it plays now.
    static func clients() -> [AudioClient] {
        let objects: [AudioObjectID] = array(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object in
            guard let pid: pid_t = value(object, kAudioProcessPropertyPID) else { return nil }
            let playing: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            // The output it opened itself, which is the system's unless the app chose one, as a call app may.
            let device = array(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).first
            return AudioClient(
                objectID: object, pid: pid, isPlaying: playing != 0, outputUID: device.flatMap(uid(of:)))
        }
    }

    /// The app a client plays for: a helper's responsible app, or the process's own. Nil for this app, whose own
    /// sound the mixer never takes, and for anything with neither an app nor a name.
    @MainActor
    static func owner(of client: AudioClient) -> AudioOwner? {
        let ownBundle = Bundle.main.bundleIdentifier
        let responsible = ResponsibleProcess.pid(responsibleFor: client.pid) ?? client.pid
        for pid in [responsible, client.pid] {
            guard let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier else {
                continue
            }
            if bundleID == ownBundle { return nil }
            return AudioOwner(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: pid)
        }
        // A process with no app, such as a command-line player, goes by its name.
        guard let name = processName(client.pid), client.pid != getpid() else { return nil }
        return AudioOwner(bundleID: "process:" + name, name: name, pid: client.pid)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    // MARK: Properties

    static func scope(_ input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    static func value<T: BitwiseCopyable>(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ newValue: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        return withUnsafeBytes(of: newValue) { bytes in
            guard let base = bytes.baseAddress else { return false }
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(bytes.count), base) == noErr
        }
    }

    static func isSettable(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address)
            && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var text: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &text) == noErr, let text else { return nil }
        return text.takeRetainedValue() as String
    }

    static func array(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

/// Listens to properties of audio objects and calls back on the main thread, until stopped or released.
final class AudioListener {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// One block for every property listed, on the main queue.
    func listen(
        to id: AudioObjectID, _ selectors: [AudioObjectPropertySelector],
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping @MainActor () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(id, &address),
                AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr
            else { continue }
            registrations.append((id, address, block))
        }
    }

    func stop() {
        for (id, address, block) in registrations {
            var copy = address
            AudioObjectRemovePropertyListenerBlock(id, &copy, .main, block)
        }
        registrations = []
    }

    isolated deinit {
        for (id, address, block) in registrations {
            var copy = address
            AudioObjectRemovePropertyListenerBlock(id, &copy, .main, block)
        }
    }
}
