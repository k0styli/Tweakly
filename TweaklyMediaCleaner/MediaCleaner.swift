import AVFoundation
import Darwin
import ImageIO
import LiveWallpaperCore
import UniformTypeIdentifiers
import VideoToolbox
import os

/// Checks one file and writes it anew in its job folder. Everything a later reader parses comes from here: a picture's
/// pixels, decoded and written as PNG without metadata, and a video's compressed frames in a container written by
/// AVFoundation, with a format description holding only the decoder's parameters and the colour it says.
enum MediaCleaner {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "media-cleaner")

    /// The inbox in the real home folder. Inside the sandbox the home folder calls name the container instead.
    static var inbox: String {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return "" }
        return String(cString: home) + "/" + MediaInbox.homeRelativePath
    }

    static func clean(_ data: Data) async -> CleanReply {
        guard let request = try? JSONDecoder().decode(CleanRequest.self, from: data),
            MediaInbox.isJobFolder(request.folder, inbox: inbox), MediaInbox.isPlainName(request.input)
        else { return .refused(.couldNotCheck) }
        let folder = URL(fileURLWithPath: request.folder, isDirectory: true)
        #if TWEAKLY_AUTOMATION
            if request.input == "sandbox-probe" { return await SandboxProbe.run(in: folder) }
        #endif
        let input = folder.appendingPathComponent(request.input)
        // A plain file read where it is, never through a link that could lead somewhere else.
        var info = stat()
        guard lstat(input.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .refused(.unsupported) }
        guard Int64(info.st_size) <= MediaInbox.largestFile else { return .refused(.tooLarge) }
        guard let header = readHeader(of: input), let sniffed = SniffedMedia.sniff(header) else {
            return .refused(.unsupported)
        }
        // The readers pick their parser by the extension, so the file gets the one its bytes call for.
        let source = folder.appendingPathComponent("source." + sniffed.fileExtension)
        do {
            try FileManager.default.moveItem(at: input, to: source)
            switch sniffed.kind {
            case .picture: return try cleanPicture(source, sniffed: sniffed, in: folder, request: request)
            case .video: return try await cleanVideo(source, sniffed: sniffed, in: folder, request: request)
            }
        } catch let problem as ImportProblem {
            return .refused(problem)
        } catch {
            log.error("Could not clean a file: \(error.localizedDescription, privacy: .public)")
            return .refused(.couldNotCheck)
        }
    }

    private static func readHeader(of url: URL) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: SniffedMedia.headerLength)).map { Array($0) }
    }

    // MARK: Pictures

    private static func cleanPicture(
        _ url: URL, sniffed: SniffedMedia, in folder: URL, request: CleanRequest
    ) throws -> CleanReply {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?, sniffed.imageTypes.contains(type),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImportProblem.unsupported }
        // The size the file claims, before a single pixel is decoded.
        if let problem = ImportCheck.problem(withPictureWidth: width, height: height) { throw problem }
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw ImportProblem.unplayable }
        // PNG keeps every pixel. No properties are passed, so nothing of the original file but its colour profile,
        // which belongs to the pixels, goes into the new one.
        let clean = folder.appendingPathComponent("clean.png")
        try write(image, as: .png, to: clean)
        try write(
            scaled(image, longestSide: request.thumbnailWidth), as: .jpeg, quality: 0.8, to: thumbnail(in: folder))
        return .cleaned(
            CleanedMedia(
                kind: .picture, fileName: clean.lastPathComponent, stillName: nil, thumbnailName: "thumbnail.jpg",
                width: image.width, height: image.height))
    }

    // MARK: Videos

    private static func cleanVideo(
        _ url: URL, sniffed: SniffedMedia, in folder: URL, request: CleanRequest
    ) async throws -> CleanReply {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = try await VideoFile(asset)
        if let problem = ImportCheck.problem(with: video.facts) { throw problem }
        guard SniffedMedia.videoCodecs.contains(video.facts.codec) else {
            throw ImportProblem.needsSoftwareDecoding(codec: video.facts.codec)
        }
        let fileType: AVFileType = sniffed.format == .quickTime ? .mov : .mp4
        let clean = folder.appendingPathComponent(fileType == .mov ? "clean.mov" : "clean.mp4")
        try await Remux(video, to: clean, fileType: fileType).run()
        // The new file must play as the old one did, for as long.
        let result = try await VideoFile(AVURLAsset(url: clean))
        guard ImportCheck.problem(with: result.facts) == nil, abs(result.facts.duration - video.facts.duration) < 0.25
        else { throw ImportProblem.couldNotCheck }
        let generator = AVAssetImageGenerator(asset: result.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let frame = try await generator.image(at: .zero).image
        try write(
            scaled(frame, longestSide: request.stillLongestSide), as: .jpeg, quality: 0.9,
            to: folder.appendingPathComponent("still.jpg"))
        try write(
            scaled(frame, longestSide: request.thumbnailWidth), as: .jpeg, quality: 0.8, to: thumbnail(in: folder))
        return .cleaned(
            CleanedMedia(
                kind: .video, fileName: clean.lastPathComponent, stillName: "still.jpg", thumbnailName: "thumbnail.jpg",
                width: result.facts.width, height: result.facts.height, duration: result.facts.duration))
    }

    // MARK: Writing

    private static func thumbnail(in folder: URL) -> URL { folder.appendingPathComponent("thumbnail.jpg") }

    private static func write(_ image: CGImage, as type: UTType, quality: Double = 1, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let options = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func scaled(_ image: CGImage, longestSide: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longestSide else { return image }
        let factor = Double(longestSide) / Double(longest)
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}

/// A video's track and what the checks need to know about it.
struct VideoFile {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let transform: CGAffineTransform
    let format: CMFormatDescription
    let facts: VideoFacts

    init(_ asset: AVURLAsset) async throws {
        let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportProblem.unsupported
        }
        let (size, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        guard let format = formats.first else { throw ImportProblem.unplayable }
        let codecType = CMFormatDescriptionGetMediaSubType(format)
        let turned = CGRect(origin: .zero, size: size).applying(transform)
        self.asset = asset
        self.track = track
        self.transform = transform
        self.format = format
        facts = VideoFacts(
            hasVideo: true, isPlayable: playable, isProtected: protected, codec: VideoFacts.codecName(codecType),
            isHardwareDecoded: VTIsHardwareDecodeSupported(codecType), width: Int(abs(turned.width).rounded()),
            height: Int(abs(turned.height).rounded()), duration: duration.seconds)
    }

}

/// Copies a video's compressed frames, untouched, into a new file with the video track alone: no sound, no subtitles,
/// no metadata, no atoms of the original but the decoder's parameters. The picture stays exactly as it was.
///
/// `@unchecked Sendable`: the reader, writer and counters are touched only on `queue` once `run` starts, and the
/// initialiser runs before any of that.
nonisolated final class Remux: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.tweakly.Tweakly.remux", qos: .utility)
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMFormatDescription
    private var started = false
    /// The writer may ask for more once more after the end; the continuation must be resumed only once.
    private var isDone = false

    /// Extension keys a format description keeps: how the colour and pixel shape are meant, which the picture needs.
    private static var keptExtensions: [CFString] {
        [
            kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_FullRangeVideo,
            kCMFormatDescriptionExtension_PixelAspectRatio, kCMFormatDescriptionExtension_Depth,
        ]
    }
    /// The atoms with the decoder's parameters, the one part of the sample description it cannot do without.
    private static let keptAtoms = ["avcC", "hvcC"]

    init(_ video: VideoFile, to url: URL, fileType: AVFileType) throws {
        format = try Self.cleanFormat(video.format)
        reader = try AVAssetReader(asset: video.asset)
        output = AVAssetReaderTrackOutput(track: video.track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportProblem.couldNotCheck }
        reader.add(output)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = false
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.transform = video.transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ImportProblem.couldNotCheck }
        writer.add(input)
    }

    /// A new description of the same codec and size, from the decoder's parameters and the colour alone.
    private static func cleanFormat(_ original: CMFormatDescription) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [:]
        for key in keptExtensions {
            if let value = CMFormatDescriptionGetExtension(original, extensionKey: key) { extensions[key] = value }
        }
        let atoms =
            CMFormatDescriptionGetExtension(
                original, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any] ?? [:]
        let kept = atoms.filter { keptAtoms.contains($0.key) && $0.value is Data }
        guard !kept.isEmpty else { throw ImportProblem.couldNotCheck }
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = kept
        let dimensions = CMVideoFormatDescriptionGetDimensions(original)
        var clean: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(original), width: dimensions.width,
            height: dimensions.height, extensions: extensions as CFDictionary, formatDescriptionOut: &clean)
        guard status == noErr, let clean else { throw ImportProblem.couldNotCheck }
        return clean
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.reader.startReading(), self.writer.startWriting() else {
                    continuation.resume(throwing: self.reader.error ?? self.writer.error ?? ImportProblem.couldNotCheck)
                    return
                }
                self.input.requestMediaDataWhenReady(on: self.queue) {
                    self.pump(continuation)
                }
            }
        }
    }

    private func pump(_ continuation: CheckedContinuation<Void, Error>) {
        guard !isDone else { return }
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                finish(continuation)
                return
            }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            guard let rewrapped = rewrap(sample) else {
                fail(continuation)
                return
            }
            if !started {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                started = true
            }
            guard input.append(rewrapped) else {
                fail(continuation)
                return
            }
        }
    }

    /// The same compressed bytes and timing under the clean description, with the attachments that mark key frames.
    private func rewrap(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let count = CMSampleBufferGetNumSamples(sample)
        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: timingCount, arrayToFill: &timing, entriesNeededOut: &timingCount)
        var sizeCount: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: sizeCount)
        CMSampleBufferGetSampleSizeArray(
            sample, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: count,
            sampleTimingEntryCount: timingCount, sampleTimingArray: timing, sampleSizeEntryCount: sizeCount,
            sampleSizeArray: sizes, sampleBufferOut: &result)
        guard status == noErr, let result else { return nil }
        Self.copySampleAttachments(from: sample, to: result)
        return result
    }

    private static var keptSampleAttachments: [CFString] {
        [
            kCMSampleAttachmentKey_NotSync, kCMSampleAttachmentKey_PartialSync, kCMSampleAttachmentKey_DependsOnOthers,
            kCMSampleAttachmentKey_IsDependedOnByOthers, kCMSampleAttachmentKey_EarlierDisplayTimesAllowed,
        ]
    }

    private static func copySampleAttachments(from source: CMSampleBuffer, to target: CMSampleBuffer) {
        guard
            let from = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) as? [[CFString: Any]],
            let to = CMSampleBufferGetSampleAttachmentsArray(target, createIfNecessary: true)
        else { return }
        for (index, attachments) in from.enumerated() where index < CFArrayGetCount(to) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(to, index), to: CFMutableDictionary.self)
            for key in keptSampleAttachments {
                guard let value = attachments[key] else { continue }
                CFDictionarySetValue(
                    dictionary, Unmanaged.passUnretained(key).toOpaque(),
                    Unmanaged.passUnretained(value as AnyObject).toOpaque())
            }
        }
    }

    private func fail(_ continuation: CheckedContinuation<Void, Error>) {
        isDone = true
        reader.cancelReading()
        writer.cancelWriting()
        continuation.resume(throwing: writer.error ?? ImportProblem.couldNotCheck)
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>) {
        isDone = true
        input.markAsFinished()
        guard reader.status == .completed, started else {
            writer.cancelWriting()
            continuation.resume(throwing: reader.error ?? ImportProblem.couldNotCheck)
            return
        }
        writer.finishWriting {
            if self.writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: self.writer.error ?? ImportProblem.couldNotCheck)
            }
        }
    }
}

#if TWEAKLY_AUTOMATION
    /// For tests only: tries what the sandbox must forbid and writes down what happened, in the job's folder.
    enum SandboxProbe {
        static func run(in folder: URL) async -> CleanReply {
            var lines: [String] = []
            let home = (MediaCleaner.inbox as NSString).deletingLastPathComponent
                .replacingOccurrences(of: "/Library/Caches", with: "")
            let preferences = home + "/Library/Preferences/.GlobalPreferences.plist"
            lines.append("read preferences: \(FileManager.default.contents(atPath: preferences) != nil)")
            let desktop = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Desktop")) != nil
            lines.append("list desktop: \(desktop)")
            lines.append(
                "write /tmp: \(FileManager.default.createFile(atPath: "/tmp/tweakly-probe", contents: Data()))")
            lines.append(
                "write home: \(FileManager.default.createFile(atPath: home + "/tweakly-probe", contents: Data()))")
            var network = "no"
            if let url = URL(string: "https://www.apple.com") {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 5
                if let (_, response) = try? await URLSession(configuration: configuration).data(from: url) {
                    network = "yes \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                }
            }
            lines.append("network: \(network)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            process.arguments = [home + "/tweakly-probe-run"]
            let ran = (try? process.run()) != nil
            process.waitUntilExit()
            lines.append(
                "run a program: \(ran) wrote: \(FileManager.default.fileExists(atPath: home + "/tweakly-probe-run"))")
            lines.append(
                "write inbox: \(FileManager.default.createFile(atPath: folder.path + "/probe-ok", contents: Data()))")
            try? lines.joined(separator: "\n").write(
                to: folder.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            return .refused(.couldNotCheck)
        }
    }
#endif
