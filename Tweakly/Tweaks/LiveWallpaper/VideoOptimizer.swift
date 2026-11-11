import AVFoundation
import Accelerate
import AppKit
import LiveWallpaperCore
import VideoToolbox
import os

/// Converts wallpaper videos in the media engine, which decodes and encodes, so the processor does little. Two kinds of
/// conversion, each checked before it is kept:
/// - `optimize`, once per video, when `VideoOptimization` finds it would play more lightly: fewer frames, a smaller
///   picture or another codec. The result takes the original's place under the same name, so a display playing it goes
///   on with the old file until it next starts. Most videos stay as they came.
/// - `makeVariant`, for a display: a copy no larger than it asks for, with fewer frames too while economy mode is on,
///   next to the video, which stays as it is. See `PlaybackSize`.
enum VideoOptimizer {
    struct Result {
        let width: Int
        let height: Int
    }

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    /// The pixel sizes of the connected displays, which the video only has to fill.
    static var displays: [(width: Int, height: Int)] {
        WallpaperFolder.screens.map {
            (Int($0.frame.width * $0.backingScaleFactor), Int($0.frame.height * $0.backingScaleFactor))
        }
    }

    /// Nil when the file is already as light as it gets and stays as it is.
    static func optimize(
        fileNamed name: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result? {
        guard let url = WallpaperFolder.file(named: name) else { throw CocoaError(.fileNoSuchFile) }
        guard let video = try await Video(url: url),
            let plan = VideoOptimization.plan(for: video.source, displays: displays)
        else { return nil }
        let output = try await convert(video, plan: plan, progress: progress)
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
        log.info(
            "Optimized \(name, privacy: .public) to \(plan.width)×\(plan.height) at \(plan.framesPerSecond) fps")
        return Result(width: plan.width, height: plan.height)
    }

    /// A smaller copy for a display, with fewer frames too while economy mode is on and the video has frames to spare,
    /// made next to the video. Its name once it exists, or nil when the video needs no copy: as large as asked for,
    /// and slow enough already.
    static func makeVariant(
        fileNamed name: String, size: PixelSize?, economy: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        guard let url = WallpaperFolder.file(named: name) else { throw CocoaError(.fileNoSuchFile) }
        guard let video = try await Video(url: url) else { return nil }
        let rate = economy ? EconomyMode.frameRate(for: video.source.framesPerSecond) : nil
        guard size != nil || rate != nil else { return nil }
        let copyName = WallpaperVariant.name(for: name, size: size, economy: rate != nil)
        guard let target = WallpaperFolder.file(named: copyName) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: target.path) { return copyName }
        let plan = ConversionPlan(
            width: size?.width ?? video.source.width, height: size?.height ?? video.source.height,
            quality: rate == nil ? VideoOptimization.quality : EconomyMode.quality,
            framesPerSecond: rate ?? video.source.framesPerSecond)
        let output = try await convert(video, plan: plan, progress: progress)
        defer { try? FileManager.default.removeItem(at: output) }
        try FileManager.default.moveItem(at: output, to: target)
        log.info(
            "Made \(copyName, privacy: .public) at \(plan.width)×\(plan.height), \(plan.framesPerSecond) fps")
        return copyName
    }

    /// A video's track and what the plans need to know about it.
    private struct Video {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let duration: Double
        let source: VideoSource

        init?(url: URL) async throws {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (size, transform, formats, rate) = try await track.load(
                .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate)
            let turned = CGRect(origin: .zero, size: size).applying(transform)
            self.url = url
            self.asset = asset
            self.track = track
            self.transform = transform
            duration = try await asset.load(.duration).seconds
            source = VideoSource(
                codec: formats.first.map { VideoFacts.codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "",
                width: Int(abs(turned.width).rounded()), height: Int(abs(turned.height).rounded()),
                framesPerSecond: Double(rate))
        }
    }

    /// Encodes the video as planned into a temporary file, which the caller moves or removes. Only a result that plays,
    /// in the media engine and for as long, is returned.
    private static func convert(
        _ video: Video, plan: ConversionPlan, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // The encoder works in the track's own orientation, and the transform turns it as before.
        let isTurned = abs(video.transform.b) == 1 && abs(video.transform.c) == 1
        let encoded = isTurned ? (plan.height, plan.width) : (plan.width, plan.height)
        let fileType: AVFileType = video.url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "." + video.url.pathExtension)
        do {
            let conversion = try Conversion(
                asset: video.asset, track: video.track, transform: video.transform, output: output,
                fileType: fileType, size: encoded,
                isShrunk: plan.width * plan.height < video.source.width * video.source.height, plan: plan,
                sourceFrameRate: video.source.framesPerSecond, duration: video.duration, progress: progress)
            try await conversion.run()
            let facts = try await WallpaperImporter.facts(of: output)
            guard ImportCheck.problem(with: facts) == nil, abs(facts.duration - video.duration) < 0.25 else {
                log.error("Converted video did not check out: \(video.url.lastPathComponent, privacy: .public)")
                throw CocoaError(.fileReadCorruptFile)
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

/// One conversion: frames out of the reader, decoded by the media engine, into the writer, encoded by it.
///
/// `@unchecked Sendable`: the reader, writer and counters are touched only on `queue` once `run` starts, and the
/// initialiser runs before any of that.
nonisolated private final class Conversion: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.tweakly.Tweakly.optimize", qos: .utility)
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    /// Takes the frames this conversion shrinks itself, nil when the picture keeps its size.
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let scaler = FrameScaler()
    private let duration: Double
    /// Frames closer together than this are dropped, so that a faster source comes out at the planned rate.
    private let shortestGap: Double
    private let progress: @Sendable (Double) -> Void
    private var lastKept = -Double.infinity
    private var started = false
    /// The writer may ask for more once more after the end; the continuation must be resumed only once.
    private var isDone = false

    init(
        asset: AVAsset, track: AVAssetTrack, transform: CGAffineTransform, output: URL, fileType: AVFileType,
        size: (Int, Int), isShrunk: Bool, plan: ConversionPlan, sourceFrameRate: Double, duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        reader = try AVAssetReader(asset: asset)
        readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(readerOutput)
        writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.0,
            AVVideoHeightKey: size.1,
            AVVideoCompressionPropertiesKey: [
                // Constant quality rather than a bit rate: a rate low enough to save space left the first frames of
                // each loop soft, as the encoder had not found it yet.
                AVVideoQualityKey: plan.quality,
                AVVideoExpectedSourceFrameRateKey: plan.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                // Without frames out of order the decoder keeps fewer for reference: 193 against 207 MB for a 4K
                // copy. A conversion is only made to play more lightly, so the slightly larger file is no loss.
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // A shrunk picture is drawn by `FrameScaler` rather than the encoder's own scaler, which softened it.
        adaptor =
            isShrunk
            ? AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ]) : nil
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(writerInput)
        self.duration = max(duration, 0.001)
        shortestGap = plan.framesPerSecond < sourceFrameRate ? 1 / plan.framesPerSecond - 0.001 : 0
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.reader.startReading(), self.writer.startWriting() else {
                    continuation.resume(
                        throwing: self.reader.error ?? self.writer.error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                self.writerInput.requestMediaDataWhenReady(on: self.queue) {
                    self.pump(continuation)
                }
            }
        }
    }

    private func pump(_ continuation: CheckedContinuation<Void, Error>) {
        guard !isDone else { return }
        while writerInput.isReadyForMoreMediaData {
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                finish(continuation)
                return
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            guard time.seconds - lastKept >= shortestGap else { continue }
            lastKept = time.seconds
            guard append(sample, at: time) else {
                isDone = true
                reader.cancelReading()
                // As the remux does: a writer left open holds the file and its encoder.
                let error = writer.error ?? CocoaError(.fileWriteUnknown)
                writer.cancelWriting()
                continuation.resume(throwing: error)
                return
            }
            progress(min(1, time.seconds / duration))
        }
    }

    /// The frame as it came, or shrunk into one of the writer's buffers with the source's colour tags.
    private func append(_ sample: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let adaptor else { return writerInput.append(sample) }
        guard let frame = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { return false }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let shrunk = made,
            scaler.scale(frame, into: shrunk)
        else { return false }
        if let tags = CVBufferCopyAttachments(frame, .shouldPropagate) {
            CVBufferSetAttachments(shrunk, tags, .shouldPropagate)
        }
        return adaptor.append(shrunk, withPresentationTime: time)
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>) {
        isDone = true
        writerInput.markAsFinished()
        guard reader.status == .completed, started else {
            writer.cancelWriting()
            continuation.resume(throwing: reader.error ?? CocoaError(.fileReadCorruptFile))
            return
        }
        writer.finishWriting {
            if self.writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: self.writer.error ?? CocoaError(.fileWriteUnknown))
            }
        }
    }
}

/// Shrinks a video frame with Lanczos in vImage, the luma and the chroma planes each, on the processor: about 9 ms a 4K
/// frame on a MacBook Air M2, once per copy. Measured with a 4K wallpaper, each copy scaled back to
/// 4K and scored with VMAF against the original: at 3398, 2958, 2560 and 1920 wide vImage scored 97.4, 96.8, 96.0 and
/// 92.1, ffmpeg's Lanczos 94.2, 93.4, 92.0 and 87.3, and the encoder's own scaler 69.1, 92.4, 88.8 and 79.0. Core
/// Image's Lanczos shifted the colours.
///
/// `@unchecked Sendable`: used only on the conversion's queue, and its scratch memory only inside `scale`.
nonisolated private final class FrameScaler: @unchecked Sendable {
    private var scratch: [UnsafeMutableRawPointer?] = [nil, nil]
    private var scratchSizes = [0, 0]

    deinit {
        for buffer in scratch { buffer?.deallocate() }
    }

    func scale(_ source: CVPixelBuffer, into target: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(target) == 2 else { return false }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(target, [])
        }
        var lumaIn = plane(source, 0)
        var lumaOut = plane(target, 0)
        var chromaIn = plane(source, 1)
        var chromaOut = plane(target, 1)
        let flags = vImage_Flags(kvImageHighQualityResampling)
        guard
            let lumaScratch = scratch(
                0, vImageScale_Planar8(&lumaIn, &lumaOut, nil, flags | vImage_Flags(kvImageGetTempBufferSize))),
            let chromaScratch = scratch(
                1, vImageScale_CbCr8(&chromaIn, &chromaOut, nil, flags | vImage_Flags(kvImageGetTempBufferSize)))
        else { return false }
        return vImageScale_Planar8(&lumaIn, &lumaOut, lumaScratch, flags) == kvImageNoError
            && vImageScale_CbCr8(&chromaIn, &chromaOut, chromaScratch, flags) == kvImageNoError
    }

    private func plane(_ buffer: CVPixelBuffer, _ index: Int) -> vImage_Buffer {
        vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(buffer, index),
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, index)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, index)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, index))
    }

    /// Scratch memory for one plane, kept between frames, or nil when vImage could not say how much it needs.
    private func scratch(_ index: Int, _ needed: vImage_Error) -> UnsafeMutableRawPointer? {
        guard needed >= 0 else { return nil }
        let size = max(Int(needed), 1)
        if scratchSizes[index] < size {
            scratch[index]?.deallocate()
            scratch[index] = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
            scratchSizes[index] = size
        }
        return scratch[index]
    }
}
