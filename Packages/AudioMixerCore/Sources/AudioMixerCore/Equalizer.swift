import Foundation

/// A ten-band equalizer as Music has: the same bands, the same ±12 dB and a preamp, so its presets sound as they do
/// there. Kept for an output, where it changes everything played on it, or for an app.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    /// Music's bands, in hertz.
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let range: ClosedRange<Double> = -12...12

    /// Lowers or raises everything before the bands, in decibels.
    public var preamp: Double
    /// One gain in decibels for each of `frequencies`.
    public var bands: [Double]
    /// The preset these values came from, built in or saved by the person, until a slider moves them.
    public var presetID: String?

    public init(preamp: Double = 0, bands: [Double] = Array(repeating: 0, count: 10), presetID: String? = nil) {
        self.preamp = preamp
        self.bands = bands
        self.presetID = presetID
        self = sanitized
    }

    public static let flat = EqualizerSettings()

    /// Nothing to change, so the sound passes untouched and nothing is taken for it.
    public var isFlat: Bool {
        abs(preamp) < 0.05 && bands.allSatisfy { abs($0) < 0.05 }
    }

    /// Always ten bands, each within the sliders' reach, whatever was stored.
    public var sanitized: EqualizerSettings {
        var copy = self
        copy.preamp = Self.clamp(preamp)
        let count = Self.frequencies.count
        copy.bands = (bands.prefix(count) + Array(repeating: 0, count: max(0, count - bands.count))).map(Self.clamp)
        return copy
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }

    /// A band's gain while its point is dragged on the curve: moved by as much as the pointer, in quarter decibels,
    /// from the gain it had when taken, and caught at 0 dB within half a decibel. A pointer that has not yet moved a
    /// quarter decibel leaves it as it was, so a click, or a preset's value off the quarter steps, changes nothing.
    public static func draggedGain(from gain: Double, by distance: Double) -> Double {
        let step = (distance * 4).rounded() / 4
        guard step != 0 else { return gain }
        let moved = clamp(gain + step)
        return abs(moved) < 0.5 ? 0 : moved
    }

    private enum CodingKeys: String, CodingKey { case preamp, bands, presetID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        bands = try container.decodeIfPresent([Double].self, forKey: .bands) ?? []
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        self = sanitized
    }
}

/// Music's own presets, values as Music stores them. Their names come from the app's catalog, under the same words as
/// in Music, so `id` is all that is kept.
public struct EqualizerPreset: Identifiable, Sendable {
    public let id: String
    public let bands: [Double]

    public var settings: EqualizerSettings { EqualizerSettings(bands: bands, presetID: id) }

    public static let flatID = "flat"

    public static let builtIn: [EqualizerPreset] = [
        .init(id: "acoustic", bands: [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        .init(id: "bassBooster", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        .init(id: "bassReducer", bands: [-5.5, -4.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        .init(id: "classical", bands: [4.75, 3.75, 3, 2.5, -1.5, -1.5, 0, 2.25, 3.25, 3.75]),
        .init(id: "dance", bands: [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]),
        .init(id: "deep", bands: [4.95, 3.55, 1.75, 1, 2.85, 2.5, 1.45, -2.15, -3.55, -4.6]),
        .init(id: "electronic", bands: [4.25, 3.8, 1.2, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.8]),
        .init(id: flatID, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(id: "hipHop", bands: [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        .init(id: "jazz", bands: [4, 3, 1.5, 2.25, -1.5, -1.5, 0, 1.5, 3, 3.75]),
        .init(id: "latin", bands: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        .init(id: "loudness", bands: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        .init(id: "lounge", bands: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        .init(id: "piano", bands: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        .init(id: "pop", bands: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        .init(id: "rnb", bands: [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3, 3.75]),
        .init(id: "rock", bands: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        .init(id: "smallSpeakers", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.25]),
        .init(id: "spokenWord", bands: [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]),
        .init(id: "trebleBooster", bands: [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
        .init(id: "trebleReducer", bands: [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        .init(id: "vocalBooster", bands: [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5]),
    ]

    public static func builtIn(_ id: String) -> EqualizerPreset? {
        builtIn.first { $0.id == id }
    }
}

/// A preset the person saved under a name of their own.
public struct CustomEqualizerPreset: Codable, Equatable, Identifiable, Sendable {
    public static let idPrefix = "custom."

    public var id: String
    public var name: String
    public var preamp: Double
    public var bands: [Double]

    public init(id: String = idPrefix + UUID().uuidString, name: String, from settings: EqualizerSettings) {
        self.id = id
        self.name = name
        preamp = settings.preamp
        bands = settings.bands
    }

    public var settings: EqualizerSettings { EqualizerSettings(preamp: preamp, bands: bands, presetID: id) }
}

/// One second-order section, with `a0` divided out.
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// How much the section changes a sine at this frequency, in decibels.
    public func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numeratorRe = b0 + b1 * c1 + b2 * c2
        let numeratorIm = -(b1 * s1 + b2 * s2)
        let denominatorRe = 1 + a1 * c1 + a2 * c2
        let denominatorIm = -(a1 * s1 + a2 * s2)
        let numerator = numeratorRe * numeratorRe + numeratorIm * numeratorIm
        let denominator = denominatorRe * denominatorRe + denominatorIm * denominatorIm
        return 10 * log10(max(numerator, 1e-30) / max(denominator, 1e-30))
    }
}

/// The filters behind the bands: one peaking section per band.
public enum EqualizerFilter {
    /// Each band's width in octaves. The bands are an octave apart; a little wider, ten equal sliders make a curve
    /// within 0.6 dB of them between the bands as well, while sliders pulling every other way still come within a
    /// decibel or so of where they are set.
    public static let bandwidth = 1.2
    /// How far a filter may go to put the curve through a slider its neighbours pull the other way.
    public static let highestFilterGain = 24.0

    /// A band too close to half the sample rate cannot be drawn there, as on a Bluetooth headset during a call.
    public static func isUsable(_ frequency: Double, sampleRate: Double) -> Bool {
        sampleRate > 0 && frequency < 0.45 * sampleRate
    }

    /// The peaking section from Robert Bristow-Johnson's cookbook, its width given in octaves with the correction for
    /// the bilinear transform, so a band near the top keeps its width instead of narrowing. At 0 dB it still has its
    /// shape, with the numerator equal to the denominator: a band gliding to 0 dB thus lets what it holds die away
    /// instead of dropping it.
    public static func peaking(frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        guard isUsable(frequency, sampleRate: sampleRate), gain.isFinite else { return .identity }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) * sinh(log(2) / 2 * bandwidth * w / sin(w))
        let cosine = cos(w)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0, b1: -2 * cosine / a0, b2: (1 - alpha * a) / a0, a1: -2 * cosine / a0,
            a2: (1 - alpha / a) / a0)
    }

    /// The whole curve at one frequency, for gains as the filters get them.
    public static func response(filterGains: [Double], at frequency: Double, sampleRate: Double) -> Double {
        zip(EqualizerSettings.frequencies, filterGains).reduce(0) { sum, band in
            sum
                + peaking(frequency: band.0, gain: band.1, sampleRate: sampleRate)
                .response(at: frequency, sampleRate: sampleRate)
        }
    }

    /// The gain each filter gets so that the curve passes through every slider at its band. Neighbouring bands
    /// overlap, and given the sliders as they are, five bands at +6 dB would raise the middle of them by nearly 10 dB,
    /// so the sliders would say less than is heard. Solved on the main thread, once a change.
    public static func filterGains(for bands: [Double], sampleRate: Double) -> [Double] {
        let frequencies = EqualizerSettings.frequencies
        let usable = frequencies.indices.filter { isUsable(frequencies[$0], sampleRate: sampleRate) }
        var gains = Array(repeating: 0.0, count: frequencies.count)
        guard !usable.isEmpty, bands.count == frequencies.count, bands.contains(where: { abs($0) > 1e-6 }) else {
            return gains
        }
        let unit = 6.0
        // How much each filter at the unit gain raises each band's centre, per decibel.
        let spread = usable.map { row in
            usable.map { column in
                peaking(frequency: frequencies[column], gain: unit, sampleRate: sampleRate)
                    .response(at: frequencies[row], sampleRate: sampleRate) / unit
            }
        }
        let targets = usable.map { bands[$0] }
        guard var solved = solve(spread, targets) else { return bands.map { $0 } }
        // The filters are not quite linear in decibels, so the rest is taken in a few more steps.
        for _ in 0..<3 {
            for (index, band) in usable.enumerated() { gains[band] = solved[index] }
            let missing = usable.enumerated().map { index, band in
                targets[index] - response(filterGains: gains, at: frequencies[band], sampleRate: sampleRate)
            }
            guard let step = solve(spread, missing) else { break }
            solved = zip(solved, step).map { min(max($0 + $1, -highestFilterGain), highestFilterGain) }
        }
        for (index, band) in usable.enumerated() { gains[band] = solved[index] }
        return gains
    }

    /// Gaussian elimination with partial pivoting; nil for a system without one answer.
    static func solve(_ matrix: [[Double]], _ values: [Double]) -> [Double]? {
        let size = values.count
        var rows = zip(matrix, values).map { $0 + [$1] }
        for column in 0..<size {
            guard
                let pivot = (column..<size).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
                abs(rows[pivot][column]) > 1e-12
            else { return nil }
            rows.swapAt(column, pivot)
            for row in 0..<size where row != column {
                let factor = rows[row][column] / rows[column][column]
                guard factor != 0 else { continue }
                for index in column...size { rows[row][index] -= factor * rows[column][index] }
            }
        }
        return (0..<size).map { rows[$0][size] / rows[$0][$0] }
    }
}
