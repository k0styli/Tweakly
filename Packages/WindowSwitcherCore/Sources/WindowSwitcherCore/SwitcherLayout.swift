import CoreGraphics

/// Where everything goes in the panel: rows of tiles sharing one height, each about as wide as its window's shape,
/// and the glass behind them. Coordinates start at the panel's top left.
public struct SwitcherLayout: Equatable, Sendable {
    public struct Metrics: Equatable, Sendable {
        public var padding: CGFloat = 24
        public var spacing: CGFloat = 20
        public var maximumTileHeight: CGFloat = 176
        public var minimumTileHeight: CGFloat = 84
        /// Used only with the extra room the panel gets when even tiles of `minimumTileHeight` do not all fit.
        public var smallestTileHeight: CGFloat = 60
        /// Extreme window shapes are cropped to these, or a long thin window would make an unusable tile.
        public var minimumAspect: CGFloat = 0.62
        public var maximumAspect: CGFloat = 2.2
        /// Of the glass behind the tiles.
        public var cornerRadius: CGFloat = 44
        /// Gives every row the same margin from the glass, which then narrows around the shorter rows.
        public var fitsBackgroundToRows = false
        /// How far the glass has to step in on each side for a corner and the curve beneath it to fit. On macOS 27.2
        /// anything shorter comes out as a bump, so rows closer than that are made equally wide instead.
        public var smallestStep: CGFloat = 60

        public init() {}
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }

    public private(set) var panelSize: CGSize = .zero
    /// May hold fewer tiles than asked for, if even the smallest ones do not all fit. The first ones stay,
    /// as they are the windows used most recently.
    public private(set) var tileFrames: [CGRect] = []
    public private(set) var rows: [Range<Int>] = []
    public private(set) var tileHeight: CGFloat = 0
    /// One rectangle, or with `fitsBackgroundToRows` one piece for each run of rows of the same width, `padding`
    /// clear of the tiles. Pieces overlap, and are meant to be merged into one shape.
    public private(set) var backgroundFrames: [CGRect] = []

    /// - Parameters:
    ///   - available: the most the panel normally covers, which leaves most of the screen in view.
    ///   - overflow: the most it may cover when that would leave windows out. A window that cannot be reached
    ///     is worse than a large panel.
    public init(aspects: [CGFloat], available: CGSize, overflow: CGSize? = nil, metrics: Metrics = Metrics()) {
        guard !aspects.isEmpty, available.width > metrics.padding * 2, available.height > metrics.padding * 2
        else { return }
        let clamped = aspects.map { min(max($0, metrics.minimumAspect), metrics.maximumAspect) }

        var innerWidth = available.width - metrics.padding * 2
        var innerHeight = available.height - metrics.padding * 2
        var height = metrics.maximumTileHeight
        var lowest = metrics.minimumTileHeight
        var count = clamped.count
        var wrapped = Self.wrap(clamped, height: height, width: innerWidth, spacing: metrics.spacing)
        while !Self.fits(wrapped, height: height, into: innerHeight, spacing: metrics.spacing) {
            if height > lowest {
                height = max(height - 4, lowest)
            } else if let overflow, lowest > metrics.smallestTileHeight {
                innerWidth = overflow.width - metrics.padding * 2
                innerHeight = overflow.height - metrics.padding * 2
                lowest = metrics.smallestTileHeight
            } else if count > 1 {
                count -= 1
            } else {
                break
            }
            wrapped = Self.wrap(Array(clamped[..<count]), height: height, width: innerWidth, spacing: metrics.spacing)
        }

        wrapped = Self.balance(wrapped, aspects: Array(clamped[..<count]), height: height, spacing: metrics.spacing)

        tileHeight = height
        rows = wrapped
        let naturalWidths = wrapped.map { row in
            row.reduce(0) { $0 + clamped[$1] * height } + CGFloat(max(row.count - 1, 0)) * metrics.spacing
        }
        let roundedWidths = naturalWidths.map { $0.rounded() }
        let rowWidths =
            metrics.fitsBackgroundToRows
            ? Self.evened(roundedWidths, within: metrics.smallestStep * 2) : roundedWidths
        let contentWidth = rowWidths.max() ?? 0
        var y = metrics.padding
        for (position, row) in wrapped.enumerated() {
            // Edges rather than widths are rounded, or rows meant to line up would end a point or two apart.
            let gaps = CGFloat(row.count - 1) * metrics.spacing
            let stretch = (rowWidths[position] - gaps) / (naturalWidths[position] - gaps)
            let left = metrics.padding + ((contentWidth - rowWidths[position]) / 2).rounded()
            var edge: CGFloat = 0
            for index in row {
                let start = edge.rounded()
                edge += clamped[index] * height * stretch
                tileFrames.append(CGRect(x: left + start, y: y, width: edge.rounded() - start, height: height))
                edge += metrics.spacing
            }
            y += height + metrics.spacing
        }
        panelSize = CGSize(width: contentWidth + metrics.padding * 2, height: y - metrics.spacing + metrics.padding)
        backgroundFrames =
            metrics.fitsBackgroundToRows
            ? pieces(rowWidths: rowWidths, metrics: metrics) : [CGRect(origin: .zero, size: panelSize)]
    }

    /// Going down from the widest, a row close to the width above it takes that width, which is at most
    /// `tolerance` more than its own. Any two widths left are then at least `tolerance` apart.
    private static func evened(_ widths: [CGFloat], within tolerance: CGFloat) -> [CGFloat] {
        var evened = widths
        var target = widths.max() ?? 0
        for index in widths.indices.sorted(by: { widths[$0] > widths[$1] }) {
            if target - widths[index] >= tolerance { target = widths[index] }
            evened[index] = target
        }
        return evened
    }

    private func pieces(rowWidths: [CGFloat], metrics: Metrics) -> [CGRect] {
        // A piece running on behind a wider neighbour by the length of its corner hides that corner, so that its
        // side stays straight all the way to the step. The neighbour's edge is `padding - spacing` past the tiles.
        let reach = max(metrics.padding, metrics.cornerRadius + metrics.spacing - metrics.padding)
        var pieces: [CGRect] = []
        var start = 0
        while start < rows.count {
            var end = start
            while end + 1 < rows.count, rowWidths[end + 1] == rowWidths[start] { end += 1 }
            let first = tileFrames[rows[start].lowerBound]
            let last = tileFrames[rows[end].lowerBound]
            let widerAbove = start > 0 && rowWidths[start - 1] > rowWidths[start]
            let widerBelow = end + 1 < rows.count && rowWidths[end + 1] > rowWidths[start]
            let top = first.minY - (widerAbove ? reach : metrics.padding)
            let bottom = last.maxY + (widerBelow ? reach : metrics.padding)
            pieces.append(
                CGRect(
                    x: first.minX - metrics.padding, y: top, width: rowWidths[start] + metrics.padding * 2,
                    height: bottom - top))
            start = end + 1
        }
        return pieces
    }

    private static func wrap(_ aspects: [CGFloat], height: CGFloat, width: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, aspect) in aspects.enumerated() {
            let tile = aspect * height
            if index > start, used + spacing + tile > width {
                rows.append(start..<index)
                start = index
                used = tile
            } else {
                used += (index > start ? spacing : 0) + tile
            }
        }
        if start < aspects.count { rows.append(start..<aspects.count) }
        return rows
    }

    /// Filling each row to the edge leaves a short last one. This finds the narrowest width that needs no more
    /// rows, which evens them out and makes the panel smaller.
    private static func balance(_ rows: [Range<Int>], aspects: [CGFloat], height: CGFloat, spacing: CGFloat) -> [Range<
        Int
    >] {
        guard rows.count > 1 else { return rows }
        let widths = aspects.map { $0 * height }
        var limit = max(widths.reduce(0, +) / CGFloat(rows.count), widths.max() ?? 0)
        while true {
            let attempt = wrap(aspects, height: height, width: limit, spacing: spacing)
            if attempt.count <= rows.count { return attempt }
            limit += 8
        }
    }

    private static func fits(_ rows: [Range<Int>], height: CGFloat, into available: CGFloat, spacing: CGFloat) -> Bool {
        CGFloat(rows.count) * height + CGFloat(max(rows.count - 1, 0)) * spacing <= available
    }

    /// The tile an arrow key leads to. Left and right follow the order of the tiles and wrap around, the way
    /// Tab does; up and down go to the nearest tile of the next row and stop at the edge.
    public func neighbour(of index: Int, in direction: Direction) -> Int {
        guard tileFrames.indices.contains(index) else { return index }
        switch direction {
        case .left: return (index + tileFrames.count - 1) % tileFrames.count
        case .right: return (index + 1) % tileFrames.count
        case .up, .down:
            guard let row = rows.firstIndex(where: { $0.contains(index) }) else { return index }
            let target = direction == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return index }
            let center = tileFrames[index].midX
            return rows[target].min { abs(tileFrames[$0].midX - center) < abs(tileFrames[$1].midX - center) } ?? index
        }
    }

    /// The size to capture a window at for a tile: enough to fill it on this screen, keeping the window's
    /// shape, and never more than the window has, since a larger picture would add memory and no detail.
    public static func thumbnailPixelSize(window: CGSize, tile: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        guard window.width > 0, window.height > 0 else { return (0, 0) }
        let cover = max(tile.width / window.width, tile.height / window.height)
        let factor = min(cover * scale, scale)
        return (Int((window.width * factor).rounded(.up)), Int((window.height * factor).rounded(.up)))
    }
}

/// The empty edge of a picture. A window with parts in windows of its own, as a full-screen Chrome has, is captured
/// together with them but fitted into the size asked for, which leaves the rest transparent.
public enum SwitcherPictureEdges {
    /// A smaller edge cannot be seen, and is more likely the window's own rounded corner or shadow.
    private static let smallestEdgeShare = 0.01
    /// A window with this little in the middle has a shape of its own, which is not something to cut.
    private static let smallestContentShare = 0.5
    private static let opaque: UInt8 = 8

    /// What to keep of one line of alpha values through the middle of a picture, or nil to keep all of it.
    public static func content(ofLine alpha: some Collection<UInt8>) -> Range<Int>? {
        let values = Array(alpha)
        guard let first = values.firstIndex(where: { $0 > opaque }),
            let last = values.lastIndex(where: { $0 > opaque })
        else { return nil }
        let kept = last - first + 1
        let share = Double(kept) / Double(values.count)
        guard share >= smallestContentShare, share <= 1 - smallestEdgeShare else { return nil }
        return first..<(last + 1)
    }
}

/// The tile a session starts on and how Tab moves through them.
public enum SwitcherSelection {
    /// As in the system's switcher, the first press goes to the previous window, so that a quick tap goes back.
    /// That only applies if the first tile is where the person already is.
    public static func initial(count: Int, firstIsCurrent: Bool, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        if backward { return count - 1 }
        return firstIsCurrent && count > 1 ? 1 : 0
    }

    public static func next(after index: Int, count: Int) -> Int {
        count > 0 ? (index + 1) % count : 0
    }

    public static func previous(before index: Int, count: Int) -> Int {
        count > 0 ? (index + count - 1) % count : 0
    }
}
