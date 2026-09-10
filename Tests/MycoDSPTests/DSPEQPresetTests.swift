import Foundation
import XCTest
@testable import MycoDSP

final class DSPEQPresetTests: XCTestCase {
    private static let autoEqURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Myco/Resources/autoeq.json")

    func testBundledAutoEqDecodesIntoTenBandPresets() throws {
        let data = try Data(contentsOf: Self.autoEqURL)
        let start = Date()
        let presets = try EQPreset.autoEq(from: data)
        print("autoeq.json: \(presets.count) presets, \(data.count) bytes, decoded in \(Int(-start.timeIntervalSinceNow * 1000)) ms")

        // The six rigs that publish nowhere else; squig.link measurers are read live instead.
        XCTAssertGreaterThan(presets.count, 4500)
        XCTAssertFalse(presets.contains { $0.source == "Super Review" })
        XCTAssertTrue(presets.contains { $0.source == "oratory1990" })
        XCTAssertTrue(presets.allSatisfy { $0.bands.count == Equalizer.bandCount })
        XCTAssertTrue(presets.allSatisfy { ["over-ear", "in-ear", "earbud"].contains($0.form) })
        let shelves = presets.first!.bands.map(\.type)
        XCTAssertTrue(shelves.contains(.lowShelf) && shelves.contains(.highShelf) && shelves.contains(.parametric))
    }

    func testAutoEqRowMapsShapeQAndPadding() throws {
        let json = #"[{"n":"X","m":"lab","f":"in-ear","p":-2.5,"e":[["LSC",105,6.7,0.7],["PK",178,-2.9,1.5],["HSC",10000,-3.1,0.7]]}]"#
        let preset = try XCTUnwrap(EQPreset.autoEq(from: Data(json.utf8)).first)

        XCTAssertEqual(preset.title, "X (lab)")
        XCTAssertEqual(preset.preampDB, -2.5)
        XCTAssertEqual(preset.bands.count, Equalizer.bandCount)
        XCTAssertEqual(preset.bands[0].type, .lowShelf)
        XCTAssertEqual(preset.bands[1].type, .parametric)
        XCTAssertEqual(preset.bands[1].frequency, 178)
        XCTAssertEqual(preset.bands[1].gainDB, -2.9)
        // Q 1.5 is 0.95 octaves between the half-gain points.
        XCTAssertEqual(preset.bands[1].bandwidth, 0.945, accuracy: 0.005)
        XCTAssertEqual(preset.bands[2].type, .highShelf)
        XCTAssertEqual(preset.bands[3], BandSettings(bypass: true))
    }

    func testMoreThanTenFiltersKeepsTheFirstTen() {
        let many = (0..<12).map { BandSettings(frequency: Double(100 * ($0 + 1))) }
        let preset = EQPreset(name: "n", source: "s", form: "", preampDB: 0, bands: many)
        XCTAssertEqual(preset.bands, Array(many.prefix(10)))
    }
}
