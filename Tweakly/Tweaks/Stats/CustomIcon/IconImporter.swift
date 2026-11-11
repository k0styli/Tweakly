import AppKit
import CustomIconCore
import ImageIO

/// Turns a file someone chose into an icon in the library: drawn at the size of the menu bar, with empty margins gone.
/// Runs only in the window's process, because a picture from anywhere is the likeliest thing here to go wrong, and the
/// window can crash without the menu bar noticing.
nonisolated enum IconImporter {
    /// Far more than an icon needs, and little enough that reading it cannot take the Mac down.
    private static let largestPictureFile = 30_000_000
    /// The side a frame is looked at to find its edges, and a bitmap is reduced to. Far above what is shown.
    private static let analysisSide = 512
    /// A file can give any size at all, and what is below or above this would not survive being scaled to the side above.
    private static let usableCanvasSides = 0.001...1_000_000.0

    /// One frame, able to draw itself so that its whole canvas fills a rectangle.
    private struct Frame {
        let draw: (CGContext, CGRect) -> Void
    }

    private struct Decoded {
        let canvas: CGSize
        let frames: [Frame]
        let cycleSeconds: Double
    }

    static func add(fileAt url: URL) throws -> IconManifest {
        // Something dragged from a browser can be a link, and only a file has a size to go by.
        guard url.isFileURL, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            throw IconFileError.unreadable
        }
        guard size <= largestPictureFile else { throw IconFileError.tooLarge }
        return try add(data: try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    /// What a chat gives: SVG text, maybe with words or a code fence around it.
    static func add(text: String, name: String) throws -> IconManifest {
        guard let data = IconSVG.find(inText: text) else { throw IconFileError.unreadable }
        return try add(data: data, name: name)
    }

    static func add(data: Data, name: String) throws -> IconManifest {
        guard data.count <= largestPictureFile else { throw IconFileError.tooLarge }
        let decoded: Decoded
        if IconSVG.looksLikeSVG(data) {
            // A saved answer from a chat can have words or a code fence around the file too.
            decoded = try decodeSVG(IconSVG.find(inText: String(decoding: data, as: UTF8.self)) ?? data)
        } else {
            decoded = try decodePicture(data)
        }

        var box: IconPixels.Box?
        var hasColours = false
        for frame in decoded.frames {
            guard let pixels = rasterize(frame, canvas: decoded.canvas) else { throw IconFileError.unreadable }
            if let found = pixels.contentBox { box = box?.union(found) ?? found }
            hasColours = hasColours || pixels.hasColours
        }
        guard let box else { throw IconFileError.empty }

        let size = IconFit.pixelSize(ofContentWidth: Double(box.width), height: Double(box.height))
        let analysis = analysisSize(of: decoded.canvas)
        guard
            let strip = makeStrip(
                decoded, box: box, analysis: analysis, frameWidth: size.width, frameHeight: size.height)
        else { throw IconFileError.unreadable }
        let manifest = IconManifest(
            id: UUID().uuidString, name: name, frameCount: decoded.frames.count, frameWidth: size.width,
            frameHeight: size.height, cycleSeconds: decoded.cycleSeconds, hasColours: hasColours, added: Date())
        try IconLibrary.add(manifest, strip: strip)
        return manifest
    }

    private static func decodeSVG(_ data: Data) throws -> Decoded {
        let svg = try IconSVG(data: data)
        let images = svg.frames.compactMap { NSImage(data: $0) }
        guard images.count == svg.frames.count, let first = images.first,
            usableCanvasSides.contains(first.size.width), usableCanvasSides.contains(first.size.height)
        else {
            throw IconFileError.unreadable
        }
        let frames = images.map { image in
            Frame { context, rect in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let seconds = IconFit.cycleSeconds(frameCount: svg.frameCount, framesPerSecond: svg.framesPerSecond)
        return Decoded(canvas: first.size, frames: frames, cycleSeconds: seconds)
    }

    private static func decodePicture(_ data: Data) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw IconFileError.unreadable }
        let count = CGImageSourceGetCount(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSide,
        ]
        var images: [CGImage] = []
        for index in IconFit.keptFrames(of: count) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw IconFileError.unreadable
            }
            images.append(withoutBackground(image) ?? image)
        }
        guard let first = images.first else { throw IconFileError.unreadable }
        let delays = (0..<count).map { frameDelay(of: source, at: $0) }
        let frames = images.map { image in
            Frame { context, rect in
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            }
        }
        return Decoded(
            canvas: CGSize(width: first.width, height: first.height), frames: frames,
            cycleSeconds: IconFit.cycleSeconds(frameDelays: delays))
    }

    private static func frameDelay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let kinds: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in kinds {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let delay = (values[unclamped] ?? values[clamped]) as? Double { return delay }
        }
        return 0
    }

    /// A picture with no transparency of its own, or nil if it has some or its background cannot be told.
    private static func withoutBackground(_ image: CGImage) -> CGImage? {
        guard var pixels = pixels(of: image), pixels.removeBackground() else { return nil }
        return makeImage(pixels)
    }

    private static func analysisSize(of canvas: CGSize) -> (width: Int, height: Int) {
        let scale = Double(analysisSide) / max(canvas.width, canvas.height)
        return (max(Int((canvas.width * scale).rounded()), 1), max(Int((canvas.height * scale).rounded()), 1))
    }

    private static func rasterize(_ frame: Frame, canvas: CGSize) -> IconPixels? {
        let size = analysisSize(of: canvas)
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = makeContext(width: size.width, height: size.height, data: buffer.baseAddress) else {
                return false
            }
            frame.draw(context, CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        return isDrawn ? IconPixels(bytes: bytes, width: size.width, height: size.height) : nil
    }

    private static func pixels(of image: CGImage) -> IconPixels? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = makeContext(width: image.width, height: image.height, data: buffer.baseAddress) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return isDrawn ? IconPixels(bytes: bytes, width: image.width, height: image.height) : nil
    }

    private static func makeImage(_ pixels: IconPixels) -> CGImage? {
        var bytes = pixels.bytes
        return bytes.withUnsafeMutableBytes { buffer in
            makeContext(width: pixels.width, height: pixels.height, data: buffer.baseAddress)?.makeImage()
        }
    }

    private static func makeContext(width: Int, height: Int, data: UnsafeMutableRawPointer?) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: data == nil ? 0 : width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws every frame anew at its final size rather than scaling down a picture, so that a vector stays as sharp as
    /// the display allows. All frames use one box, so that what moves stays in step.
    private static func makeStrip(
        _ decoded: Decoded, box: IconPixels.Box, analysis: (width: Int, height: Int), frameWidth: Int, frameHeight: Int
    ) -> CGImage? {
        guard
            let context = makeContext(width: frameWidth * decoded.frames.count, height: frameHeight, data: nil)
        else { return nil }
        let scaleX = Double(frameWidth) / Double(box.width)
        let scaleY = Double(frameHeight) / Double(box.height)
        // The box counts from the top, and a context counts from the bottom.
        let boxBottom = Double(analysis.height - box.y - box.height)
        for (index, frame) in decoded.frames.enumerated() {
            let cell = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: frameHeight)
            let canvas = CGRect(
                x: cell.minX - Double(box.x) * scaleX, y: -boxBottom * scaleY,
                width: Double(analysis.width) * scaleX, height: Double(analysis.height) * scaleY)
            context.saveGState()
            context.clip(to: cell)
            frame.draw(context, canvas)
            context.restoreGState()
        }
        return context.makeImage()
    }
}
