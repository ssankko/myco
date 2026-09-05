import MixanimoAtomics

/// Interleaved delay with an equal-gain crossfade whenever the delay changes, so a new delay slides
/// in over a few milliseconds instead of stepping the signal.
///
/// The control thread stores the wanted delay in an atomic slot; the audio thread picks it up at the
/// next block and fades from the old tap to the new one. A change that lands during a fade waits for
/// that fade to finish, so there is only ever one fade in flight.
///
/// All state lives in one allocation, so a copy of the struct is another handle. Call `deallocate()`
/// once, when neither thread runs.
public struct DelayLine: @unchecked Sendable {
    public let maxDelayFrames: Int
    public let channels: Int
    public let crossfadeFrames: Int

    private let capacityFrames: Int
    private let mask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let requested: UnsafeMutablePointer<UInt64>
    private let state: UnsafeMutablePointer<Int>

    // Slots inside `state`, all owned by the audio thread.
    private static let writeIndex = 0
    private static let currentDelay = 1
    private static let fadeTarget = 2
    private static let fadeProgress = 3
    private static let pendingDelay = 4
    private static let primed = 5

    /// `maxDelayFrames` defaults to two seconds at 192 kHz, the longest rate the app publishes.
    public init(maxDelayFrames: Int = 384_000, channels: Int = 2, crossfadeFrames: Int = 256) {
        precondition(maxDelayFrames > 0, "max delay must be positive")
        precondition(channels > 0, "channels must be positive")
        precondition(crossfadeFrames > 0, "crossfade must be positive")
        self.maxDelayFrames = maxDelayFrames
        self.channels = channels
        self.crossfadeFrames = crossfadeFrames
        self.capacityFrames = nextPowerOfTwo(maxDelayFrames + 1)
        self.mask = capacityFrames - 1
        samples = .allocate(capacity: capacityFrames * channels)
        samples.initialize(repeating: 0, count: capacityFrames * channels)
        requested = .allocate(capacity: 1)
        requested.initialize(to: 0)
        state = .allocate(capacity: 6)
        state.initialize(repeating: 0, count: 6)
        state[Self.pendingDelay] = -1
    }

    public func deallocate() {
        samples.deallocate()
        requested.deallocate()
        state.deallocate()
    }

    /// Asks for a new delay, clamped to the maximum. Control thread.
    public func setDelay(frames: Int) {
        let clamped = min(max(frames, 0), maxDelayFrames)
        mixanimo_atomic_store_release(requested, UInt64(clamped))
    }

    /// The delay the audio thread is currently reading at; a fade may still be running towards a
    /// newer value.
    public var delayFrames: Int { state[Self.currentDelay] }

    public var requestedDelayFrames: Int { Int(mixanimo_atomic_load_acquire(requested)) }

    /// Clears the stored audio and jumps straight to the requested delay.
    public func reset() {
        samples.update(repeating: 0, count: capacityFrames * channels)
        state[Self.writeIndex] = 0
        state[Self.currentDelay] = requestedDelayFrames
        state[Self.fadeTarget] = state[Self.currentDelay]
        state[Self.fadeProgress] = 0
        state[Self.pendingDelay] = -1
        state[Self.primed] = 1
    }

    /// Delays an interleaved buffer in place. Audio thread only.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        takeRequestedDelay()

        var write = state[Self.writeIndex]
        var current = state[Self.currentDelay]
        var target = state[Self.fadeTarget]
        var progress = state[Self.fadeProgress]
        let fadeLength = Float(crossfadeFrames)

        for frame in 0..<frames {
            let slot = (write & mask) * channels
            let base = frame * channels
            for channel in 0..<channels {
                samples[slot + channel] = buffer[base + channel]
            }

            if current == target {
                let read = ((write - current) & mask) * channels
                for channel in 0..<channels {
                    buffer[base + channel] = samples[read + channel]
                }
            } else {
                let mix = Float(progress) / fadeLength
                let old = ((write - current) & mask) * channels
                let new = ((write - target) & mask) * channels
                for channel in 0..<channels {
                    buffer[base + channel] =
                        samples[old + channel] * (1 - mix) + samples[new + channel] * mix
                }
                progress += 1
                if progress >= crossfadeFrames {
                    current = target
                    progress = 0
                    if state[Self.pendingDelay] >= 0 {
                        target = state[Self.pendingDelay]
                        state[Self.pendingDelay] = -1
                    }
                }
            }
            write += 1
        }

        state[Self.writeIndex] = write
        state[Self.currentDelay] = current
        state[Self.fadeTarget] = target
        state[Self.fadeProgress] = progress
    }

    public func process(_ buffer: UnsafeMutableBufferPointer<Float>, frames: Int) {
        precondition(frames * channels <= buffer.count, "buffer is shorter than frames")
        guard let base = buffer.baseAddress else { return }
        process(base, frames: frames)
    }

    private func takeRequestedDelay() {
        let wanted = requestedDelayFrames
        // The first block starts at whatever delay is already configured; only a later change fades.
        if state[Self.primed] == 0 {
            state[Self.primed] = 1
            state[Self.currentDelay] = wanted
            state[Self.fadeTarget] = wanted
        } else if state[Self.currentDelay] == state[Self.fadeTarget] {
            state[Self.fadeTarget] = wanted
        } else if wanted != state[Self.fadeTarget] {
            state[Self.pendingDelay] = wanted
        }
    }
}
