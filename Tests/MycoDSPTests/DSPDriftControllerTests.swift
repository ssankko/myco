import XCTest
@testable import MycoDSP

final class DSPDriftControllerTests: XCTestCase {
    func testAFastSourceSettlesAtTheTargetFill() {
        let target = 1024.0
        let controller = DriftController(targetFillFrames: target)
        let baseRatio = 88200.0 / 48000.0
        let outputBlock = 512.0
        let sourceError = 100e-6

        var fill = target + 300
        var lowest = Double.infinity
        var highest = -Double.infinity
        var history = [Double]()

        for block in 0..<2000 {
            let ratio = baseRatio * controller.ratioMultiplier(fillFrames: fill)
            fill += outputBlock * baseRatio * (1 + sourceError) - outputBlock * ratio
            if block > 20 {
                lowest = min(lowest, fill)
                highest = max(highest, fill)
            }
            history.append(fill)
        }

        // The proportional term leaves the clock difference divided by the gain as a standing
        // offset, one frame at the default gain.
        XCTAssertEqual(fill, target, accuracy: 4)
        XCTAssertGreaterThan(lowest, target - 4, "the fill undershot to \(lowest)")
        XCTAssertLessThan(highest, target + 300, "the fill overshot to \(highest)")
        XCTAssertTrue(
            zip(history, history.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 },
            "the fill did not fall monotonically"
        )
    }

    func testASlowSourceIsPulledBackUp() {
        let target = 1024.0
        let controller = DriftController(targetFillFrames: target)
        var fill = target - 300
        for _ in 0..<2000 {
            fill += 512 * (1 - 100e-6) - 512 * controller.ratioMultiplier(fillFrames: fill)
        }
        XCTAssertEqual(fill, target, accuracy: 4)
    }

    func testTheCorrectionIsClamped() {
        let controller = DriftController(targetFillFrames: 1024, gain: 1e-4, maxCorrection: 0.005)
        XCTAssertEqual(controller.ratioMultiplier(fillFrames: 1_000_000), 1.005, accuracy: 1e-12)
        XCTAssertEqual(controller.ratioMultiplier(fillFrames: 0), 0.995, accuracy: 1e-12)
        XCTAssertEqual(controller.ratioMultiplier(fillFrames: 1024), 1.0, accuracy: 1e-12)
    }
}
