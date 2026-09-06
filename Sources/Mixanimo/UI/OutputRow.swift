import SwiftUI

/// One physical output. Off, it costs a single line; on, it opens into its full chain so the
/// popover stays readable with a dozen devices attached.
struct OutputRow: View {
    let model: AppModel
    let entry: DeviceEntry
    @Environment(\.openWindow) private var openWindow

    private var settings: OutputSettings { model.output(entry.id) }
    private var status: OutputStatus { model.outputStatus[entry.id] ?? OutputStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if settings.enabled { chain }
        }
        .padding(.vertical, 5)
        .rail(settings.enabled ? (status.isActive ? .live : .armed) : .off)
        .animation(.snappy(duration: 0.18), value: settings.enabled)
        .animation(.snappy(duration: 0.18), value: settings.monitor)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle("Play to \(entry.name)", isOn: binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.signal)
                .labelsHidden()
                .accessibilityLabel("Play to \(entry.name)")
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(settings.enabled ? .primary : .secondary)
            TransportGlyph(transport: entry.device.transportType)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var chain: some View {
        MeterSlider(
            label: "\(entry.name) volume", value: gain, range: -60...12, step: 0.5,
            readout: "\(Readout.decibels(settings.gainDB)) dB", readoutWidth: 58)

        HStack(spacing: 8) {
            bufferPicker
            GlyphToggle(
                label: "Monitor microphones on \(entry.name)", symbol: "ear",
                isOn: binding(\.monitor))
            if model.settings.sync { syncTrim }
            Spacer(minLength: 0)
            Button("EQ") { openWindow(id: "eq", value: entry.id) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Theme.signal)
                .accessibilityLabel("Open the equaliser for \(entry.name)")
        }

        if settings.monitor {
            MeterSlider(
                label: "Monitor level on \(entry.name)", value: monitorGain, range: -60...12,
                step: 0.5, readout: "\(Readout.decibels(settings.monitorGainDB)) dB",
                readoutWidth: 58)
            .padding(.leading, 14)
        }

        statusLine
    }

    private var bufferPicker: some View {
        Picker("Buffer", selection: binding(\.bufferFrames)) {
            Text("Auto").tag(UInt32?.none)
            ForEach([32, 64, 128, 256, 512, 1024, 2048] as [UInt32], id: \.self) { frames in
                Text("\(frames)").tag(UInt32?(frames))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 76)
        .accessibilityLabel("Buffer size for \(entry.name), in frames")
    }

    private var syncTrim: some View {
        Stepper(value: binding(\.syncTrimMilliseconds), in: -100...100, step: 0.5) {
            Text("\(Readout.milliseconds(settings.syncTrimMilliseconds)) ms")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .controlSize(.mini)
        .accessibilityLabel("Sync trim for \(entry.name)")
        .accessibilityValue("\(Readout.milliseconds(settings.syncTrimMilliseconds)) milliseconds")
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if status.isActive {
                Text("\(Readout.milliseconds(status.latencyMilliseconds)) ms latency")
                Text("\(Readout.milliseconds(status.delayMilliseconds)) ms delay")
                if status.underruns > 0 {
                    Text("\(status.underruns) underruns").foregroundStyle(Theme.caution)
                }
            } else {
                Text("Waiting for the engine")
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(status.isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .accessibilityElement(children: .combine)
    }

    private func binding<T>(_ key: WritableKeyPath<OutputSettings, T>) -> Binding<T> {
        Binding(
            get: { model.output(entry.id)[keyPath: key] },
            set: { value in model.updateOutput(entry.id) { $0[keyPath: key] = value } })
    }

    private var gain: Binding<Double> { floatBinding(\.gainDB) }
    private var monitorGain: Binding<Double> { floatBinding(\.monitorGainDB) }

    private func floatBinding(_ key: WritableKeyPath<OutputSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.output(entry.id)[keyPath: key]) },
            set: { value in model.updateOutput(entry.id) { $0[keyPath: key] = Float(value) } })
    }
}
