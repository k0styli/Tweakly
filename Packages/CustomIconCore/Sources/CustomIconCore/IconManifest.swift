import Foundation

/// What the library keeps about an icon next to its frames.
public struct IconManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var frameCount: Int
    /// In pixels, at `IconFit.pixelsPerPoint`.
    public var frameWidth: Int
    public var frameHeight: Int
    /// How long one round takes at normal speed.
    public var cycleSeconds: Double
    public var hasColours: Bool
    public var added: Date

    public init(
        id: String, name: String, frameCount: Int, frameWidth: Int, frameHeight: Int, cycleSeconds: Double,
        hasColours: Bool, added: Date
    ) {
        self.id = id
        self.name = name
        self.frameCount = frameCount
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.cycleSeconds = cycleSeconds
        self.hasColours = hasColours
        self.added = added
    }

    public var isAnimated: Bool { frameCount > 1 }

    /// A file that was changed by hand or left half-written must not get as far as being drawn.
    public var isValid: Bool {
        frameCount >= 1 && frameCount <= IconFit.largestFrameCount
            && frameWidth >= 1 && frameWidth <= IconFit.largestPointWidth * IconFit.pixelsPerPoint
            && frameHeight >= 1 && frameHeight <= IconFit.pointHeight * IconFit.pixelsPerPoint
            && cycleSeconds > 0 && cycleSeconds.isFinite
    }
}
