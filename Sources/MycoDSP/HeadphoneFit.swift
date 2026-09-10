import Foundation

/// A magnitude response as a measurer publishes it: frequency and level pairs, one per line.
public struct FrequencyCurve: Sendable, Equatable {
    public var frequencies: [Double]
    public var levels: [Double]

    public init(frequencies: [Double], levels: [Double]) {
        self.frequencies = frequencies
        self.levels = levels
    }

    /// Reads a REW export or an AutoEq CSV: two or more numbers per line, separated by tabs,
    /// commas or spaces. Lines that start with anything else are comments or headers.
    public init?(text: String) {
        var frequencies: [Double] = []
        var levels: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == "," || $0 == " " })
            guard fields.count >= 2, let frequency = Double(fields[0]), let level = Double(fields[1]),
                  frequency > 0
            else { continue }
            frequencies.append(frequency)
            levels.append(level)
        }
        guard frequencies.count >= 2 else { return nil }
        self.init(frequencies: frequencies, levels: levels)
    }

    /// The level at `frequency`, linear between the points on a log frequency axis and held
    /// flat past either end.
    public func level(at frequency: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if frequency <= first { return levels[0] }
        if frequency >= last { return levels[levels.count - 1] }
        var low = 0
        var high = frequencies.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if frequencies[mid] <= frequency { low = mid } else { high = mid }
        }
        let t = log(frequency / frequencies[low]) / log(frequencies[high] / frequencies[low])
        return levels[low] + (levels[high] - levels[low]) * t
    }
}

/// Turns a headphone measurement and a target into the ten bands that bring one to the other,
/// the way AutoEq does: centre both at 1 kHz, smooth the difference, cap the boost, then fit.
public enum HeadphoneFit {
    /// The grid every curve is compared on: 24 points per octave from 20 Hz to 20 kHz.
    static let grid: [Double] = (0...240).map { 20 * pow(2, Double($0) / 24) }
    static let sampleRate = 48000.0
    /// AutoEq's cap on boost: a measurement dip is a leak or a resonance more often than a real
    /// lack of output.
    static let maxBoostDB = 6.0

    /// The preset that plays `measurement` (the channels averaged) as `target` would sound.
    public static func preset(
        name: String, source: String, form: String, measurement: [FrequencyCurve], target: FrequencyCurve
    ) -> EQPreset {
        let bands = rounded(fit(correction(measurement: measurement, target: target)))
        return EQPreset(name: name, source: source, form: form, preampDB: preamp(for: [bands]), bands: bands)
    }

    /// The preset for a headphone measured at several device volumes. The band shapes come from
    /// the step nearest half volume and only the gains are fitted per step, so the gains can be
    /// interpolated between steps as the volume moves.
    public static func preset(
        name: String, source: String, form: String,
        volumes: [(volume: Double, measurement: [FrequencyCurve])], target: FrequencyCurve
    ) -> EQPreset {
        precondition(!volumes.isEmpty, "a volume preset needs at least one measured step")
        let corrections = volumes.map { correction(measurement: $0.measurement, target: target) }
        let reference = volumes.indices.min { abs(volumes[$0].volume - 0.5) < abs(volumes[$1].volume - 0.5) }!
        let shapes = fit(corrections[reference])
        let perStep = corrections.map { rounded(fit($0, from: shapes, gainsOnly: true)) }
        let steps = zip(volumes, perStep).map { EQVolumeStep(volume: $0.volume, gainsDB: $1.map(\.gainDB)) }
        return EQPreset(
            name: name, source: source, form: form, preampDB: preamp(for: perStep), bands: perStep[reference],
            volumes: steps)
    }

    /// The trim that keeps the loudest of the band sets from clipping, rounded to 0.1 dB.
    private static func preamp(for sets: [[BandSettings]]) -> Double {
        let peak = sets.map { bands in
            grid.indices.map { index in bands.reduce(0.0) { $0 + gainDB($1, at: index) } }.max() ?? 0
        }.max() ?? 0
        return -(max(0, peak) * 10).rounded() / 10
    }

    /// Bands as the inspector fields show them: 1 Hz, 0.1 dB and 0.01 octave.
    private static func rounded(_ bands: [BandSettings]) -> [BandSettings] {
        bands.map { band in
            var band = band
            band.frequency = band.frequency.rounded()
            band.gainDB = (band.gainDB * 10).rounded() / 10
            band.bandwidth = (band.bandwidth * 100).rounded() / 100
            return band
        }
    }

    /// The gain to add at each grid point: target minus measurement, both at 0 dB at 1 kHz,
    /// smoothed over 1/12 octave (2 octaves above 8 kHz, where rigs and seals disagree).
    static func correction(measurement: [FrequencyCurve], target: FrequencyCurve) -> [Double] {
        let channels = Double(max(measurement.count, 1))
        let measured = grid.map { f in measurement.reduce(0.0) { $0 + $1.level(at: f) } / channels }
        let measuredAt1k = measurement.reduce(0.0) { $0 + $1.level(at: 1000) } / channels
        let targetAt1k = target.level(at: 1000)
        let raw = grid.indices.map { (target.level(at: grid[$0]) - targetAt1k) - (measured[$0] - measuredAt1k) }
        return grid.indices.map { index in
            let f = grid[index]
            // Window half-width in grid points: 1 below 6 kHz, 24 above 8 kHz, blended between.
            let blend = min(max((log2(f) - log2(6000)) / (log2(8000) - log2(6000)), 0), 1)
            let half = Int((1 + 23 * blend).rounded())
            let window = max(0, index - half)...min(grid.count - 1, index + half)
            let mean = window.reduce(0.0) { $0 + raw[$1] } / Double(window.count)
            return min(mean, maxBoostDB)
        }
    }

    /// Ten bands that follow `wanted`: a low shelf, eight peaks and a high shelf, refined by
    /// coordinate descent on frequency, gain and bandwidth until no step helps. `from` starts the
    /// descent at given bands, and `gainsOnly` keeps their frequencies and bandwidths.
    static func fit(_ wanted: [Double], from start: [BandSettings]? = nil, gainsOnly: Bool = false) -> [BandSettings] {
        var bands = start ?? Self.startingBands
        // Above 10 kHz the fit matters less: measurements differ between rigs there.
        let weights = grid.map { $0 > 10000 ? 0.3 : 1.0 }
        var responses = bands.map { band in grid.indices.map { gainDB(band, at: $0) } }
        func error() -> Double {
            var sum = 0.0
            for index in grid.indices {
                var total = 0.0
                for response in responses { total += response[index] }
                let diff = total - wanted[index]
                sum += weights[index] * diff * diff
            }
            return sum
        }
        var best = error()
        var steps = (octaves: 0.5, gain: 2.0, bandwidth: 0.5)
        while steps.gain > 0.05 {
            var improved = false
            for slot in bands.indices {
                for parameter in gainsOnly ? 1..<2 : 0..<3 {
                    for sign in [1.0, -1.0] {
                        var trial = bands[slot]
                        switch parameter {
                        case 0: trial.frequency = min(max(trial.frequency * pow(2, sign * steps.octaves), 20), 12000)
                        case 1: trial.gainDB = min(max(trial.gainDB + sign * steps.gain, -20), 20)
                        default:
                            guard trial.type == .parametric else { continue }
                            trial.bandwidth = min(max(trial.bandwidth + sign * steps.bandwidth, 0.25), 5)
                        }
                        guard trial != bands[slot] else { continue }
                        let saved = responses[slot]
                        responses[slot] = grid.indices.map { gainDB(trial, at: $0) }
                        let candidate = error()
                        if candidate < best {
                            best = candidate
                            bands[slot] = trial
                            improved = true
                        } else {
                            responses[slot] = saved
                        }
                    }
                }
            }
            if !improved {
                steps = (steps.octaves / 2, steps.gain / 2, steps.bandwidth / 2)
            }
        }
        return bands
    }

    private static var startingBands: [BandSettings] {
        var bands = [BandSettings(type: .lowShelf, frequency: 105, gainDB: 0)]
        bands += (0..<8).map { BandSettings(frequency: 60 * pow(8000 / 60, Double($0) / 7), gainDB: 0, bandwidth: 1) }
        bands.append(BandSettings(type: .highShelf, frequency: 10000, gainDB: 0))
        return bands
    }

    private static func gainDB(_ band: BandSettings, at index: Int) -> Double {
        let coefficients = BiquadCoefficients(band, sampleRate: sampleRate)
        return 20 * log10(max(coefficients.magnitude(at: grid[index], sampleRate: sampleRate), 1e-9))
    }
}
