import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperCore
import UniformTypeIdentifiers
import os

/// A smaller copy of a picture or a video's still for a display, next to it, as the system's wallpaper service holds
/// what it is given: an 8K picture took it 141 MB against 127 MB for one the size of the panel. Only files the
/// sandboxed cleaner wrote are read here. See `PlaybackSize`.
enum PictureVariant {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    /// The copy's name once it exists, or nil when the picture is no larger than the size by much.
    static func make(fileNamed name: String, size: PixelSize) async throws -> String? {
        let copyName = WallpaperVariant.name(for: name, size: size, economy: false)
        guard let source = WallpaperFolder.file(named: name), let target = WallpaperFolder.file(named: copyName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: target.path) { return copyName }
        let made = try await Task.detached(priority: .utility) { try shrink(source, to: target, size: size) }.value
        guard made else { return nil }
        log.info("Made \(copyName, privacy: .public)")
        return copyName
    }

    /// Draws the picture anew at the size with Lanczos in vImage, in its own colours and format. On a still of a 4K
    /// wallpaper shrunk to a MacBook Air's panel and scored with VMAF against the original, vImage scored 95.9,
    /// as ffmpeg's Lanczos did, and Core Graphics at its highest quality 94.0.
    nonisolated private static func shrink(_ source: URL, to target: URL, size: PixelSize) throws -> Bool {
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(file),
            let image = CGImageSourceCreateImageAtIndex(file, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        // Enough to cover the size, which was worked out for the same shape, so the system never stretches it.
        let scale = max(Double(size.width) / Double(image.width), Double(size.height) / Double(image.height))
        guard scale <= 1 - WallpaperSizing.smallestSaving / 2 else { return false }
        let width = max(2, Int((Double(image.width) * scale).rounded()))
        let height = max(2, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
            var format = vImage_CGImageFormat(
                bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        else { throw CocoaError(.fileWriteUnknown) }
        var whole = vImage_Buffer()
        var shrunk = vImage_Buffer()
        defer {
            free(whole.data)
            free(shrunk.data)
        }
        guard vImageBuffer_InitWithCGImage(&whole, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
            vImageBuffer_Init(
                &shrunk, vImagePixelCount(height), vImagePixelCount(width), 32, vImage_Flags(kvImageNoFlags))
                == kvImageNoError,
            vImageScale_ARGB8888(&whole, &shrunk, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError,
            let picture = vImageCreateCGImageFromBuffer(
                &shrunk, &format, nil, nil, vImage_Flags(kvImageNoFlags), nil)?.takeRetainedValue()
        else { throw CocoaError(.fileWriteUnknown) }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).\(target.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] =
            UTType(type as String) == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: temporary, to: target)
        return true
    }
}
