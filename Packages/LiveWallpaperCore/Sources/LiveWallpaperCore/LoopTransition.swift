/// How a video goes from its end back to its start, to soften the jump in one that does not loop smoothly. None by
/// default: a video made to loop needs nothing.
///
/// Every transition but Fade to Black gives the video way to its own first frame, which the agent makes the desktop
/// picture under it, placed as the video is. At the loop the video goes on from that very frame, so it ends with no
/// jump, and nothing more is decoded or kept: a second player crossing over would decode both ends at once, and the
/// system's decoder is what a wallpaper costs most, about 280 MB for 4K at 60 frames a second. Taking the last frame
/// from the player instead meant stopping it for a moment, which rebuilt its video pipeline at every loop, or an output
/// on every frame, which more than doubled the wakeups.
public enum LoopTransition: String, Codable, CaseIterable, Sendable {
    case none
    /// The end fades into the first frame.
    case dissolve
    /// The end blurs as it fades, which hides a jump in detail as well as in position.
    case blur
    /// The end grows a little as it fades, which reads as moving on rather than as a cut.
    case zoom
    /// The first frame is uncovered from left to right under a soft edge.
    case wipe
    /// The end darkens to black and the start comes up out of it, which hides any jump at the cost of a blink.
    case fadeToBlack

    /// Seconds a transition takes when the video is long enough for it.
    public var nominalLength: Double {
        switch self {
        case .none: 0
        case .dissolve, .wipe: 1.2
        case .blur, .zoom, .fadeToBlack: 1.4
        }
    }

    /// The length for a video of `seconds`: never more than a third of it, so a short loop is not mostly transition.
    public func length(forVideoOf seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(nominalLength, seconds / 3)
    }

    /// Seconds before the end it starts: all of it for one that reaches the first frame at the loop, half for Fade to
    /// Black, which is darkest at the loop.
    public func lead(forLength length: Double) -> Double {
        self == .fadeToBlack ? length / 2 : length
    }

    /// Whether the video gives way to its first frame, rather than to black.
    public var revealsFirstFrame: Bool { self != .none && self != .fadeToBlack }

    /// Whether it moves the picture, which Reduce Motion asks to replace with a plain dissolve.
    public var moves: Bool { self == .zoom || self == .wipe }

    /// What plays when the person has asked for less motion.
    public func respectingReducedMotion(_ reduceMotion: Bool) -> LoopTransition {
        reduceMotion && moves ? .dissolve : self
    }
}
