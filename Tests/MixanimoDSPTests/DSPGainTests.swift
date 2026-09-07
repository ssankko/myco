import MixanimoTestSupport
import XCTest
@testable import MixanimoDSP

final class DSPGainTests: XCTestCase {
    func testDecibelConversion() {
        XCTAssertEqual(decibelsToLinear(0), 1, accuracy: 1e-6)
        XCTAssertEqual(decibelsToLinear(-6), 0.501187, accuracy: 1e-5)
        XCTAssertEqual(decibelsToLinear(-20), 0.1, accuracy: 1e-6)
        XCTAssertEqual(decibelsToLinear(silenceDecibels), 0)
        XCTAssertEqual(linearToDecibels(decibelsToLinear(-12)), -12, accuracy: 1e-4)
        XCTAssertEqual(linearToDecibels(0), silenceDecibels)
    }

    func testAStepReachesTheTargetInsideTheRamp() {
        let channels = 2
        var gain = SmoothedGain(sampleRate: 48000, rampMilliseconds: 5)
        XCTAssertEqual(gain.rampFrames, 240)
        gain.setTarget(decibels: -20)

        let frames = gain.rampFrames
        var buffer = [Float](repeating: 1, count: frames * channels)
        buffer.withUnsafeMutableBufferPointer { gain.apply($0, frames: frames, channels: channels) }

        XCTAssertEqual(gain.current, 0.1, accuracy: 1e-6)
        XCTAssertEqual(buffer.first, 1)
        for (index, sample) in buffer.enumerated() {
            XCTAssertLessThanOrEqual(sample, 1.0, "sample \(index) rose above the start level")
            XCTAssertGreaterThanOrEqual(sample, 0.1, "sample \(index) fell below the target level")
        }
        XCTAssertTrue(
            zip(buffer, buffer.dropFirst()).allSatisfy { $1 <= $0 },
            "the ramp is not monotonic"
        )

        // The next block sits flat on the target.
        var next = [Float](repeating: 1, count: 64 * channels)
        next.withUnsafeMutableBufferPointer { gain.apply($0, frames: 64, channels: channels) }
        XCTAssertEqual(next, [Float](repeating: 0.1, count: 64 * channels))
    }

    func testARampSpanningSeveralBlocksStillLands() {
        let channels = 2
        var gain = SmoothedGain(sampleRate: 48000, rampMilliseconds: 5)
        gain.setTarget(decibels: -20)
        var buffer = [Float](repeating: 1, count: 64 * channels)
        for _ in 0..<3 {
            buffer.withUnsafeMutableBufferPointer { gain.apply($0, frames: 64, channels: channels) }
            XCTAssertGreaterThan(gain.current, 0.1)
        }
        buffer.withUnsafeMutableBufferPointer { gain.apply($0, frames: 64, channels: channels) }
        XCTAssertEqual(gain.current, 0.1, accuracy: 1e-6)
    }

    func testSnapSkipsTheRamp() {
        let channels = 2
        var gain = SmoothedGain(sampleRate: 48000, rampMilliseconds: 5)
        gain.setTarget(decibels: -6)
        gain.snapToTarget()
        var buffer = [Float](repeating: 1, count: 8 * channels)
        buffer.withUnsafeMutableBufferPointer { gain.apply($0, frames: 8, channels: channels) }
        XCTAssertEqual(buffer, [Float](repeating: decibelsToLinear(-6), count: 8 * channels))
    }

    func testUnityGainLeavesTheBufferAlone() {
        let channels = 2
        var gain = SmoothedGain(sampleRate: 48000)
        let input = makeNoise(frames: 128)
        var buffer = input
        buffer.withUnsafeMutableBufferPointer { gain.apply($0, frames: 128, channels: channels) }
        XCTAssertEqual(buffer, input)
    }
}
