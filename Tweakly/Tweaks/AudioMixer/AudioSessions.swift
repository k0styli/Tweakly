import AppKit
import AudioMixerCore
import CoreAudio
import Darwin

/// The apps heard since they started, as the Windows mixer keeps an app's session after its sound stops: an app that
/// played once stays in the popover, silent, until it quits, so its volume can be set before it plays again. An app
/// that only connected to the sound server, as Finder always does, never shows unless it plays, and a background agent
/// or daemon, such as the one that chimes when a charger is connected, shows only while it plays.
///
/// Lives in the agent while the mixer is on. Each client of the sound server is listened to on its own, added and
/// dropped as clients come and go; when one starts to play, only it is read, and its app is looked up once.
final class AudioSessions {
    private let systemListener = AudioListener()
    private var listeners: [AudioObjectID: AudioListener] = [:]
    /// Each client's app, once looked up: nil for one that is no app with a Dock icon.
    private var owners: [AudioObjectID: (bundleID: String, pid: pid_t)?] = [:]
    /// Each app heard, by bundle ID, with its process, which tells when it has quit.
    private(set) var heard: [String: pid_t] = [:]

    init() {
        systemListener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyProcessObjectList]) {
            [weak self] in self?.clientsChanged()
        }
        // Every client is new to a sound server that started again.
        systemListener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]) {
            [weak self] in
            guard let self else { return }
            listeners.values.forEach { $0.stop() }
            listeners = [:]
            owners = [:]
            clientsChanged()
        }
        clientsChanged()
    }

    func stop() {
        systemListener.stop()
        listeners.values.forEach { $0.stop() }
        listeners = [:]
        owners = [:]
    }

    var heardApps: Set<String> { Set(heard.keys) }

    private func clientsChanged() {
        // An app that quit ends its session, as on Windows.
        heard = heard.filter { _, pid in kill(pid, 0) == 0 || errno != ESRCH }
        let objects = Set(
            AudioSystem.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList))
        for gone in Set(listeners.keys).subtracting(objects) {
            listeners[gone]?.stop()
            listeners[gone] = nil
            owners[gone] = nil
        }
        for object in objects.subtracting(listeners.keys) {
            let listener = AudioListener()
            listener.listen(to: object, [kAudioProcessPropertyIsRunningOutput]) { [weak self] in
                self?.playingChanged(object)
            }
            listeners[object] = listener
            playingChanged(object)
        }
    }

    /// One client started or stopped: only it is read, and only a start matters.
    private func playingChanged(_ object: AudioObjectID) {
        let playing: UInt32 = AudioSystem.value(object, kAudioProcessPropertyIsRunningOutput) ?? 0
        guard playing != 0 else { return }
        let owner: (bundleID: String, pid: pid_t)?
        if let known = owners[object] {
            owner = known
        } else {
            owner = Self.app(of: object)
            owners[object] = owner
        }
        guard let owner, heard[owner.bundleID] == nil else { return }
        heard[owner.bundleID] = owner.pid
    }

    /// The app with a Dock icon a client plays for, or nil for an agent, a daemon or a command-line tool.
    private static func app(of object: AudioObjectID) -> (bundleID: String, pid: pid_t)? {
        guard let pid: pid_t = AudioSystem.value(object, kAudioProcessPropertyPID),
            let owner = AudioSystem.owner(of: AudioClient(objectID: object, pid: pid, isPlaying: true)),
            !owner.bundleID.hasPrefix("process:"),
            NSRunningApplication(processIdentifier: owner.pid)?.activationPolicy == .regular
        else { return nil }
        return (owner.bundleID, owner.pid)
    }
}
