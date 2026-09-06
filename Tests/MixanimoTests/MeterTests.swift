//  What the level meters measure, away from any device.

import XCTest

@testable import Mixanimo

final class MeterTests: XCTestCase {
    func testPeakMagnitudeTakesTheLargestAbsoluteSample() {
        var block: [Float] = [0.1, -0.7, 0.25, -0.05]
        XCTAssertEqual(peakMagnitude(&block, count: block.count), 0.7, accuracy: 1e-6)
        XCTAssertEqual(peakMagnitude(&block, count: 1), 0.1, accuracy: 1e-6)
    }

    func testPeakMagnitudeOfNothingIsZero() {
        var block: [Float] = [1]
        XCTAssertEqual(peakMagnitude(&block, count: 0), 0)
    }

    func testHeldPeakJumpsUpAndFallsBack() {
        XCTAssertEqual(heldPeak(0.2, peak: 0.9), 0.9, accuracy: 1e-6)
        XCTAssertEqual(heldPeak(0.9, peak: 0.1, fallPerPoll: 0.02), 0.88, accuracy: 1e-6)
        XCTAssertEqual(heldPeak(0.01, peak: 0, fallPerPoll: 0.02), 0)
    }
}
