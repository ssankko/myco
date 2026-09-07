import MycoAtomics

/// Ten bands of biquad per channel, one instance per output.
///
/// Coefficient handover: two published coefficient sets and a generation counter. The control
/// thread fills the set the counter does not point at, then bumps the counter with a release store.
/// The audio thread loads the counter, copies the set it points at into scratch, and reloads the
/// counter; a match means no publish overlapped the copy and the coefficients move into the
/// filters, a mismatch means the copy is dropped and the next block picks the change up. That gives
/// the audio thread a consistent set with no lock and no wait.
///
/// All state lives in one allocation, so a copy of the struct is another handle: hand one to the
/// audio thread and keep one on the control thread. Call `deallocate()` once, when neither runs.
public struct Equalizer: @unchecked Sendable {
    public static let bandCount = 10

    public let sampleRate: Double
    public let channels: Int

    private let generation: UnsafeMutablePointer<UInt64>
    private let published: UnsafeMutablePointer<BiquadCoefficients>
    private let scratch: UnsafeMutablePointer<BiquadCoefficients>
    private let filters: UnsafeMutablePointer<Biquad>
    private let appliedGeneration: UnsafeMutablePointer<UInt64>

    public init(sampleRate: Double, channels: Int = 2) {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(channels > 0, "channels must be positive")
        self.sampleRate = sampleRate
        self.channels = channels

        let bands = Self.bandCount
        generation = .allocate(capacity: 1)
        generation.initialize(to: 0)
        appliedGeneration = .allocate(capacity: 1)
        appliedGeneration.initialize(to: 0)
        published = .allocate(capacity: bands * 2)
        published.initialize(repeating: .identity, count: bands * 2)
        scratch = .allocate(capacity: bands)
        scratch.initialize(repeating: .identity, count: bands)
        filters = .allocate(capacity: bands * channels)
        filters.initialize(repeating: Biquad(), count: bands * channels)
    }

    public func deallocate() {
        generation.deallocate()
        appliedGeneration.deallocate()
        published.deallocate()
        scratch.deallocate()
        filters.deallocate()
    }

    /// Publishes a whole set of bands. Control thread only; a bypassed band becomes an identity
    /// section, which passes its input through bit for bit.
    public func setBands(_ bands: [BandSettings]) {
        precondition(bands.count == Self.bandCount, "expected \(Self.bandCount) bands")
        let next = myco_atomic_load_relaxed(generation) &+ 1
        let slot = Int(next % 2) * Self.bandCount
        for index in 0..<Self.bandCount {
            published[slot + index] = BiquadCoefficients(bands[index], sampleRate: sampleRate)
        }
        myco_atomic_store_release(generation, next)
    }

    /// Clears every filter's state. Audio thread, between streams.
    public func reset() {
        for index in 0..<(Self.bandCount * channels) {
            filters[index].reset()
        }
    }

    /// Filters an interleaved buffer in place. Audio thread only.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        adoptPublishedCoefficients()
        guard frames > 0 else { return }
        for band in 0..<Self.bandCount {
            for channel in 0..<channels {
                filters[band * channels + channel]
                    .process(buffer, frames: frames, channel: channel, channels: channels)
            }
        }
    }

    public func process(_ buffer: UnsafeMutableBufferPointer<Float>, frames: Int) {
        precondition(frames * channels <= buffer.count, "buffer is shorter than frames")
        guard let base = buffer.baseAddress else { return }
        process(base, frames: frames)
    }

    private func adoptPublishedCoefficients() {
        let seen = myco_atomic_load_acquire(generation)
        guard seen != myco_atomic_load_relaxed(appliedGeneration) else { return }
        let slot = Int(seen % 2) * Self.bandCount
        scratch.update(from: published + slot, count: Self.bandCount)
        guard myco_atomic_load_acquire(generation) == seen else { return }
        for band in 0..<Self.bandCount {
            for channel in 0..<channels {
                filters[band * channels + channel].coefficients = scratch[band]
            }
        }
        myco_atomic_store_relaxed(appliedGeneration, seen)
    }
}
