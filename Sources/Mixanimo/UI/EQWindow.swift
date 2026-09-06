import SwiftUI

/// The ten band equaliser for one output, with the shape it makes drawn above the numbers.
struct EQWindow: View {
    let model: AppModel
    let uid: String

    private var bands: [BandSettings] { model.output(uid).eq }

    /// The rate the device runs at now; the curve is only right at the rate the filters see.
    private var sampleRate: Double {
        let measured = model.outputStatus[uid]?.sampleRate ?? 0
        return measured > 0 ? measured : 48000
    }

    private var name: String {
        (try? AudioDevice.find(uid: uid))??.name.nilIfEmpty ?? uid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(String(format: "%.1f kHz", sampleRate / 1000))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Reset all bands") {
                    model.updateOutput(uid) { $0.eq = OutputSettings.defaultEQ }
                }
                .controlSize(.small)
            }

            ResponseCurve(bands: bands, sampleRate: sampleRate)
                .frame(height: 190)

            columnTitles

            ForEach(bands.indices, id: \.self) { index in
                BandRow(model: model, uid: uid, index: index)
            }
        }
        .padding(16)
        .frame(width: 760)
    }

    private var columnTitles: some View {
        HStack(spacing: 12) {
            Text("Shape").frame(width: 146, alignment: .leading)
            Text("Frequency").frame(width: 222, alignment: .leading)
            Text("Gain").frame(width: 156, alignment: .leading)
            Text("Bandwidth").frame(width: 152, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.rowGap + 2)
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

/// One band. Only the parameters this filter shape reads stay live.
private struct BandRow: View {
    let model: AppModel
    let uid: String
    let index: Int

    private var band: BandSettings { model.output(uid).eq[index] }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Shape", selection: binding(\.type)) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 146)
            .accessibilityLabel("Band \(index + 1) filter shape")

            HStack(spacing: 8) {
                Slider(value: logFrequency, in: 0...1)
                    .controlSize(.mini)
                    .tint(Theme.signal)
                    .accessibilityLabel("Band \(index + 1) frequency")
                    .accessibilityValue(Readout.hertz(band.frequency))
                TextField("Hz", value: binding(\.frequency), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                    .accessibilityLabel("Band \(index + 1) frequency in hertz")
            }
            .frame(width: 222)

            MeterSlider(
                label: "Band \(index + 1) gain", value: binding(\.gainDB), range: -24...24,
                step: 0.1, readout: "\(Readout.decibels(band.gainDB)) dB", readoutWidth: 54)
                .frame(width: 156)
                .disabled(!band.type.usesGain)
                .opacity(band.type.usesGain ? 1 : 0.35)

            MeterSlider(
                label: "Band \(index + 1) bandwidth", value: binding(\.bandwidth), range: 0.05...6,
                step: 0.05, readout: Readout.octaves(band.bandwidth), readoutWidth: 56)
                .frame(width: 152)
                .disabled(!band.type.usesBandwidth)
                .opacity(band.type.usesBandwidth ? 1 : 0.35)

            GlyphToggle(
                label: "Bypass band \(index + 1)", symbol: "power",
                isOn: binding(\.bypass))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .rail(band.bypass ? .off : .live)
        .opacity(band.bypass ? 0.55 : 1)
    }

    private func binding<T>(_ key: WritableKeyPath<BandSettings, T>) -> Binding<T> {
        Binding(
            get: { model.output(uid).eq[index][keyPath: key] },
            set: { value in model.updateOutput(uid) { $0.eq[index][keyPath: key] = value } })
    }

    private var logFrequency: Binding<Double> {
        Binding(
            get: { LogScale.position(of: band.frequency) },
            set: { position in
                model.updateOutput(uid) {
                    $0.eq[index].frequency = (LogScale.frequency(at: position) * 10).rounded() / 10
                }
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
