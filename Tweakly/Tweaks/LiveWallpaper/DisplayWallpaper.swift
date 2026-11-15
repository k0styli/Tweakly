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
    /// How the video goes from its end back to its start.
    private(set) var transition: LoopTransition

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
    /// Black over the video for Fade to Black, hidden and empty otherwise, so it costs nothing between loops.
    private let blackLayer = CALayer()
    private var loopObserver: Any?
    private var videoLength: CMTime = .invalid
    /// Whether a transition is on screen, so that a second one never starts over it.
    private var isInTransition = false
    #if TWEAKLY_AUTOMATION
        /// How many transitions have run, for a test to see that they do.
        private(set) var transitionsShown = 0
    #endif

    init(
        key: String, screen: NSScreen, choice: WallpaperChoice, title: String, isEconomy: Bool, size: PixelSize?,
        transition: LoopTransition
    ) {
        self.key = key
        self.choice = choice
        self.title = title
        self.isEconomy = isEconomy
        self.size = size
        self.transition = transition
        window = WallpaperWindow(frame: screen.frame)
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        // The blur transition is a Core Image filter on a layer, which AppKit draws only when told it may.
        host.layerUsesCoreImageFilters = true
        playerLayer.frame = root.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(playerLayer)
        blackLayer.frame = root.bounds
        blackLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        blackLayer.backgroundColor = NSColor.black.cgColor
        blackLayer.opacity = 0
        blackLayer.isHidden = true
        // Only the transitions below change these, by animations of their own; nothing may fade or slide by itself.
        let still: [String: any CAAction] = [
            "hidden": NSNull(), "opacity": NSNull(), "filters": NSNull(), "mask": NSNull(), "transform": NSNull(),
        ]
        blackLayer.actions = still
        playerLayer.actions = still
        root.addSublayer(blackLayer)
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
        var isShowingTransition: Bool { isInTransition }
        var desktopPictureName: String {
            window.screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0)?.lastPathComponent } ?? ""
        }
    #endif

    /// Follows a display that moved or changed its size.
    func place(on screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
    }

    /// Another video, the same one with another fit, economy mode turned on or off, another size, or a copy made.
    func update(
        choice newChoice: WallpaperChoice, title newTitle: String, isEconomy newEconomy: Bool, size newSize: PixelSize?,
        transition newTransition: LoopTransition
    ) {
        title = newTitle
        let isNewVideo = newChoice.fileName != choice.fileName
        choice = newChoice
        isEconomy = newEconomy
        size = newSize
        if newTransition != transition {
            transition = newTransition
            observeLoop()
        }
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
                let video = try await Self.videoOnlyItem(for: url)
                guard let self, !Task.isCancelled, self.loadingAttempt == attempt, self.choice.fileName == fileName
                else { return }
                self.loading = nil
                self.videoLength = video.length
                self.makePlayer(with: video.item)
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
    private static func videoOnlyItem(for url: URL) async throws -> (item: AVPlayerItem, length: CMTime) {
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
        return (AVPlayerItem(asset: composition), duration)
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
        observeLoop()
        // The mode may have changed while the file loaded.
        if mode.isPlaying { player.play() }
    }

    // MARK: From the end back to the start

    /// Watches for the end of each loop: once a loop, as long before the end as the transition takes. The looper plays
    /// copies of the same item, and the time is the item's own, so one boundary serves every loop.
    private func observeLoop() {
        if let loopObserver { player?.removeTimeObserver(loopObserver) }
        loopObserver = nil
        guard let player, transition != .none, videoLength.isValid, videoLength.seconds > 0 else { return }
        let length = transition.length(forVideoOf: videoLength.seconds)
        let lead = transition.lead(forLength: length)
        let time = CMTime(seconds: max(videoLength.seconds - lead, 0), preferredTimescale: 600)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) {
            [weak self] in
            MainActor.assumeIsolated { self?.loopIsEnding(length: length) }
        }
    }

    /// How long the video stays given way once the loop has come, which covers the boundary arriving a little late.
    private static let hold = 0.12
    /// How long it takes to come back over its first frame, a few frames into the loop by then.
    private static let restore = 0.2

    /// Starts the whole transition at once, on the render server's clock, so nothing here wakes until it is over.
    ///
    /// Every transition but Fade to Black gives the video way to its first frame: the agent made that frame the desktop
    /// picture, placed as the video is, and the window is clear wherever the video is not. At the loop the video goes
    /// on from that very frame, so taking nothing from the decoder, it ends with no jump at all.
    private func loopIsEnding(length: Double) {
        guard player != nil, mode.isPlaying, !isInTransition else { return }
        var kind = transition.respectingReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard kind != .none else { return }
        // Giving way to a picture that is not this video's first frame would show something else entirely, which black
        // never does.
        if kind.revealsFirstFrame, !isFirstFrameUnder { kind = .fadeToBlack }
        isInTransition = true
        #if TWEAKLY_AUTOMATION
            transitionsShown += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.endTransition() }
        }
        let begin = CACurrentMediaTime()
        if kind == .fadeToBlack {
            blackLayer.isHidden = false
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0, 1, 0]
            blink.keyTimes = [0, 0.5, 1]
            blink.timingFunctions = [Self.ease, Self.ease]
            add(blink, to: blackLayer, at: begin, for: length)
        } else {
            reveal(kind, length: length, from: begin)
        }
        CATransaction.commit()
    }

    private static let ease = CAMediaTimingFunction(name: .easeInEaseOut)

    /// Whether the desktop picture under the window is this video's first frame, or the copy of it made for this
    /// display, as the agent sets it. It may not be yet, or the system may show another one on this Space.
    var isFirstFrameUnder: Bool {
        guard let screen = window.screen, let still = choice.stillName, let folder = WallpaperFolder.files,
            let shown = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return false }
        let stem = (still as NSString).deletingPathExtension
        return shown.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
            && shown.lastPathComponent.hasPrefix(stem)
    }

    /// The video goes over `length` seconds, holds a moment past the loop, and comes back.
    private func reveal(_ kind: LoopTransition, length: Double, from begin: CFTimeInterval) {
        let total = length + Self.hold + Self.restore
        let gone = length / total
        let back = (length + Self.hold) / total
        // Just after `back`: what changes with the video in place may jump, as nothing of it shows.
        let jump = min(back + 0.001, 1)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        // A wipe uncovers the frame with its mask, and turns the video off only once the mask has passed.
        opacity.values = kind == .wipe ? [1, 1, 0, 0, 1] : [1, 0, 0, 1]
        opacity.keyTimes = (kind == .wipe ? [0, gone - 0.001, gone, back, 1] : [0, gone, back, 1]).map {
            NSNumber(value: $0)
        }
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        opacity.timingFunctions =
            kind == .wipe ? [Self.linear, Self.linear, Self.linear, easeOut] : [Self.ease, Self.linear, easeOut]
        add(opacity, to: playerLayer, at: begin, for: total)
        switch kind {
        case .blur:
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.name = "blur"
            blur?.setValue(0, forKey: kCIInputRadiusKey)
            playerLayer.filters = blur.map { [$0] }
            let radius = CAKeyframeAnimation(keyPath: "filters.blur.inputRadius")
            radius.values = [0, Self.blurRadius, Self.blurRadius, 0, 0]
            radius.keyTimes = [0, gone, back, jump, 1].map { NSNumber(value: $0) }
            radius.timingFunctions = [Self.ease, Self.linear, Self.linear, Self.linear]
            add(radius, to: playerLayer, at: begin, for: total, key: Self.effectKey)
        case .zoom:
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [1, Self.zoomScale, Self.zoomScale, 1, 1]
            grow.keyTimes = [0, gone, back, jump, 1].map { NSNumber(value: $0) }
            grow.timingFunctions = [Self.ease, Self.linear, Self.linear, Self.linear]
            add(grow, to: playerLayer, at: begin, for: total, key: Self.effectKey)
        case .wipe:
            // Clear where the first frame shows, from the left, under a soft edge a fifth of the width wide.
            let mask = CAGradientLayer()
            mask.frame = playerLayer.bounds
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            mask.locations = [-0.2, 0]
            mask.actions = ["locations": NSNull(), "bounds": NSNull(), "position": NSNull()]
            playerLayer.mask = mask
            let sweep = CAKeyframeAnimation(keyPath: "locations")
            sweep.values = [[-0.2, 0], [1, 1.2], [1, 1.2], [-0.2, 0], [-0.2, 0]]
            sweep.keyTimes = [0, gone, back, jump, 1].map { NSNumber(value: $0) }
            sweep.timingFunctions = [Self.ease, Self.linear, Self.linear, Self.linear]
            add(sweep, to: mask, at: begin, for: total)
        case .none, .dissolve, .fadeToBlack:
            break
        }
    }

    private static let linear = CAMediaTimingFunction(name: .linear)
    /// Points, at the layer's scale: enough to lose every edge, little enough to stay a picture.
    private static let blurRadius = 30.0
    private static let zoomScale = 1.08

    /// The fade has one key and what goes with it another, or the second would take the first's place.
    private static let fadeKey = "loop"
    private static let effectKey = "loop.effect"

    private func add(
        _ animation: CAAnimation, to layer: CALayer, at begin: CFTimeInterval, for duration: Double,
        key: String = fadeKey
    ) {
        animation.beginTime = layer.convertTime(begin, from: nil)
        animation.duration = duration
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }

    /// Leaves the video as it plays between loops, with nothing over it or in it that costs a thing.
    private func endTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.removeAnimation(forKey: Self.fadeKey)
        playerLayer.removeAnimation(forKey: Self.effectKey)
        playerLayer.mask?.removeAllAnimations()
        playerLayer.mask = nil
        playerLayer.filters = nil
        blackLayer.removeAnimation(forKey: Self.fadeKey)
        blackLayer.isHidden = true
        CATransaction.commit()
        isInTransition = false
    }

    private func releasePlayer() {
        loading?.cancel()
        loading = nil
        loadingAttempt = nil
        playingName = nil
        observations = []
        if let loopObserver { player?.removeTimeObserver(loopObserver) }
        loopObserver = nil
        endTransition()
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
