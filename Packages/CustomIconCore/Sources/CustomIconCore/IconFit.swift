/// Sizes in the menu bar, and how a picture of any size and shape comes to sit well among the system's icons.
public enum IconFit {
    /// The system's own icons there are about this tall.
    public static let pointHeight = 16
    /// Wide enough for a running animal or a car, and not so wide that it pushes other icons away.
    public static let largestPointWidth = 40
    /// Macs have no denser displays, and a less dense one gets a smooth reduction of this.
    public static let pixelsPerPoint = 2
    /// More frames than this cannot be told apart at this size, and each one takes memory.
    public static let largestFrameCount = 60
    /// A loop shorter than this flickers, and one longer than this does not read as movement in the corner of an eye.
    private static let cycleSeconds: ClosedRange<Double> = 0.2...10
    /// What a frame of a GIF with no delay of its own gets, as in web browsers.
    private static let usualFrameDelay = 0.1
    private static let shortestFrameDelay = 0.02
    private static let usualFramesPerSecond = 12.0

    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// The frame's size in pixels, so that a drawing of this shape gets as big as it can within the limits.
    public static func pixelSize(ofContentWidth width: Double, height: Double) -> Size {
        guard width > 0, height > 0 else {
            return Size(width: pointHeight * pixelsPerPoint, height: pointHeight * pixelsPerPoint)
        }
        let scale = min(
            Double(pointHeight * pixelsPerPoint) / height, Double(largestPointWidth * pixelsPerPoint) / width)
        return Size(width: max(Int((width * scale).rounded()), 1), height: max(Int((height * scale).rounded()), 1))
    }

    /// Which frames to keep of this many. A long animation loses frames evenly and keeps its pace.
    public static func keptFrames(of count: Int) -> [Int] {
        guard count > largestFrameCount else { return Array(0..<max(count, 0)) }
        return (0..<largestFrameCount).map { $0 * count / largestFrameCount }
    }

    /// The rate to ask the render server for, with as many frames a second as the fastest speed shows. Core Animation throws
    /// an exception at a range that does not hold its preferred rate, and nothing here could catch it, so a slow icon of a
    /// few frames must not fall below the range's lower end.
    public static func preferredFrameRate(
        frameCount: Int, cycleSeconds: Double, fastestSpeed: Double, within range: ClosedRange<Float>
    ) -> Float {
        let wanted = Float(Double(frameCount) / cycleSeconds * fastestSpeed)
        return wanted.isFinite ? min(max(wanted, range.lowerBound), range.upperBound) : range.upperBound
    }

    /// How long one round takes at normal speed, from the delays of a GIF or a similar file.
    public static func cycleSeconds(frameDelays: [Double]) -> Double {
        let total = frameDelays.reduce(0) { sum, delay in
            sum + (delay >= shortestFrameDelay ? delay : usualFrameDelay)
        }
        return min(max(total, cycleSeconds.lowerBound), cycleSeconds.upperBound)
    }

    /// How long one round takes at normal speed, from an SVG's frame rate if it gives one.
    public static func cycleSeconds(frameCount: Int, framesPerSecond: Double?) -> Double {
        let total = Double(max(frameCount, 1)) / (framesPerSecond ?? usualFramesPerSecond)
        return min(max(total, cycleSeconds.lowerBound), cycleSeconds.upperBound)
    }
}

/// A frame as 8-bit premultiplied RGBA, top row first.
public struct IconPixels: Sendable {
    /// Fainter than this does not count as part of the drawing, so that a stray soft edge does not change its size.
    private static let visibleAlpha: UInt8 = 16
    /// How far a colour may be from the background's to count as background, per channel, for JPEG noise and the like.
    private static let backgroundTolerance = 40
    /// How far apart the channels of a pixel must be, to count as coloured rather than grey.
    private static let colouredDifference = 40
    /// The share of a drawing that must be coloured. A little colour fringe from smoothing should not count.
    private static let colouredShare = 0.02

    public struct Box: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public func union(_ other: Box) -> Box {
            let left = min(x, other.x)
            let top = min(y, other.y)
            let right = max(x + width, other.x + other.width)
            let bottom = max(y + height, other.y + other.height)
            return Box(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    public var bytes: [UInt8]
    public let width: Int
    public let height: Int

    public init(bytes: [UInt8], width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    /// The smallest box around what can be seen. Nil if nothing can.
    public var contentBox: Box? {
        var (left, top, right, bottom) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) >= Self.visibleAlpha {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return Box(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    /// Whether it has colours of its own, rather than being one shade. Those are kept unless someone says otherwise.
    public var hasColours: Bool {
        var seen = 0
        var coloured = 0
        for index in stride(from: 0, to: bytes.count - 3, by: 4) where bytes[index + 3] >= Self.visibleAlpha {
            seen += 1
            let (r, g, b) = (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
            // Premultiplied, so a faint pixel has small channels, and its difference is scaled up to compare fairly.
            if (max(r, g, b) - min(r, g, b)) * 255 >= Self.colouredDifference * Int(bytes[index + 3]) { coloured += 1 }
        }
        return seen > 0 && Double(coloured) / Double(seen) >= Self.colouredShare
    }

    public var isFullyOpaque: Bool {
        stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
    }

    /// Makes the background transparent in a picture that has none, such as a JPEG or most GIFs, if its corners agree on
    /// what the background is. Only what is connected to the edge goes, so a white cat on white keeps its white eyes.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func removeBackground() -> Bool {
        guard width > 1, height > 1, isFullyOpaque else { return false }
        let corners = [offset(0, 0), offset(width - 1, 0), offset(0, height - 1), offset(width - 1, height - 1)]
        let colour = (Int(bytes[corners[0]]), Int(bytes[corners[0] + 1]), Int(bytes[corners[0] + 2]))
        func isBackground(_ index: Int) -> Bool {
            abs(Int(bytes[index]) - colour.0) <= Self.backgroundTolerance
                && abs(Int(bytes[index + 1]) - colour.1) <= Self.backgroundTolerance
                && abs(Int(bytes[index + 2]) - colour.2) <= Self.backgroundTolerance
        }
        guard corners.allSatisfy(isBackground) else { return false }
        let original = bytes
        var pending: [(Int, Int)] = []
        var visited = [Bool](repeating: false, count: width * height)
        func visit(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height, !visited[y * width + x] else { return }
            visited[y * width + x] = true
            if isBackground(offset(x, y)) { pending.append((x, y)) }
        }
        for x in 0..<width {
            visit(x, 0)
            visit(x, height - 1)
        }
        for y in 0..<height {
            visit(0, y)
            visit(width - 1, y)
        }
        var cleared = 0
        while let (x, y) = pending.popLast() {
            let index = offset(x, y)
            bytes[index] = 0
            bytes[index + 1] = 0
            bytes[index + 2] = 0
            bytes[index + 3] = 0
            cleared += 1
            visit(x + 1, y)
            visit(x - 1, y)
            visit(x, y + 1)
            visit(x, y - 1)
        }
        // A background that is nearly all of it, or none of it, means this was not a background after all: a flat logo,
        // or a drawing close to its corners' colour, is kept whole rather than cleared away.
        guard cleared > 0, cleared < width * height * 95 / 100 else {
            bytes = original
            return false
        }
        return true
    }

    private func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
    private func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[offset(x, y) + 3] }
}
