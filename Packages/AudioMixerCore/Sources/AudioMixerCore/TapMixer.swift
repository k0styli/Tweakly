import CoreAudio
import Synchronization

/// The gains, set on the main thread and read on the audio thread, each a 32-bit float in an atomic.
///
/// `@unchecked Sendable`: the storage is allocated once, holds only atomics, and is freed when the last reference, the
/// audio block's included, goes.
public final class GainBoard: @unchecked Sendable {
    public let count: Int
    private let values: UnsafeMutablePointer<Atomic<UInt32>>

    public init(_ gains: [Float]) {
        count = gains.count
        values = .allocate(capacity: max(gains.count, 1))
        for (index, gain) in gains.enumerated() { (values + index).initialize(to: Atomic(gain.bitPattern)) }
    }

    deinit {
        values.deinitialize(count: count)
        values.deallocate()
    }

    public func set(_ index: Int, _ gain: Float) {
        guard index >= 0, index < count else { return }
        values[index].store(gain.bitPattern, ordering: .relaxed)
    }

    public func get(_ index: Int) -> Float {
        Float(bitPattern: values[index].load(ordering: .relaxed))
    }
}

/// What the audio thread does each cycle: adds every tap's stereo sound to the output's first two channels, each through
/// its app's equalizer and at its gain moved smoothly from the last cycle (`GainRamp`), runs the output's own equalizer
/// over the sum, then keeps a sum that can pass full scale from clipping (`SoftLimiter`). Nothing here allocates, locks
/// or waits. It lives here, apart from Core Audio's devices, so that tests can run it on buffers of every shape an
/// output may have.
///
/// The taps' streams are the last of the aggregate device's inputs, after the output device's own, such as a headset's
/// microphone, whose number can change while it runs.
///
/// `@unchecked Sendable`: `ramps`, the scratch buffers and the peaks are touched only by the audio thread, which calls
/// `render` one cycle at a time; the main thread reads the peaks for tests alone.
public final class TapMixer: @unchecked Sendable {
    /// A tap's sound goes through its equalizer this many frames at a time, in buffers made once.
    static let chunk = 1024

    public let gains: GainBoard
    /// One for each tap, flat until its app has one.
    public let equalizers: [EqualizerProcessor]
    /// The output's own, over everything played on it.
    public let outputEqualizer: EqualizerProcessor
    private let ramps: UnsafeMutablePointer<GainRamp>
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    /// Whether to keep the peaks, which only tests read.
    private let meters: Bool
    public private(set) var inputPeak: Float = 0
    public private(set) var outputPeak: Float = 0

    public init(gains: [Float], sampleRate: Double = 48_000, meters: Bool = false) {
        self.gains = GainBoard(gains)
        self.meters = meters
        equalizers = gains.map { _ in EqualizerProcessor(sampleRate: sampleRate) }
        outputEqualizer = EqualizerProcessor(sampleRate: sampleRate)
        ramps = .allocate(capacity: max(gains.count, 1))
        for (index, gain) in gains.enumerated() { (ramps + index).initialize(to: GainRamp(gain)) }
        scratchLeft = .allocate(capacity: Self.chunk)
        scratchLeft.initialize(repeating: 0, count: Self.chunk)
        scratchRight = .allocate(capacity: Self.chunk)
        scratchRight.initialize(repeating: 0, count: Self.chunk)
    }

    deinit {
        ramps.deinitialize(count: gains.count)
        ramps.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    /// The output's rate, which every filter is drawn for. Main thread.
    public func setSampleRate(_ rate: Double) {
        equalizers.forEach { $0.setSampleRate(rate) }
        outputEqualizer.setSampleRate(rate)
    }

    /// The block the audio thread calls, made here so that it belongs to no actor: one formed on the main actor would
    /// check, on the audio thread, that it runs on the main thread, and stop the process.
    public func ioBlock() -> AudioDeviceIOBlock {
        { [self] _, input, _, output, _ in render(input: input, output: output) }
    }

    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // Up to two output channels, wherever they sit: one interleaved stream or two of one channel each.
        var left: (data: UnsafeMutablePointer<Float>, stride: Int)?
        var right: (data: UnsafeMutablePointer<Float>, stride: Int)?
        var frames = Int.max
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            if left == nil {
                left = (samples, channels)
                if channels > 1 { right = (samples + 1, channels) }
            } else if right == nil {
                right = (samples, channels)
            }
        }
        guard let left, frames != .max, frames > 0 else { return }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let firstTap = inputs.count - gains.count
        var peakIn: Float = 0
        // The loudest the sum can be against its sources: at most one app at most at full volume needs no limiter,
        // which would only bend the peaks of a loudly mastered song. An equalizer may raise anything, so with one at
        // work the limiter always watches.
        var totalGain: Float = 0
        var isEqualizing = false
        for tap in 0..<gains.count {
            let index = firstTap + tap
            guard index >= 0, index < inputs.count, let data = inputs[index].mData else { continue }
            let channels = max(Int(inputs[index].mNumberChannels), 1)
            let count = min(frames, Int(inputs[index].mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let source = data.assumingMemoryBound(to: Float.self)
            let target = gains.get(tap)
            totalGain += max(ramps[tap].current, target)
            let (first, step) = ramps[tap].begin(towards: target, frames: count)
            let equalizer = equalizers[tap]
            var done = 0
            while done < count {
                let length = min(Self.chunk, count - done)
                for frame in 0..<length {
                    let l = source[(done + frame) * channels]
                    scratchLeft[frame] = l
                    scratchRight[frame] = channels > 1 ? source[(done + frame) * channels + 1] : l
                }
                if meters {
                    for frame in 0..<length { peakIn = max(peakIn, abs(scratchLeft[frame]), abs(scratchRight[frame])) }
                }
                equalizer.process(
                    left: scratchLeft, leftStride: 1, right: scratchRight, rightStride: 1, frames: length)
                if !equalizer.isBypassed { isEqualizing = true }
                for frame in 0..<length {
                    let gain = first + step * Float(done + frame)
                    let l = scratchLeft[frame]
                    let r = scratchRight[frame]
                    let at = done + frame
                    if let right {
                        left.data[at * left.stride] += l * gain
                        right.data[at * right.stride] += r * gain
                    } else {
                        left.data[at * left.stride] += (l + r) * 0.5 * gain
                    }
                }
                done += length
            }
        }
        outputEqualizer.process(
            left: left.data, leftStride: left.stride, right: right?.data, rightStride: right?.stride ?? 0,
            frames: frames)
        if !outputEqualizer.isBypassed { isEqualizing = true }
        if totalGain > 1 || isEqualizing {
            for frame in 0..<frames {
                left.data[frame * left.stride] = SoftLimiter.limit(left.data[frame * left.stride])
                if let right { right.data[frame * right.stride] = SoftLimiter.limit(right.data[frame * right.stride]) }
            }
        }
        guard meters else { return }
        var peakOut: Float = 0
        for frame in 0..<frames {
            peakOut = max(peakOut, abs(left.data[frame * left.stride]))
            if let right { peakOut = max(peakOut, abs(right.data[frame * right.stride])) }
        }
        // Held for a moment and let fall slowly, as a level meter would.
        inputPeak = max(peakIn, inputPeak * 0.95)
        outputPeak = max(peakOut, outputPeak * 0.95)
    }
}
