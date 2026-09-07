import MixanimoTestSupport
import XCTest
@testable import MixanimoDSP

final class DSPDelayLineTests: XCTestCase {
    func testImpulseComesOutAfterExactlyTheDelay() {
        for delay in [0, 1, 64, 999] {
            let line = DelayLine(maxDelayFrames: 4096, channels: 2, crossfadeFrames: 64)
            defer { line.deallocate() }
            line.setDelay(frames: delay)

            let frames = 2048
            var buffer = [Float](repeating: 0, count: frames * 2)
            buffer[0] = 1
            buffer[1] = 1
            buffer.withUnsafeMutableBufferPointer { line.process($0, frames: frames) }

            for frame in 0..<frames {
                let expected: Float = frame == delay ? 1 : 0
                XCTAssertEqual(buffer[frame * 2], expected, "delay \(delay), frame \(frame)")
                XCTAssertEqual(buffer[frame * 2 + 1], expected, "delay \(delay), frame \(frame)")
            }
        }
    }

    func testDelayChangeDoesNotStepTheSignal() {
        let sampleRate = 48000.0
        let frames = 4096
        let line = DelayLine(maxDelayFrames: 4096, channels: 2, crossfadeFrames: 256)
        defer { line.deallocate() }
        line.setDelay(frames: 100)

        let input = makeSine(frequency: 200, sampleRate: sampleRate, frames: frames * 3)
        var inputStep: Float = 0
        for frame in 1..<(frames * 3) {
            inputStep = max(inputStep, abs(input[frame * 2] - input[(frame - 1) * 2]))
        }

        var output = [Float]()
        var block = [Float](repeating: 0, count: frames * 2)
        for index in 0..<3 {
            if index == 1 { line.setDelay(frames: 700) }
            for sample in 0..<(frames * 2) {
                block[sample] = input[index * frames * 2 + sample]
            }
            block.withUnsafeMutableBufferPointer { line.process($0, frames: frames) }
            output.append(contentsOf: block)
        }

        var worstStep: Float = 0
        for frame in 1..<(frames * 3) {
            worstStep = max(worstStep, abs(output[frame * 2] - output[(frame - 1) * 2]))
        }
        XCTAssertLessThanOrEqual(worstStep, inputStep, "delay change stepped the signal")
        XCTAssertEqual(line.delayFrames, 700)
    }

    func testDelayIsClampedToTheMaximum() {
        let line = DelayLine(maxDelayFrames: 128, channels: 2, crossfadeFrames: 16)
        defer { line.deallocate() }
        line.setDelay(frames: 10_000)
        XCTAssertEqual(line.requestedDelayFrames, 128)
        line.setDelay(frames: -5)
        XCTAssertEqual(line.requestedDelayFrames, 0)
    }

    func testASecondChangeDuringACrossfadeIsHonoured() {
        let line = DelayLine(maxDelayFrames: 2048, channels: 2, crossfadeFrames: 256)
        defer { line.deallocate() }
        var block = [Float](repeating: 0.1, count: 128 * 2)
        block.withUnsafeMutableBufferPointer { line.process($0, frames: 128) }

        line.setDelay(frames: 200)
        block.withUnsafeMutableBufferPointer { line.process($0, frames: 128) }
        XCTAssertEqual(line.delayFrames, 0, "the first fade is still running")

        line.setDelay(frames: 400)
        for _ in 0..<8 {
            block.withUnsafeMutableBufferPointer { line.process($0, frames: 128) }
        }
        XCTAssertEqual(line.delayFrames, 400)
    }

    func testTwoSecondsAt192kFits() {
        let line = DelayLine()
        defer { line.deallocate() }
        XCTAssertGreaterThanOrEqual(line.maxDelayFrames, 2 * 192_000)
    }
}
