//  The shared feed's header check and an output's reading position, both against a header this
//  test writes itself, so none of it needs the driver or CoreAudio.

import Darwin
import XCTest

@testable import MycoEngine

final class SharedFeedTests: XCTestCase {
    private let ringFrames = 8
    private var base: UnsafeMutableRawPointer!
    private var bytes = 0

    /// A header shaped like the driver's, over memory this test owns.
    override func setUp() {
        bytes = SharedFeed.headerBytes + ringFrames * 2 * MemoryLayout<Float>.size
        base = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        memset(base, 0, bytes)
        store(SharedFeed.magic, at: 0)
        store(SharedFeed.layoutVersion, at: 4)
        store(UInt32(2), at: 8)
        store(UInt32(ringFrames), at: 12)
        store(Double(48000), at: 16)
        store(UInt64(7), at: 24)
    }

    override func tearDown() {
        munmap(base, bytes)
        base = nil
    }

    private func store<Value>(_ value: Value, at offset: Int) {
        base.storeBytes(of: value, toByteOffset: offset, as: Value.self)
    }

    private func write(frame: UInt64, block: UInt32 = 4) {
        store(block, at: 72)
        store(frame, at: 64)
    }

    private func feed() throws -> SharedFeed { try SharedFeed(base: base, bytes: bytes) }

    // MARK: - Header

    func testHeaderIsRead() throws {
        write(frame: 96, block: 32)
        let feed = try feed()
        XCTAssertEqual(feed.channels, 2)
        XCTAssertEqual(feed.ringFrames, ringFrames)
        XCTAssertEqual(feed.sampleRate, 48000)
        XCTAssertEqual(feed.generation, 7)
        XCTAssertEqual(feed.writeFrame, 96)
        XCTAssertEqual(feed.writeBlockFrames, 32)
    }

    func testAnotherLayoutIsRefused() {
        store(SharedFeed.layoutVersion + 1, at: 4)
        XCTAssertThrowsError(try feed(), "a layout this build cannot read")
        store(SharedFeed.layoutVersion, at: 4)
        store(UInt32(0), at: 0)
        XCTAssertThrowsError(try feed(), "a header the driver has not finished")
    }

    /// A ring larger than the object it sits in would read past the mapping.
    func testARingThatDoesNotFitIsRefused() {
        store(UInt32(ringFrames * 4), at: 12)
        XCTAssertThrowsError(try feed())
    }

    // MARK: - Reading

    func testReadWrapsAroundTheEndOfTheRing() throws {
        let samples = (base + SharedFeed.headerBytes).assumingMemoryBound(to: Float.self)
        for index in 0..<(ringFrames * 2) { samples[index] = Float(index) }
        let feed = try feed()

        var taken = [Float](repeating: -1, count: 8)
        //  Four frames from frame six of a ring of eight: two at the end, two from the start.
        taken.withUnsafeMutableBufferPointer { feed.read(from: 6, into: $0.baseAddress!, frames: 4) }
        XCTAssertEqual(taken, [12, 13, 14, 15, 0, 1, 2, 3])

        //  The position is free running, so the same offset a lap later reads the same frames.
        taken.withUnsafeMutableBufferPointer {
            feed.read(from: 6 + UInt64(ringFrames), into: $0.baseAddress!, frames: 4)
        }
        XCTAssertEqual(taken, [12, 13, 14, 15, 0, 1, 2, 3])
    }

    // MARK: - The reading position

    func testTargetHoldsTheDriverBlockAndTwoPulls() {
        XCTAssertEqual(FeedReader.targetFill(writeBlock: 512, pull: 140), 792)
    }

    /// The first cycle only learns where the writer stands; the second one takes a position behind
    /// it, but only because it moved.
    func testAMovingWriterIsWhatStartsTheReader() {
        var reader = FeedReader()
        XCTAssertNil(reader.step(write: 1000, generation: 1, target: 300))
        XCTAssertNil(reader.step(write: 1000, generation: 1, target: 300), "the writer stands still")

        let step = reader.step(write: 1200, generation: 1, target: 300)
        XCTAssertEqual(step?.fill, 300)
        XCTAssertEqual(step?.resynced, true)
        XCTAssertEqual(reader.readFrame, 900)
        XCTAssertFalse(reader.idle)
    }

    /// A writer that stops leaves the reader to drain what is left, and then to wait.
    func testTheReaderGoesIdleWhenItCatchesUp() {
        var reader = FeedReader()
        _ = reader.step(write: 1000, generation: 1, target: 300)
        _ = reader.step(write: 1200, generation: 1, target: 300)
        reader.advance(200)

        XCTAssertEqual(reader.step(write: 1200, generation: 1, target: 300)?.fill, 100)
        reader.advance(100)
        XCTAssertNil(reader.step(write: 1200, generation: 1, target: 300), "nothing is left")
        XCTAssertTrue(reader.idle)

        let back = reader.step(write: 1500, generation: 1, target: 300)
        XCTAssertEqual(back?.resynced, true)
        XCTAssertEqual(reader.readFrame, 1200)
    }

    /// A driver that loaded again restarts its positions, so the reader drops the one it had.
    func testAGenerationChangeStartsOver() {
        var reader = FeedReader()
        _ = reader.step(write: 1000, generation: 1, target: 300)
        _ = reader.step(write: 1200, generation: 1, target: 300)
        XCTAssertFalse(reader.idle)

        XCTAssertNil(reader.step(write: 40, generation: 2, target: 300))
        XCTAssertTrue(reader.idle)
        let step = reader.step(write: 80, generation: 2, target: 300)
        XCTAssertEqual(step?.resynced, true)
        XCTAssertEqual(step?.fill, 300, "modular arithmetic carries a position behind zero")
        XCTAssertEqual(reader.readFrame, UInt64.max - 219)
    }

    /// The driver zeroes its write position when the device starts again. The reader drops what it
    /// had and waits for the next frames rather than taking a position in front of them.
    func testAWritePositionThatRestartsSendsTheReaderBackToIdle() {
        var reader = FeedReader()
        _ = reader.step(write: 90000, generation: 1, target: 300)
        _ = reader.step(write: 90512, generation: 1, target: 300)
        XCTAssertFalse(reader.idle)

        XCTAssertNil(reader.step(write: 0, generation: 1, target: 300))
        XCTAssertTrue(reader.idle)
        XCTAssertNil(reader.step(write: 0, generation: 1, target: 300), "still nothing written")

        let back = reader.step(write: 512, generation: 1, target: 300)
        XCTAssertEqual(back?.resynced, true)
        XCTAssertEqual(reader.readFrame, 212)
    }
}
