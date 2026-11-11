/// What the shared store of window pictures keeps, and which of it each event takes away. The capturing and the
/// system's notices stay with the store; this is only the bookkeeping, so it can be tested.
///
/// A sharp picture lives outside the process, about 800 KB each, and goes a minute after it was last of use, on sleep,
/// and as soon as memory gets short. A compressed copy, about 50 KB, stays for as long as its window does: it is what
/// a tile shows from its first frame, until the sharp picture replaces it. Only critical pressure takes the copies too.
public struct WindowPictureShelf<Sharp, Kept> {
    public enum MemoryPressure: Sendable {
        case warning
        case critical
    }

    /// When a capture began, as far as forgetting goes: a picture begun before something was forgotten for want of
    /// memory is not put back by its arrival.
    public struct Era: Equatable, Sendable {
        fileprivate var sharp = 0
        fileprivate var kept = 0
    }

    public private(set) var sharp: [UInt32: Sharp] = [:]
    public private(set) var kept: [UInt32: Kept] = [:]
    public private(set) var era = Era()

    public init() {}

    public mutating func store(_ picture: Sharp, kept copy: Kept?, of window: UInt32, takenIn era: Era) {
        if era.sharp == self.era.sharp { sharp[window] = picture }
        if let copy, era.kept == self.era.kept { kept[window] = copy }
    }

    /// Keeps only what belongs to these windows, which are all that still exist. A minimized window, a hidden one and
    /// one on another Space still exist.
    public mutating func keepOnly(_ open: Set<UInt32>) {
        sharp = sharp.filter { open.contains($0.key) }
        kept = kept.filter { open.contains($0.key) }
    }

    /// For the minute after a panel closed running out, and for sleep. The copies stay.
    public mutating func forgetSharp() {
        sharp = [:]
    }

    /// For the copies being turned off in Settings.
    public mutating func forgetKept() {
        kept = [:]
        era.kept += 1
    }

    /// For the permission going away: nothing taken with it should stay.
    public mutating func forgetEverything() {
        sharp = [:]
        kept = [:]
        era.sharp += 1
        era.kept += 1
    }

    /// On a Mac with 8 GB the system's warning reached a 30 MB process twice in nine minutes of work on macOS 27.2,
    /// and the sharp pictures are nearly all of what this holds. Taking the copies too on every warning emptied the
    /// tiles of anyone who had not pressed Command-Tab for a few minutes, and gave back a few megabytes at most.
    public mutating func memoryIsShort(_ pressure: MemoryPressure) {
        switch pressure {
        case .warning:
            sharp = [:]
            era.sharp += 1
        case .critical:
            forgetEverything()
        }
    }
}
