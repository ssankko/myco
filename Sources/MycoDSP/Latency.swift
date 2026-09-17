import Foundation

/// What one output reports about its own latency, all in frames at that device's rate.
public struct OutputLatency: Sendable, Equatable {
    public var deviceLatency: Int
    public var safetyOffset: Int
    public var streamLatency: Int
    public var bufferSize: Int
    /// What the feed ring holds while it plays. The audio in the ring is already this old when the
    /// chain picks it up, so it counts as much as the device's own latency.
    public var ringFill: Int
    public var sampleRate: Double

    public init(
        deviceLatency: Int = 0,
        safetyOffset: Int = 0,
        streamLatency: Int = 0,
        bufferSize: Int = 0,
        ringFill: Int = 0,
        sampleRate: Double
    ) {
        self.deviceLatency = deviceLatency
        self.safetyOffset = safetyOffset
        self.streamLatency = streamLatency
        self.bufferSize = bufferSize
        self.ringFill = ringFill
        self.sampleRate = sampleRate
    }

    public var totalFrames: Int {
        deviceLatency + safetyOffset + streamLatency + bufferSize + ringFill
    }

    public var seconds: Double { sampleRate > 0 ? Double(totalFrames) / sampleRate : 0 }
}

/// Delay each output needs so that all of them come out together with the slowest one.
///
/// Latencies are compared in seconds because the outputs run at different rates, and the answer is
/// converted back to frames at each output's own rate.
public func alignmentDelays(_ outputs: [OutputLatency]) -> [Int] {
    guard let slowest = outputs.map(\.seconds).max() else { return [] }
    return outputs.map { output in
        guard output.sampleRate > 0 else { return 0 }
        return max(0, Int(((slowest - output.seconds) * output.sampleRate).rounded()))
    }
}

/// Frames at `rate` the virtual device reports as its own latency: the fastest output's latency
/// plus the delay the engine gives it, so a player that holds video back by that much lands in
/// step with the fastest output. Empty means nothing plays and the device reports zero.
public func reportedLatency(_ outputs: [OutputLatency], delays: [Int], rate: Double) -> Int {
    let seconds = zip(outputs, delays).map { output, delay in
        output.seconds + (output.sampleRate > 0 ? Double(delay) / output.sampleRate : 0)
    }
    guard let fastest = seconds.min(), rate > 0 else { return 0 }
    return Int((fastest * rate).rounded())
}
