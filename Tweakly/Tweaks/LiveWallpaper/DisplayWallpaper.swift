import AVFoundation
import AppKit
import LiveWallpaperCore
import os

/// A borderless window over one display's desktop picture and under its icons, on every Space, that never takes a click
/// or the keyboard. Mission Control leaves it in place, as it does the desktop.
final class WallpaperWindow: NSWindow {
    /// One above the system's own wallpaper, which sits at the desktop level, so that the system ordering its window
    /// forward on a change of Space cannot cover this one. The icons are 20 levels higher.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The window covers the menu bar's strip too, as the desktop picture does.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One display's wallpaper: its window, and a player only while the video can be seen or about to be.
///
/// Whether the desktop can be seen is the video window's own: it covers the whole screen, menu bar strip included, so
/// under a zoomed window it is still seen behind the clear menu bar and the Dock, and goes on moving there. Only an app
/// in full screen, or windows over every bit of the screen, hide it. An empty window over the
/// visible frame paused the video under zoomed windows too, which was turned down.
///
/// A looping `AVQueuePlayer` decodes in the media engine. The audio never reaches it, as the player is given a
/// composition of the video track alone. While nothing is decoded, the window is clear and the system's desktop picture
/// shows through: the agent made it the video's first frame. A still layer of the window's own kept about 19 MB of
/// decoded picture for good, and 4 MB more each time the video changed (measured 2026-11-08).
final class DisplayWallpaper {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    let key: String
    private(set) var choice: WallpaperChoice
    private(set) var mode: PlaybackMode = .release(.hidden)
    var onVisibilityChange: (() -> Void)?
    var onFailure: ((DisplayWallpaper, LiveWallpaperStopReason) -> Void)?
    /// What the video is called, for a message if it cannot play.
    var title: String
    /// Whether economy mode is on, which plays the video's copy with fewer frames once it is made.
    private(set) var isEconomy: Bool
    /// The size this display shows the video at, nil for its own, which plays a smaller copy once it is made.
    private(set) var size: PixelSize?
    /// The file the player was made from: the video or one of its copies.
    private var playingName: String?

    private let window: WallpaperWindow
    /// Where the video was when its player was let go, to go on from there.
    private var resumeAt: CMTime?
    private let host = NSView()
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loading: Task<Void, Never>?
    /// Which load `loading` is, so that one cancelled or overtaken can tell.
    private var loadingAttempt: UUID?
    private var observations: [NSKeyValueObservation] = []
    private var occlusionObserver: NSObjectProtocol?

    init(
        key: String, screen: NSScreen, choice: WallpaperChoice, title: String, isEconomy: Bool, size: PixelSize?
    ) {
        self.key = key
        self.choice = choice
        self.title = title
        self.isEconomy = isEconomy
        self.size = size
        window = WallpaperWindow(frame: screen.frame)
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        playerLayer.frame = root.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(playerLayer)
        applyFit()
        window.contentView = host
        window.setFrame(screen.frame, display: false)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onVisibilityChange?() }
        }
        window.orderFrontRegardless()
    }

    var isVisible: Bool { window.occlusionState.contains(.visible) }

    #if TWEAKLY_AUTOMATION
        var hasPlayer: Bool { player != nil }
        var playingFile: String { playingName ?? "" }
        /// Where the video is in its loop, to check that it goes on from where it stopped.
        var playedSeconds: Double { player?.currentTime().seconds ?? resumeAt?.seconds ?? -1 }
    #endif

    /// Follows a display that moved or changed its size.
    func place(on screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
    }

    /// Another video, the same one with another fit, economy mode turned on or off, another size, or a copy made.
    func update(
        choice newChoice: WallpaperChoice, title newTitle: String, isEconomy newEconomy: Bool, size newSize: PixelSize?
    ) {
        title = newTitle
        let isNewVideo = newChoice.fileName != choice.fileName
        choice = newChoice
        isEconomy = newEconomy
        size = newSize
        applyFit()
        if isNewVideo {
            restart(from: nil)
        } else if player != nil || loading != nil, fileToPlay() != playingName {
            // A copy and the video last as long, so the switch goes on from the same moment.
            restart(from: player?.currentTime() ?? resumeAt)
        }
    }

    private func restart(from time: CMTime?) {
        let wasPlaying = mode
        let hadPlayer = player != nil || loading != nil
        releasePlayer()
        resumeAt = time
        mode = .release(.hidden)
        apply(wasPlaying)
        // A video paused in sight goes on showing the frame it stopped at, now from the new file, rather than the first
        // frame under it.
        if hadPlayer, case .pause = wasPlaying { startPlayer() }
    }

    /// The closest copy made for this display's size and economy mode, otherwise the video itself.
    private func fileToPlay() -> String {
        WallpaperVariant.fileToPlay(choice.fileName, size: size, economy: isEconomy) { name in
            WallpaperFolder.file(named: name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    func apply(_ newMode: PlaybackMode) {
        mode = newMode
        switch newMode {
        case .play:
            if player == nil {
                startPlayer()
            } else {
                player?.play()
            }
        case .pause:
            player?.pause()
        case .release:
            // A player still being made goes too, or it would appear and be kept through sleep.
            if let player { resumeAt = player.currentTime() }
            releasePlayer()
        }
    }

    func close() {
        loading?.cancel()
        releasePlayer()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    private func applyFit() {
        let gravity: AVLayerVideoGravity =
            switch choice.fit {
            case .fill: .resizeAspectFill
            case .fit: .resizeAspect
            case .stretch: .resize
            }
        playerLayer.videoGravity = gravity
    }

    private func startPlayer() {
        let name = fileToPlay()
        guard loading == nil, let url = WallpaperFolder.file(named: name) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(.fileMissing(title: title))
            return
        }
        let fileName = choice.fileName
        playingName = name
        let attempt = UUID()
        loadingAttempt = attempt
        loading = Task { [weak self] in
            do {
                let item = try await Self.videoOnlyItem(for: url)
                guard let self, !Task.isCancelled, self.loadingAttempt == attempt, self.choice.fileName == fileName
                else { return }
                self.loading = nil
                self.makePlayer(with: item)
            } catch {
                // A load that was cancelled, or overtaken by another, speaks for nothing: its file may have been
                // removed on purpose, and the newer one must not lose its handle or turn the tweak off.
                guard let self, !Task.isCancelled, self.loadingAttempt == attempt else { return }
                self.loading = nil
                Self.log.error(
                    "Cannot play \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.fail(.unplayable(title: self.title))
            }
        }
    }

    /// The video track alone, so no audio is ever decoded, and so a file with sound stays silent.
    private static func videoOnlyItem(for url: URL) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let (tracks, duration) = try await (asset.loadTracks(withMediaType: .video), asset.load(.duration))
        guard let track = tracks.first, duration.seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let transform = try await track.load(.preferredTransform)
        let composition = AVMutableComposition()
        guard
            let target = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        target.preferredTransform = transform
        return AVPlayerItem(asset: composition)
    }

    private func makePlayer(with item: AVPlayerItem) {
        let player = AVQueuePlayer()
        player.isMuted = true
        // By default a playing video keeps the display awake, which a wallpaper must never do.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .advance
        let looper = AVPlayerLooper(player: player, templateItem: item)
        observations = [
            looper.observe(\.status) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.looper === looper else { return }
                        Self.log.error("Looping failed: \(String(describing: looper.error), privacy: .public)")
                        self.fail(.unplayable(title: self.title))
                    }
                }
            }
        ]
        self.player = player
        self.looper = looper
        playerLayer.player = player
        if let resumeAt, resumeAt.isValid, resumeAt.seconds > 0 {
            player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        resumeAt = nil
        // The mode may have changed while the file loaded.
        if mode.isPlaying { player.play() }
    }

    private func releasePlayer() {
        loading?.cancel()
        loading = nil
        loadingAttempt = nil
        playingName = nil
        observations = []
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
    }

    private func fail(_ reason: LiveWallpaperStopReason) {
        releasePlayer()
        onFailure?(self, reason)
    }
}
