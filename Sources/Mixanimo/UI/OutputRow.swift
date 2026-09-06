import SwiftUI

/// One physical output. Off, it is a quiet single line; on, it becomes a card that shows the level
/// it carries and the controls the user reaches for while playing.
struct OutputRow: View {
    let model: AppModel
    let entry: DeviceEntry
    @Environment(\.openWindow) private var openWindow

    /// The buffer size, the sync trim and the measured latency, which are set once and then left.
    @State private var showsMore = false
    @State private var isHovered = false

    private var settings: OutputSettings { model.output(entry.id) }
    private var status: OutputStatus { model.outputStatus[entry.id] ?? OutputStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if settings.enabled { chain }
        }
        .padding(.trailing, 9)
        .padding(.vertical, settings.enabled ? Theme.cardPadding : 5)
        .rail(settings.enabled ? (status.isActive ? .live : .armed) : .off)
        .background(fill, in: .rect(cornerRadius: Theme.cardRadius))
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: settings.enabled)
        .animation(.snappy(duration: 0.18), value: settings.monitor)
        .animation(.snappy(duration: 0.18), value: showsMore)
    }

    private var fill: Color {
        if settings.enabled { return isHovered ? Theme.cardFillHover : Theme.cardFill }
        return isHovered ? Theme.rowFillHover : .clear
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle("Play to \(entry.name)", isOn: binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.signal)
                .labelsHidden()
                .accessibilityLabel("Play to \(entry.name)")
            DeviceIcon(
                name: entry.name, transport: entry.device.transportType, isOn: settings.enabled)
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(settings.enabled ? .primary : .secondary)
            Spacer(minLength: 6)
            TransportTag(transport: entry.device.transportType)
            if settings.enabled {
                MoreToggle(label: "More settings for \(entry.name)", isOn: $showsMore)
            }
        }
    }

    @ViewBuilder
    private var chain: some View {
        HStack(spacing: 8) {
            MeterSlider(
                label: "\(entry.name) volume", value: gain, range: -60...12, step: 0.5,
                readout: "\(Readout.decibels(settings.gainDB)) dB", readoutWidth: 58)
            GlyphToggle(
                label: "Monitor microphones on \(entry.name)", symbol: "ear",
                isOn: binding(\.monitor))
            Button { openWindow(id: "eq", value: entry.id) } label: {
                Text("EQ")
                    .font(.system(size: 11, weight: .medium))
                    .glyphChrome(tint: Theme.signal)
            }
            .buttonStyle(.borderless)
            .help("Equaliser for \(entry.name)")
            .accessibilityLabel("Open the equaliser for \(entry.name)")
        }

        if settings.monitor {
            HStack(spacing: 6) {
                Image(systemName: "ear")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                MeterSlider(
                    label: "Monitor level on \(entry.name)", value: monitorGain, range: -60...12,
                    step: 0.5, readout: "\(Readout.decibels(settings.monitorGainDB)) dB",
                    readoutWidth: 58)
            }
        }

        if showsMore { more }
    }

    private var more: some View {
        HStack(spacing: 8) {
            bufferPicker
            if model.settings.sync { syncTrim }
            Spacer(minLength: 4)
            statusLine
        }
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
        .help("Frames the device plays per cycle. Less is faster and needs more of the machine.")
        .accessibilityLabel("Buffer size for \(entry.name), in frames")
    }

    private var syncTrim: some View {
        Stepper(value: binding(\.syncTrimMilliseconds), in: -100...100, step: 0.5) {
            Text("\(Readout.milliseconds(settings.syncTrimMilliseconds)) ms")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .controlSize(.mini)
        .help("Extra delay for this output on top of the one Align outputs computes.")
        .accessibilityLabel("Sync trim for \(entry.name)")
        .accessibilityValue("\(Readout.milliseconds(settings.syncTrimMilliseconds)) milliseconds")
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if status.isActive {
                Text("\(Readout.milliseconds(status.latencyMilliseconds)) ms out")
                if status.delayMilliseconds > 0 {
                    Text("\(Readout.milliseconds(status.delayMilliseconds)) ms delay")
                }
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
