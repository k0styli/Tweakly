import AppKit
import AudioMixerCore
import CoreAudio
import notify
import os

/// The process that plays apps' sound at their own volume and output. The agent starts it while any app has a rule of
/// its own, and it lives no longer than the agent. Its audio thread wakes about a hundred times a second while an app
/// with a rule plays, which the agent, at one wakeup a second, must not pay for; and a fault in audio code here leaves
/// the menu bar alone. Apps without a rule, or not playing, cost it nothing.
enum AudioProcess {
    static let flag = "--audio"

    static var isAudioProcess: Bool { ProcessInfo.processInfo.arguments.contains(flag) }
}

final class AudioAppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer")

    private let engine = TapEngine()
    private let systemListener = AudioListener()
    private var clientListener = AudioListener()
    private var listenedClients: Set<AudioObjectID> = []
    private var rules = AudioRuleBook()
    /// Core Audio's clients as apps, and the outputs, read again only when they change: a slider moved in the popover
    /// changes the rules many times a second, and that needs no new look at every process playing sound.
    private var sound: (apps: [MixerApp], systemOutput: String?, connected: Set<String>)?
    /// When each app with a rule was last heard, for `TapPlan.linger`, and which of them played at the last look.
    private var lastPlayed: [String: Date] = [:]
    private var wasPlaying: Set<String> = []
    /// While the system refuses the recording, a moved slider tries again, at most this often: right after someone
    /// allows it the slider should work, and while refused each try silences the app for a moment.
    private static let refusedRetryInterval: TimeInterval = 5
    private var lastRefusedRetry = Date.distantPast
    /// When the running taps were last asked whether they may still be read, at most once a refusal interval.
    private var lastPermissionCheck = Date.distantPast
    private var permissionToken: Int32 = NOTIFY_TOKEN_INVALID
    private var linger: DispatchWorkItem?
    /// Apps whose rule went a moment ago, see `TapPlan.releaseHold`, and when.
    private var released: [String: Date] = [:]
    private var releaseEnd: DispatchWorkItem?
    private var eventTokens: [Int32] = []
    private var parentWatch: DispatchSourceProcess?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchParent()
        eventTokens = [
            ProcessEvents.observe(.quitAll) { NSApp.terminate(nil) },
            ProcessEvents.observe(.audioRulesChanged) { [weak self] in self?.reload() },
        ]
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject),
            [
                kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDevices,
            ]
        ) { [weak self] in self?.evaluate(readingClients: true) }
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]
        ) { [weak self] in self?.restartedSoundServer() }
        // tccd announces any change of a privacy permission. System Audio Recording taken away leaves the running taps
        // reading silence while they keep their apps muted, and given back lets what was refused run.
        notify_register_dispatch("com.apple.tcc.access.changed", &permissionToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionsChanged() }
        }
        #if TWEAKLY_AUTOMATION
            listenForStateRequests()
        #endif
        reload()
    }

    private func permissionsChanged() {
        lastPermissionCheck = .now
        engine.checkPermission()
        engine.retryFailed()
        evaluate(readingClients: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// The agent alone decides when this process goes, once the rules have been empty for a moment: a slider passing
    /// through 100 % empties them for an instant. Started with none at all, there is nothing to wait for.
    private func reload() {
        let isFirst = sound == nil
        let ruledBefore = Set(rules.rules.keys)
        rules = AudioRuleStore.load()
        if rules.rules.isEmpty, isFirst {
            NSApp.terminate(nil)
            return
        }
        // An app given its first rule, or one given back, is a moment to try again what could not run, perhaps right
        // after someone allowed the recording; a slider moving is not. Whether the new app plays is looked at afresh,
        // as it was not listened to.
        let ruledChanged = Set(rules.rules.keys) != ruledBefore
        let now = Date.now
        for id in ruledBefore.subtracting(rules.rules.keys) { released[id] = now }
        for id in rules.rules.keys { released[id] = nil }
        if ruledChanged {
            engine.retryFailed()
        } else if !engine.isPermitted, Date.now.timeIntervalSince(lastRefusedRetry) >= Self.refusedRetryInterval {
            lastRefusedRetry = .now
            engine.retryFailed()
        } else if engine.isPermitted, now.timeIntervalSince(lastPermissionCheck) >= Self.refusedRetryInterval {
            // A slider moved on an app gone silent is someone noticing: ask again, in case tccd's notice was missed.
            lastPermissionCheck = now
            engine.checkPermission()
        }
        evaluate(readingClients: ruledChanged)
    }

    /// Every object is new after the sound server starts again, and its taps went with it.
    private func restartedSoundServer() {
        Self.log.notice("The sound server started again")
        engine.stop()
        engine.retryFailed()
        clientListener.stop()
        clientListener = AudioListener()
        listenedClients = []
        evaluate(readingClients: true)
    }

    /// Works out which apps to take, from who plays now and the rules, and runs that. Called on every change of the
    /// clients, the outputs and the rules, and once more when a quiet app's tap is due to go.
    private func evaluate(readingClients: Bool) {
        if readingClients || sound == nil {
            let before = sound?.connected
            sound = (
                AudioAppGrouping.apps(clients: AudioSystem.clients(), owner: AudioSystem.owner(of:)),
                AudioSystem.defaultDevice(input: false).flatMap(AudioSystem.uid(of:)),
                // Our own private devices come and go with every group built, and are no output to play on.
                Set(AudioSystem.devices(input: false).map(\.uid).filter { !$0.hasPrefix(TapEngine.deviceUIDPrefix) })
            )
            // An output that arrived, AirPods still coming up say, is worth trying again on.
            if let before, before != sound?.connected { engine.retryFailed() }
        }
        guard let sound else { return }
        let apps = sound.apps
        listenToPlaying(of: apps)
        let now = Date.now
        // Only apps with a rule are ever taken, so only their silence is worth a wakeup when it lasts.
        let playing = Set(apps.filter { $0.isPlaying && !rules.rule(for: $0.id).isStandard }.map(\.id))
        if !playing.subtracting(wasPlaying).isEmpty {
            // An app starting to play is when a try that failed is worth making again, and when permission taken
            // away from the taps that run would show.
            engine.retryFailed()
            engine.checkPermission()
        }
        lastPlayed = TapPlan.heard(lastPlayed: lastPlayed, wasPlaying: wasPlaying, playing: playing, now: now)
        wasPlaying = playing
        let active = TapPlan.active(lastPlayed: lastPlayed, playing: playing, now: now)
        lastPlayed = lastPlayed.filter { active.contains($0.key) }
        released = released.filter { now.timeIntervalSince($0.value) < TapPlan.releaseHold }
        let groups = TapPlan.groups(
            apps: apps, rules: rules, active: active, systemOutputUID: sound.systemOutput,
            connectedOutputs: sound.connected, holding: Set(released.keys))
        engine.apply(groups)
        report()
        scheduleLinger(playing: playing, now: now)
        scheduleReleaseEnd(now: now)
    }

    /// One look more once the last hold is over, to let the app go if its rule is still gone.
    private func scheduleReleaseEnd(now: Date) {
        releaseEnd?.cancel()
        releaseEnd = nil
        guard let last = released.values.max() else { return }
        let delay = max(0.1, TapPlan.releaseHold - now.timeIntervalSince(last) + 0.1)
        let work = DispatchWorkItem { [weak self] in self?.evaluate(readingClients: false) }
        releaseEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether each app with a rule plays is a property of its processes, heard as it changes, not asked for.
    private func listenToPlaying(of apps: [MixerApp]) {
        let ruled = Set(apps.filter { !rules.rule(for: $0.id).isStandard }.flatMap(\.objectIDs))
        guard ruled != listenedClients else { return }
        clientListener.stop()
        clientListener = AudioListener()
        for object in ruled {
            // Whether it plays, and where: a call app may move to a headset on its own.
            clientListener.listen(to: object, [kAudioProcessPropertyIsRunningOutput]) { [weak self] in
                self?.evaluate(readingClients: true)
            }
            clientListener.listen(
                to: object, [kAudioProcessPropertyDevices], scope: kAudioObjectPropertyScopeOutput
            ) { [weak self] in self?.evaluate(readingClients: true) }
        }
        listenedClients = ruled
    }

    /// One wakeup, when the soonest quiet app's tap is due to go: no timer runs while nothing changes.
    private func scheduleLinger(playing: Set<String>, now: Date) {
        linger?.cancel()
        linger = nil
        let quiet = lastPlayed.filter { !playing.contains($0.key) }.values
        guard let soonest = quiet.min() else { return }
        let delay = max(1, TapPlan.linger - now.timeIntervalSince(soonest) + 0.5)
        let work = DispatchWorkItem { [weak self] in self?.evaluate(readingClients: true) }
        linger = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Tells the agent and the window when the system refuses the apps' sound, so they can say so.
    private func report() {
        let defaults = UserDefaults.standard
        let refused = !engine.isPermitted
        guard defaults.bool(forKey: AudioRuleStore.notPermittedKey) != refused else { return }
        defaults.set(refused, forKey: AudioRuleStore.notPermittedKey)
        defaults.synchronize()
        ProcessEvents.post(.volumeMixerStateChanged)
    }

    private func watchParent() {
        let parent = getppid()
        guard parent > 1 else {
            NSApp.terminate(nil)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        parentWatch = source
        // The agent may have gone between the question and the watch, which would then never fire: a new agent would
        // start a second of these, and the apps would play twice.
        if getppid() != parent { NSApp.terminate(nil) }
    }

    #if TWEAKLY_AUTOMATION
        /// Writes what is taken when asked, for tests: notify `<automation name>.audio` and read
        /// `/tmp/tweakly-audio-state[-<channel>].json`.
        private func listenForStateRequests() {
            let channel = UserDefaults.standard.string(forKey: "automationChannel")
            let name = "me.tweakly.Tweakly.automation" + (channel.map { ".\($0)" } ?? "") + ".audio"
            let path = "/tmp/tweakly-audio-state" + (channel.map { "-\($0)" } ?? "") + ".json"
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let object: [String: Any] = [
                        "groups": self.engine.state, "permitted": self.engine.isPermitted,
                        "rules": self.rules.rules.keys.sorted(), "active": self.lastPlayed.keys.sorted(),
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    #endif
}
