import Accelerate
import CoreAudio
import MixanimoAtomics

/// One float handed from the control thread to an IO thread without a lock. All state lives in one
/// allocation, so a copy of the struct is another handle; call `deallocate()` when neither runs.
struct AtomicFloat: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<UInt64>

    init(_ value: Float = 0) {
        slot = .allocate(capacity: 1)
        slot.initialize(to: UInt64(value.bitPattern))
    }

    func deallocate() { slot.deallocate() }

    var value: Float {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: mixanimo_atomic_load_acquire(slot))) }
        nonmutating set { mixanimo_atomic_store_release(slot, UInt64(newValue.bitPattern)) }
    }
}

/// A count raised on one IO thread and read from anywhere, which is how the engine reports events
/// that happen in a callback without touching the main actor from it.
struct AtomicCounter: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<UInt64>

    init() {
        slot = .allocate(capacity: 1)
        slot.initialize(to: 0)
    }

    func deallocate() { slot.deallocate() }

    var value: Int { Int(mixanimo_atomic_load_acquire(slot)) }

    /// IO thread only: the single writer needs no read-modify-write.
    func add(_ count: Int) {
        mixanimo_atomic_store_release(slot, mixanimo_atomic_load_relaxed(slot) &+ UInt64(count))
    }

    /// Control thread only, for a count that is handed over rather than accumulated.
    func set(_ value: Int) {
        mixanimo_atomic_store_release(slot, UInt64(max(0, value)))
    }
}

/// Frames one IO cycle carries, taken from the first buffer of the list.
@inline(__always)
func bufferListFrames(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
    guard list.count > 0 else { return 0 }
    let buffer = list[0]
    let channels = Int(buffer.mNumberChannels)
    guard channels > 0 else { return 0 }
    return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
}

/// Strided copy, the interleave and de-interleave step of every gather and scatter.
@inline(__always)
private func copy(
    _ source: UnsafePointer<Float>, stride sourceStride: Int,
    to destination: UnsafeMutablePointer<Float>, stride destinationStride: Int, count: Int
) {
    var zero = Float(0)
    vDSP_vsadd(
        source, vDSP_Stride(sourceStride), &zero, destination, vDSP_Stride(destinationStride),
        vDSP_Length(count))
}

@inline(__always)
private func frames(in buffer: AudioBuffer) -> Int {
    let channels = Int(buffer.mNumberChannels)
    guard channels > 0 else { return 0 }
    return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
}

/// Averages every channel of an interleaved list into one mono block.
func mixToMono(_ list: UnsafeMutableAudioBufferListPointer, frames count: Int, into destination: UnsafeMutablePointer<Float>) {
    destination.update(repeating: 0, count: count)
    var channels = 0
    for buffer in list {
        let width = Int(buffer.mNumberChannels)
        guard width > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let available = min(count, frames(in: buffer))
        for channel in 0..<width {
            vDSP_vadd(
                destination, 1, samples + channel, vDSP_Stride(width), destination, 1,
                vDSP_Length(available))
        }
        channels += width
    }
    guard channels > 1 else { return }
    var scale = 1 / Float(channels)
    vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(count))
}

/// Copies the first two channels of an interleaved list into a stereo block; a mono source goes to
/// both sides.
func mixToStereo(_ list: UnsafeMutableAudioBufferListPointer, frames count: Int, into destination: UnsafeMutablePointer<Float>) {
    destination.update(repeating: 0, count: count * 2)
    var taken = 0
    for buffer in list where taken < 2 {
        let width = Int(buffer.mNumberChannels)
        guard width > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let available = min(count, frames(in: buffer))
        let copies = min(width, 2 - taken)
        for channel in 0..<copies {
            copy(
                samples + channel, stride: width, to: destination + taken + channel, stride: 2,
                count: available)
        }
        taken += copies
    }
    guard taken == 1 else { return }
    copy(destination, stride: 2, to: destination + 1, stride: 2, count: count)
}

/// Writes a stereo block to a device's output list: one channel takes the average, two take the
/// pair, more take the pair on the first two channels and silence elsewhere.
func scatterStereo(_ source: UnsafePointer<Float>, frames count: Int, into list: UnsafeMutableAudioBufferListPointer) {
    var written = 0
    for buffer in list {
        let width = Int(buffer.mNumberChannels)
        guard width > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let available = min(count, frames(in: buffer))
        samples.update(repeating: 0, count: available * width)
        for channel in 0..<width where written + channel < 2 {
            copy(
                source + written + channel, stride: 2, to: samples + channel, stride: width,
                count: available)
        }
        // A mono device would otherwise hear only the left side.
        if width == 1 && written == 0 {
            var half = Float(0.5)
            vDSP_vsmul(samples, 1, &half, samples, 1, vDSP_Length(available))
            vDSP_vsma(source + 1, 2, &half, samples, 1, samples, 1, vDSP_Length(available))
        }
        written += width
    }
}

/// Copies one mono block to every channel of a device's output list.
func scatterMono(_ source: UnsafePointer<Float>, frames count: Int, into list: UnsafeMutableAudioBufferListPointer) {
    for buffer in list {
        let width = Int(buffer.mNumberChannels)
        guard width > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let available = min(count, frames(in: buffer))
        for channel in 0..<width {
            copy(source, stride: 1, to: samples + channel, stride: width, count: available)
        }
    }
}

/// Zeroes every buffer of a list, which is what a callback plays while it waits for its ring to fill.
func silence(_ list: UnsafeMutableAudioBufferListPointer) {
    for buffer in list {
        guard let samples = buffer.mData else { continue }
        memset(samples, 0, Int(buffer.mDataByteSize))
    }
}
