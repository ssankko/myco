import Darwin
import Foundation
import MixanimoAtomics

/// The driver's `Mixanimo` ring, mapped read only out of POSIX shared memory.
///
/// The driver is the only writer. After every IO cycle it publishes a free-running frame position
/// with a release store, and an acquire load of that position is the whole handshake: a reader
/// needs no lock and no system call per cycle. The mapping is fixed for the life of the value, so
/// an IO callback may capture a copy of it; that is what `@unchecked Sendable` stands for here.
struct SharedFeed: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let name = "/mixanimo-feed"
    /// 'MXFD', stored last by the driver, so a header carrying it is whole.
    static let magic: UInt32 = 0x4D58_4644
    static let layoutVersion: UInt32 = 1
    /// Bytes the header owns; the interleaved float ring starts right after them.
    static let headerBytes = 4096

    /// Byte offsets inside the header, which the driver's `FeedHeader` fixes.
    private enum Field {
        static let magic = 0
        static let layoutVersion = 4
        static let channels = 8
        static let ringFrames = 12
        static let sampleRate = 16
        static let generation = 24
        static let writeFrame = 64
        static let writeBlockFrames = 72
    }

    let channels: Int
    let ringFrames: Int

    private let base: UnsafeMutableRawPointer
    private let mapBytes: Int
    private let data: UnsafePointer<Float>
    private let writePosition: UnsafePointer<UInt64>
    private let mask: UInt64

    /// Maps the object the driver published. Throws when it is absent, too small, or carries a
    /// layout this build does not know, which is how a stale driver is told apart from a missing one.
    static func open(name: String = SharedFeed.name) throws -> SharedFeed {
        let file = mixanimo_shm_open_read_only(name)
        guard file >= 0 else {
            throw Failure(description: "\(name) is not there, errno \(errno)")
        }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > off_t(headerBytes) else {
            close(file)
            throw Failure(description: "\(name) holds no ring")
        }
        let bytes = Int(info.st_size)
        let map = mmap(nil, bytes, PROT_READ, MAP_SHARED, file, 0)
        close(file)
        guard let map, map != MAP_FAILED else {
            throw Failure(description: "cannot map \(name), errno \(errno)")
        }
        do {
            return try SharedFeed(base: map, bytes: bytes)
        } catch {
            munmap(map, bytes)
            throw error
        }
    }

    /// Takes over a mapping and checks the header against it.
    init(base: UnsafeMutableRawPointer, bytes: Int) throws {
        let magic = base.load(fromByteOffset: Field.magic, as: UInt32.self)
        let version = base.load(fromByteOffset: Field.layoutVersion, as: UInt32.self)
        guard magic == SharedFeed.magic, version == SharedFeed.layoutVersion else {
            throw Failure(
                description: "layout \(version) magic \(String(magic, radix: 16)) is not this build's")
        }
        let channels = Int(base.load(fromByteOffset: Field.channels, as: UInt32.self))
        let ringFrames = Int(base.load(fromByteOffset: Field.ringFrames, as: UInt32.self))
        // Stereo is what the engine's chain carries, so another width is a layout it cannot read.
        guard channels == 2, ringFrames > 0, ringFrames & (ringFrames - 1) == 0,
            SharedFeed.headerBytes + ringFrames * channels * MemoryLayout<Float>.size <= bytes
        else {
            throw Failure(description: "\(ringFrames) frames of \(channels) do not fit \(bytes) bytes")
        }

        self.base = base
        self.mapBytes = bytes
        self.channels = channels
        self.ringFrames = ringFrames
        self.mask = UInt64(ringFrames - 1)
        self.data = UnsafePointer(
            (base + SharedFeed.headerBytes).assumingMemoryBound(to: Float.self))
        self.writePosition = UnsafePointer(
            (base + Field.writeFrame).assumingMemoryBound(to: UInt64.self))

        // An IO callback must not take a page fault, so the whole mapping is made resident now.
        if mlock(base, bytes) != 0 { madvise(base, bytes, MADV_WILLNEED) }
    }

    /// Gives the mapping back. Call it only once every IO callback that captured a copy has gone.
    func unmap() {
        munlock(base, mapBytes)
        munmap(base, mapBytes)
    }

    /// The rate the samples in the ring were written at.
    var sampleRate: Double { base.load(fromByteOffset: Field.sampleRate, as: Double.self) }

    /// Changes when coreaudiod loads the driver again, which is a reader's cue to start over.
    var generation: UInt64 { base.load(fromByteOffset: Field.generation, as: UInt64.self) }

    /// Frames the driver has written since the device last started. Acquire: everything below it is
    /// visible once this is read.
    var writeFrame: UInt64 { mixanimo_atomic_load_acquire(writePosition) }

    /// Frames the driver's last IO cycle carried, that is how far a reader has to sit behind it.
    var writeBlockFrames: Int {
        Int(base.load(fromByteOffset: Field.writeBlockFrames, as: UInt32.self))
    }

    /// Copies interleaved frames starting at a free-running position, wrapping at the end of the
    /// ring. Nothing checks that the driver still has them; the caller's fill level does that.
    /// Audio thread safe.
    func read(from frame: UInt64, into destination: UnsafeMutablePointer<Float>, frames count: Int) {
        guard count > 0 else { return }
        guard count <= ringFrames else {
            destination.update(repeating: 0, count: count * channels)
            return
        }
        let start = Int(frame & mask)
        let head = min(count, ringFrames - start)
        destination.update(from: data + start * channels, count: head * channels)
        if count > head {
            destination.advanced(by: head * channels)
                .update(from: data, count: (count - head) * channels)
        }
    }
}

/// Where one output reads in the driver's shared ring.
///
/// The reader keeps its own free-running position `targetFill` frames behind the driver's. A write
/// position that stops, jumps or goes backwards leaves the output idle and silent until it moves
/// again, when the reader takes a fresh position behind it.
struct FeedReader {
    /// Frames the reader stays behind the driver's write position.
    ///
    /// The driver fills the ring one whole IO block at a time, so a reader closer than that block
    /// runs dry between two of the driver's cycles. It holds the block plus two of its own pulls:
    /// one for the pull in flight and one for the jitter between the two clocks.
    static func targetFill(writeBlock: Int, pull: Int) -> Int { writeBlock + 2 * pull }

    /// What the reader may take this cycle, and whether it just took a fresh position.
    struct Step {
        var fill: Int
        var resynced: Bool
    }

    private(set) var readFrame: UInt64 = 0
    private(set) var idle = true
    private var lastWrite: UInt64 = 0
    private var seenWrite = false
    private var generation: UInt64 = 0

    /// Answers what the ring holds for this reader, or nil when the output must stay silent: the
    /// driver has not moved since the last cycle it was seen at, or the reader has caught up with
    /// it. Audio thread safe.
    mutating func step(write: UInt64, generation: UInt64, target: Int) -> Step? {
        if generation != self.generation {
            self.generation = generation
            idle = true
            seenWrite = false
        }
        defer { lastWrite = write }

        // One cycle of silence buys the position the writer moved from, which tells a running
        // writer from one that stopped long ago and left the ring full of the past.
        guard seenWrite else {
            seenWrite = true
            return nil
        }
        guard !idle else {
            // Forwards only: the driver zeroes its position when the device starts again, and a
            // reader that took the jump would sit in front of everything written since.
            guard Int64(bitPattern: write &- lastWrite) > 0 else { return nil }
            readFrame = write &- UInt64(target)
            idle = false
            return Step(fill: target, resynced: true)
        }
        // Modular arithmetic, so a write position that restarted at zero reads as a huge negative
        // fill and sends the reader back to idle.
        let fill = Int(Int64(bitPattern: write &- readFrame))
        guard fill > 0 else {
            idle = true
            return nil
        }
        return Step(fill: fill, resynced: false)
    }

    /// The reader took `frames`, which the driver has already written.
    mutating func advance(_ frames: Int) { readFrame &+= UInt64(frames) }
}
