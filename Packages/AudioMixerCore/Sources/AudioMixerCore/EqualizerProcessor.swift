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
    /// The most a gain moves in one cycle, whatever its length: each band's coefficients change once a cycle, and a
    /// cycle of 4096 frames would otherwise step 10 dB at once. Cycles of up to 512 frames glide at the full speed.
    static let largestStepPerCycle = 1.5
    /// A literal, not the array's count: the audio thread reads it every cycle.
    static let bandCount = 10
    /// A band back at 0 dB keeps running while what it holds dies away, below this, which takes a few tens of
    /// milliseconds for the lowest band: dropping it sooner would leave a step in the sound.
    private static let silentMemory = 1e-7

    // Shared: Double bit patterns, written by the main thread, read by the audio thread.
    private let wantedGainBits: UnsafeMutablePointer<Atomic<UInt64>>
    private let wantedPreampBits = Atomic<UInt64>(0)
    /// Whether the sliders raise any band above 0 dB, preamp included.
    private let raises = Atomic<Bool>(false)
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
    /// The preamp as a factor and in decibels, gliding in decibels at the bands' speed.
    private var preamp: Double = 1
    private var preampDecibels: Double = 0
    private var wantedPreampDecibels: Double = 0
    /// Whether the sliders now raise anything, and whether anything since the gains last stood still did: a glide
    /// between two settings that only cut never raises.
    private var raisesNow = false
    private var glideMayRaise = false
    private let filters: UnsafeMutablePointer<Biquad>
    private let tails: UnsafeMutablePointer<Int>
    /// Each band's two numbers of memory, the left channel's and the right's side by side.
    private let memory1: UnsafeMutablePointer<SIMD2<Double>>
    private let memory2: UnsafeMutablePointer<SIMD2<Double>>
    private let active: UnsafeMutablePointer<Int>
    private var activeCount = 0
    /// The bands at work this cycle, their coefficients and memory side by side, so each frame walks them in order.
    private let packedFilters: UnsafeMutablePointer<Biquad>
    private let packed1: UnsafeMutablePointer<SIMD2<Double>>
    private let packed2: UnsafeMutablePointer<SIMD2<Double>>
    /// This cycle's preamp, gliding from where it was.
    private var cycleGain = 1.0
    private var cycleGainStep = 0.0
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
        memory1 = .allocate(capacity: count)
        memory1.initialize(repeating: .zero, count: count)
        memory2 = .allocate(capacity: count)
        memory2.initialize(repeating: .zero, count: count)
        active = .allocate(capacity: count)
        active.initialize(repeating: 0, count: count)
        packedFilters = .allocate(capacity: count)
        packedFilters.initialize(repeating: .identity, count: count)
        packed1 = .allocate(capacity: count)
        packed1.initialize(repeating: .zero, count: count)
        packed2 = .allocate(capacity: count)
        packed2.initialize(repeating: .zero, count: count)
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
        memory1.deallocate()
        memory2.deallocate()
        active.deallocate()
        packedFilters.deallocate()
        packed1.deallocate()
        packed2.deallocate()
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
        // From the sliders, not the filters: to put the curve through a slider at 0 dB, a filter may be raised a
        // little against its neighbours' cuts, and that raises nothing a song can be louder for. Far from every band
        // the curve is the preamp alone, so a raised preamp raises something even with every band cut.
        raises.store(max(settings.bands.max() ?? 0, 0) + settings.preamp > 0.05, ordering: .relaxed)
        sampleRateBits.store(sampleRate.bitPattern, ordering: .relaxed)
        generation.add(1, ordering: .releasing)
    }

    // MARK: The audio thread

    /// Whether the last cycle left the sound untouched.
    public private(set) var isBypassed = true
    /// Whether the last cycle could make anything louder than it came: a slider or the preamp above 0 dB, or gains
    /// still gliding from or towards such settings. Only then does the limiter after it have anything to catch; an
    /// equalizer that only cuts leaves a loud song's peaks alone.
    public private(set) var mayRaise = false
    /// Whether what the bands hold has died away, so that silence in would give silence out: a cycle of silence may
    /// then pass without filtering, see `passSilence`.
    public private(set) var isSettled = true

    /// Whether the next cycle has anything to do: no new settings came, and the last cycle left the sound untouched
    /// with nothing still gliding or dying away. A caller may then skip it, and the copying around it, altogether.
    public var hasWork: Bool {
        generation.load(ordering: .acquiring) != seenGeneration || !isBypassed
    }

    /// Runs the equalizer in place over one cycle of up to two channels, each with its own stride between frames.
    public func process(
        left: UnsafeMutablePointer<Float>, leftStride: Int, right: UnsafeMutablePointer<Float>?, rightStride: Int,
        frames: Int
    ) {
        guard beginCycle(frames: frames) else { return }
        for frame in 0..<frames {
            let r = right.map { Double($0[frame * rightStride]) } ?? 0
            let y = filterFrame(SIMD2(Double(left[frame * leftStride]), r))
            left[frame * leftStride] = Float(y.x)
            right?[frame * rightStride] = Float(y.y)
        }
        endCycle(frames: frames)
    }

    /// Readies a cycle of so many frames: new settings taken, gains moved on, the bands at work packed. False when the
    /// sound passes untouched, and then nothing else of the cycle is to be called.
    func beginCycle(frames: Int) -> Bool {
        guard frames > 0 else { return false }
        takeNewSettings()
        let step = min(Self.decibelsPerSecond * Double(frames) / rate, Self.largestStepPerCycle)
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
            packedFilters[activeCount] = filters[band]
            packed1[activeCount] = memory1[band]
            packed2[activeCount] = memory2[band]
            activeCount += 1
        }
        let startPreamp = preamp
        if preampDecibels != wantedPreampDecibels {
            let difference = wantedPreampDecibels - preampDecibels
            preampDecibels =
                abs(difference) <= step ? wantedPreampDecibels : preampDecibels + (difference > 0 ? step : -step)
            preamp = preampDecibels == 0 ? 1 : pow(10, preampDecibels / 20)
            moving = true
        }
        isBypassed = activeCount == 0 && startPreamp == 1 && preamp == 1 && !moving
        if !moving { glideMayRaise = raisesNow }
        mayRaise = moving ? glideMayRaise : raisesNow
        cycleGain = startPreamp
        cycleGainStep = (preamp - startPreamp) / Double(frames)
        return !isBypassed
    }

    /// One frame of both channels through the preamp and every band at work. Transposed direct form II, in double
    /// precision: a 32 Hz band at 96 kHz has its poles very near the unit circle. Frame by frame through the bands,
    /// the two channels side by side in one instruction: each band's chain waits on its own last result, and running
    /// the bands in turn lets the processor overlap them. Measured on an M2, a fifth of the time of one channel at a
    /// time, and a third of running each band over the whole stretch.
    @inline(__always)
    func filterFrame(_ input: SIMD2<Double>) -> SIMD2<Double> {
        cycleGain += cycleGainStep
        var x = input * cycleGain
        for index in 0..<activeCount {
            let filter = packedFilters[index]
            let y = filter.b0 * x + packed1[index]
            packed1[index] = filter.b1 * x - filter.a1 * y + packed2[index]
            packed2[index] = filter.b2 * x - filter.a2 * y
            x = y
        }
        return x
    }

    /// Puts the bands' memory back, clears what is not a number, and lets a band back at 0 dB stop once what it holds
    /// has died away.
    func endCycle(frames: Int) {
        var settled = true
        for index in 0..<activeCount {
            let band = active[index]
            let held = (packed1[index], packed2[index])
            memory1[band] = held.0
            memory2[band] = held.1
            if !(held.0.x.isFinite && held.0.y.isFinite && held.1.x.isFinite && held.1.y.isFinite) {
                clearMemory(of: band)
                continue
            }
            let loudest = max(abs(held.0.x), abs(held.0.y), abs(held.1.x), abs(held.1.y))
            if loudest >= Self.silentMemory { settled = false }
            guard gains[band] == 0 else { continue }
            tails[band] -= frames
            if loudest < Self.silentMemory || tails[band] <= 0 {
                tails[band] = 0
                clearMemory(of: band)
            }
        }
        isSettled = settled
    }

    /// A cycle of silence in, once what the bands hold has died away (`isSettled`): silence comes out, so nothing is
    /// filtered, while the gains go on gliding and what is left in the bands, far below hearing, is let go.
    public func passSilence(frames: Int) {
        guard beginCycle(frames: frames) else { return }
        for index in 0..<activeCount {
            packed1[index] = .zero
            packed2[index] = .zero
        }
        endCycle(frames: frames)
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
        wantedPreampDecibels = decibels.isFinite ? decibels : 0
        let newRaises = raises.load(ordering: .relaxed)
        // Wherever the gains now are, they glide from settings that raised or did not towards these.
        glideMayRaise = glideMayRaise || raisesNow || newRaises
        raisesNow = newRaises
        let newRate = Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
        if newRate.isFinite, newRate > 0, newRate != rate {
            rate = newRate
            // Every filter is drawn again for the new rate, from where it is now.
            for band in 0..<Self.bandCount {
                filters[band] = EqualizerFilter.peaking(frequency: centres[band], gain: gains[band], sampleRate: rate)
            }
        }
    }

    private func clearMemory(of band: Int) {
        memory1[band] = .zero
        memory2[band] = .zero
    }
}
