import MycoTestSupport
import XCTest
@testable import MycoDSP

/// Ten seconds of the busiest real path: one output at 256 frames pulling 88.2 kHz stereo down to
/// 48 kHz, one `process` call per IO cycle.
final class ResamplerBenchmarkTests: XCTestCase {
    func testTenSecondsOfStereoNoiseTo48k() {
        let ratio = 88200.0 / 48000.0
        let pullFrames = 256
        let pulls = 48000 * 10 / pullFrames
        let noise = makeNoise(frames: 88200 * 11)
        let resampler = Resampler(channels: 2, ratio: ratio)
        defer { resampler.deallocate() }
        var output = [Float](repeating: 0, count: pullFrames * 2)

        measure {
            resampler.reset()
            var offset = 0
            for _ in 0..<pulls {
                let needed = resampler.inputFramesNeeded(forOutput: pullFrames)
                let result = noise.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        resampler.process(
                            input: source.baseAddress! + offset * 2,
                            frames: needed,
                            output: destination.baseAddress!,
                            capacity: pullFrames
                        )
                    }
                }
                offset += result.consumed
            }
        }
    }
}
