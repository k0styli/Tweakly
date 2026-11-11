import AppKit
import LiveWallpaperCore
import os

/// The agent's side of live wallpapers. It sets each display's desktop picture, a picture from the library or the
/// still frame of a video, and keeps the process that plays videos running while some connected display has one.
/// Between changes it holds one observer of the displays and a process handle, and no timer.
final class LiveWallpaperTweak {
    /// Two unexpected exits this close together mean something is wrong with the video or the system, not bad luck.
    private static let crashWindow: TimeInterval = 300
    private static let restartDelay: TimeInterval = 2
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    private var assignments = DisplayAssignments()
    private var playbackSize = PlaybackSize.display
    private var process: Process?
    private var lastUnexpectedExit: Date?
    private var pendingRestart: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// Called when the tweak has turned itself off, so the agent reloads its settings.
    var onStopped: (() -> Void)?

    func update(assignments newAssignments: DisplayAssignments, playbackSize newSize: PlaybackSize) {
        assignments = newAssignments
        playbackSize = newSize
        observeScreens()
        let screens = WallpaperFolder.screens
        showPictures(on: screens)
        if assignments.hasVideo(forDisplays: screens.compactMap(WallpaperFolder.key(of:))) {
            startProcess()
        } else {
            stopProcess()
        }
    }

    /// Each display's desktop picture: the wallpaper, or the still of its video. The system keeps one for each Space and
    /// sets the one in front, so this runs again as Spaces change; it does nothing where the picture is already there.
    private func showPictures(on screens: [NSScreen]) {
        // The sizes the pictures were found to have, for the copy each display shows.
        let entries = WallpaperFolder.readIndex().entries
        for screen in screens {
            guard let key = WallpaperFolder.key(of: screen) else { continue }
            let choice = assignments.choice(forDisplay: key)
            let size = choice.flatMap { entries[$0.wallpaperID] }.flatMap {
                WallpaperSizing.size(
                    of: $0.pixelSize, setting: playbackSize, panel: WallpaperFolder.panelSize(of: screen))
            }
            DesktopPicture.show(choice, on: screen, size: size)
        }
    }

    /// Leaves nothing running and gives every display its own picture back, so the object can be released.
    func stop() {
        stopProcess()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        DesktopPicture.restoreAll(on: WallpaperFolder.screens)
    }

    /// A display that comes or goes may need a picture, the player or neither. The process that plays follows the
    /// displays on its own.
    private func observeScreens() {
        if spaceObserver == nil {
            // Without the still on every Space, the menu bar there takes its colour from a picture not on show.
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPictures(on: WallpaperFolder.screens) }
            }
        }
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(assignments: self.assignments, playbackSize: self.playbackSize)
            }
        }
    }

    private func stopProcess() {
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private func startProcess() {
        guard process == nil, pendingRestart == nil, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [WallpaperProcess.flag]
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
            Self.log.error("Could not start the wallpaper process: \(error.localizedDescription, privacy: .public)")
            turnOff(because: .stoppedUnexpectedly)
        }
    }

    private func ended(_ ended: Process, status: Int32, reason: Process.TerminationReason) {
        // A process this object let go of, or one that left because the tweak went off, is no surprise.
        let wasCurrent = ended === process
        if wasCurrent { process = nil }
        guard wasCurrent, !(reason == .exit && status == 0) else { return }
        Self.log.error("Wallpaper process ended unexpectedly: \(status, privacy: .public)")
        let now = Date.now
        if let last = lastUnexpectedExit, now.timeIntervalSince(last) < Self.crashWindow {
            turnOff(because: .stoppedUnexpectedly)
            return
        }
        lastUnexpectedExit = now
        let restart = DispatchWorkItem { [weak self] in
            self?.pendingRestart = nil
            self?.startProcess()
        }
        pendingRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: restart)
    }

    private func turnOff(because reason: LiveWallpaperStopReason) {
        AppSettings.stopLiveWallpaper(because: reason)
        ProcessEvents.post(.liveWallpaperStopped)
        onStopped?()
    }
}
