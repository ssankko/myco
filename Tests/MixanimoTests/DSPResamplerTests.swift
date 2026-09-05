import XCTest
@testable import Mixanimo

/// Runs a whole signal through one resampler in blocks, the way an IO callback would.
func resampleAll(
    _ input: [Float],
    ratio: Double,
    channels: Int = 2,
    blockFrames: Int = 512
) -> [Float] {
    let resampler = Resampler(channels: channels, ratio: ratio)
    defer { resampler.deallocate() }
    let inputFrames = input.count / channels
    let capacity = blockFrames * 8
    var scratch = [Float](repeating: 0, count: capacity * channels)
    var output = [Float]()
    var offset = 0
    while offset < inputFrames {
        let frames = min(blockFrames, inputFrames - offset)
        let result = input.withUnsafeBufferPointer { source in
            scratch.withUnsafeMutableBufferPointer { destination in
                resampler.process(
                    input: source.baseAddress! + offset * channels,
                    frames: frames,
                    output: destination.baseAddress!,
                    capacity: capacity
                )
            }
        }
        output.append(contentsOf: scratch[0..<(result.produced * channels)])
        if result.consumed == 0 && result.produced == 0 { break }
        offset += result.consumed
    }
    return output
}

final class DSPResamplerTests: XCTestCase {
    private let downRatio = 88200.0 / 48000.0
    /// Amplitude of every test sine, as an RMS value.
    private let referenceLevel = 0.5 / (2.0).squareRoot()

    func testSineSurvivesDownsampling() {
        let input = makeSine(frequency: 1000, sampleRate: 88200, frames: 88200)
        let output = resampleAll(input, ratio: downRatio)
        let frames = output.count / 2
        let middle = (frames / 4)..<(frames * 3 / 4)

        XCTAssertEqual(Double(frames), 88200 / downRatio, accuracy: 64)
        XCTAssertEqual(decibels(rms(output, range: middle) / referenceLevel), 0, accuracy: 0.5)
        XCTAssertLessThan(
            totalDistortionDecibels(output, frequency: 1000, sampleRate: 48000, range: middle),
            -60
        )
    }

    func testContentAboveTheOutputNyquistIsSuppressed() {
        // 25 kHz and 30 kHz at 88200 cannot exist at 48000; whatever comes out is an alias.
        for frequency in [25000.0, 30000.0] {
            let output = resampleAll(
                makeSine(frequency: frequency, sampleRate: 88200, frames: 88200),
                ratio: downRatio
            )
            let frames = output.count / 2
            let level = decibels(rms(output, range: (frames / 4)..<(frames * 3 / 4)) / referenceLevel)
            XCTAssertLessThan(level, -40, "\(frequency) Hz aliased through at \(level) dB")
        }
    }

    func testTwentyKilohertzStaysInsideTheOutputBand() {
        // 20 kHz fits under the 24 kHz Nyquist of 48000, so the resampler must keep it.
        let output = resampleAll(
            makeSine(frequency: 20000, sampleRate: 88200, frames: 88200),
            ratio: downRatio
        )
        let frames = output.count / 2
        let level = decibels(rms(output, range: (frames / 4)..<(frames * 3 / 4)) / referenceLevel)
        XCTAssertEqual(level, 0, accuracy: 1.5)
    }

    func testUpsamplingPreservesASine() {
        let input = makeSine(frequency: 1000, sampleRate: 48000, frames: 48000)
        let output = resampleAll(input, ratio: 48000.0 / 96000.0)
        let frames = output.count / 2
        let middle = (frames / 4)..<(frames * 3 / 4)

        XCTAssertEqual(Double(frames), 96000, accuracy: 64)
        XCTAssertEqual(decibels(rms(output, range: middle) / referenceLevel), 0, accuracy: 0.5)
        XCTAssertLessThan(
            totalDistortionDecibels(output, frequency: 1000, sampleRate: 96000, range: middle),
            -60
        )
    }

    func testARatioNudgeChangesTheProducedFrameCount() {
        let input = makeSine(frequency: 1000, sampleRate: 88200, frames: 441_000)
        let plain = resampleAll(input, ratio: downRatio).count / 2
        let nudged = resampleAll(input, ratio: downRatio * 1.001).count / 2
        let expected = Double(plain) - 441_000 / downRatio * 0.001 / 1.001
        XCTAssertEqual(Double(nudged), expected, accuracy: 2)
    }

    func testInputFramesNeededCoversTheWantedOutput() {
        let resampler = Resampler(channels: 2, ratio: downRatio)
        defer { resampler.deallocate() }
        let wanted = 480
        var produced = 0
        var input = makeSine(frequency: 1000, sampleRate: 88200, frames: 4096)
        var output = [Float](repeating: 0, count: wanted * 2)

        // The first call carries the filter's own startup, later calls settle on a steady count.
        for _ in 0..<4 {
            let needed = resampler.inputFramesNeeded(forOutput: wanted)
            XCTAssertLessThanOrEqual(needed, 4096)
            let result = input.withUnsafeMutableBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    resampler.process(
                        input: source.baseAddress!,
                        frames: needed,
                        output: destination.baseAddress!,
                        capacity: wanted
                    )
                }
            }
            produced = result.produced
            XCTAssertGreaterThanOrEqual(produced, wanted)
        }
    }

    func testChannelsStayIndependent() {
        let frames = 4096
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            input[frame * 2] = Float(sin(Double(frame) * 0.01))
            input[frame * 2 + 1] = 0
        }
        let output = resampleAll(input, ratio: downRatio)
        for frame in 0..<(output.count / 2) {
            XCTAssertEqual(output[frame * 2 + 1], 0)
        }
        XCTAssertGreaterThan(output.map { abs($0) }.max() ?? 0, 0.5)
    }
}
