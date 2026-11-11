import Foundation
import Testing

@testable import CustomIconCore

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private let frames = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 56 36" data-fps="10">
      <defs><path id="body" d="M0 0H9V9Z"/></defs>
      <g data-frame="2" id="b"><use href="#body"/><circle r="2"/></g>
      <g data-frame="1" id="a"><use href="#body"/><rect width="2" height="2"/></g>
      <g data-frame="3" id="c" display="none"><use href="#body"/><ellipse rx="1" ry="1"/></g>
    </svg>
    """#

@Suite struct IconSVGTests {
    @Test func aDrawingWithoutFramesIsOneFrame() throws {
        let icon = try IconSVG(data: Data(#"<svg viewBox="0 0 36 36"><path d="M0 0Z"/></svg>"#.utf8))
        #expect(icon.frames.count == 1)
        #expect(icon.framesPerSecond == nil)
    }

    @Test func eachFrameHoldsOnlyItselfAndWhatIsShared() throws {
        let icon = try IconSVG(data: Data(frames.utf8))
        #expect(icon.frames.count == 3)
        #expect(icon.framesPerSecond == 10)
        // In order of their numbers, not of the file.
        let first = text(icon.frames[0])
        #expect(first.contains("<rect"))
        #expect(!first.contains("<circle"))
        #expect(!first.contains("<ellipse"))
        #expect(first.contains("id=\"body\""))
        #expect(text(icon.frames[1]).contains("<circle"))
    }

    /// The system's reader draws such a group anyway, but a frame that is shown must not rely on that.
    @Test func aFrameMarkedHiddenIsShownAfterAll() throws {
        let icon = try IconSVG(data: Data(frames.utf8))
        #expect(!text(icon.frames[2]).contains("display"))
    }

    @Test func framesAreFoundByTheirIdsAndInsideAWrapper() throws {
        let byID = #"<svg viewBox="0 0 36 36"><g id="frame-2"><rect/></g><g id="frame_1"><circle/></g></svg>"#
        let icon = try IconSVG(data: Data(byID.utf8))
        #expect(icon.frames.count == 2)
        #expect(text(icon.frames[0]).contains("<circle"))

        let wrapped =
            #"<svg viewBox="0 0 36 36"><g><g data-frame="1"><rect/></g><g data-frame="2"><circle/></g></g></svg>"#
        #expect(try IconSVG(data: Data(wrapped.utf8)).frames.count == 2)
    }

    @Test func whatCouldReachOutsideTheFileIsRemoved() throws {
        let file = #"""
            <svg viewBox="0 0 36 36" onload="x()">
              <script>alert(1)</script>
              <image href="http://example.com/a.png"/>
              <use href="http://example.com/b.svg#c"/>
              <use href="#local"/>
              <style>@import url(http://example.com/c.css);</style>
              <rect fill="url(http://example.com/d)" width="1"/>
              <circle fill="url(#local)" onclick="y()"/>
            </svg>
            """#
        let result = text(try IconSVG(data: Data(file.utf8)).frames[0])
        #expect(!result.contains("example.com"))
        #expect(!result.contains("script"))
        #expect(!result.contains("onload"))
        #expect(!result.contains("onclick"))
        #expect(result.contains("#local"))
    }

    @Test func anAddressInAnOlderKindOfLinkIsRemovedToo() throws {
        let file = #"""
            <svg viewBox="0 0 36 36" xmlns:xlink="http://www.w3.org/1999/xlink">
              <use xlink:href="http://example.com/b.svg#c"/>
              <use xlink:href="#local"/>
            </svg>
            """#
        let result = text(try IconSVG(data: Data(file.utf8)).frames[0])
        #expect(!result.contains("example.com"))
        #expect(result.contains("#local"))
    }

    /// Each frame costs a copy of the whole file, and a frame is a few bytes, so these would be gigabytes if all were made.
    @Test func framesBeyondTheLimitAreNotMade() throws {
        let groups = (0..<500).map { #"<g data-frame="\#($0)"><rect/></g>"# }.joined()
        let icon = try IconSVG(data: Data(#"<svg viewBox="0 0 36 36" data-fps="10">\#(groups)</svg>"#.utf8))
        #expect(icon.frames.count == IconFit.largestFrameCount)
        #expect(icon.frameCount == 500)
        #expect(try IconSVG(data: Data(frames.utf8)).frameCount == 3)
    }

    @Test func aFrameKeepsWhatItsStyleSaysAboutColour() throws {
        let file = #"""
            <svg viewBox="0 0 36 36">
              <g data-frame="1" style="fill:#e00; display:none"><rect/></g>
              <g data-frame="2" style="display:none"><circle/></g>
              <g data-frame="3" style="VISIBILITY: hidden;stroke:#00e;opacity:0"><path d="M0 0Z"/></g>
            </svg>
            """#
        let icon = try IconSVG(data: Data(file.utf8))
        #expect(text(icon.frames[0]).contains("fill:#e00"))
        #expect(!text(icon.frames[0]).contains("display"))
        #expect(!text(icon.frames[1]).contains("style"))
        #expect(text(icon.frames[2]).contains("stroke:#00e"))
        #expect(!text(icon.frames[2]).lowercased().contains("visibility"))
        #expect(!text(icon.frames[2]).contains("opacity"))
    }

    /// Cyrillic text in a comment puts a two-byte letter across the place where the look ahead ends.
    @Test func aFileIsRecognisedWhereverItsFirstBytesEnd() throws {
        for padding in 4090...4100 {
            let comment = "<!--" + String(repeating: " ", count: padding) + "ж-->"
            let file = #"<?xml version="1.0"?>"# + "<svg viewBox=\"0 0 1 1\">" + comment + "<rect/></svg>"
            #expect(IconSVG.looksLikeSVG(Data(file.utf8)))
        }
    }

    @Test func aPictureThatMentionsSVGInItsMetadataIsStillAPicture() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE])
        png.append(Data("<svg in some metadata".utf8))
        #expect(!IconSVG.looksLikeSVG(png))
    }

    @Test func aFileThatIsNotAnIconIsRefused() {
        let refused = [
            "hello",
            "<html></html>",
            // No size: the system's reader would stretch this to something useless.
            "<svg><rect/></svg>",
            #"<!DOCTYPE svg [<!ENTITY a "aaaa">]><svg viewBox="0 0 1 1">&a;</svg>"#,
        ]
        for file in refused {
            #expect(throws: IconFileError.unreadable) { try IconSVG(data: Data(file.utf8)) }
        }
        let huge = Data(repeating: 32, count: IconSVG.largestFile + 1)
        #expect(throws: IconFileError.tooLarge) { try IconSVG(data: huge) }
    }

    @Test func aFrameRateOutsideReasonIsIgnored() throws {
        let file = #"<svg viewBox="0 0 1 1" data-fps="9000"><rect/></svg>"#
        #expect(try IconSVG(data: Data(file.utf8)).framesPerSecond == nil)
    }

    @Test func theSVGIsFoundInACopiedAnswer() throws {
        let answer = """
            Here is your icon:
            ```svg
            <svg viewBox="0 0 36 36"><rect/></svg>
            ```
            Enjoy!
            """
        let found = try #require(IconSVG.find(inText: answer))
        #expect(text(found) == #"<svg viewBox="0 0 36 36"><rect/></svg>"#)
        #expect(IconSVG.find(inText: "no icon here") == nil)
        #expect(IconSVG.looksLikeSVG(Data("<?xml version=\"1.0\"?>\n<svg></svg>".utf8)))
        #expect(!IconSVG.looksLikeSVG(Data([0x89, 0x50, 0x4E, 0x47])))
    }
}

@Suite struct IconFitTests {
    @Test func aShapeGetsAsBigAsTheLimitsAllow() {
        #expect(IconFit.pixelSize(ofContentWidth: 32, height: 32) == .init(width: 32, height: 32))
        // Twice as tall as allowed, whatever its resolution.
        #expect(IconFit.pixelSize(ofContentWidth: 500, height: 1000) == .init(width: 16, height: 32))
        #expect(IconFit.pixelSize(ofContentWidth: 56, height: 32) == .init(width: 56, height: 32))
        // Too wide for the menu bar, so its width decides.
        #expect(IconFit.pixelSize(ofContentWidth: 320, height: 32) == .init(width: 80, height: 8))
        #expect(IconFit.pixelSize(ofContentWidth: 0, height: 0) == .init(width: 32, height: 32))
    }

    @Test func aLongAnimationLosesFramesEvenly() {
        #expect(IconFit.keptFrames(of: 3) == [0, 1, 2])
        let kept = IconFit.keptFrames(of: 600)
        #expect(kept.count == IconFit.largestFrameCount)
        #expect(kept.first == 0)
        #expect(kept[1] == 10)
        #expect(kept.allSatisfy { $0 < 600 })
    }

    @Test func aRoundTakesAsLongAsTheFileSays() {
        #expect(IconFit.cycleSeconds(frameDelays: [0.1, 0.1, 0.1]) == 0.1 + 0.1 + 0.1)
        // A delay of zero means the usual pace in a GIF.
        #expect(abs(IconFit.cycleSeconds(frameDelays: [0, 0, 0]) - 0.3) < 0.001)
        #expect(IconFit.cycleSeconds(frameDelays: [100]) == 10)
        #expect(IconFit.cycleSeconds(frameCount: 12, framesPerSecond: 12) == 1)
        #expect(IconFit.cycleSeconds(frameCount: 6, framesPerSecond: nil) == 0.5)
        #expect(IconFit.cycleSeconds(frameCount: 1, framesPerSecond: 60) == 0.2)
    }

    /// Two frames of a slow GIF ask for fewer frames a second than the range allows, and Core Animation stops the app for it.
    @Test func theFrameRateAskedForIsAlwaysWithinTheRange() {
        let range: ClosedRange<Float> = 1...30
        func rate(_ frames: Int, _ seconds: Double) -> Float {
            IconFit.preferredFrameRate(frameCount: frames, cycleSeconds: seconds, fastestSpeed: 4, within: range)
        }
        #expect(rate(2, 10) == 1)
        #expect(rate(10, 5) == 8)
        #expect(rate(60, 0.2) == 30)
        #expect(rate(2, 0) == 30)
    }
}

@Suite struct IconPixelsTests {
    /// A square picture of one colour with a square of another in the middle.
    private func picture(
        background: (UInt8, UInt8, UInt8, UInt8), square: (UInt8, UInt8, UInt8, UInt8), size: Int = 8
    ) -> IconPixels {
        var bytes: [UInt8] = []
        for y in 0..<size {
            for x in 0..<size {
                let inside = (2..<size - 2).contains(x) && (2..<size - 2).contains(y)
                let pixel = inside ? square : background
                bytes += [pixel.0, pixel.1, pixel.2, pixel.3]
            }
        }
        return IconPixels(bytes: bytes, width: size, height: size)
    }

    @Test func theBoxIsAroundWhatCanBeSeen() {
        let image = picture(background: (0, 0, 0, 0), square: (0, 0, 0, 255))
        #expect(image.contentBox == .init(x: 2, y: 2, width: 4, height: 4))
        #expect(picture(background: (0, 0, 0, 0), square: (0, 0, 0, 0)).contentBox == nil)
        // Too faint to count as part of the drawing.
        #expect(picture(background: (0, 0, 0, 0), square: (0, 0, 0, 8)).contentBox == nil)
    }

    @Test func boxesCombine() {
        let box = IconPixels.Box(x: 2, y: 2, width: 4, height: 4).union(.init(x: 4, y: 0, width: 4, height: 4))
        #expect(box == .init(x: 2, y: 0, width: 6, height: 6))
    }

    @Test func aBackgroundThatTheCornersAgreeOnGoes() {
        var image = picture(background: (255, 255, 255, 255), square: (0, 0, 0, 255))
        let changed = image.removeBackground()
        #expect(changed)
        #expect(image.contentBox == .init(x: 2, y: 2, width: 4, height: 4))
    }

    @Test func onlyWhatTouchesTheEdgeIsBackground() {
        var bytes: [UInt8] = []
        let size = 9
        for y in 0..<size {
            for x in 0..<size {
                let ring = (2..<size - 2).contains(x) && (2..<size - 2).contains(y)
                let eye = x == 4 && y == 4
                let value: UInt8 = ring && !eye ? 0 : 255
                bytes += [value, value, value, 255]
            }
        }
        var image = IconPixels(bytes: bytes, width: size, height: size)
        let changed = image.removeBackground()
        #expect(changed)
        #expect(image.bytes[(4 * size + 4) * 4 + 3] == 255)
        #expect(image.bytes[3] == 0)
    }

    @Test func aPictureWithItsOwnTransparencyKeepsIt() {
        var image = picture(background: (0, 0, 0, 0), square: (255, 255, 255, 255))
        let before = image.bytes
        let changed = image.removeBackground()
        #expect(!changed)
        #expect(image.bytes == before)
    }

    @Test func aPictureThatIsAllBackgroundIsKeptWhole() {
        // A pale grey drawing on white, within the tolerance of its corners, would otherwise vanish entirely.
        var image = picture(background: (255, 255, 255, 255), square: (240, 240, 240, 255))
        let before = image.bytes
        let changed = image.removeBackground()
        #expect(!changed)
        #expect(image.bytes == before)
    }

    @Test func cornersThatDisagreeLeaveThePictureAlone() {
        var image = picture(background: (255, 255, 255, 255), square: (0, 0, 0, 255))
        image.bytes[0] = 0
        image.bytes[1] = 0
        image.bytes[2] = 0
        let changed = image.removeBackground()
        #expect(!changed)
    }

    @Test func coloursAreToldFromShades() {
        #expect(picture(background: (0, 0, 0, 0), square: (255, 59, 48, 255)).hasColours)
        #expect(!picture(background: (0, 0, 0, 0), square: (0, 0, 0, 255)).hasColours)
        #expect(!picture(background: (0, 0, 0, 0), square: (128, 128, 128, 255)).hasColours)
        // Faint premultiplied colour counts as much as strong colour.
        #expect(picture(background: (0, 0, 0, 0), square: (64, 15, 12, 64)).hasColours)
    }
}

@Suite struct IconMotionTests {
    @Test func speedFollowsLoadBetweenTheTwoEnds() {
        var motion = IconMotion()
        motion.idleSpeed = 1
        motion.busySpeed = 3
        #expect(motion.speed(atLoad: 0) == 1)
        #expect(motion.speed(atLoad: 0.5) == 2)
        #expect(motion.speed(atLoad: 1) == 3)
        #expect(motion.speed(atLoad: 7) == 3)
        #expect(motion.speed(atLoad: -1) == 1)
        #expect(motion.speed(atLoad: .nan) == 1)
    }

    @Test func preferencesAreKeptWithinReason() {
        var motion = IconMotion()
        motion.loopSpeed = 100
        motion.idleSpeed = -3
        motion.busySpeed = .infinity
        let valid = motion.validated
        #expect(valid.loopSpeed == IconMotion.speeds.upperBound)
        #expect(valid.idleSpeed == IconMotion.speeds.lowerBound)
        #expect(valid.busySpeed == 3)
    }

    /// The setting stays as it was for the next animated icon.
    @Test func anIconWithOneFrameHasNothingToPlay() {
        let motion = IconMotion()
        #expect(motion.shownMode(isAnimated: true) == .load)
        #expect(motion.shownMode(isAnimated: false) == .still)
        #expect(motion.mode == .load)
    }

    /// Filling is a choice of its own, so that it can go with any movement or none.
    @Test func fillingIsOffUntilChosenAndLeavesTheMovementAlone() {
        var motion = IconMotion()
        #expect(motion.fills == false)
        motion.fills = true
        #expect(motion.mode == .load)
        #expect(motion.validated.fills)
        #expect(motion.shownMode(isAnimated: true) == .load)
    }

    @Test func aFirstReadingFillsAtOnce() {
        var follower = IconFillFollower()
        #expect(follower.next(load: 0.5) == 0.5)
    }

    @Test func theLevelMovesPartOfTheWayToANewReading() {
        var follower = IconFillFollower()
        _ = follower.next(load: 0)
        #expect(follower.next(load: 1) == 0.5)
        #expect(follower.next(load: 1) == 0.75)
    }

    /// Every change reaches the render server, and an icon this size cannot show a wobble anyway.
    @Test func aSmallWobbleDoesNotMoveTheLevel() {
        var follower = IconFillFollower()
        _ = follower.next(load: 0.5)
        #expect(follower.next(load: 0.55) == nil)
        #expect(follower.next(load: 0.47) == nil)
    }

    @Test func aRealChangeMovesTheLevel() {
        var follower = IconFillFollower()
        _ = follower.next(load: 0.5)
        #expect(follower.next(load: 0.7) == 0.6)
    }

    @Test func theLevelStaysWithinTheIcon() throws {
        var high = IconFillFollower()
        #expect(high.next(load: 7) == 1)
        var low = IconFillFollower()
        #expect(low.next(load: -1) == 0)
        var broken = IconFillFollower()
        #expect(broken.next(load: .nan) == 0)
    }

    @Test func aResetForgetsThePast() {
        var follower = IconFillFollower()
        _ = follower.next(load: 0.2)
        follower.reset()
        #expect(follower.next(load: 0.8) == 0.8)
    }

    @Test func anIconFollowsTheLoadUntilSomeoneChoosesOtherwise() {
        #expect(IconMotion().mode == .load)
    }

    /// Each change reaches the render server, so a load that wobbles must not cause one.
    @Test func aSmallWobbleChangesNothing() {
        var follower = IconSpeedFollower()
        let motion = IconMotion()
        let first = follower.next(load: 0.5, motion: motion)
        let second = follower.next(load: 0.51, motion: motion)
        let third = follower.next(load: 0.49, motion: motion)
        #expect(first != nil)
        #expect(second == nil)
        #expect(third == nil)
    }

    @Test func aRealChangeComesThroughGradually() {
        var follower = IconSpeedFollower()
        var motion = IconMotion()
        motion.idleSpeed = 1
        motion.busySpeed = 3
        _ = follower.next(load: 0, motion: motion)
        let first = follower.next(load: 1, motion: motion)
        let second = follower.next(load: 1, motion: motion)
        #expect(first == 2)
        #expect(second == 2.5)
    }

    @Test func startingOverFollowsTheNextReadingAtOnce() {
        var follower = IconSpeedFollower()
        var motion = IconMotion()
        motion.idleSpeed = 1
        motion.busySpeed = 3
        _ = follower.next(load: 0, motion: motion)
        follower.reset()
        let next = follower.next(load: 1, motion: motion)
        #expect(next == 3)
    }
}

@Suite struct IconManifestTests {
    private func manifest() -> IconManifest {
        IconManifest(
            id: "a", name: "Cat", frameCount: 8, frameWidth: 56, frameHeight: 32, cycleSeconds: 0.7, hasColours: false,
            added: Date(timeIntervalSince1970: 0))
    }

    @Test func itSurvivesTheFile() throws {
        let data = try JSONEncoder().encode(manifest())
        #expect(try JSONDecoder().decode(IconManifest.self, from: data) == manifest())
        #expect(manifest().isValid)
        #expect(manifest().isAnimated)
    }

    @Test func aFileChangedByHandIsNotTrusted() {
        var wide = manifest()
        wide.frameWidth = 5000
        #expect(!wide.isValid)
        var none = manifest()
        none.frameCount = 0
        #expect(!none.isValid)
        var never = manifest()
        never.cycleSeconds = 0
        #expect(!never.isValid)
    }
}

@Suite struct IconPromptTests {
    @Test func theDescriptionGoesIn() {
        let prompt = IconPrompt.make(description: "бегущая кошка", isAnimated: true, isColoured: false)
        #expect(prompt.contains("бегущая кошка"))
        #expect(!prompt.contains(IconPrompt.placeholder))
    }

    @Test func withNoDescriptionThePlaceholderStays() {
        let prompt = IconPrompt.make(description: "  ", isAnimated: true, isColoured: false)
        #expect(prompt.contains(IconPrompt.placeholder))
    }

    @Test func aDescriptionStaysOnOneLine() {
        let prompt = IconPrompt.make(description: "a cat\nrunning", isAnimated: false, isColoured: false)
        #expect(prompt.contains("a cat running"))
    }

    @Test func theKindDecidesWhatIsAskedFor() {
        let moving = IconPrompt.make(description: "a", isAnimated: true, isColoured: false)
        #expect(moving.contains("data-frame"))
        #expect(moving.contains("data-fps"))
        #expect(moving.contains(##"fill="#000000""##))

        let still = IconPrompt.make(description: "a", isAnimated: false, isColoured: false)
        #expect(!still.contains("data-frame"))

        let coloured = IconPrompt.make(description: "a", isAnimated: false, isColoured: true)
        #expect(coloured.contains("flat colours"))
    }

    /// What the prompt promises has to be what the app accepts.
    @Test func theSkeletonParses() throws {
        let file = #"""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 56 36" data-fps="12">
              <defs><path id="body" d="M0 0Z" fill="#000000"/></defs>
              <g data-frame="1"><use href="#body"/><path d="M1 1Z" fill="#000000"/></g>
              <g data-frame="2"><use href="#body"/><path d="M2 2Z" fill="#000000"/></g>
            </svg>
            """#
        let icon = try IconSVG(data: Data(file.utf8))
        #expect(icon.frames.count == 2)
        #expect(icon.framesPerSecond == 12)
    }
}
