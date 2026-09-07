import Foundation

/// Interleaved sine, the same tone in every channel.
package func makeSine(
    frequency: Double,
    sampleRate: Double,
    frames: Int,
    channels: Int = 2,
    amplitude: Double = 0.5
) -> [Float] {
    var out = [Float](repeating: 0, count: frames * channels)
    let step = 2 * Double.pi * frequency / sampleRate
    for frame in 0..<frames {
        let value = Float(amplitude * sin(step * Double(frame)))
        for channel in 0..<channels {
            out[frame * channels + channel] = value
        }
    }
    return out
}

/// Repeatable white noise, so a failure can be reproduced.
package func makeNoise(frames: Int, channels: Int = 2, seed: UInt64 = 12345) -> [Float] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var out = [Float](repeating: 0, count: frames * channels)
    for index in 0..<out.count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out[index] = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max) * 0.5
    }
    return out
}

package func rms(_ samples: [Float], channel: Int = 0, channels: Int = 2, range: Range<Int>) -> Double {
    var sum = 0.0
    for frame in range {
        let value = Double(samples[frame * channels + channel])
        sum += value * value
    }
    return (sum / Double(range.count)).squareRoot()
}

package func decibels(_ ratio: Double) -> Double {
    ratio <= 0 ? -200 : 20 * log10(ratio)
}

/// Level of everything that is not the fundamental, relative to the fundamental, in dB.
///
/// A Hann window over the analysis range keeps the ends of the buffer from leaking into the
/// residual; the fundamental is removed by a weighted least-squares fit at the exact frequency.
package func totalDistortionDecibels(
    _ samples: [Float],
    frequency: Double,
    sampleRate: Double,
    channel: Int = 0,
    channels: Int = 2,
    range: Range<Int>
) -> Double {
    let count = range.count
    var window = [Double](repeating: 0, count: count)
    for index in 0..<count {
        window[index] = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count))
    }
    let step = 2 * Double.pi * frequency / sampleRate

    var windowSum = 0.0
    var cosineProjection = 0.0
    var sineProjection = 0.0
    for index in 0..<count {
        let phase = step * Double(range.lowerBound + index)
        let value = Double(samples[(range.lowerBound + index) * channels + channel])
        windowSum += window[index]
        cosineProjection += window[index] * value * cos(phase)
        sineProjection += window[index] * value * sin(phase)
    }
    let a = 2 * cosineProjection / windowSum
    let b = 2 * sineProjection / windowSum

    var residual = 0.0
    for index in 0..<count {
        let phase = step * Double(range.lowerBound + index)
        let value = Double(samples[(range.lowerBound + index) * channels + channel])
        let fitted = a * cos(phase) + b * sin(phase)
        residual += window[index] * (value - fitted) * (value - fitted)
    }
    let fundamental = (a * a + b * b).squareRoot() / (2.0).squareRoot()
    return decibels((residual / windowSum).squareRoot() / fundamental)
}
