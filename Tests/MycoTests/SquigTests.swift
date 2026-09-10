import Foundation
import XCTest

@testable import Myco

final class SquigTests: XCTestCase {
    private func item(_ labels: [String?]) -> Squig.Item {
        Squig.Item(
            name: "Apple AirPods Pro 3", source: "Super* Review", form: "in-ear",
            data: URL(string: "https://squig.link/data/")!,
            variants: labels.enumerated().map { Squig.Item.Variant(label: $1, file: "file \($0)") })
    }

    func testVolumeSetIsTheLargestAlikeGroupWithTheLaterLabelOnATie() {
        let item = item([
            "(volume: 100% :: firmware: 8A357)", "(volume: 50% :: firmware: 8A357)",
            "(volume: 100% :: firmware: 8A358)", "(volume: 50% :: firmware: 8A358)",
            "(volume: 62.5% :: firmware: 8A358)",
            "(volume: 50% :: accomodations: brightness - slight)",
            "(volume: 50% :: accomodations: brightness - strong)",
        ])
        let set = item.volumeSet
        XCTAssertEqual(set.map(\.volume), [1, 0.5, 0.625])
        XCTAssertEqual(set.map(\.labelWithoutVolume), Array(repeating: "(firmware: 8A358)", count: 3))

        // Two files at one volume are not a set, and neither is a lone volume.
        XCTAssertTrue(self.item(["(volume: 50% :: A)", "(volume: 50% :: B)"]).volumeSet.isEmpty)
        XCTAssertTrue(self.item(["(volume: 50%)", nil]).volumeSet.isEmpty)
        XCTAssertEqual(self.item(["(volume: 25%)", "(volume: 75%)"]).volumeSet.map(\.labelWithoutVolume), [nil, nil])
    }

    func testVariantsAreLabelledBySuffixOrByTheFileNameAfterTheStem() {
        let bySuffix = Squig.variants(files: ["a", "b"], suffixes: ["(ANC)", nil], stem: "X")
        XCTAssertEqual(bySuffix.map(\.label), ["(ANC)", "b"])

        let byFile = Squig.variants(
            files: ["Apple Airpods Pro 3 (70dB, ANC, 8A357)", "Apple Airpods Pro 3 (94dB, Transparency, 8A357)"],
            suffixes: [nil, nil], stem: "Apple Airpods Pro 3")
        XCTAssertEqual(byFile.map(\.label), ["(70dB, ANC, 8A357)", "(94dB, Transparency, 8A357)"])

        XCTAssertNil(Squig.variants(files: ["only"], suffixes: [nil], stem: "only")[0].label)
    }
}
