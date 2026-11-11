import AppKit
import AudioMixerCore
import AudioToolbox
import CoreAudio
import notify
import os

/// The agent's side of the volume mixer: its item in the menu bar, the popover, and the process that plays apps at
/// their own volume. While on and closed it holds the item and listens to the output's volume, mute and the choice of
/// output, which change only when someone changes them: no timer and no process unless an app has a rule of its own.
final class VolumeMixerTweak {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "volume-mixer")
    /// Two unexpected exits this close together mean something is wrong with the sound or the system, not bad luck.
    private static let crashWindow: TimeInterval = 300
    private static let restartDelay: TimeInterval = 2
    /// How long the rules stay empty before the process that plays goes: a slider passing through 100 % empties them
    /// for an instant, and starting the process again would be heard.
    private static let stopDelay: TimeInterval = 5

    private let statusMenu: AppStatusMenu
    private let item = MixerStatusItem()
    private let presenter = MixerPopoverPresenter()
    private let systemListener = AudioListener()
    private var outputListener = AudioListener()
    private var outputID: AudioObjectID?
    private var eventTokens: [Int32] = []
    private var process: Process?
    private var lastUnexpectedExit: Date?
    private var pendingRestart: DispatchWorkItem?
    private var pendingStop: DispatchWorkItem?
    private var hasGivenUp = false
    private var options = MixerOptions(showsInput: true, boosts: false)

    init(statusMenu: AppStatusMenu) {
        self.statusMenu = statusMenu
        presenter.options = { [weak self] in self?.options ?? MixerOptions(showsInput: true, boosts: false) }
        item.onOpen = { [weak self] in self.map { $0.presenter.show(for: $0.item) } }
        item.onToggle = { [weak self] in self.map { $0.presenter.toggle(for: $0.item) } }
        item.onDismiss = { [weak self] in self?.presenter.close() }
        item.onRightClick = { [weak self] event in self?.showMenu(for: event) }
        item.onScroll = { [weak self] steps in self?.scroll(by: steps) }
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject),
            [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
        ) { [weak self] in self?.followOutput() }
        // After the sound server starts again the output may keep its number, but the listeners on it are gone.
        systemListener.listen(
            to: AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyServiceRestarted]
        ) { [weak self] in
            self?.outputID = nil
            self?.followOutput()
        }
        // A new start: whatever stopped the process that plays before is worth another try.
        AudioRuleStore.setStopped(false)
        AudioRuleStore.forgetRefusal()
        eventTokens = [
            ProcessEvents.observe(.audioRulesChanged) { [weak self] in self?.syncProcess() }
        ]
        followOutput()
        syncProcess()
    }

    func update(showsInput: Bool, scrolls: Bool, boosts: Bool) {
        item.scrolls = scrolls
        options = MixerOptions(showsInput: showsInput, boosts: boosts)
        // The theme may be what changed.
        presenter.updateAppearance()
        // With boosting off, nothing plays louder than the app itself any more.
        var rules = AudioRuleStore.load()
        let before = rules
        rules.limit(boosting: boosts)
        if rules != before { AudioRuleStore.save(rules) }
    }

    /// Leaves nothing behind: the item, the listeners and the process that plays, whose taps go with it.
    func stop() {
        presenter.close()
        item.remove()
        systemListener.stop()
        outputListener.stop()
        for token in eventTokens { notify_cancel(token) }
        eventTokens = []
        stopProcess()
    }

    // MARK: The item

    /// The output in use now, and its volume and mute, heard as they change, the keys included.
    private func followOutput() {
        let id = AudioSystem.defaultDevice(input: false)
        if id != outputID {
            outputID = id
            outputListener.stop()
            outputListener = AudioListener()
            if let id {
                outputListener.listen(
                    to: id, [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute],
                    scope: kAudioObjectPropertyScopeOutput
                ) { [weak self] in self?.showVolume() }
            }
        }
        showVolume()
    }

    private func showVolume() {
        guard let id = outputID else {
            item.show(volume: nil, isMuted: false, outputName: nil)
            return
        }
        item.show(
            volume: AudioSystem.volume(of: id, input: false) ?? 1,
            isMuted: AudioSystem.isMuted(id, input: false) ?? false,
            outputName: AudioSystem.string(id, kAudioObjectPropertyName))
    }

    private func scroll(by steps: Int) {
        guard let id = outputID, AudioSystem.canSetVolume(of: id, input: false) else { return }
        let volume = AudioSystem.volume(of: id, input: false) ?? 0
        AudioSystem.setVolume(VolumeLevel.stepped(volume, by: steps), of: id, input: false)
    }

    private func showMenu(for event: NSEvent) {
        guard let button = item.button else { return }
        presenter.close()
        let menu = NSMenu()
        statusMenu.fill(menu, offersSoundSettings: true)
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    #if TWEAKLY_AUTOMATION
        func openPopover() { presenter.show(for: item) }
        func closePopover() { presenter.close() }
    #endif

    // MARK: The process that plays

    /// Runs while any app has a rule of its own. It decides by itself which of them to take and when.
    private func syncProcess() {
        guard !hasGivenUp else { return }
        if !AudioRuleStore.load().rules.isEmpty {
            pendingStop?.cancel()
            pendingStop = nil
            startProcess()
        } else if process != nil, pendingStop == nil {
            let stop = DispatchWorkItem { [weak self] in
                self?.pendingStop = nil
                if AudioRuleStore.load().rules.isEmpty { self?.stopProcess() }
            }
            pendingStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDelay, execute: stop)
        }
    }

    private func startProcess() {
        guard process == nil, pendingRestart == nil, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [AudioProcess.flag]
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            let reason = ended.terminationReason
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ended(ended, status: status, reason: reason) }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            Self.log.error("Could not start the audio process: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopProcess() {
        pendingRestart?.cancel()
        pendingRestart = nil
        pendingStop?.cancel()
        pendingStop = nil
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
        AudioRuleStore.forgetRefusal()
    }

    private func ended(_ ended: Process, status: Int32, reason: Process.TerminationReason) {
        let wasCurrent = ended === process
        if wasCurrent { process = nil }
        // A process let go of on purpose is no longer `process`, so its end is no surprise.
        guard wasCurrent else { return }
        guard !(reason == .exit && status == 0) else {
            // It left by itself, having found no rules as it started; a rule written meanwhile still needs it.
            scheduleRestart()
            return
        }
        Self.log.error("Audio process ended unexpectedly: \(status, privacy: .public)")
        let now = Date.now
        if let last = lastUnexpectedExit, now.timeIntervalSince(last) < Self.crashWindow {
            // Every app plays at its own volume again, as its taps went with the process; the rest of the mixer goes on,
            // and the popover and the page say why the apps' own volumes do nothing.
            hasGivenUp = true
            AudioRuleStore.setStopped(true)
            return
        }
        lastUnexpectedExit = now
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard pendingRestart == nil else { return }
        let restart = DispatchWorkItem { [weak self] in
            self?.pendingRestart = nil
            self?.syncProcess()
        }
        pendingRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: restart)
    }
}
