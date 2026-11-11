import CoreGraphics
import Testing

@testable import WindowSwitcherCore

@Suite struct SwitcherLayoutTests {
    private let screen = CGSize(width: 1320, height: 570)

    @Test func nothingToShowGivesAnEmptyLayout() {
        let layout = SwitcherLayout(aspects: [], available: screen)
        #expect(layout.panelSize == .zero)
        #expect(layout.tileFrames.isEmpty)
    }

    @Test func aFewWindowsFitInOneRowAtFullHeight() {
        let layout = SwitcherLayout(aspects: [1.6, 1, 1.6], available: screen)
        #expect(layout.rows == [0..<3])
        #expect(layout.tileHeight == SwitcherLayout.Metrics().maximumTileHeight)
        #expect(Set(layout.tileFrames.map(\.height)) == [layout.tileHeight])
    }

    @Test func tilesKeepTheirWindowsShape() {
        let layout = SwitcherLayout(aspects: [1.5, 1], available: screen)
        #expect(layout.tileFrames[0].width == (1.5 * layout.tileHeight).rounded())
        #expect(layout.tileFrames[1].width == layout.tileHeight)
    }

    @Test func panelWrapsItsContentWithPadding() {
        let metrics = SwitcherLayout.Metrics()
        let layout = SwitcherLayout(aspects: [1, 1], available: screen)
        let last = try! #require(layout.tileFrames.last)
        #expect(layout.tileFrames[0].minX == metrics.padding)
        #expect(layout.tileFrames[0].minY == metrics.padding)
        #expect(layout.panelSize.width == last.maxX + metrics.padding)
        #expect(layout.panelSize.height == last.maxY + metrics.padding)
    }

    @Test func extremeShapesAreClamped() {
        let metrics = SwitcherLayout.Metrics()
        let layout = SwitcherLayout(aspects: [20, 0.05], available: screen)
        #expect(layout.tileFrames[0].width == (metrics.maximumAspect * layout.tileHeight).rounded())
        #expect(layout.tileFrames[1].width == (metrics.minimumAspect * layout.tileHeight).rounded())
    }

    @Test func manyWindowsWrapAndShrinkToStayWithinTheSpace() {
        let layout = SwitcherLayout(aspects: Array(repeating: 1.6, count: 20), available: screen)
        #expect(layout.tileFrames.count == 20)
        #expect(layout.rows.count > 1)
        #expect(layout.tileHeight < SwitcherLayout.Metrics().maximumTileHeight)
        #expect(layout.panelSize.width <= screen.width)
        #expect(layout.panelSize.height <= screen.height)
    }

    @Test func rowsAreCentredUnderEachOther() {
        let layout = SwitcherLayout(aspects: [1.6, 1.6, 1.6, 1.6, 1.6], available: CGSize(width: 1100, height: 700))
        #expect(layout.rows.count == 2)
        let first =
            layout.tileFrames[layout.rows[0].lowerBound].minX + layout.tileFrames[layout.rows[0].upperBound - 1].maxX
        let second =
            layout.tileFrames[layout.rows[1].lowerBound].minX + layout.tileFrames[layout.rows[1].upperBound - 1].maxX
        #expect(abs(first - second) <= 1)
    }

    @Test func rowsAreEvenedOut() {
        // Filling rows to the edge would give four and two.
        let layout = SwitcherLayout(
            aspects: Array(repeating: 1.34, count: 6), available: CGSize(width: 1100, height: 600))
        #expect(layout.rows == [0..<3, 3..<6])
    }

    @Test func tilesThatCannotFitAreDroppedFromTheEnd() {
        let small = CGSize(width: 400, height: 260)
        let layout = SwitcherLayout(aspects: Array(repeating: 1.6, count: 200), available: small)
        #expect(layout.tileFrames.count < 200)
        #expect(layout.tileFrames.count >= 1)
        #expect(layout.panelSize.height <= small.height)
    }

    @Test func extraRoomIsUsedOnlyWhenWindowsWouldBeLeftOut() {
        let normal = CGSize(width: 1320, height: 530)
        let more = CGSize(width: 1320, height: 800)
        let few = SwitcherLayout(aspects: Array(repeating: 1.4, count: 8), available: normal, overflow: more)
        #expect(few.panelSize.height <= normal.height)
        #expect(few.tileHeight >= SwitcherLayout.Metrics().minimumTileHeight)

        let many = SwitcherLayout(aspects: Array(repeating: 1.4, count: 60), available: normal, overflow: more)
        #expect(many.tileFrames.count == 60)
        #expect(many.panelSize.height > normal.height)
        #expect(many.panelSize.height <= more.height)
        #expect(many.tileHeight >= SwitcherLayout.Metrics().smallestTileHeight)
    }

    @Test func aVeryLargeNumberOfWindowsStillStaysOnScreen() {
        let more = CGSize(width: 1320, height: 800)
        let layout = SwitcherLayout(
            aspects: Array(repeating: 1.4, count: 500), available: CGSize(width: 1320, height: 530), overflow: more)
        #expect(layout.tileFrames.count > 60)
        #expect(layout.tileFrames.count < 500)
        #expect(layout.panelSize.height <= more.height)
        #expect(layout.panelSize.width <= more.width)
    }

    @Test func tilesNeverOverlap() {
        let layout = SwitcherLayout(aspects: (0..<30).map { CGFloat(1 + $0 % 3) / 2 + 0.2 }, available: screen)
        for (index, frame) in layout.tileFrames.enumerated() {
            for other in layout.tileFrames[(index + 1)...] { #expect(!frame.intersects(other)) }
        }
    }

    private var fitted: SwitcherLayout.Metrics {
        var metrics = SwitcherLayout.Metrics()
        metrics.fitsBackgroundToRows = true
        return metrics
    }
    private let roomy = CGSize(width: 1100, height: 600)
    /// Two rows of 724 and 548 pt at full height, too far apart to be evened out.
    private var stepped: SwitcherLayout {
        SwitcherLayout(aspects: [2, 2, 2, 1], available: roomy, metrics: fitted)
    }
    /// Two rows of 583 and 548 pt, close enough to be evened out.
    private var nearlyEqual: SwitcherLayout {
        SwitcherLayout(aspects: [1.6, 1.6, 1.4, 1.6], available: roomy, metrics: fitted)
    }

    @Test func byDefaultTheGlassIsOneRectangleAndRowsKeepTheirWidths() {
        for aspects: [CGFloat] in [[2, 2, 2, 1], [1.6, 1.6, 1.4, 1.6]] {
            let layout = SwitcherLayout(aspects: aspects, available: roomy)
            #expect(layout.rows.count == 2)
            #expect(layout.backgroundFrames == [CGRect(origin: .zero, size: layout.panelSize)])
            for (aspect, tile) in zip(aspects, layout.tileFrames) {
                #expect(abs(tile.width - aspect * layout.tileHeight) <= 1)
            }
        }
    }

    @Test func oneRowHasOnePieceOfGlassTheSizeOfThePanel() {
        let layout = SwitcherLayout(aspects: [1.5, 1, 1.7], available: screen, metrics: fitted)
        #expect(layout.backgroundFrames == [CGRect(origin: .zero, size: layout.panelSize)])
    }

    @Test func glassKeepsTheSameDistanceFromEveryRow() {
        let padding = SwitcherLayout.Metrics().padding
        for layout in [stepped, nearlyEqual] {
            #expect(layout.rows.count == 2)
            for row in layout.rows {
                let first = layout.tileFrames[row.lowerBound]
                let last = layout.tileFrames[row.upperBound - 1]
                let piece = layout.backgroundFrames.first {
                    $0.minY <= first.minY - padding && $0.maxY >= first.maxY + padding
                }
                #expect(piece?.minX == first.minX - padding)
                #expect(piece?.maxX == last.maxX + padding)
            }
        }
    }

    @Test func rowsFarApartKeepTheirOwnWidthsAndGetAPieceEach() {
        let layout = stepped
        #expect(layout.rows == [0..<2, 2..<4])
        #expect(layout.backgroundFrames.count == 2)
        #expect(layout.backgroundFrames[0].width == 772)
        #expect(layout.backgroundFrames[1].width == 596)
        #expect(layout.tileFrames[2].width == 352)
        #expect(layout.tileFrames[3].width == 176)
    }

    @Test func rowsCloseInWidthLineUpOnOnePieceOfGlass() {
        let layout = nearlyEqual
        #expect(layout.backgroundFrames == [CGRect(origin: .zero, size: layout.panelSize)])
        #expect(layout.tileFrames[0].minX == layout.tileFrames[2].minX)
        #expect(layout.tileFrames[1].maxX == layout.tileFrames[3].maxX)
    }

    @Test func evenedRowsKeepTheirGapsAndHeight() {
        let layout = nearlyEqual
        let spacing = SwitcherLayout.Metrics().spacing
        for row in layout.rows {
            #expect(layout.tileFrames[row.lowerBound + 1].minX - layout.tileFrames[row.lowerBound].maxX == spacing)
        }
        #expect(Set(layout.tileFrames.map(\.height)) == [layout.tileHeight])
        // The tiles of the shorter row share the extra width in proportion.
        #expect(layout.tileFrames[2].width > (1.4 * layout.tileHeight).rounded())
        #expect(layout.tileFrames[3].width > (1.6 * layout.tileHeight).rounded())
        #expect(layout.tileFrames[3].width / layout.tileFrames[2].width > 1.1)
    }

    @Test func aNarrowerPieceRunsOnBehindTheWiderOneByItsCorner() {
        let metrics = SwitcherLayout.Metrics()
        let wideOnTop = stepped.backgroundFrames
        #expect(wideOnTop[0].maxY - wideOnTop[1].minY >= metrics.cornerRadius)
        #expect(wideOnTop[1].maxY == stepped.panelSize.height)

        let wideBelow = SwitcherLayout(aspects: [1, 2, 2, 2], available: roomy, metrics: fitted)
        #expect(wideBelow.rows.count == 2)
        let pieces = wideBelow.backgroundFrames
        #expect(pieces[0].width < pieces[1].width)
        #expect(pieces[0].maxY - pieces[1].minY >= metrics.cornerRadius)
        #expect(pieces[0].maxY < pieces[1].maxY)
    }

    @Test func piecesStayInsideThePanelAndAreNeverCloseInWidth() {
        let metrics = fitted
        for count in 2...60 {
            let aspects = (0..<count).map { CGFloat(5 + ($0 * 7) % 13) / 10 }
            let layout = SwitcherLayout(aspects: aspects, available: CGSize(width: 1320, height: 620), metrics: metrics)
            let panel = CGRect(origin: .zero, size: layout.panelSize)
            for (index, piece) in layout.backgroundFrames.enumerated() {
                #expect(panel.contains(piece))
                for other in layout.backgroundFrames[(index + 1)...] where other.width != piece.width {
                    #expect(abs(other.width - piece.width) >= metrics.smallestStep * 2)
                }
            }
            // Every tile sits on the glass with its full margin, and nothing reaches past the widest row.
            for tile in layout.tileFrames {
                let margin = tile.insetBy(dx: -metrics.padding, dy: -metrics.padding)
                #expect(panel.contains(margin))
                #expect(layout.backgroundFrames.contains { $0.contains(margin) })
            }
            #expect(layout.backgroundFrames.map(\.width).max() == layout.panelSize.width)
        }
    }

    @Test func leftAndRightWrapAround() {
        let layout = SwitcherLayout(aspects: [1, 1, 1], available: screen)
        #expect(layout.neighbour(of: 0, in: .left) == 2)
        #expect(layout.neighbour(of: 2, in: .right) == 0)
        #expect(layout.neighbour(of: 1, in: .right) == 2)
    }

    @Test func upAndDownGoToTheNearestTileAndStopAtTheEdge() {
        let layout = SwitcherLayout(
            aspects: Array(repeating: 1.6, count: 8), available: CGSize(width: 1100, height: 460))
        #expect(layout.rows.count == 2)
        let lastOfFirstRow = layout.rows[0].upperBound - 1
        let below = layout.neighbour(of: lastOfFirstRow, in: .down)
        #expect(layout.rows[1].contains(below))
        #expect(layout.neighbour(of: below, in: .up) == lastOfFirstRow)
        #expect(layout.neighbour(of: 0, in: .up) == 0)
        #expect(layout.neighbour(of: below, in: .down) == below)
    }

    @Test func thumbnailCoversTheTileAtScreenScale() {
        let size = SwitcherLayout.thumbnailPixelSize(
            window: CGSize(width: 1600, height: 1000), tile: CGSize(width: 320, height: 200), scale: 2)
        #expect(size.width == 640)
        #expect(size.height == 400)
    }

    @Test func thumbnailOfACroppedWindowStillFillsTheTile() {
        let size = SwitcherLayout.thumbnailPixelSize(
            window: CGSize(width: 2000, height: 400), tile: CGSize(width: 440, height: 200), scale: 2)
        #expect(size.height == 400)
        #expect(size.width == 2000)
    }

    @Test func thumbnailOfASmallWindowIsNotEnlarged() {
        let size = SwitcherLayout.thumbnailPixelSize(
            window: CGSize(width: 200, height: 100), tile: CGSize(width: 400, height: 200), scale: 2)
        #expect(size.width == 400)
        #expect(size.height == 200)
    }

    @Test func thumbnailOfAnEmptyWindowIsEmpty() {
        let size = SwitcherLayout.thumbnailPixelSize(window: .zero, tile: CGSize(width: 400, height: 200), scale: 2)
        #expect(size.width == 0)
    }
}

@Suite struct SwitcherPictureEdgesTests {
    private func line(transparentFirst: Int = 0, opaque: Int, transparentLast: Int = 0) -> [UInt8] {
        Array(repeating: 0, count: transparentFirst) + Array(repeating: 255, count: opaque)
            + Array(repeating: 0, count: transparentLast)
    }

    @Test func aFullScreenChromesEmptyEdgeIsFound() {
        // Measured: 561 of 619 columns.
        #expect(SwitcherPictureEdges.content(ofLine: line(opaque: 561, transparentLast: 58)) == 0..<561)
    }

    @Test func anEdgeCanBeOnEitherSide() {
        #expect(SwitcherPictureEdges.content(ofLine: line(transparentFirst: 40, opaque: 300)) == 40..<340)
    }

    @Test func aPictureWithNoEmptyEdgeIsLeftAlone() {
        #expect(SwitcherPictureEdges.content(ofLine: line(opaque: 619)) == nil)
    }

    @Test func aRoundedCornerOrShadowIsNotAnEdge() {
        #expect(SwitcherPictureEdges.content(ofLine: line(transparentFirst: 1, opaque: 600, transparentLast: 1)) == nil)
    }

    @Test func aWindowWithAShapeOfItsOwnIsNotCut() {
        #expect(
            SwitcherPictureEdges.content(ofLine: line(transparentFirst: 200, opaque: 100, transparentLast: 200)) == nil)
    }

    @Test func aFullyTransparentLineSaysNothing() {
        #expect(SwitcherPictureEdges.content(ofLine: line(transparentFirst: 100, opaque: 0)) == nil)
        #expect(SwitcherPictureEdges.content(ofLine: [UInt8]()) == nil)
    }
}

@Suite struct SwitcherSelectionTests {
    @Test func startsOnThePreviousWindow() {
        #expect(SwitcherSelection.initial(count: 3, firstIsCurrent: true, backward: false) == 1)
    }

    @Test func startsOnTheFirstWhenThePersonIsNotOnIt() {
        #expect(SwitcherSelection.initial(count: 3, firstIsCurrent: false, backward: false) == 0)
    }

    @Test func aSingleTileIsSelected() {
        #expect(SwitcherSelection.initial(count: 1, firstIsCurrent: true, backward: false) == 0)
    }

    @Test func shiftStartsAtTheEnd() {
        #expect(SwitcherSelection.initial(count: 3, firstIsCurrent: true, backward: true) == 2)
    }

    @Test func noTilesDoesNotCrash() {
        #expect(SwitcherSelection.initial(count: 0, firstIsCurrent: true, backward: true) == 0)
        #expect(SwitcherSelection.next(after: 0, count: 0) == 0)
        #expect(SwitcherSelection.previous(before: 0, count: 0) == 0)
    }

    @Test func movesWrapAround() {
        #expect(SwitcherSelection.next(after: 2, count: 3) == 0)
        #expect(SwitcherSelection.previous(before: 0, count: 3) == 2)
    }
}
