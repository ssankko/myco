import MixanimoAtomics

/// Rounds up to a power of two, so a free-running position becomes an index with a mask.
@inline(__always)
package func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
}

/// Lock-free single-producer single-consumer ring for interleaved float audio.
///
/// The writer owns the write position and the reader owns the read position; each publishes its own
/// with a release store and reads the other with an acquire load, which orders the sample copies
/// around it without a lock. Positions are free-running frame counts, so the fill level is their
/// difference and the power-of-two capacity turns a position into an index with a mask.
///
/// All state lives in one allocation, so a copy of the struct is another handle on the same ring:
/// give one copy to the producer thread and one to the consumer thread. Call `deallocate()` once,
/// when neither thread runs.
public struct RingBuffer: @unchecked Sendable {
    /// Frame capacity, rounded up to a power of two at init.
    public let capacityFrames: Int
    public let channels: Int

    private let mask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let positions: UnsafeMutablePointer<UInt64>

    /// The read position sits a cache line past the write position, so the two threads never fight
    /// over the same line.
    private static let readSlot = 8

    public init(capacityFrames: Int, channels: Int) {
        precondition(capacityFrames > 0, "capacity must be positive")
        precondition(channels > 0, "channels must be positive")
        let capacity = nextPowerOfTwo(capacityFrames)
        self.capacityFrames = capacity
        self.channels = channels
        self.mask = capacity - 1
        self.samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        self.samples.initialize(repeating: 0, count: capacity * channels)
        self.positions = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.readSlot + 1)
        self.positions.initialize(repeating: 0, count: Self.readSlot + 1)
    }

    public func deallocate() {
        samples.deallocate()
        positions.deallocate()
    }

    /// Frames the reader has not taken yet.
    public var fillLevel: Int {
        let write = mixanimo_atomic_load_acquire(positions)
        let read = mixanimo_atomic_load_acquire(positions + Self.readSlot)
        return Int(write &- read)
    }

    /// Frames the writer may still add.
    public var freeSpace: Int { capacityFrames - fillLevel }

    /// Writes up to `frames` interleaved frames and returns how many fit. Producer thread only.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
        let write = mixanimo_atomic_load_relaxed(positions)
        let read = mixanimo_atomic_load_acquire(positions + Self.readSlot)
        let count = min(frames, capacityFrames - Int(write &- read))
        guard count > 0 else { return 0 }

        let start = Int(write) & mask
        let head = min(count, capacityFrames - start)
        samples.advanced(by: start * channels).update(from: source, count: head * channels)
        if count > head {
            samples.update(from: source + head * channels, count: (count - head) * channels)
        }
        mixanimo_atomic_store_release(positions, write &+ UInt64(count))
        return count
    }

    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Float>, frames: Int) -> Int {
        precondition(frames * channels <= source.count, "source is shorter than frames")
        guard let base = source.baseAddress else { return 0 }
        return write(base, frames: frames)
    }

    /// Reads up to `frames` interleaved frames, zero-filling what the writer has not produced, and
    /// returns the number of real frames. Consumer thread only.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let read = mixanimo_atomic_load_relaxed(positions + Self.readSlot)
        let write = mixanimo_atomic_load_acquire(positions)
        let count = min(frames, Int(write &- read))
        if count > 0 {
            let start = Int(read) & mask
            let head = min(count, capacityFrames - start)
            destination.update(from: samples + start * channels, count: head * channels)
            if count > head {
                destination.advanced(by: head * channels)
                    .update(from: samples, count: (count - head) * channels)
            }
            mixanimo_atomic_store_release(positions + Self.readSlot, read &+ UInt64(count))
        }
        if count < frames {
            destination.advanced(by: count * channels)
                .update(repeating: 0, count: (frames - count) * channels)
        }
        return count
    }

    @discardableResult
    public func read(into destination: UnsafeMutableBufferPointer<Float>, frames: Int) -> Int {
        precondition(frames * channels <= destination.count, "destination is shorter than frames")
        guard let base = destination.baseAddress else { return 0 }
        return read(into: base, frames: frames)
    }

    /// Drops everything and returns both positions to zero. Safe only while neither thread runs.
    public func reset() {
        mixanimo_atomic_store_release(positions, 0)
        mixanimo_atomic_store_release(positions + Self.readSlot, 0)
    }
}
