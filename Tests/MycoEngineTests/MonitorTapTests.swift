//  The monitor tap against rings this test writes itself, so it needs no device.

import MycoDSP
import XCTest

@testable import MycoEngine

final class MonitorTapTests: XCTestCase {
    private let frames = 32

    /// Feeds silence in small steps until the tap plays, and answers how much that took.
    private func framesToPrime(_ tap: MonitorTap, into scratch: UnsafeMutablePointer<Float>) -> Int {
        let step = [Float](repeating: 0, count: 16)
        var written = 0
        while written < 20000 {
            step.withUnsafeBufferPointer { tap.rings[0].write($0.baseAddress!, frames: 16) }
            written += 16
            if tap.render(into: scratch, frames: frames) { return written }
        }
        return written
    }

    func testAShortReadEarnsAPullOfMargin() {
        let tap = MonitorTap(rate: 48000, frames: frames)
        defer { tap.deallocate() }
        tap.configure(inputs: 1, producerFrames: 128)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { scratch.deallocate() }
        XCTAssertFalse(tap.render(into: scratch, frames: frames), "empty rings play nothing")

        let first = framesToPrime(tap, into: scratch)
        var renders = 0
        while tap.render(into: scratch, frames: frames), renders < 100 { renders += 1 }
        XCTAssertGreaterThan(renders, 0, "a primed tap plays what it holds before it runs dry")

        let second = framesToPrime(tap, into: scratch)
        XCTAssertGreaterThanOrEqual(second, first + frames, "the tap waits for one more pull after running dry")
    }
}
