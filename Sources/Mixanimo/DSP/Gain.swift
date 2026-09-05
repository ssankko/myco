import Accelerate
import Foundation

/// Below this the gain is treated as silence, which keeps a slider's bottom end at true zero.
public let silenceDecibels: Float = -96

public func decibelsToLinear(_ decibels: Float) -> Float {
    decibels <= silenceDecibels ? 0 : pow(10, decibels / 20)
}

public func linearToDecibels(_ linear: Float) -> Float {
    linear <= 0 ? silenceDecibels : max(silenceDecibels, 20 * log10(linear))
}

/// Linear gain that slides to a new target over a fixed ramp instead of stepping, so a slider move
/// does not click.
///
/// The ramp is recomputed from wherever the current gain sits, so a target that changes mid-ramp
/// still lands smoothly. The audio thread owns the value; hand a new target in the same way the
/// rest of the engine hands over parameters.
public struct SmoothedGain: Sendable {
    public private(set) var current: Float
    public private(set) var target: Float
    /// Frames the gain takes to cover a change.
    public let rampFrames: Int

    private var stepPerFrame: Float = 0

    public init(sampleRate: Double, rampMilliseconds: Double = 5, decibels: Float = 0) {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(rampMilliseconds > 0, "ramp must be positive")
        self.rampFrames = max(1, Int((sampleRate * rampMilliseconds / 1000).rounded()))
        let linear = decibelsToLinear(decibels)
        self.current = linear
        self.target = linear
    }

    public mutating func setTarget(decibels: Float) {
        setTarget(linear: decibelsToLinear(decibels))
    }

    public mutating func setTarget(linear: Float) {
        let wanted = max(0, linear)
        guard wanted != target else { return }
        target = wanted
        stepPerFrame = (target - current) / Float(rampFrames)
    }

    /// Jumps to the target with no ramp, for a stream that has not started yet.
    public mutating func snapToTarget() {
        current = target
        stepPerFrame = 0
    }

    /// Scales an interleaved buffer in place, ramping across the block when the target has moved.
    public mutating func apply(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int
    ) {
        guard frames > 0, channels > 0 else { return }
        let samples = frames * channels
        if current == target || stepPerFrame == 0 {
            current = target
            var gain = current
            vDSP_vsmul(buffer, 1, &gain, buffer, 1, vDSP_Length(samples))
            return
        }

        // The ramp runs per sample rather than per frame, so the two channels of one frame differ by
        // half a step; the step itself is sized so the whole change lands in `rampFrames` frames.
        var step = stepPerFrame / Float(channels)
        let samplesToTarget = max(0, Int(((target - current) / step).rounded(.up)))
        let rampSamples = min(samples, samplesToTarget)
        var start = current
        vDSP_vrampmul(buffer, 1, &start, &step, buffer, 1, vDSP_Length(rampSamples))

        if rampSamples == samplesToTarget {
            current = target
            stepPerFrame = 0
        } else {
            current += step * Float(rampSamples)
        }
        if rampSamples < samples {
            var gain = current
            vDSP_vsmul(
                buffer + rampSamples, 1, &gain,
                buffer + rampSamples, 1, vDSP_Length(samples - rampSamples)
            )
        }
    }

    public mutating func apply(_ buffer: UnsafeMutableBufferPointer<Float>, frames: Int, channels: Int) {
        precondition(frames * channels <= buffer.count, "buffer is shorter than frames")
        guard let base = buffer.baseAddress else { return }
        apply(base, frames: frames, channels: channels)
    }
}
