import MycoDSP
import MycoEngine
import SwiftUI

/// The ten band equaliser for one output. The curve is the control: the strip and the inspector
/// under it read out and refine whichever band the user holds.
struct EQPanel: View {
    let model: AppModel
    let uid: String
    let panels: Panels
    /// The panel's height, set by the column beside it; the curve takes what the rest leaves.
    let height: CGFloat

    @State private var selected = 0

    /// The rate the device runs at now; the curve is only right at the rate the filters see.
    private var sampleRate: Double {
        let measured = model.outputStatus[uid]?.sampleRate ?? 0
        return measured > 0 ? measured : 48000
    }

    private var name: String {
        model.settings.outputNames[uid] ?? DeviceNames.guess(uid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header

            ResponseCurve(model: model, uid: uid, sampleRate: sampleRate, selected: $selected)
                .frame(minHeight: 210, maxHeight: .infinity)

            BandStrip(model: model, uid: uid, selected: $selected)

            Divider().opacity(0.6)

            BandInspector(model: model, uid: uid, index: selected)

            footer
        }
        .padding(14)
        .frame(width: 560, height: height, alignment: .top)
        .animation(.snappy(duration: 0.15), value: selected)
    }

    private var header: some View {
        PanelHeader(title: name, panels: panels) {
            PresetButton(model: model, uid: uid)
            Text(String(format: "%.1f kHz", sampleRate / 1000))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Drag a handle. Option-drag sets bandwidth. Double-click bypasses.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("Reset all bands") {
                model.editEQ(uid) { $0 = OutputSettings.defaultEQ }
            }
            .controlSize(.small)
        }
    }
}

/// Ten bands at a glance, each hanging off its own lane. A click brings a band into the inspector.
private struct BandStrip: View {
    let model: AppModel
    let uid: String
    @Binding var selected: Int

    private var bands: [BandSettings] { model.eqBands(uid) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(bands.indices, id: \.self) { index in chip(index) }
        }
    }

    private func chip(_ index: Int) -> some View {
        let band = bands[index]
        let isSelected = index == selected
        return Button {
            selected = index
        } label: {
            VStack(spacing: 3) {
                Capsule()
                    .fill(isSelected ? Theme.signal : Theme.track)
                    .frame(height: 2)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.tertiary))
                Text(Readout.compactHertz(band.frequency))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(band.type.usesGain ? Readout.decibels(band.gainDB) : "—")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                isSelected ? Theme.signal.opacity(0.09) : .clear, in: .rect(cornerRadius: 5))
            .opacity(band.bypass ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(index + 1)")
        .accessibilityValue(
            "\(Readout.hertz(band.frequency))\(band.bypass ? ", bypassed" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Every parameter of the one selected band. Shapes that read no gain or no bandwidth leave those
/// fields dead rather than lying about their effect.
private struct BandInspector: View {
    let model: AppModel
    let uid: String
    let index: Int

    private var band: BandSettings { model.eqBands(uid)[index] }

    var body: some View {
        HStack(spacing: 9) {
            Text("Band \(index + 1)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.signal)
                .frame(width: 48, alignment: .leading)

            Picker("Shape", selection: binding(\.type)) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 148)
            .accessibilityLabel("Band \(index + 1) filter shape")

            field(\.frequency, unit: "Hz", range: 20...20000, digits: 1, width: 58, live: true)
            field(\.gainDB, unit: "dB", range: -24...24, digits: 1, width: 50, live: band.type.usesGain)
            field(\.bandwidth, unit: "oct", range: 0.05...6, digits: 2, width: 50, live: band.type.usesBandwidth)

            Spacer(minLength: 0)

            GlyphToggle(
                label: "Bypass band \(index + 1)", symbol: "power", isOn: binding(\.bypass))
        }
        .opacity(band.bypass ? 0.6 : 1)
    }

    private func field(
        _ key: WritableKeyPath<BandSettings, Double>, unit: String,
        range: ClosedRange<Double>, digits: Int, width: CGFloat, live: Bool
    ) -> some View {
        HStack(spacing: 4) {
            TextField(
                unit, value: clamped(key, to: range),
                format: .number.precision(.fractionLength(0...digits)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .accessibilityLabel("Band \(index + 1) \(name(of: unit))")
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .disabled(!live)
        .opacity(live ? 1 : 0.35)
    }

    private func name(of unit: String) -> String {
        switch unit {
        case "Hz": "frequency in hertz"
        case "dB": "gain in decibels"
        default: "bandwidth in octaves"
        }
    }

    private func binding<T>(_ key: WritableKeyPath<BandSettings, T>) -> Binding<T> {
        Binding(
            get: { model.eqBands(uid)[index][keyPath: key] },
            set: { value in model.editEQ(uid) { $0[index][keyPath: key] = value } })
    }

    private func clamped(
        _ key: WritableKeyPath<BandSettings, Double>, to range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.eqBands(uid)[index][keyPath: key] },
            set: { value in
                let kept = clamp(value, range.lowerBound, range.upperBound)
                model.editEQ(uid) { $0[index][keyPath: key] = kept }
            })
    }
}

extension FilterType {
    var title: String {
        switch self {
        case .parametric: "Parametric"
        case .lowPass: "Low pass"
        case .highPass: "High pass"
        case .resonantLowPass: "Resonant low pass"
        case .resonantHighPass: "Resonant high pass"
        case .bandPass: "Band pass"
        case .bandStop: "Band stop"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .resonantLowShelf: "Resonant low shelf"
        case .resonantHighShelf: "Resonant high shelf"
        }
    }

    /// Shapes that read no gain leave the control dead rather than lying about its effect.
    var usesGain: Bool {
        switch self {
        case .lowPass, .highPass, .bandPass, .bandStop: false
        default: true
        }
    }

    var usesBandwidth: Bool {
        switch self {
        case .parametric, .bandPass, .bandStop, .resonantLowShelf, .resonantHighShelf: true
        default: false
        }
    }
}

/// The top line of a panel, set like the column's own header: the title, what belongs beside it,
/// and the glyph that closes the panel.
struct PanelHeader<Trailing: View>: View {
    let title: String
    let panels: Panels
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            trailing
            Button { panels.open = nil } label: {
                Image(systemName: "xmark").imageScale(.small).frame(width: 14).glyphChrome()
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close panel")
        }
        .accessibilityAddTraits(.isHeader)
    }
}
