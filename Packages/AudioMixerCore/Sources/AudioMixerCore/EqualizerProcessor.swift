import Foundation
import Synchronization

/// The equalizer as the audio thread runs it on up to two channels. The main thread says what it should be, filter
/// gains already solved (`EqualizerFilter.filterGains`); the audio thread glides there and recomputes only the bands
/// that move. While everything is at 0 dB it does not touch the sound at all.
///
/// `@unchecked Sendable`: the shared values are atomics allocated once. Everything else is touched by the audio
/// thread alone, one cycle at a time, except `settings` and `sampleRate`, which only the main thread uses.
public final class EqualizerProcessor: @unchecked Sendable {
    /// How fast a gain glides, so that a dragged slider or a new preset neither clicks nor buzzes: the whole range in
    /// a fifth of a second.
    public static let decibelsPerSecond = 120.0
    /// A literal, not the array's count: the audio thread reads it every cycle.
    static let bandCount = 10
    /// A band back at 0 dB keeps running while what it holds dies away, below this, which takes a few tens of
    /// milliseconds for the lowest band: dropping it sooner would leave a step in the sound.
    private static let silentMemory = 1e-7

    // Shared: Double bit patterns, written by the main thread, read by the audio thread.
    private let wantedGainBits: UnsafeMutablePointer<Atomic<UInt64>>
    private let wantedPreampBits = Atomic<UInt64>(0)
    private let sampleRateBits: Atomic<UInt64>
    private let generation = Atomic<UInt32>(0)

    // The main thread's.
    public private(set) var settings = EqualizerSettings.flat
    public private(set) var sampleRate: Double

    // The audio thread's.
    private var seenGeneration: UInt32 = .max
    private var rate: Double
    private let gains: UnsafeMutablePointer<Double>
    private let wanted: UnsafeMutablePointer<Double>
    private var preamp: Double = 1
    private var wantedPreamp: Double = 1
    private let filters: UnsafeMutablePointer<Biquad>
    private let tails: UnsafeMutablePointer<Int>
    /// Two numbers a band for each channel.
    private let memory: UnsafeMutablePointer<Double>
    private let active: UnsafeMutablePointer<Int>
    private var activeCount = 0
    /// The bands' frequencies, copied once, so the audio thread never touches a Swift array.
    private let centres: UnsafeMutablePointer<Double>

    public init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        self.rate = rate
        sampleRateBits = Atomic(rate.bitPattern)
        let count = Self.bandCount
        wantedGainBits = .allocate(capacity: count)
        for index in 0..<count { (wantedGainBits + index).initialize(to: Atomic(Double(0).bitPattern)) }
        gains = .allocate(capacity: count)
        gains.initialize(repeating: 0, count: count)
        wanted = .allocate(capacity: count)
        wanted.initialize(repeating: 0, count: count)
        filters = .allocate(capacity: count)
        filters.initialize(repeating: .identity, count: count)
        tails = .allocate(capacity: count)
        tails.initialize(repeating: 0, count: count)
        memory = .allocate(capacity: count * 4)
        memory.initialize(repeating: 0, count: count * 4)
        active = .allocate(capacity: count)
        active.initialize(repeating: 0, count: count)
        centres = .allocate(capacity: count)
        for (index, frequency) in EqualizerSettings.frequencies.enumerated() {
            (centres + index).initialize(to: frequency)
        }
    }

    deinit {
        let count = Self.bandCount
        wantedGainBits.deinitialize(count: count)
        wantedGainBits.deallocate()
        gains.deallocate()
        wanted.deallocate()
        filters.deallocate()
        tails.deallocate()
        memory.deallocate()
        active.deallocate()
        centres.deallocate()
    }

    // MARK: The main thread

    /// What to sound like from now on. The bands' filters are solved here, not on the audio thread.
    public func set(_ newSettings: EqualizerSettings) {
        settings = newSettings.sanitized
        publish()
    }

    /// The output's rate changed, which moves every filter.
    public func setSampleRate(_ newRate: Double) {
        guard newRate.isFinite, newRate > 0, newRate != sampleRate else { return }
        sampleRate = newRate
        publish()
    }

    private func publish() {
        let filterGains = EqualizerFilter.filterGains(for: settings.bands, sampleRate: sampleRate)
        for index in 0..<Self.bandCount {
            wantedGainBits[index].store(filterGains[index].bitPattern, ordering: .relaxed)
        }
        wantedPreampBits.store(settings.preamp.bitPattern, ordering: .relaxed)
        sampleRateBits.store(sampleRate.bitPattern, ordering: .relaxed)
        generation.add(1, ordering: .releasing)
    }

    // MARK: The audio thread

    /// Whether the last cycle left the sound untouched.
    public private(set) var isBypassed = true

    /// Runs the equalizer in place over one cycle of up to two channels, each with its own stride between frames.
    public func process(
        left: UnsafeMutablePointer<Float>, leftStride: Int, right: UnsafeMutablePointer<Float>?, rightStride: Int,
        frames: Int
    ) {
        guard frames > 0 else { return }
        takeNewSettings()
        let step = Self.decibelsPerSecond * Double(frames) / rate
        activeCount = 0
        var moving = false
        for band in 0..<Self.bandCount {
            if gains[band] != wanted[band] {
                let difference = wanted[band] - gains[band]
                gains[band] = abs(difference) <= step ? wanted[band] : gains[band] + (difference > 0 ? step : -step)
                filters[band] = EqualizerFilter.peaking(frequency: centres[band], gain: gains[band], sampleRate: rate)
                moving = true
            }
            // `tails` counts the frames a band at 0 dB may still run, a second at most, in case its memory never
            // settles below `silentMemory`.
            if gains[band] != 0 {
                tails[band] = Int(rate)
            } else if tails[band] <= 0 {
                continue
            }
            active[activeCount] = band
            activeCount += 1
        }
        let startPreamp = preamp
        preamp = wantedPreamp
        isBypassed = activeCount == 0 && startPreamp == 1 && wantedPreamp == 1 && !moving
        guard !isBypassed else { return }
        let preampStep = (wantedPreamp - startPreamp) / Double(frames)
        run(left, stride: leftStride, frames: frames, channel: 0, preamp: startPreamp, preampStep: preampStep)
        if let right {
            run(right, stride: rightStride, frames: frames, channel: 1, preamp: startPreamp, preampStep: preampStep)
        }
        // A band back at 0 dB stops once what it holds has died away, and only then forgets it.
        for index in 0..<activeCount {
            let band = active[index]
            guard gains[band] == 0 else { continue }
            tails[band] -= frames
            var loudest = 0.0
            for slot in 0..<4 { loudest = max(loudest, abs(memory[band * 4 + slot])) }
            if loudest < Self.silentMemory || tails[band] <= 0 {
                tails[band] = 0
                clearMemory(of: band)
            }
        }
    }

    private func takeNewSettings() {
        let current = generation.load(ordering: .acquiring)
        guard current != seenGeneration else { return }
        seenGeneration = current
        for band in 0..<Self.bandCount {
            let value = Double(bitPattern: wantedGainBits[band].load(ordering: .relaxed))
            wanted[band] = value.isFinite ? value : 0
        }
        let decibels = Double(bitPattern: wantedPreampBits.load(ordering: .relaxed))
        wantedPreamp = decibels.isFinite ? pow(10, decibels / 20) : 1
        let newRate = Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
        if newRate.isFinite, newRate > 0, newRate != rate {
            rate = newRate
            // Every filter is drawn again for the new rate, from where it is now.
            for band in 0..<Self.bandCount {
                filters[band] = EqualizerFilter.peaking(frequency: centres[band], gain: gains[band], sampleRate: rate)
            }
        }
    }

    /// Transposed direct form II, in double precision: a 32 Hz band at 96 kHz has its poles very near the unit circle.
    private func run(
        _ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int, preamp: Double,
        preampStep: Double
    ) {
        var gain = preamp
        for frame in 0..<frames {
            gain += preampStep
            var x = Double(samples[frame * stride]) * gain
            for index in 0..<activeCount {
                let band = active[index]
                let filter = filters[band]
                let state = memory + (band * 4 + channel * 2)
                let y = filter.b0 * x + state[0]
                state[0] = filter.b1 * x - filter.a1 * y + state[1]
                state[1] = filter.b2 * x - filter.a2 * y
                x = y
            }
            samples[frame * stride] = Float(x)
        }
        // What dies away below hearing is cleared, and anything that is not a number starts again from silence.
        for index in 0..<activeCount {
            let state = memory + (active[index] * 4 + channel * 2)
            for slot in 0..<2 where !state[slot].isFinite || abs(state[slot]) < 1e-20 { state[slot] = 0 }
        }
    }

    private func clearMemory(of band: Int) {
        for slot in 0..<4 { memory[band * 4 + slot] = 0 }
    }
}
