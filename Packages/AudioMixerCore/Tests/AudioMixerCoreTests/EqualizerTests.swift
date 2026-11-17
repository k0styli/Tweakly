import CoreAudio
import Foundation
import Testing

@testable import AudioMixerCore

/// What a sine at one frequency comes out as through the processor, after it has settled.
private func measuredGain(
    _ processor: EqualizerProcessor, frequency: Double, sampleRate: Double, amplitude: Float = 0.1
) -> Double {
    let frames = 512
    var phase = 0.0
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    var power = 0.0
    var counted = 0
    // Long enough to glide anywhere and for the lowest band to settle, then a second to measure. Measured as power,
    // not peaks, which the samples of a high sine miss.
    let cycles = Int(sampleRate * 1.5) / frames
    for cycle in 0..<cycles {
        for frame in 0..<frames {
            left[frame] = amplitude * Float(sin(phase))
            right[frame] = left[frame]
            phase += 2 * Double.pi * frequency / sampleRate
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                processor.process(
                    left: l.baseAddress!, leftStride: 1, right: r.baseAddress!, rightStride: 1, frames: frames)
            }
        }
        if cycle > cycles / 3 {
            for sample in left { power += Double(sample) * Double(sample) }
            counted += frames
        }
    }
    let rms = (power / Double(counted)).squareRoot()
    return 20 * log10(rms / (Double(amplitude) / 2.0.squareRoot()))
}

@Suite struct EqualizerSettingsTests {
    @Test func musicsPresetsAreAllThere() {
        #expect(EqualizerSettings.frequencies.count == EqualizerProcessor.bandCount)
        #expect(EqualizerPreset.builtIn.count == 22)
        #expect(Set(EqualizerPreset.builtIn.map(\.id)).count == 22)
        #expect(EqualizerPreset.builtIn.allSatisfy { $0.bands.count == 10 })
        #expect(EqualizerPreset.builtIn(EqualizerPreset.flatID)?.settings.isFlat == true)
        #expect(EqualizerPreset.builtIn("bassBooster")?.bands.first == 5.5)
    }

    @Test func storedValuesStayWithinTheSlidersReach() throws {
        let wild = #"{"preamp": 40, "bands": [99, -99, 3, null, 1, 2]}"#.replacingOccurrences(of: "null", with: "0")
        let settings = try JSONDecoder().decode(EqualizerSettings.self, from: Data(wild.utf8))
        #expect(settings.preamp == 12)
        #expect(settings.bands == [12, -12, 3, 0, 1, 2, 0, 0, 0, 0])
        let missing = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
        #expect(missing == .flat)
        #expect(EqualizerSettings(bands: [Double.nan] + Array(repeating: 1, count: 9)).bands.first == 0)
    }

    @Test func aFlatEqualizerIsNoRule() {
        var book = AudioRuleBook()
        book.set(AppAudioRule(equalizer: .flat), for: "a")
        #expect(book.rules.isEmpty)
        book.set(AppAudioRule(equalizer: EqualizerPreset.builtIn("rock")!.settings), for: "a")
        #expect(book.rules["a"]?.hasEqualizer == true)
        book.setEqualizer(.flat, forOutput: "speakers", name: "Speakers")
        #expect(book.outputs.isEmpty && !book.isEmpty)
        book.setEqualizer(EqualizerPreset.builtIn("pop")!.settings, forOutput: "speakers", name: "Speakers")
        #expect(book.equalizer(forOutput: "speakers").presetID == "pop")
        #expect(book.outputs["speakers"]?.name == "Speakers")
    }

    @Test func rulesSavedBeforeEqualizersStillLoad() throws {
        let old = #"{"rules":{"com.apple.Safari":{"volume":0.5,"isMuted":false}}}"#
        let book = try JSONDecoder().decode(AudioRuleBook.self, from: Data(old.utf8))
        #expect(book.rule(for: "com.apple.Safari").volume == 0.5)
        #expect(book.rule(for: "com.apple.Safari").equalizer == nil)
        #expect(book.outputs.isEmpty)
        let saved = try JSONEncoder().encode(book)
        let reloaded = try JSONDecoder().decode(AudioRuleBook.self, from: saved)
        #expect(reloaded == book)
    }
}

@Suite struct EqualizerDragTests {
    @Test func aClickMovesNothing() {
        // Acoustic's 4 kHz is off the quarter steps and stays exactly so.
        #expect(EqualizerSettings.draggedGain(from: 4.1, by: 0) == 4.1)
        #expect(EqualizerSettings.draggedGain(from: 4.1, by: 0.12) == 4.1)
        #expect(EqualizerSettings.draggedGain(from: -1.5, by: -0.1) == -1.5)
    }

    @Test func aPointMovesAsFarAsThePointer() {
        #expect(EqualizerSettings.draggedGain(from: -1.5, by: 4.02) == 2.5)
        #expect(abs(EqualizerSettings.draggedGain(from: 4.1, by: -1.0) - 3.1) < 1e-9)
    }

    @Test func zeroCatchesThePointWithinHalfADecibel() {
        #expect(EqualizerSettings.draggedGain(from: 3, by: -2.7) == 0)
        #expect(EqualizerSettings.draggedGain(from: 3, by: -2.5) == 0.5)
        #expect(EqualizerSettings.draggedGain(from: 0, by: 0.3) == 0)
        #expect(EqualizerSettings.draggedGain(from: 0, by: 0.5) == 0.5)
    }

    @Test func thePointStopsAtTheSlidersReach() {
        #expect(EqualizerSettings.draggedGain(from: 10, by: 5) == 12)
        #expect(EqualizerSettings.draggedGain(from: -10, by: -40) == -12)
    }
}

@Suite struct EqualizerFilterTests {
    @Test(arguments: [44_100.0, 48_000, 96_000])
    func everyPresetPassesThroughItsSliders(sampleRate: Double) {
        for preset in EqualizerPreset.builtIn {
            let gains = EqualizerFilter.filterGains(for: preset.bands, sampleRate: sampleRate)
            for (index, frequency) in EqualizerSettings.frequencies.enumerated() {
                let heard = EqualizerFilter.response(filterGains: gains, at: frequency, sampleRate: sampleRate)
                #expect(abs(heard - preset.bands[index]) < 0.05, "\(preset.id) at \(frequency) Hz: \(heard)")
            }
        }
    }

    @Test func equalSlidersMakeAnEvenCurve() {
        let gains = EqualizerFilter.filterGains(for: Array(repeating: 6, count: 10), sampleRate: 48_000)
        // Between the bands, not only on them.
        for frequency in stride(from: 40.0, through: 12_000, by: 37) {
            let heard = EqualizerFilter.response(filterGains: gains, at: frequency, sampleRate: 48_000)
            #expect(abs(heard - 6) < 0.75, "\(frequency) Hz: \(heard)")
        }
    }

    @Test func slidersPullingApartStayWithinReach() {
        let zigzag: [Double] = [12, -12, 12, -12, 12, -12, 12, -12, 12, -12]
        let gains = EqualizerFilter.filterGains(for: zigzag, sampleRate: 48_000)
        #expect(gains.allSatisfy { abs($0) <= EqualizerFilter.highestFilterGain })
        for (index, frequency) in EqualizerSettings.frequencies.enumerated() {
            let heard = EqualizerFilter.response(filterGains: gains, at: frequency, sampleRate: 48_000)
            #expect(abs(heard - zigzag[index]) < 1.5, "\(frequency) Hz: \(heard)")
        }
    }

    @Test func bandsTooHighForTheRateAreLeftOut() {
        // A Bluetooth headset in a call plays at 16 kHz: 8 and 16 kHz cannot be drawn there.
        let gains = EqualizerFilter.filterGains(for: Array(repeating: 6, count: 10), sampleRate: 16_000)
        #expect(gains[8] == 0 && gains[9] == 0)
        let heard = EqualizerFilter.response(filterGains: gains, at: 1000, sampleRate: 16_000)
        #expect(abs(heard - 6) < 0.05)
        #expect(EqualizerFilter.peaking(frequency: 16_000, gain: 6, sampleRate: 16_000) == .identity)
    }
}

@Suite struct EqualizerProcessorTests {
    @Test func flatLeavesTheSoundExactlyAsItIs() {
        let processor = EqualizerProcessor(sampleRate: 48_000)
        processor.set(.flat)
        var samples: [Float] = (0..<256).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let original = samples
        samples.withUnsafeMutableBufferPointer {
            processor.process(left: $0.baseAddress!, leftStride: 1, right: nil, rightStride: 0, frames: 256)
        }
        #expect(samples == original)
        #expect(processor.isBypassed)
    }

    @Test(arguments: [44_100.0, 48_000])
    func aSineIsRaisedAsTheSliderSays(sampleRate: Double) {
        let processor = EqualizerProcessor(sampleRate: sampleRate)
        let preset = EqualizerPreset.builtIn("loudness")!
        processor.set(preset.settings)
        for (index, frequency) in EqualizerSettings.frequencies.enumerated() where frequency < 0.45 * sampleRate {
            let heard = measuredGain(processor, frequency: frequency, sampleRate: sampleRate)
            #expect(abs(heard - preset.bands[index]) < 0.3, "\(frequency) Hz: \(heard)")
        }
    }

    @Test func thePreampMovesEverything() {
        let processor = EqualizerProcessor(sampleRate: 48_000)
        processor.set(EqualizerSettings(preamp: -6))
        let heard = measuredGain(processor, frequency: 1000, sampleRate: 48_000)
        #expect(abs(heard + 6) < 0.1)
    }

    @Test func aNewPresetGlidesInWithoutAJump() {
        let rate = 48_000.0
        let processor = EqualizerProcessor(sampleRate: rate)
        let frames = 256
        var phase = 0.0
        var largestStep: Float = 0
        var last: Float = 0
        // A 100 Hz sine, whose own largest step between two frames is about 0.013 at this level.
        for cycle in 0..<200 {
            if cycle == 50 { processor.set(EqualizerSettings(bands: [12, 12, 12, 12, 0, 0, 0, 0, 0, 0])) }
            if cycle == 120 { processor.set(.flat) }
            var buffer = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                buffer[frame] = 0.1 * Float(sin(phase))
                phase += 2 * Double.pi * 100 / rate
            }
            buffer.withUnsafeMutableBufferPointer {
                processor.process(left: $0.baseAddress!, leftStride: 1, right: nil, rightStride: 0, frames: frames)
            }
            for sample in buffer {
                largestStep = max(largestStep, abs(sample - last))
                last = sample
            }
        }
        // At +12 dB the sine's own steps are four times larger; a click would be far beyond that.
        #expect(largestStep < 0.06, "largest step \(largestStep)")
        #expect(processor.isBypassed, "back to flat, it lets the sound alone again")
    }

    @Test(arguments: [128, 512])
    func aLowBandTurnedOffDiesAwayWithoutAClick(frames: Int) {
        // A 40 Hz tone through the 32 Hz band at +6 dB, then Off: the band glides to 0 dB and lets its memory fade.
        let rate = 48_000.0
        let processor = EqualizerProcessor(sampleRate: rate)
        processor.set(EqualizerSettings(bands: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        var phase = 0.0
        var last: Float = 0
        var largestStep: Float = 0
        for cycle in 0..<(Int(rate) * 2 / frames) {
            if cycle == Int(rate) / frames { processor.set(.flat) }
            var buffer = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                buffer[frame] = 0.5 * Float(sin(phase))
                phase += 2 * Double.pi * 40 / rate
            }
            buffer.withUnsafeMutableBufferPointer {
                processor.process(left: $0.baseAddress!, leftStride: 1, right: nil, rightStride: 0, frames: frames)
            }
            for sample in buffer {
                largestStep = max(largestStep, abs(sample - last))
                last = sample
            }
        }
        // The tone's own steps at +6 dB are about 0.0053; a band cut off early would jump by several times that.
        #expect(largestStep < 0.0065, "largest step \(largestStep)")
        #expect(processor.isBypassed)
    }

    @Test func interleavedChannelsAreEachTheirOwn() {
        let processor = EqualizerProcessor(sampleRate: 48_000)
        processor.set(EqualizerSettings(preamp: -6))
        // The first cycle glides the preamp in; the second is all at its value.
        var frames: [Float] = []
        for _ in 0..<2 {
            frames = [Float]([0.5, -0.25]).repeated(2048)
            frames.withUnsafeMutableBufferPointer {
                processor.process(
                    left: $0.baseAddress!, leftStride: 2, right: $0.baseAddress! + 1, rightStride: 2, frames: 2048)
            }
        }
        #expect(abs(frames[0] - 0.5 * 0.501) < 0.002)
        #expect(abs(frames[1] + 0.25 * 0.501) < 0.002)
        #expect(abs(frames[4094] - 0.5 * 0.501) < 0.002)
    }

    @Test func nothingWildReachesTheSpeakers() {
        let processor = EqualizerProcessor(sampleRate: 48_000)
        processor.set(EqualizerSettings(preamp: 12, bands: Array(repeating: 12, count: 10)))
        var samples = [Float](repeating: 0, count: 512)
        samples[0] = .infinity
        samples[1] = .nan
        samples.withUnsafeMutableBufferPointer {
            processor.process(left: $0.baseAddress!, leftStride: 1, right: nil, rightStride: 0, frames: 512)
        }
        // What came in broken is forgotten: what follows comes out as numbers again.
        for _ in 0..<3 {
            samples = [Float](repeating: 0.01, count: 512)
            samples.withUnsafeMutableBufferPointer {
                processor.process(left: $0.baseAddress!, leftStride: 1, right: nil, rightStride: 0, frames: 512)
            }
        }
        let allFinite = samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    @Test func aNewRateRedrawsTheFilters() {
        let processor = EqualizerProcessor(sampleRate: 48_000)
        processor.set(EqualizerSettings(bands: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0]))
        processor.setSampleRate(44_100)
        let heard = measuredGain(processor, frequency: 1000, sampleRate: 44_100)
        #expect(abs(heard - 6) < 0.3)
    }
}

@Suite struct EqualizingMixerTests {
    private func stereo(_ pairs: [(Float, Float)]) -> [Float] { pairs.flatMap { [$0.0, $0.1] } }

    /// One tap of a steady stereo level into a stereo output, enough cycles for an equalizer to settle.
    private func run(_ mixer: TapMixer, level: Float, cycles: Int = 20) -> Float {
        let frames = 512
        var outputValue: Float = 0
        for _ in 0..<cycles {
            var tap = [Float](repeating: level, count: frames * 2)
            var out = [Float](repeating: 0, count: frames * 2)
            tap.withUnsafeMutableBytes { tapBytes in
                out.withUnsafeMutableBytes { outBytes in
                    var input = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count),
                            mData: tapBytes.baseAddress))
                    var output = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                    mixer.render(input: &input, output: &output)
                }
            }
            outputValue = out[frames * 2 - 2]
        }
        return outputValue
    }

    @Test func anAppsPreampChangesOnlyItsOwnSound() {
        let mixer = TapMixer(gains: [1])
        mixer.equalizers[0].set(EqualizerSettings(preamp: -6))
        // A steady level is all the bands' 0 Hz: only the preamp moves it.
        #expect(abs(run(mixer, level: 0.4) - 0.4 * 0.501) < 0.005)
    }

    @Test func theOutputsEqualizerWorksOnTheSum() {
        let mixer = TapMixer(gains: [1])
        mixer.outputEqualizer.set(EqualizerSettings(preamp: -12))
        #expect(abs(run(mixer, level: 0.4) - 0.4 * 0.251) < 0.005)
    }

    @Test func anEqualizerThatOnlyCutsLeavesLoudPeaksAlone() {
        // A steady level is every band's 0 Hz, where a peaking band changes nothing: what comes out is what came in,
        // not bent by the limiter, which has nothing to catch.
        let mixer = TapMixer(gains: [1])
        mixer.outputEqualizer.set(EqualizerPreset.builtIn("bassReducer")!.settings)
        #expect(abs(run(mixer, level: 0.95) - 0.95) < 0.0005)
    }

    @Test func whatACutPushesPastFullScaleIsStillCaught() {
        // A steady level of 1.0 through a cut: unchanged by the bands, it reaches the gentle knee and stays below 1.
        let mixer = TapMixer(gains: [1])
        mixer.outputEqualizer.set(EqualizerPreset.builtIn("bassReducer")!.settings)
        let value = run(mixer, level: 1.05)
        #expect(value < 1 && value > SoftLimiter.cutKnee)
    }

    @Test func aRaisedSoundIsKeptFromClipping() {
        let mixer = TapMixer(gains: [1])
        mixer.outputEqualizer.set(EqualizerSettings(preamp: 12))
        let value = run(mixer, level: 0.5)
        #expect(value <= 1 && value > SoftLimiter.knee)
    }
}

extension Array {
    fileprivate func repeated(_ times: Int) -> [Element] {
        (0..<times).flatMap { _ in self }
    }
}
