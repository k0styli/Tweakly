import AppKit
import WindowSwitcherCore
import notify
import os

/// The pictures of windows that Command-Tab and the Dock's previews share, so a window taken for one shows at once in
/// the other and is not taken twice. It exists while either is on.
///
/// Two kinds are kept, and `WindowPictureShelf` says which of them each event takes away. A sharp picture lives outside
/// this process, about 800 KB each, so it is kept for a minute after it was last of use and dropped on sleep and when
/// memory gets short. A compressed copy, about 50 KB, stays for as long as its window does, so any tile can show
/// something from its first frame. Only critical pressure on memory takes the copies too.
///
/// A window already being taken is not taken again: whoever asks for it too is handed the same picture when it comes.
final class WindowPictureStore {
    private typealias Shelf = WindowPictureShelf<SwitcherPicture, SwitcherKeptPicture>
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "pictures")

    /// Read at each capture, so a change shows from the next one. Owned by the switcher's settings.
    var tuning = SwitcherTuning() {
        didSet {
            if !tuning.savesCompressedPictures { shelf.forgetKept() }
        }
    }

    /// Whether Screen Recording is allowed. Asking takes 12 to 37 ms on macOS 27.2, every time, which a panel that must
    /// appear with the Dock's own bubble cannot wait for. So it is asked when the store starts, when tccd announces that
    /// some permission changed, and on `refreshPermission`, which follows every change of settings. Taken away in
    /// between, captures just give nothing and the tiles keep their icons.
    private(set) var mayCapture = CGPreflightScreenCaptureAccess()

    private var shelf = Shelf()
    var sharp: [CGWindowID: SwitcherPicture] { shelf.sharp }
    var kept: [CGWindowID: SwitcherKeptPicture] { shelf.kept }

    /// One capture of one or more windows, and who waits for each of them.
    private final class Batch {
        var task: Task<Void, Never>?
        var windows: Set<CGWindowID>
        /// What had been forgotten when it began: what was forgotten since is not put back by what it brings.
        let era: Shelf.Era
        init(windows: Set<CGWindowID>, era: Shelf.Era) {
            self.windows = windows
            self.era = era
        }
    }

    /// One caller's interest in a set of windows, given back to cancel it.
    final class Request {
        fileprivate let windows: Set<CGWindowID>
        fileprivate init(windows: Set<CGWindowID>) { self.windows = windows }
    }

    private var batches: [CGWindowID: Batch] = [:]
    private var waiting: [CGWindowID: [ObjectIdentifier: @MainActor (SwitcherPicture?) -> Void]] = [:]
    private var forgetSharp: DispatchWorkItem?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var sleepObserver: NSObjectProtocol?
    private var permissionToken: Int32 = NOTIFY_TOKEN_INVALID

    init() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.memoryIsShort(event.contains(.critical) ? .critical : .warning)
            }
        }
        pressure.resume()
        memoryPressure = pressure
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetSharpPictures() }
        }
        // Given or taken away in System Settings while the window is closed, which no page is there to report. tccd
        // posts this for every app's change of any privacy permission, which is rare.
        notify_register_dispatch("com.apple.tcc.access.changed", &permissionToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    /// Asked off the main thread: every change of settings on any page comes here, and the agent's main thread draws
    /// the menu bar and answers the Dock meanwhile.
    func refreshPermission() {
        Task.detached(priority: .utility) { [weak self] in
            let allowed = CGPreflightScreenCaptureAccess()
            await MainActor.run { self?.mayCapture = allowed }
        }
    }

    /// Leaves nothing running, so the object can be released.
    func stop() {
        forgetEverything()
        memoryPressure?.cancel()
        memoryPressure = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        if permissionToken != NOTIFY_TOKEN_INVALID { notify_cancel(permissionToken) }
        permissionToken = NOTIFY_TOKEN_INVALID
    }

    /// Takes these windows, except any already being taken, and hands each picture to `deliver` as it arrives, or nil
    /// for a window that gave none. Pass the result to `cancel` once the pictures are no longer wanted.
    func capture(
        _ requests: [WindowThumbnailer.Request], deliver: @escaping @MainActor (CGWindowID, SwitcherPicture?) -> Void
    ) -> Request {
        let request = Request(windows: Set(requests.map(\.window)))
        let key = ObjectIdentifier(request)
        var fresh: [WindowThumbnailer.Request] = []
        for item in requests {
            waiting[item.window, default: [:]][key] = { picture in deliver(item.window, picture) }
            if batches[item.window] == nil { fresh.append(item) }
        }
        guard !fresh.isEmpty else { return request }
        let batch = Batch(windows: Set(fresh.map(\.window)), era: shelf.era)
        for item in fresh { batches[item.window] = batch }
        batch.task = WindowThumbnailer.capture(
            fresh, atOnce: tuning.capturesAtOnce,
            keptQuality: tuning.savesCompressedPictures ? tuning.compressionQuality : nil
        ) { [weak self] id, picture in
            self?.arrived(picture, of: id, in: batch)
        }
        return request
    }

    /// The pictures still on their way to this request are not wanted any more. Those nobody else waits for are not
    /// taken, as far as a capture that has begun can be called off.
    func cancel(_ request: Request) {
        let key = ObjectIdentifier(request)
        for id in request.windows {
            waiting[id]?[key] = nil
            if waiting[id]?.isEmpty == true { waiting[id] = nil }
        }
        var abandoned: Set<ObjectIdentifier> = []
        for (id, batch) in batches where !abandoned.contains(ObjectIdentifier(batch)) {
            guard waiting[id] == nil, batch.windows.allSatisfy({ waiting[$0] == nil }) else { continue }
            abandoned.insert(ObjectIdentifier(batch))
            batch.task?.cancel()
        }
        batches = batches.filter { !abandoned.contains(ObjectIdentifier($0.value)) }
    }

    private func arrived(_ picture: SwitcherPicture?, of id: CGWindowID, in batch: Batch) {
        guard batches[id] === batch else { return }
        batches[id] = nil
        batch.windows.remove(id)
        // A capture that ends after pictures were forgotten for want of memory is handed to whoever waits for it but
        // does not put back what was forgotten.
        if let picture { shelf.store(picture, kept: picture.kept, of: id, takenIn: batch.era) }
        let callbacks = waiting.removeValue(forKey: id) ?? [:]
        for deliver in callbacks.values { deliver(picture) }
    }

    /// A panel that took pictures has closed: they stay sharp for the next one to open soon. One that took none leaves
    /// the time as it was, or someone switching often would keep old pictures for good.
    func panelClosed(tookPictures: Bool) {
        guard tookPictures else { return }
        forgetSharp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.forgetSharpPictures() }
        }
        forgetSharp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(tuning.keepSharpPicturesSeconds), execute: work)
    }

    /// Keeps only what belongs to windows that still exist. Asks the window server for the numbers of all windows, which
    /// costs a millisecond or two, once per panel.
    func forgetClosedWindows() {
        guard !shelf.sharp.isEmpty || !shelf.kept.isEmpty,
            let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as NSArray?
        else { return }
        var open: Set<CGWindowID> = []
        for case let info as NSDictionary in list {
            if let id = info[kCGWindowNumber] as? UInt32 { open.insert(id) }
        }
        shelf.keepOnly(open)
    }

    func forgetSharpPictures() {
        forgetSharp?.cancel()
        forgetSharp = nil
        shelf.forgetSharp()
    }

    /// For when the permission has gone or the previews were turned off. A person only loses a moment of tiles filling
    /// in.
    func forgetEverything() {
        forgetSharp?.cancel()
        forgetSharp = nil
        shelf.forgetEverything()
    }

    /// Said in the log, as a tile that opens empty is otherwise hard to explain. Which pictures go is the shelf's call.
    private func memoryIsShort(_ pressure: Shelf.MemoryPressure) {
        let sharpCount = shelf.sharp.count
        forgetSharp?.cancel()
        forgetSharp = nil
        shelf.memoryIsShort(pressure)
        let level = pressure == .critical ? "critical" : "warning"
        let keptCount = shelf.kept.count
        Self.log.notice(
            "Memory is short (\(level, privacy: .public)): forgot \(sharpCount) sharp pictures, kept \(keptCount)")
    }
}
