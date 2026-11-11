import CoreGraphics
import CustomIconCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An icon ready to show: its frames, all of the same size.
struct LoadedIcon {
    let manifest: IconManifest
    let frames: [CGImage]
}

/// The icons that come with the app and the ones people added, each a strip of frames and what is known about them.
/// Only what the importer made ever gets here, so the agent reads nothing but plain PNGs of a known size, and a file
/// someone chose has already been through the window's process, which can afford to crash on it.
nonisolated enum IconLibrary {
    /// Made ahead by the importer from the original drawings. They live in the
    /// bundle, so nothing is written or kept until one is chosen, and like the system's own choices they cannot be
    /// deleted. The ids are fixed because preferences remember the choice by id.
    private struct BuiltIn {
        let id: String
        let resource: String
        let name: String
    }

    private static let builtIns = [
        BuiltIn(
            id: "4AF7705B-4811-465B-A908-F1C3CBBC73DD", resource: "cat-sit-left",
            name: String(localized: "Sitting, Left")),
        BuiltIn(
            id: "F028D438-08F1-4C29-B290-13F0C5AC6359", resource: "cat-sit-right",
            name: String(localized: "Sitting, Right")),
        BuiltIn(
            id: "EF0D7799-53DD-4217-9A0C-6DA6460EA35C", resource: "cat-play-left",
            name: String(localized: "Playing, Left")),
        BuiltIn(
            id: "AB0512D9-363C-469D-BA0A-0A611C2B442E", resource: "cat-play-right",
            name: String(localized: "Playing, Right")),
    ]

    private static let framesFile = "frames.png"
    private static let manifestFile = "icon.json"

    /// In a folder named for the bundle, so that a test copy has a library of its own.
    private static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tweakly", isDirectory: true)
            .appendingPathComponent("Icons", isDirectory: true)
    }

    /// The app's own first, then the added ones oldest first, so that an icon keeps its place in the grid and a new
    /// one goes last.
    static func all() -> [IconManifest] {
        builtIns.compactMap { manifest(id: $0.id) } + added()
    }

    private static func added() -> [IconManifest] {
        guard let folder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return names.filter { !isBuiltIn(id: $0) }.compactMap(manifest(id:)).sorted { $0.added < $1.added }
    }

    static func isBuiltIn(id: String) -> Bool {
        builtIns.contains { $0.id == id }
    }

    static func manifest(id: String) -> IconManifest? {
        guard let url = files(ofIcon: id)?.manifest,
            let data = try? Data(contentsOf: url),
            var manifest = try? JSONDecoder().decode(IconManifest.self, from: data),
            manifest.isValid, manifest.id == id
        else { return nil }
        // The name in the file is the same in every language.
        if let builtIn = builtIns.first(where: { $0.id == id }) { manifest.name = builtIn.name }
        return manifest
    }

    /// Nil if anything about it is off, in which case the gear stands in rather than anything going wrong.
    static func load(id: String) -> LoadedIcon? {
        guard let manifest = manifest(id: id),
            let url = files(ofIcon: id)?.frames,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let strip = CGImageSourceCreateImageAtIndex(source, 0, nil),
            strip.width == manifest.frameWidth * manifest.frameCount, strip.height == manifest.frameHeight,
            let decoded = decoded(strip)
        else { return nil }
        // Crops share one bitmap, and an image that is decoded now does not get decoded again on its way to the screen.
        let frames = (0..<manifest.frameCount).compactMap { index in
            decoded.cropping(
                to: CGRect(
                    x: index * manifest.frameWidth, y: 0, width: manifest.frameWidth, height: manifest.frameHeight))
        }
        guard frames.count == manifest.frameCount else { return nil }
        return LoadedIcon(manifest: manifest, frames: frames)
    }

    static func add(_ manifest: IconManifest, strip: CGImage) throws {
        guard let folder = iconFolder(id: manifest.id) else { throw IconFileError.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let frames = folder.appendingPathComponent(framesFile)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    frames as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw IconFileError.unreadable }
            CGImageDestinationAddImage(destination, strip, nil)
            guard CGImageDestinationFinalize(destination) else { throw IconFileError.unreadable }
            // Last, so that a folder with a manifest always has its frames.
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(manifestFile), options: .atomic)
        } catch {
            // Without a manifest nothing would ever list this folder, or remove it.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func delete(id: String) {
        guard !isBuiltIn(id: id), let folder = iconFolder(id: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func files(ofIcon id: String) -> (manifest: URL, frames: URL)? {
        if let builtIn = builtIns.first(where: { $0.id == id }) {
            guard let manifest = Bundle.main.url(forResource: builtIn.resource, withExtension: "json"),
                let frames = Bundle.main.url(forResource: builtIn.resource, withExtension: "png")
            else { return nil }
            return (manifest, frames)
        }
        guard let folder = iconFolder(id: id) else { return nil }
        return (folder.appendingPathComponent(manifestFile), folder.appendingPathComponent(framesFile))
    }

    /// Only an id made here names a folder, so that a value in preferences cannot point anywhere else.
    private static func iconFolder(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return folder?.appendingPathComponent(id, isDirectory: true)
    }

    private static func decoded(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
