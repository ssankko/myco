import Foundation

/// A headphone correction for the ten bands, measured by an AutoEq contributor.
public struct EQPreset: Sendable, Equatable, Identifiable {
    public var id: String { "\(source)/\(form)/\(name)" }
    public var name: String
    /// The AutoEq measurer the curve comes from.
    public var source: String
    /// "over-ear", "in-ear" or "earbud".
    public var form: String
    /// The trim that keeps the boosted bands from clipping, in dB.
    public var preampDB: Double
    /// Always `Equalizer.bandCount` bands.
    public var bands: [BandSettings]

    /// The name as the EQ window shows it: the measurer follows the headphone name.
    public var title: String { "\(name) (\(source))" }

    public init(name: String, source: String, form: String, preampDB: Double, bands: [BandSettings]) {
        self.name = name
        self.source = source
        self.form = form
        self.preampDB = preampDB
        self.bands = Self.padded(bands)
    }

    /// Exactly `Equalizer.bandCount` bands: the first ten, or the given ones followed by bypassed
    /// flat bands.
    static func padded(_ bands: [BandSettings]) -> [BandSettings] {
        let filler = BandSettings(bypass: true)
        return Array((bands + Array(repeating: filler, count: Equalizer.bandCount)).prefix(Equalizer.bandCount))
    }

    /// Decodes the compact JSON `scripts/autoeq.py` writes.
    public static func autoEq(from data: Data) throws -> [EQPreset] {
        try JSONDecoder().decode([AutoEqEntry].self, from: data).map(\.preset)
    }

    /// Bandwidth in octaves of a peaking filter with the given Q.
    static func bandwidth(q: Double) -> Double {
        2 / log(2.0) * asinh(1 / (2 * q))
    }

    private struct AutoEqEntry: Decodable {
        let n: String
        let m: String
        let f: String
        let p: Double
        let e: [Filter]

        var preset: EQPreset {
            EQPreset(name: n, source: m, form: f, preampDB: p, bands: e.map(\.band))
        }

        /// One `[type, fc, gain, q]` row.
        struct Filter: Decodable {
            let band: BandSettings

            init(from decoder: Decoder) throws {
                var row = try decoder.unkeyedContainer()
                let type = try row.decode(String.self)
                let fc = try row.decode(Double.self)
                let gain = try row.decode(Double.self)
                let q = try row.decode(Double.self)
                let shape: FilterType = switch type {
                case "LSC": .lowShelf
                case "HSC": .highShelf
                default: .parametric
                }
                band = BandSettings(type: shape, frequency: fc, gainDB: gain, bandwidth: bandwidth(q: q))
            }
        }
    }
}
