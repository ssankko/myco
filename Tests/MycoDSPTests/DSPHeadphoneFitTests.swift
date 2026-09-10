import Foundation
import XCTest
@testable import MycoDSP

final class DSPHeadphoneFitTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/\(name)"), encoding: .utf8)
    }

    private static func target(_ name: String) throws -> FrequencyCurve {
        let url = root.appendingPathComponent("Sources/Myco/Resources/\(name)")
        return try XCTUnwrap(FrequencyCurve(text: String(contentsOf: url, encoding: .utf8)))
    }

    func testParsesRewExportAndAutoEqCsv() throws {
        let rew = "* Measurement data measured by REW\n* Source: USB\n"
            + "20.299999\t85.620\t-171.5\n1000.0\t90.0\t3.2\n20000\t70.1\t0\n"
        let curve = try XCTUnwrap(FrequencyCurve(text: rew))
        XCTAssertEqual(curve.frequencies, [20.299999, 1000, 20000])
        XCTAssertEqual(curve.levels, [85.62, 90, 70.1])
        // Log-linear between points, flat past the ends.
        XCTAssertEqual(curve.level(at: 4472.1), 80.05, accuracy: 0.05)
        XCTAssertEqual(curve.level(at: 5), 85.62)
        XCTAssertEqual(curve.level(at: 30000), 70.1)

        let csv = try XCTUnwrap(FrequencyCurve(text: "frequency,raw\n20.00,7.61\n20.20,7.62\n"))
        XCTAssertEqual(csv.frequencies.count, 2)
        XCTAssertNil(FrequencyCurve(text: "frequency,raw\n"))
    }

    /// A headphone that is the target plus three known filters gets those filters undone.
    func testFitUndoesKnownColouration() throws {
        let target = try Self.target("target-in-ear.csv")
        let colour = [
            BandSettings(type: .lowShelf, frequency: 120, gainDB: 4),
            BandSettings(frequency: 800, gainDB: -5, bandwidth: 1.2),
            BandSettings(frequency: 3200, gainDB: 3, bandwidth: 0.6),
        ]
        let frequencies = HeadphoneFit.grid
        let levels = frequencies.map { f in
            80 + target.level(at: f) + colour.reduce(0.0) { $0 + Self.gainDB($1, at: f) }
        }
        let measurement = FrequencyCurve(frequencies: frequencies, levels: levels)

        let start = Date()
        let preset = HeadphoneFit.preset(
            name: "X", source: "lab", form: "in-ear", measurement: [measurement, measurement], target: target)
        print("fit took \(Int(-start.timeIntervalSinceNow * 1000)) ms, preamp \(preset.preampDB) dB")

        XCTAssertEqual(preset.bands.count, Equalizer.bandCount)
        // Both curves sit at 0 dB at 1 kHz, so what is left is a shape, not a level.
        let residual = { (f: Double) in
            colour.reduce(0.0) { $0 + Self.gainDB($1, at: f) }
                + preset.bands.reduce(0.0) { $0 + Self.gainDB($1, at: f) }
        }
        let offset = residual(1000)
        let worst = frequencies.filter { $0 >= 30 && $0 <= 10000 }.map { abs(residual($0) - offset) }.max()!
        XCTAssertLessThan(worst, 1.0, "the fit leaves \(worst) dB of the colouration")
        XCTAssertLessThanOrEqual(preset.preampDB, 0)
        XCTAssertGreaterThan(preset.preampDB, -6)
    }

    /// AutoEq's own result for the same measurement and target lands close to ours.
    func testMatchesAutoEqOnAirPodsPro() throws {
        let measurement = try XCTUnwrap(FrequencyCurve(text: Self.fixture("Apple AirPods Pro.csv")))
        let reference = try EQPreset.autoEq(
            from: Data(Self.autoEqJSON(Self.fixture("Apple AirPods Pro ParametricEQ.txt")).utf8)).first!
        let target = try Self.target("target-in-ear.csv")

        let preset = HeadphoneFit.preset(
            name: "AirPods Pro", source: "Super Review", form: "in-ear", measurement: [measurement], target: target)

        let response = { (bands: [BandSettings], f: Double) in bands.reduce(0.0) { $0 + Self.gainDB($1, at: f) } }
        let difference = { (f: Double) in response(preset.bands, f) - response(reference.bands, f) }
        let band = HeadphoneFit.grid.filter { $0 >= 20 && $0 <= 10000 }
        let offset = difference(1000)
        let rms = (band.map { pow(difference($0) - offset, 2) }.reduce(0, +) / Double(band.count)).squareRoot()
        print("AirPods Pro: \(rms) dB rms from AutoEq, preamp \(preset.preampDB) vs \(reference.preampDB)")
        XCTAssertLessThan(rms, 1.5)
        XCTAssertLessThanOrEqual(preset.preampDB, 0)
    }

    /// Gains lerped between the 50% and 75% fits land close to the curve measured at 62.5%.
    func testVolumeStepsInterpolateToTheMeasuredCurveBetween() throws {
        let target = try Self.target("target-in-ear.csv")
        let curve = { (pct: String) in
            try XCTUnwrap(FrequencyCurve(text: Self.fixture("Apple AirPods Pro 3 \(pct).csv")))
        }
        let preset = HeadphoneFit.preset(
            name: "AirPods Pro 3", source: "Super* Review", form: "in-ear",
            volumes: [(0.75, [try curve("75")]), (0.5, [try curve("50")])], target: target)
        XCTAssertEqual(preset.volumes.map(\.volume), [0.5, 0.75])
        XCTAssertEqual(preset.bands.map(\.gainDB), preset.volumes[0].gainsDB)

        let wanted = HeadphoneFit.correction(measurement: [try curve("62.5")], target: target)
        let direct = HeadphoneFit.fit(wanted)
        let lerped = EQPreset.bands(preset.bands, volumes: preset.volumes, at: 0.625)
        let rms = { (bands: [BandSettings]) in
            let band = HeadphoneFit.grid.indices.filter { HeadphoneFit.grid[$0] <= 10000 }
            let diff = band.map { i in
                bands.reduce(0.0) { $0 + Self.gainDB($1, at: HeadphoneFit.grid[i]) } - wanted[i]
            }
            return (diff.map { $0 * $0 }.reduce(0, +) / Double(diff.count)).squareRoot()
        }
        print("62.5%: lerp \(rms(lerped)) dB rms, direct fit \(rms(direct)) dB rms")
        XCTAssertLessThan(rms(lerped), 1.0)
        XCTAssertLessThan(rms(lerped) - rms(direct), 0.5)
        XCTAssertLessThanOrEqual(preset.preampDB, 0)

        // Outside the measured steps the gains hold; with no steps the bands stay as given.
        let played = { (v: Double) in EQPreset.bands(preset.bands, volumes: preset.volumes, at: v).map(\.gainDB) }
        XCTAssertEqual(played(0.1), preset.volumes[0].gainsDB)
        XCTAssertEqual(played(1), preset.volumes[1].gainsDB)
        XCTAssertEqual(EQPreset.bands(preset.bands, volumes: [], at: 0.3), preset.bands)
    }

    private static func gainDB(_ band: BandSettings, at frequency: Double) -> Double {
        20 * log10(BiquadCoefficients(band, sampleRate: 48000).magnitude(at: frequency, sampleRate: 48000))
    }

    /// The compact JSON row `scripts/autoeq.py` writes for one ParametricEQ.txt.
    private static func autoEqJSON(_ text: String) -> String {
        var preamp = "0"
        var filters: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            if words.first == "Preamp:" { preamp = words[1] }
            guard words.count >= 12, words[2] == "ON" else { continue }
            filters.append("[\"\(words[3])\",\(words[5]),\(words[8]),\(words[11])]")
        }
        let e = filters.joined(separator: ",")
        return "[{\"n\":\"X\",\"m\":\"lab\",\"f\":\"in-ear\",\"p\":\(preamp),\"e\":[\(e)]}]"
    }
}
