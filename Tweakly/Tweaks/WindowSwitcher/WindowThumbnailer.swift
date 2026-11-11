import ImageIO
@preconcurrency import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers
import WindowSwitcherCore
import os

/// A window's picture, with what the tile needs to know about it worked out off the main thread.
nonisolated struct SwitcherPicture: Sendable {
    let image: CGImage
    let takenAt: ContinuousClock.Instant
    /// Of the part the label covers, from 0 to 1, or nil if it could not be read.
    let labelBackdropBrightness: CGFloat?
    let kept: SwitcherKeptPicture?
}

/// What stays of a picture once the picture itself is gone, for a tile to show at once when the panel opens. A real
/// picture lives outside this process and costs about 800 KB. Compressed it costs about 50 KB and can stay for as long
/// as its window does, with little to see lost at the size of a tile.
nonisolated struct SwitcherKeptPicture: Sendable {
    /// JPEG is about 1 ms each way on macOS 27.2. HEIC is half the size, but takes 40 ms and brings in a video codec that
    /// adds 15 MB to the process. Few windows get past the largest size, and they just lose a little more.
    private static let qualityWhenLarge = 0.6
    private static let largestSize = 100 * 1024

    let jpeg: Data
    let labelBackdropBrightness: CGFloat?

    init?(image: CGImage, quality: Double, labelBackdropBrightness: CGFloat?) {
        var compressed = Self.compress(image, quality: quality)
        if let first = compressed, first.count > Self.largestSize, quality > Self.qualityWhenLarge {
            compressed = Self.compress(image, quality: Self.qualityWhenLarge) ?? first
        }
        guard let compressed else { return nil }
        jpeg = compressed
        self.labelBackdropBrightness = labelBackdropBrightness
    }

    /// Unpacked now and not when the panel is drawn, so that the first frame is not held up, which takes about 1 ms.
    /// It holds the memory of a whole picture until a real one replaces it.
    var image: CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Unpacks several at once, on as many cores as there are, in the order given.
    nonisolated static func unpack(_ pictures: [SwitcherKeptPicture]) -> [CGImage?] {
        guard pictures.count > 1 else { return pictures.map(\.image) }
        let images = Mutex([CGImage?](repeating: nil, count: pictures.count))
        DispatchQueue.concurrentPerform(iterations: pictures.count) { index in
            let image = pictures[index].image
            images.withLock { $0[index] = image }
        }
        return images.withLock { $0 }
    }

    private static func compress(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Takes pictures of windows for the tiles. Runs only while the panel is on screen, so a quick Command-Tab
/// captures nothing and the system's recording indicator does not light up. On macOS 27.2 any way of capturing
/// lights it, the private ones too, and they need the same permission, so the public one is used.
nonisolated enum WindowThumbnailer {
    struct Request: Sendable {
        let window: CGWindowID
        let width: Int
        let height: Int
    }

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "switcher")

    /// Delivers each picture to the main actor as it arrives, or nil for a window that gave none, so that its tile
    /// stops waiting. Cancel the returned task to stop early.
    ///
    /// - Parameter keptQuality: how to compress the copy each picture leaves behind, or nil for no copy.
    static func capture(
        _ requests: [Request], atOnce: Int, keptQuality: Double?,
        deliver: @escaping @MainActor @Sendable (CGWindowID, SwitcherPicture?) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var windows: [CGWindowID: SCWindow] = [:]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                for window in content.windows { windows[window.windowID] = window }
            } catch {
                log.error("Could not list windows: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for request in requests {
                    if running == atOnce {
                        await group.next()
                        running -= 1
                    }
                    guard !Task.isCancelled else { break }
                    guard let window = windows[request.window] else {
                        await MainActor.run { deliver(request.window, nil) }
                        continue
                    }
                    running += 1
                    group.addTask {
                        let configuration = SCStreamConfiguration()
                        configuration.width = request.width
                        configuration.height = request.height
                        configuration.showsCursor = false
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        var image = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration)
                        if image == nil, !Task.isCancelled {
                            // On macOS 27.2 a full-screen window on another Space keeps its title bar in a child
                            // window, and that child fails the whole capture with an internal error. The window on
                            // its own works.
                            configuration.includeChildWindows = false
                            image = try? await SCScreenshotManager.captureImage(
                                contentFilter: filter, configuration: configuration)
                        }
                        guard !Task.isCancelled else { return }
                        let picture = image.map { picture(from: withoutEmptyEdges($0), keptQuality: keptQuality) }
                        await MainActor.run { deliver(request.window, picture) }
                    }
                }
            }
        }
    }

    /// Looks along one line through the middle each way, which is all it takes to see an empty edge.
    private static func withoutEmptyEdges(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let across = alphaLine(of: image, width: width, height: 1, origin: CGPoint(x: 0, y: -CGFloat(height) / 2))
        let down = alphaLine(of: image, width: 1, height: height, origin: CGPoint(x: -CGFloat(width) / 2, y: 0))
        let columns = across.flatMap { SwitcherPictureEdges.content(ofLine: $0) } ?? 0..<width
        let rows = down.flatMap { SwitcherPictureEdges.content(ofLine: $0) } ?? 0..<height
        guard columns.count < width || rows.count < height else { return image }
        let kept = CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
        return image.cropping(to: kept) ?? image
    }

    /// Top to bottom and left to right, as a picture's own coordinates go.
    private static func alphaLine(of image: CGImage, width: Int, height: Int, origin: CGPoint) -> [UInt8]? {
        var line = [UInt8](repeating: 0, count: width * height)
        let drawn = line.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
            return true
        }
        return drawn ? line : nil
    }

    private static func picture(from image: CGImage, keptQuality: Double?) -> SwitcherPicture {
        let brightness = brightnessOfBottomLeft(image)
        return SwitcherPicture(
            image: image, takenAt: .now, labelBackdropBrightness: brightness,
            kept: keptQuality.flatMap {
                SwitcherKeptPicture(image: image, quality: $0, labelBackdropBrightness: brightness)
            })
    }

    static func brightnessOfBottomLeft(_ image: CGImage) -> CGFloat? {
        let corner = CGRect(
            x: 0, y: CGFloat(image.height) * 0.75, width: CGFloat(image.width) * 0.5,
            height: CGFloat(image.height) * 0.25)
        guard let part = image.cropping(to: corner) else { return nil }
        var pixel: UInt8 = 0
        // The pointer is good only inside this closure, so the context has to finish its drawing here too.
        let drawn = withUnsafeMutableBytes(of: &pixel) { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? CGFloat(pixel) / 255 : nil
    }
}
