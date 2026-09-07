import AppKit
import MixanimoDSP
import MixanimoEngine
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

/// The vertical axis of the plot: symmetric decibels, loud at the top.
enum CurveAxis {
    /// Half the vertical span, in dB.
    static let span = 24.0

    static func y(_ decibels: Double, in height: CGFloat) -> CGFloat {
        height * (0.5 - min(max(decibels, -span), span) / (2 * span))
    }
}

/// The combined response of the ten bands, and the surface the user shapes it on.
///
/// A drag moves the band under the pointer: sideways for frequency, up and down for gain, and
/// with Option held, up and down for bandwidth. A double click bypasses the band.
struct ResponseCurve: View {
    let model: AppModel
    let uid: String
    let sampleRate: Double
    @Binding var selected: Int

    /// The band as it stood when the drag began, so the pointer keeps its grip on the handle.
    @State private var anchor: (index: Int, band: BandSettings)?

    private var bands: [BandSettings] { model.output(uid).eq }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas(rendersAsynchronously: false) { context, size in
                drawGrid(&context, size)
                for (index, band) in bands.enumerated() where !band.bypass {
                    context.stroke(
                        path(in: size, bands: [band]),
                        with: .color(Theme.signal.opacity(index == selected ? 0.6 : 0.24)),
                        lineWidth: index == selected ? 1.4 : 1)
                }
                let summed = path(in: size, bands: bands)
                context.fill(closed(summed, in: size), with: .color(Theme.signal.opacity(0.13)))
                context.stroke(
                    summed, with: .color(Theme.signal),
                    style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            .overlay {
                ForEach(bands.indices, id: \.self) { index in
                    handle(index, in: size)
                }
            }
        }
        .background(Theme.track.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityLabel("Response curve")
        .accessibilityValue(
            "\(bands.filter { !$0.bypass }.count) of \(bands.count) bands are active")
    }

    // MARK: Handles

    private func handle(_ index: Int, in size: CGSize) -> some View {
        let band = bands[index]
        return BandHandle(
            number: index + 1, isSelected: index == selected, isBypassed: band.bypass)
            .position(
                x: size.width * LogScale.position(of: band.frequency),
                y: CurveAxis.y(band.type.usesGain ? band.gainDB : 0, in: size.height))
            .onTapGesture(count: 2) {
                model.updateOutput(uid) { $0.eq[index].bypass.toggle() }
            }
            .onTapGesture { selected = index }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        if anchor?.index != index {
                            anchor = (index, band)
                            selected = index
                        }
                        guard let start = anchor?.band else { return }
                        apply(drag.translation, from: start, to: index, in: size)
                    }
                    .onEnded { _ in anchor = nil })
            .accessibilityElement()
            .accessibilityLabel("Band \(index + 1) handle")
            .accessibilityValue(Self.spoken(band))
            .accessibilityHint("Adjust to move the band along the spectrum")
            .accessibilityAddTraits(index == selected ? [.isSelected] : [])
            .accessibilityAdjustableAction { direction in
                selected = index
                let step = pow(2.0, direction == .increment ? 1.0 / 3 : -1.0 / 3)
                model.updateOutput(uid) {
                    $0.eq[index].frequency = clamp(band.frequency * step, 20, 20000)
                }
            }
    }

    /// Writes the band the drag now describes. Option takes the same pointer to bandwidth, for
    /// the shapes that read it.
    private func apply(_ translation: CGSize, from start: BandSettings, to index: Int, in size: CGSize) {
        var band = start
        if NSEvent.modifierFlags.contains(.option), start.type.usesBandwidth {
            let octaves = start.bandwidth * pow(2, Double(translation.height) / 90)
            band.bandwidth = (clamp(octaves, 0.05, 6) * 100).rounded() / 100
        } else {
            let position = LogScale.position(of: start.frequency)
                + Double(translation.width) / Double(max(size.width, 1))
            band.frequency = (LogScale.frequency(at: position) * 10).rounded() / 10
            if start.type.usesGain {
                let decibels = start.gainDB
                    - Double(translation.height) / Double(max(size.height, 1)) * 2 * CurveAxis.span
                band.gainDB = (clamp(decibels, -CurveAxis.span, CurveAxis.span) * 10).rounded() / 10
            }
        }
        model.updateOutput(uid) { $0.eq[index] = band }
    }

    private static func spoken(_ band: BandSettings) -> String {
        var parts = [Readout.hertz(band.frequency)]
        if band.type.usesGain { parts.append("\(Readout.decibels(band.gainDB)) decibels") }
        if band.type.usesBandwidth { parts.append(Readout.octaves(band.bandwidth)) }
        if band.bypass { parts.append("bypassed") }
        return parts.joined(separator: ", ")
    }

    // MARK: Drawing

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
            let point = CGPoint(
                x: x, y: CurveAxis.y(20 * log10(max(magnitude, 1e-6)), in: size.height))
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
            x += 1
        }
        return path
    }

    /// The curve turned into the area between it and the flat line, for the tint under it.
    private func closed(_ curve: Path, in size: CGSize) -> Path {
        var path = curve
        path.addLine(to: CGPoint(x: size.width, y: CurveAxis.y(0, in: size.height)))
        path.addLine(to: CGPoint(x: 0, y: CurveAxis.y(0, in: size.height)))
        path.closeSubpath()
        return path
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        for decibels in [-12.0, 12.0] {
            let y = CurveAxis.y(decibels, in: size.height)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Theme.track), lineWidth: 1)
            context.draw(
                caption(String(format: "%+.0f", decibels)), at: CGPoint(x: 6, y: y - 7),
                anchor: .leading)
        }
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: CurveAxis.y(0, in: size.height)))
        zero.addLine(to: CGPoint(x: size.width, y: CurveAxis.y(0, in: size.height)))
        context.stroke(zero, with: .color(Theme.track), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        for frequency in [100.0, 1000.0, 10000.0] {
            let x = size.width * LogScale.position(of: frequency)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Theme.track), lineWidth: 1)
            let label = frequency >= 1000
                ? String(format: "%.0f kHz", frequency / 1000)
                : String(format: "%.0f Hz", frequency)
            context.draw(caption(label), at: CGPoint(x: x + 5, y: size.height - 9), anchor: .leading)
        }
    }

    private func caption(_ text: String) -> Text {
        Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
    }
}

/// One band's grip on the curve. The number ties the handle to its chip and to the inspector.
private struct BandHandle: View {
    let number: Int
    let isSelected: Bool
    let isBypassed: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(isSelected ? Color(nsColor: .textBackgroundColor) : Theme.signal)
            .frame(width: 18, height: 18)
            .background(isSelected ? Theme.signal : Theme.signal.opacity(0.16), in: Circle())
            .overlay(Circle().stroke(Theme.signal.opacity(isSelected ? 0 : 0.5), lineWidth: 1))
            .opacity(isBypassed ? 0.4 : 1)
            .padding(4)
            .contentShape(Rectangle())
    }
}

func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}
