//  The output render against a feed this test writes itself, so it needs neither the driver nor a
//  device: one IO cycle is a buffer list on the stack.

import CoreAudio
import Darwin
import XCTest

@testable import MycoEngine

final class OutputRenderTests: XCTestCase {
    private let ringFrames = 4096
    private let blockFrames = 128
    /// Frames the pretended driver writes at a time.
    private let writeBlock: UInt32 = 512

    private var base: UnsafeMutableRawPointer!
    private var bytes = 0

    /// A header shaped like the driver's over a ring of constant 0.5, so any position reads the
    /// same level and the render's own arithmetic is what the level shows.
    override func setUp() {
        bytes = SharedFeed.headerBytes + ringFrames * 2 * MemoryLayout<Float>.size
        base = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        memset(base, 0, bytes)
        base.storeBytes(of: SharedFeed.magic, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: SharedFeed.layoutVersion, toByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: UInt32(2), toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: UInt32(ringFrames), toByteOffset: 12, as: UInt32.self)
        base.storeBytes(of: Double(48000), toByteOffset: 16, as: Double.self)
        base.storeBytes(of: writeBlock, toByteOffset: 72, as: UInt32.self)
        let samples = (base + SharedFeed.headerBytes).assumingMemoryBound(to: Float.self)
        samples.update(repeating: 0.5, count: ringFrames * 2)
    }

    override func tearDown() {
        munmap(base, bytes)
        base = nil
    }

    private func write(frame: UInt64) {
        base.storeBytes(of: frame, toByteOffset: 64, as: UInt64.self)
    }

    /// The render carries the ring while the writer moves and falls silent once it stops, and it
    /// takes every frame it needs on the way.
    func testTheRenderFollowsTheWriter() throws {
        let feed = try SharedFeed(base: base, bytes: bytes)
        let render = OutputRender(
            feed: feed, virtualRate: 48000, sampleRate: 48000, bufferFrames: blockFrames, gainDB: 0)
        defer { render.deallocate() }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * 2)
        defer { samples.deallocate() }
        list[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(blockFrames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(samples))

        //  Nothing has been published, so the first cycle only learns where the writer stands.
        samples.update(repeating: 1, count: blockFrames * 2)
        render.render(into: list)
        XCTAssertEqual(samples[0], 0, "a writer that never moved must play silence")

        var frame = UInt64(2048)
        for _ in 0..<40 {
            frame &+= UInt64(blockFrames)
            write(frame: frame)
            render.render(into: list)
        }
        let mean = (0..<(blockFrames * 2)).reduce(0) { $0 + Double(samples[$1]) } / Double(blockFrames * 2)
        XCTAssertEqual(mean, 0.5, accuracy: 0.05, "the level the ring carries")
        XCTAssertEqual(render.underruns.value, 0)
        XCTAssertGreaterThan(render.frames.value, 40 * blockFrames - Int(writeBlock))

        //  The writer stopped: the render drains what is left behind it and then waits.
        for _ in 0..<40 { render.render(into: list) }
        XCTAssertEqual(samples.pointee, 0, "the render kept playing a ring that stopped")
    }
}
