//  The sample helpers the IO procs call, on buffer lists this test builds itself, so they need
//  no device.

import CoreAudio
import XCTest

@testable import MycoEngine

final class RealtimeTests: XCTestCase {
    /// Four interleaved channels holding 1, 2, 3 and 4.
    func testMonoMixdownTakesOnlyTheChosenChannels() {
        let frames = 8
        let width = 4
        var samples = (0..<frames * width).map { Float($0 % width + 1) }
        var out = [Float](repeating: 0, count: frames)
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(width), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            let pointer = UnsafeMutableAudioBufferListPointer(&list)
            out.withUnsafeMutableBufferPointer { destination in
                mixToMono(pointer, channels: [0, 1], frames: frames, into: destination.baseAddress!)
                XCTAssertEqual(destination[0], 1.5, "the first two average")
                XCTAssertEqual(destination[frames - 1], 1.5)
                mixToMono(pointer, channels: [2], frames: frames, into: destination.baseAddress!)
                XCTAssertEqual(destination[0], 3, "one channel passes as it is")
                mixToMono(pointer, channels: [7], frames: frames, into: destination.baseAddress!)
                XCTAssertEqual(destination[0], 0, "a channel the device lacks adds nothing")
            }
        }
    }

    func testDefaultChannelsAreAllOfTwoAndTheFirstTwoOfMore() {
        XCTAssertEqual(InputSettings().channels(available: 1), [0])
        XCTAssertEqual(InputSettings().channels(available: 2), [0, 1])
        XCTAssertEqual(InputSettings().channels(available: 4), [0, 1])
        var chosen = InputSettings()
        chosen.channels = [2, 9]
        XCTAssertEqual(chosen.channels(available: 4), [2], "a channel the device lacks is dropped")
        XCTAssertEqual(chosen.channels(available: 2), [0, 1], "none left falls back to the default")
    }
}
