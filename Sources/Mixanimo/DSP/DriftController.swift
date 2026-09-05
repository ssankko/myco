/// Pulls a ring buffer's fill level towards a target by nudging a resampler's ratio.
///
/// The correction is proportional to the error in frames and clamped, so a wrong fill level is
/// walked back over seconds instead of jumped, which keeps the pitch shift inaudible. A
/// proportional term leaves a standing offset that is exactly the clock difference divided by the
/// gain: at the default gain a source running 100 ppm fast settings one frame away from target.
public struct DriftController: Sendable {
    /// Fill level the ring should settle at, in frames.
    public var targetFillFrames: Double
    /// Ratio change per frame of error.
    public var gain: Double
    /// Largest ratio change allowed, as a fraction.
    public var maxCorrection: Double

    public init(targetFillFrames: Double, gain: Double = 1e-4, maxCorrection: Double = 0.005) {
        precondition(targetFillFrames >= 0, "target fill must not be negative")
        self.targetFillFrames = targetFillFrames
        self.gain = gain
        self.maxCorrection = maxCorrection
    }

    /// Multiplier for the resampler's ratio, that is for input frames consumed per output frame.
    /// A fill above target returns more than one, which drains the ring faster.
    public func ratioMultiplier(fillFrames: Double) -> Double {
        let correction = gain * (fillFrames - targetFillFrames)
        return 1 + min(max(correction, -maxCorrection), maxCorrection)
    }

    public func ratioMultiplier(fillFrames: Int) -> Double {
        ratioMultiplier(fillFrames: Double(fillFrames))
    }
}
