import Foundation

/// Filter shapes, matching the set `AVAudioUnitEQFilterType` offers.
public enum FilterType: Int, Sendable, CaseIterable, Codable {
    case parametric
    case lowPass
    case highPass
    case resonantLowPass
    case resonantHighPass
    case bandPass
    case bandStop
    case lowShelf
    case highShelf
    case resonantLowShelf
    case resonantHighShelf
}

/// One band as the user sets it.
///
/// How each type reads the parameters:
///
/// | type | frequency | gainDB | bandwidth |
/// |---|---|---|---|
/// | `parametric` | centre | peak gain | octaves between the half-gain points |
/// | `lowPass`, `highPass` | cutoff | ignored | ignored, Q is fixed at 1/sqrt(2) |
/// | `resonantLowPass`, `resonantHighPass` | cutoff | resonance, Q = 10^(gainDB/20) | ignored |
/// | `bandPass` | centre, unity peak | ignored | octaves between the -3 dB points |
/// | `bandStop` | notch centre | ignored | octaves between the -3 dB points |
/// | `lowShelf`, `highShelf` | half-gain corner | shelf gain | ignored, slope is fixed at S = 1 |
/// | `resonantLowShelf`, `resonantHighShelf` | half-gain corner | shelf gain | octaves, a narrow band puts a bump at the corner |
public struct BandSettings: Sendable, Equatable, Codable {
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    /// Bandwidth in octaves.
    public var bandwidth: Double
    public var bypass: Bool

    public init(
        type: FilterType = .parametric,
        frequency: Double = 1000,
        gainDB: Double = 0,
        bandwidth: Double = 1,
        bypass: Bool = false
    ) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.bandwidth = bandwidth
        self.bypass = bypass
    }
}

/// RBJ cookbook coefficients, already divided by a0 for direct form 2 transposed.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Float
    public var b1: Float
    public var b2: Float
    public var a1: Float
    public var a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passes every sample through untouched, bit for bit.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(_ band: BandSettings, sampleRate: Double) {
        guard !band.bypass, sampleRate > 0 else {
            self = .identity
            return
        }

        // Keep the corner inside the unit circle; at Nyquist the cookbook formulas degenerate.
        let frequency = min(max(band.frequency, 1), sampleRate * 0.49)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let bandwidth = min(max(band.bandwidth, 0.01), 12)

        /// RBJ's bandwidth-in-octaves form; `sinw / (2 * alpha)` is the matching Q.
        let alphaFromBandwidth = sinw * sinh(0.5 * log(2.0) * bandwidth * (sinw > 1e-9 ? w0 / sinw : 1))
        func alpha(q: Double) -> Double { sinw / (2 * max(q, 0.05)) }

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .parametric:
            let a = pow(10, band.gainDB / 40)
            let al = alphaFromBandwidth
            b0 = 1 + al * a
            b1 = -2 * cosw
            b2 = 1 - al * a
            a0 = 1 + al / a
            a1 = -2 * cosw
            a2 = 1 - al / a

        case .lowPass, .resonantLowPass, .highPass, .resonantHighPass:
            let resonant = band.type == .resonantLowPass || band.type == .resonantHighPass
            let al = alpha(q: resonant ? pow(10, band.gainDB / 20) : 0.5.squareRoot())
            a0 = 1 + al
            a1 = -2 * cosw
            a2 = 1 - al
            if band.type == .lowPass || band.type == .resonantLowPass {
                b0 = (1 - cosw) / 2
                b1 = 1 - cosw
                b2 = (1 - cosw) / 2
            } else {
                b0 = (1 + cosw) / 2
                b1 = -(1 + cosw)
                b2 = (1 + cosw) / 2
            }

        case .bandPass:
            let al = alphaFromBandwidth
            b0 = al
            b1 = 0
            b2 = -al
            a0 = 1 + al
            a1 = -2 * cosw
            a2 = 1 - al

        case .bandStop:
            let al = alphaFromBandwidth
            b0 = 1
            b1 = -2 * cosw
            b2 = 1
            a0 = 1 + al
            a1 = -2 * cosw
            a2 = 1 - al

        case .lowShelf, .highShelf, .resonantLowShelf, .resonantHighShelf:
            let a = pow(10, band.gainDB / 40)
            let resonant = band.type == .resonantLowShelf || band.type == .resonantHighShelf
            // A slope of S = 1 is the flattest shelf; the resonant pair takes Q from the bandwidth
            // instead, so a narrow band lifts the corner into a bump.
            let al = resonant ? alphaFromBandwidth : sinw / 2 * (2.0).squareRoot()
            let twoRootA = 2 * a.squareRoot() * al
            if band.type == .lowShelf || band.type == .resonantLowShelf {
                b0 = a * ((a + 1) - (a - 1) * cosw + twoRootA)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
                b2 = a * ((a + 1) - (a - 1) * cosw - twoRootA)
                a0 = (a + 1) + (a - 1) * cosw + twoRootA
                a1 = -2 * ((a - 1) + (a + 1) * cosw)
                a2 = (a + 1) + (a - 1) * cosw - twoRootA
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosw + twoRootA)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
                b2 = a * ((a + 1) + (a - 1) * cosw - twoRootA)
                a0 = (a + 1) - (a - 1) * cosw + twoRootA
                a1 = 2 * ((a - 1) - (a + 1) * cosw)
                a2 = (a + 1) - (a - 1) * cosw - twoRootA
            }
        }

        guard a0.isFinite, abs(a0) > 1e-12 else {
            self = .identity
            return
        }
        self.init(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    /// Magnitude response at `frequency`, useful for drawing a curve.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let cos2w = cos(2 * w), sin2w = sin(2 * w)
        let numeratorReal = Double(b0) + Double(b1) * cosw + Double(b2) * cos2w
        let numeratorImaginary = -(Double(b1) * sinw + Double(b2) * sin2w)
        let denominatorReal = 1 + Double(a1) * cosw + Double(a2) * cos2w
        let denominatorImaginary = -(Double(a1) * sinw + Double(a2) * sin2w)
        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }
}

/// One direct form 2 transposed section with its own two state words.
public struct Biquad: Sendable {
    public var coefficients: BiquadCoefficients
    private var z1: Float
    private var z2: Float

    public init(coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
        self.z1 = 0
        self.z2 = 0
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// Filters one channel of an interleaved buffer in place.
    public mutating func process(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        channel: Int,
        channels: Int
    ) {
        let c = coefficients
        var s1 = z1
        var s2 = z2
        var i = channel
        for _ in 0..<frames {
            let x = buffer[i]
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            buffer[i] = y
            i += channels
        }
        // Denormal state costs hundreds of cycles per sample once the input goes silent.
        z1 = abs(s1) < 1e-25 ? 0 : s1
        z2 = abs(s2) < 1e-25 ? 0 : s2
    }
}
