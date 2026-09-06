import SwiftUI

/// The audible band mapped onto a horizontal position, the way an EQ is always read.
enum LogScale {
    static let low = 20.0
    static let high = 20000.0

    static func position(of frequency: Double) -> Double {
        let f = min(max(frequency, low), high)
        return log(f / low) / log(high / low)
    }

    static func frequency(at position: Double) -> Double {
        low * pow(high / low, min(max(position, 0), 1))
    }
}

/// The combined response of the ten bands, with each band's own contribution behind it.
struct ResponseCurve: View {
    let bands: [BandSettings]
    let sampleRate: Double
    /// Half the vertical span, in dB.
    private let span = 24.0

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            drawGrid(&context, size)
            for band in bands where !band.bypass {
                context.stroke(
                    path(in: size, bands: [band]), with: .color(Theme.signal.opacity(0.28)),
                    lineWidth: 1)
            }
            let summed = path(in: size, bands: bands)
            context.fill(closed(summed, in: size), with: .color(Theme.signal.opacity(0.13)))
            context.stroke(
                summed, with: .color(Theme.signal),
                style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            drawHandles(&context, size)
        }
        .background(Theme.track.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityLabel("Response curve")
        .accessibilityValue(
            "\(bands.filter { !$0.bypass }.count) of \(bands.count) bands are active")
    }

    private func y(_ decibels: Double, _ size: CGSize) -> CGFloat {
        size.height * (0.5 - min(max(decibels, -span), span) / (2 * span))
    }

    private func path(in size: CGSize, bands: [BandSettings]) -> Path {
        let coefficients = bands.map { BiquadCoefficients($0, sampleRate: sampleRate) }
        let nyquist = sampleRate * 0.49
        var path = Path()
        var x = 0.0
        while x <= size.width {
            let frequency = min(LogScale.frequency(at: x / size.width), nyquist)
            let magnitude = coefficients.reduce(1.0) {
                $0 * $1.magnitude(at: frequency, sampleRate: sampleRate)
            }
            let point = CGPoint(x: x, y: y(20 * log10(max(magnitude, 1e-6)), size))
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
            x += 1
        }
        return path
    }

    /// The curve turned into the area between it and the flat line, for the tint under it.
    private func closed(_ curve: Path, in size: CGSize) -> Path {
        var path = curve
        path.addLine(to: CGPoint(x: size.width, y: y(0, size)))
        path.addLine(to: CGPoint(x: 0, y: y(0, size)))
        path.closeSubpath()
        return path
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        for decibels in [-12.0, 12.0] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(decibels, size)))
            line.addLine(to: CGPoint(x: size.width, y: y(decibels, size)))
            context.stroke(line, with: .color(Theme.track), lineWidth: 1)
        }
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: y(0, size)))
        zero.addLine(to: CGPoint(x: size.width, y: y(0, size)))
        context.stroke(zero, with: .color(Theme.track), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        for frequency in [100.0, 1000.0, 10000.0] {
            let x = size.width * LogScale.position(of: frequency)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Theme.track), lineWidth: 1)
            context.draw(
                Text(Readout.hertz(frequency)).font(.system(size: 9)).foregroundStyle(.tertiary),
                at: CGPoint(x: x + 4, y: size.height - 9), anchor: .leading)
        }
    }

    /// A dot per band at its own frequency and gain, so a row and the curve point at each other.
    private func drawHandles(_ context: inout GraphicsContext, _ size: CGSize) {
        for band in bands {
            let point = CGPoint(
                x: size.width * LogScale.position(of: band.frequency),
                y: y(band.type.usesGain ? band.gainDB : 0, size))
            let dot = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(band.bypass ? Theme.track : Theme.signal))
        }
    }
}
