import XCTest
@testable import MycoDSP

final class DSPLatencyTests: XCTestCase {
    func testThreeOutputsAlignWithTheSlowestOne() {
        let outputs = [
            // 1000 frames at 48000 is 20.8333 ms, the slowest of the three.
            OutputLatency(deviceLatency: 400, safetyOffset: 200, streamLatency: 144, bufferSize: 256, sampleRate: 48000),
            // 1500 frames at 96000 is 15.625 ms.
            OutputLatency(deviceLatency: 800, safetyOffset: 300, streamLatency: 144, bufferSize: 256, sampleRate: 96000),
            // 512 frames at 44100 is 11.61 ms.
            OutputLatency(deviceLatency: 128, safetyOffset: 128, streamLatency: 0, bufferSize: 256, sampleRate: 44100),
        ]
        XCTAssertEqual(outputs.map(\.totalFrames), [1000, 1500, 512])
        XCTAssertEqual(alignmentDelays(outputs), [0, 500, 407])
    }

    func testEqualOutputsNeedNoDelay() {
        let output = OutputLatency(deviceLatency: 100, bufferSize: 256, sampleRate: 48000)
        XCTAssertEqual(alignmentDelays([output, output, output]), [0, 0, 0])
    }

    func testAnEmptyListIsEmpty() {
        XCTAssertEqual(alignmentDelays([]), [])
    }
}
