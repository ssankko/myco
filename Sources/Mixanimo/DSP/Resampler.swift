import Foundation

/// Variable-ratio windowed-sinc resampler for interleaved audio.
///
/// A Kaiser-windowed sinc prototype is tabulated at init and read with linear interpolation between
/// entries, so any fractional position is available without building a filter per block. `ratio` is
/// input frames per output frame and may be nudged between blocks, which is how drift correction
/// pulls a ring buffer back to its target fill.
///
/// When downsampling the prototype is stretched by the ratio, which drops the cutoff to
/// `rolloff` of the output Nyquist and keeps the transition band below the fold point. That
/// stretching is why the tap loop is sized from `maxDownsampleFactor` at init: a factor of two costs
/// 32 taps per side, a factor of four costs 64.
///
/// The table lives in one allocation shared by copies of the struct, but the position and history
/// are per-instance, so use one instance per stream and call `deallocate()` when done.
public struct Resampler: @unchecked Sendable {
    public let channels: Int
    /// Taps taken on each side of the read position at the widest supported downsample factor.
    public let tapsPerSide: Int

    /// Input frames consumed per output frame, that is inputRate / outputRate.
    public var ratio: Double {
        didSet { precondition(ratio > 0, "ratio must be positive") }
    }

    /// Zero crossings on each side of the prototype sinc.
    private static let halfWidth = 16
    /// Table entries per zero crossing.
    private static let phases = 1024
    /// Cutoff as a fraction of the output Nyquist when downsampling.
    private static let rolloff = 0.90

    private let table: UnsafeMutablePointer<Float>
    private let tableCount: Int
    private let historyFrames: Int
    private let history: UnsafeMutablePointer<Float>
    private let position: UnsafeMutablePointer<Double>

    public init(channels: Int = 2, ratio: Double = 1, maxDownsampleFactor: Double = 2) {
        precondition(channels > 0, "channels must be positive")
        precondition(ratio > 0, "ratio must be positive")
        precondition(maxDownsampleFactor >= 1, "max downsample factor must be at least 1")
        self.channels = channels
        self.ratio = ratio
        self.tapsPerSide = Int((Double(Self.halfWidth) * maxDownsampleFactor / Self.rolloff).rounded(.up))

        tableCount = Self.halfWidth * Self.phases + 2
        table = .allocate(capacity: tableCount)
        // Kaiser beta 9 puts the stopband near -90 dB, which is below the noise of 32-bit float audio.
        let beta = 9.0
        let denominator = besselI0(beta)
        for index in 0..<tableCount {
            let x = Double(index) / Double(Self.phases)
            if x >= Double(Self.halfWidth) {
                table[index] = 0
                continue
            }
            let sinc = x < 1e-9 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let window = besselI0(beta * (1 - pow(x / Double(Self.halfWidth), 2)).squareRoot()) / denominator
            table[index] = Float(sinc * window)
        }

        historyFrames = 2 * tapsPerSide
        history = .allocate(capacity: historyFrames * channels)
        history.initialize(repeating: 0, count: historyFrames * channels)
        position = .allocate(capacity: 1)
        position.initialize(to: 0)
    }

    public func deallocate() {
        table.deallocate()
        history.deallocate()
        position.deallocate()
    }

    /// Drops the stored history and returns the read position to the start of the next block.
    public func reset() {
        history.update(repeating: 0, count: historyFrames * channels)
        position.pointee = 0
    }

    /// Input frames the next `process` call needs to be able to produce `frames` output frames.
    public func inputFramesNeeded(forOutput frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let last = position.pointee + Double(frames - 1) * ratio
        return max(0, Int(last.rounded(.down)) + tapsPerSide + 1)
    }

    /// Resamples interleaved input into interleaved output.
    ///
    /// Returns how many input frames were taken and how many output frames were written. Anything
    /// not consumed must be offered again at the front of the next call, which happens whenever the
    /// output capacity runs out before the input does.
    @discardableResult
    public func process(
        input: UnsafePointer<Float>,
        frames: Int,
        output: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> (consumed: Int, produced: Int) {
        let step = ratio
        // Stretching the filter below the output Nyquist is what keeps downsampling free of aliases.
        let scale = step > 1 ? Self.rolloff / step : 1.0
        let tableStep = scale * Double(Self.phases)
        let taps = min(tapsPerSide, Int((Double(Self.halfWidth) / scale).rounded(.up)))
        var p = position.pointee
        var produced = 0

        while produced < capacity {
            let base = Int(p.rounded(.down))
            guard base + taps <= frames - 1 else { break }
            let fraction = p - Double(base)

            for channel in 0..<channels {
                var sum = 0.0
                for offset in 0..<taps {
                    let leftWeight = tap(at: (fraction + Double(offset)) * tableStep)
                    if leftWeight != 0 {
                        sum += Double(sample(input, index: base - offset, channel: channel)) * leftWeight
                    }
                    let rightWeight = tap(at: (1 - fraction + Double(offset)) * tableStep)
                    if rightWeight != 0 {
                        sum += Double(sample(input, index: base + 1 + offset, channel: channel)) * rightWeight
                    }
                }
                output[produced * channels + channel] = Float(sum * scale)
            }

            produced += 1
            p += step
        }

        // Everything up to `historyFrames` before the new origin stays reachable, so the caller can
        // hand over the whole block whenever the output had room for it.
        let consumed = min(frames, max(0, Int(p.rounded(.down)) + tapsPerSide + 1))
        pushHistory(input, frames: consumed)
        position.pointee = p - Double(consumed)
        return (consumed, produced)
    }

    @discardableResult
    public func process(
        input: UnsafeBufferPointer<Float>,
        frames: Int,
        output: UnsafeMutableBufferPointer<Float>,
        capacity: Int
    ) -> (consumed: Int, produced: Int) {
        precondition(frames * channels <= input.count, "input is shorter than frames")
        precondition(capacity * channels <= output.count, "output is shorter than capacity")
        guard let source = input.baseAddress, let destination = output.baseAddress else {
            return (0, 0)
        }
        return process(input: source, frames: frames, output: destination, capacity: capacity)
    }

    /// Reads the prototype at a table position, interpolating between neighbours.
    @inline(__always)
    private func tap(at tablePosition: Double) -> Double {
        let index = Int(tablePosition)
        guard index >= 0, index < tableCount - 1 else { return 0 }
        let fraction = tablePosition - Double(index)
        let low = Double(table[index])
        return low + fraction * (Double(table[index + 1]) - low)
    }

    /// Negative indices reach back into the stored tail of the previous block.
    @inline(__always)
    private func sample(_ input: UnsafePointer<Float>, index: Int, channel: Int) -> Float {
        if index >= 0 { return input[index * channels + channel] }
        let slot = historyFrames + index
        return slot >= 0 ? history[slot * channels + channel] : 0
    }

    private func pushHistory(_ input: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        if frames >= historyFrames {
            history.update(
                from: input + (frames - historyFrames) * channels,
                count: historyFrames * channels
            )
            return
        }
        let kept = historyFrames - frames
        history.update(from: history + frames * channels, count: kept * channels)
        history.advanced(by: kept * channels).update(from: input, count: frames * channels)
    }
}

/// Zeroth-order modified Bessel function, the Kaiser window's shape term.
private func besselI0(_ x: Double) -> Double {
    var sum = 1.0
    var term = 1.0
    let half = x / 2
    for k in 1..<40 {
        term *= half / Double(k)
        sum += term * term
        if term * term < 1e-18 * sum { break }
    }
    return sum
}
