import AudioMixerCore
import CoreAudio
import Darwin
import os

/// The apps heard since they started, as the Windows mixer keeps an app's session after its sound stops: an app that
/// played once stays in the popover, silent, until it quits, so its volume can be set before it plays again. An app
/// that only connected to the sound server, as Finder always does, never shows unless it plays.
///
/// Lives in the agent while the mixer is on. It hears clients come and go and start or stop playing, and does nothing
/// in between: no timer, and an app is looked up only as it starts to play.
final class AudioSessions {
    private let systemListener = AudioListener()
    private var clientListener = AudioListener()
    private var listened: Set<AudioObjectID> = []
    /// Each app heard, by bundle ID, with the process it plays for, which tells when it has quit.
    private(set) var heard: [String: pid_t] = [:]

    init() {
        systemListener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyProcessObjectList]) {
            [weak self] in self?.clientsChanged()
        }
        // Everything is new to a sound server that started again.
        systemListener.listen(to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]) {
            [weak self] in
            guard let self else { return }
            clientListener.stop()
            clientListener = AudioListener()
            listened = []
            clientsChanged()
        }
        clientsChanged()
    }

    func stop() {
        systemListener.stop()
        clientListener.stop()
        listened = []
    }

    var heardApps: Set<String> { Set(heard.keys) }

    private func clientsChanged() {
        let clients = AudioSystem.clients()
        // An app that quit ends its session, as on Windows.
        heard = heard.filter { _, pid in kill(pid, 0) == 0 || errno != ESRCH }
        for client in clients where client.isPlaying { note(client) }
        let objects = Set(clients.map(\.objectID))
        guard objects != listened else { return }
        clientListener.stop()
        clientListener = AudioListener()
        for object in objects {
            clientListener.listen(to: object, [kAudioProcessPropertyIsRunningOutput]) { [weak self] in
                self?.playingChanged(object)
            }
        }
        listened = objects
    }

    private func playingChanged(_ object: AudioObjectID) {
        guard let client = AudioSystem.clients().first(where: { $0.objectID == object }), client.isPlaying else {
            return
        }
        note(client)
    }

    private func note(_ client: AudioClient) {
        guard let owner = AudioSystem.owner(of: client), heard[owner.bundleID] == nil else { return }
        heard[owner.bundleID] = owner.pid
    }
}
