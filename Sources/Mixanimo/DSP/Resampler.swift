import Accelerate
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
    /// Tap weights of the output frame being written, from the leftmost tap to the rightmost.
    private let weights: UnsafeMutablePointer<Float>
    /// Table positions the weights are read from, one per tap.
    private let tablePositions: UnsafeMutablePointer<Float>
    /// The history followed by the head of the current block, so a window that reaches before the
    /// block start is still one contiguous run.
    private let edge: UnsafeMutablePointer<Float>
    private let edgeFrames: Int

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
        weights = .allocate(capacity: 2 * tapsPerSide)
        weights.initialize(repeating: 0, count: 2 * tapsPerSide)
        tablePositions = .allocate(capacity: 2 * tapsPerSide)
        tablePositions.initialize(repeating: 0, count: 2 * tapsPerSide)
        // A window only reaches before the block while the read position is under `tapsPerSide`,
        // so the head this holds never has to be longer than two windows.
        edgeFrames = historyFrames + 2 * tapsPerSide
        edge = .allocate(capacity: edgeFrames * channels)
        edge.initialize(repeating: 0, count: edgeFrames * channels)
    }

    public func deallocate() {
        table.deallocate()
        history.deallocate()
        position.deallocate()
        weights.deallocate()
        tablePositions.deallocate()
        edge.deallocate()
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
        let outputScale = Float(scale)
        var p = position.pointee
        var produced = 0

        fillEdge(input, frames: frames)

        while produced < capacity {
            let base = Int(p.rounded(.down))
            guard base + taps <= frames - 1 else { break }
            makeWeights(fraction: p - Double(base), taps: taps, tableStep: tableStep)

            // The window runs from frame `first` to `base + taps`. Below zero it comes from the
            // edge buffer; a position that drifted before the stored history skips the taps the
            // history no longer holds, which read as zero.
            let first = base - taps + 1
            let skip = first < 0 ? min(2 * taps, max(0, -(historyFrames + first))) : 0
            if skip < 2 * taps {
                let window = first >= 0
                    ? input + first * channels
                    : UnsafePointer(edge + (historyFrames + first + skip) * channels)
                for channel in 0..<channels {
                    var sum: Float = 0
                    vDSP_dotpr(
                        window + channel, vDSP_Stride(channels),
                        weights + skip, 1,
                        &sum, vDSP_Length(2 * taps - skip))
                    output[produced * channels + channel] = sum * outputScale
                }
            } else {
                output.advanced(by: produced * channels).update(repeating: 0, count: channels)
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

    /// Writes the tap weights of one output frame, leftmost tap first.
    ///
    /// The table positions of the taps on each side of the read position form two arithmetic
    /// sequences, so the whole set is one pair of ramps and one interpolated table read. Clipping
    /// them to the last usable entry gives the zero the table already holds past its own end.
    @inline(__always)
    private func makeWeights(fraction: Double, taps: Int, tableStep: Double) {
        var left = Float((fraction + Double(taps - 1)) * tableStep)
        var down = Float(-tableStep)
        vDSP_vramp(&left, &down, tablePositions, 1, vDSP_Length(taps))
        var right = Float((1 - fraction) * tableStep)
        var up = Float(tableStep)
        vDSP_vramp(&right, &up, tablePositions + taps, 1, vDSP_Length(taps))
        var low: Float = 0
        var high = Float(tableCount - 2)
        vDSP_vclip(tablePositions, 1, &low, &high, tablePositions, 1, vDSP_Length(2 * taps))
        vDSP_vlint(
            table, tablePositions, 1, weights, 1, vDSP_Length(2 * taps), vDSP_Length(tableCount))
    }

    /// Lays the stored history and the head of the block end to end.
    @inline(__always)
    private func fillEdge(_ input: UnsafePointer<Float>, frames: Int) {
        edge.update(from: history, count: historyFrames * channels)
        let head = min(frames, edgeFrames - historyFrames)
        guard head > 0 else { return }
        edge.advanced(by: historyFrames * channels).update(from: input, count: head * channels)
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
