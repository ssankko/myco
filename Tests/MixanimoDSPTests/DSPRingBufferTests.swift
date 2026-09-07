import XCTest
@testable import MixanimoDSP

final class DSPRingBufferTests: XCTestCase {
    func testCapacityRoundsUpToPowerOfTwo() {
        let ring = RingBuffer(capacityFrames: 300, channels: 2)
        defer { ring.deallocate() }
        XCTAssertEqual(ring.capacityFrames, 512)
    }

    func testFillLevelIsExact() {
        let ring = RingBuffer(capacityFrames: 64, channels: 2)
        defer { ring.deallocate() }
        XCTAssertEqual(ring.fillLevel, 0)

        var input = [Float](repeating: 1, count: 64 * 2)
        XCTAssertEqual(input.withUnsafeBufferPointer { ring.write($0, frames: 20) }, 20)
        XCTAssertEqual(ring.fillLevel, 20)
        XCTAssertEqual(ring.freeSpace, 44)

        var output = [Float](repeating: 0, count: 64 * 2)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0, frames: 8) }, 8)
        XCTAssertEqual(ring.fillLevel, 12)

        // A full ring refuses the rest.
        XCTAssertEqual(input.withUnsafeBufferPointer { ring.write($0, frames: 64) }, 52)
        XCTAssertEqual(ring.fillLevel, 64)
        XCTAssertEqual(input.withUnsafeBufferPointer { ring.write($0, frames: 1) }, 0)
        input[0] = 0
    }

    func testWriteAndReadAcrossTheWrapBoundary() {
        let channels = 2
        let ring = RingBuffer(capacityFrames: 16, channels: channels)
        defer { ring.deallocate() }

        // Push the positions close to the end of the storage, then straddle it.
        var counter = 0
        func nextBlock(_ frames: Int) -> [Float] {
            var block = [Float](repeating: 0, count: frames * channels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    block[frame * channels + channel] = Float(counter * 10 + channel)
                }
                counter += 1
            }
            return block
        }

        var scratch = [Float](repeating: 0, count: 32 * channels)
        let warmup = nextBlock(12)
        XCTAssertEqual(warmup.withUnsafeBufferPointer { ring.write($0, frames: 12) }, 12)
        XCTAssertEqual(scratch.withUnsafeMutableBufferPointer { ring.read(into: $0, frames: 12) }, 12)

        let straddling = nextBlock(10)
        XCTAssertEqual(straddling.withUnsafeBufferPointer { ring.write($0, frames: 10) }, 10)
        var readBack = [Float](repeating: -1, count: 10 * channels)
        XCTAssertEqual(readBack.withUnsafeMutableBufferPointer { ring.read(into: $0, frames: 10) }, 10)
        XCTAssertEqual(readBack, straddling)
        XCTAssertEqual(ring.fillLevel, 0)
    }

    func testUnderrunZeroFillsTheRest() {
        let ring = RingBuffer(capacityFrames: 32, channels: 2)
        defer { ring.deallocate() }
        let input = [Float](repeating: 0.25, count: 8 * 2)
        input.withUnsafeBufferPointer { _ = ring.write($0, frames: 8) }

        var output = [Float](repeating: -1, count: 16 * 2)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0, frames: 16) }
        XCTAssertEqual(read, 8)
        XCTAssertEqual(Array(output[0..<16]), [Float](repeating: 0.25, count: 16))
        XCTAssertEqual(Array(output[16..<32]), [Float](repeating: 0, count: 16))
    }

    func testResetEmptiesTheRing() {
        let ring = RingBuffer(capacityFrames: 32, channels: 2)
        defer { ring.deallocate() }
        let input = [Float](repeating: 1, count: 16 * 2)
        input.withUnsafeBufferPointer { _ = ring.write($0, frames: 16) }
        ring.reset()
        XCTAssertEqual(ring.fillLevel, 0)
    }

    func testProducerAndConsumerOnSeparateThreads() {
        let channels = 2
        let ring = RingBuffer(capacityFrames: 1024, channels: channels)
        defer { ring.deallocate() }
        let totalFrames = 200_000

        let producer = Thread {
            var written = 0
            var block = [Float](repeating: 0, count: 128 * channels)
            while written < totalFrames {
                let frames = min(128, totalFrames - written)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        block[frame * channels + channel] = Float(written + frame)
                    }
                }
                var offset = 0
                while offset < frames {
                    let taken = block.withUnsafeBufferPointer {
                        ring.write($0.baseAddress! + offset * channels, frames: frames - offset)
                    }
                    offset += taken
                }
                written += frames
            }
        }

        var mismatches = 0
        var read = 0
        var block = [Float](repeating: 0, count: 96 * channels)
        producer.start()
        while read < totalFrames {
            let got = block.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, frames: min(96, totalFrames - read))
            }
            for frame in 0..<got where block[frame * channels] != Float(read + frame) {
                mismatches += 1
            }
            read += got
        }
        XCTAssertEqual(mismatches, 0)
    }
}
