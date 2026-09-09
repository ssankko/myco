import MycoDSP
import MycoEngine
import SwiftUI

/// One physical output. Off, it is a quiet single line; on, it becomes a card that shows the level
/// it carries and the controls the user reaches for while playing.
struct OutputRow: View {
    let model: AppModel
    let entry: DeviceEntry
    let panels: Panels

    @State private var isHovered = false

    private var settings: OutputSettings { model.output(entry.id) }
    private var status: OutputStatus { model.outputStatus[entry.id] ?? OutputStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if settings.enabled { chain }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, settings.enabled ? Theme.cardPadding : 5)
        .background(fill, in: .rect(cornerRadius: Theme.cardRadius))
        .onHover { isHovered = $0 }
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
            HStack(spacing: 6) {
                DeviceIcon(
                    name: entry.name, transport: entry.device.transportType, isOn: settings.enabled)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(settings.enabled ? .primary : .secondary)
            }
            .contentShape(.rect)
            .onTapGesture { model.updateOutput(entry.id) { $0.enabled.toggle() } }
            .accessibilityHidden(true)
            Spacer(minLength: 6)
            if !settings.enabled, status.isActive {
                Text("playing")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.signal)
                    .help("Every enabled output is disconnected, so the sound plays here.")
            }
            // Laid out whether shown or not, so the row keeps its shape under the pointer.
            GlyphToggle(
                label: "Play to \(entry.name) when no enabled output is connected",
                symbol: "lifepreserver",
                isOn: Binding(
                    get: { isFallback },
                    set: { model.settings.fallbackOutput = $0 ? entry.id : nil }))
                .opacity(isHovered || isFallback ? 1 : 0)
                .accessibilityHidden(!(isHovered || isFallback))
            TransportTag(transport: entry.device.transportType)
        }
    }

    private var isFallback: Bool { model.settings.fallbackOutput == entry.id }

    @ViewBuilder
    private var chain: some View {
        // A grid, so the monitor level below reads out in the same column as the volume above it.
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                MeterSlider(
                    label: "\(entry.name) volume", value: gain, range: -60...12, step: 0.5,
                    readout: "\(Readout.decibels(settings.gainDB)) dB", readoutWidth: 58,
                    reset: 0)
                GlyphToggle(
                    label: "Monitor microphones on \(entry.name)", symbol: "ear",
                    isOn: binding(\.monitor),
                    help: isMonitorSilent ? "Turn a microphone on below to hear it." : nil)
                Button { panels.toggle(.eq(entry.id)) } label: {
                    Text("EQ")
                        .font(.system(size: 11, weight: .medium))
                        .glyphChrome(isOn: isEQActive)
                }
                .buttonStyle(.borderless)
                .help("Equaliser for \(entry.name)")
                .accessibilityLabel("Open the equaliser for \(entry.name)")
                .accessibilityValue(isEQActive ? "active" : "flat")
            }

            if settings.monitor {
                GridRow {
                    HStack(spacing: 6) {
                        Image(systemName: "ear")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        MeterSlider(
                            label: "Monitor level on \(entry.name)", value: monitorGain,
                            range: -60...12, step: 0.5,
                            readout: "\(Readout.decibels(settings.monitorGainDB)) dB",
                            readoutWidth: 58, reset: 0)
                    }
                }
            }
        }

        details
    }

    /// What the user sets once and the numbers that say how it turned out.
    /// One row while it fits; the readouts drop under the controls only when they do not.
    private var details: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                setup
                Spacer(minLength: 4)
                statusLine
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    setup
                    Spacer(minLength: 4)
                }
                statusLine
            }
        }
    }

    @ViewBuilder
    private var setup: some View {
        bufferPicker
        if model.settings.sync {
            syncTrim
            Text("\(Readout.milliseconds(status.delayMilliseconds)) ms delay")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel(
                    "Delay on \(entry.name), \(Readout.milliseconds(status.delayMilliseconds)) milliseconds")
        }
    }

    private var bufferPicker: some View {
        Picker("Buffer", selection: binding(\.bufferFrames)) {
            Text("Auto (\(OutputNode.defaultBufferFrames(entry.device.transportType)))").tag(UInt32?.none)
            ForEach([32, 64, 128, 256, 512, 1024, 2048] as [UInt32], id: \.self) { frames in
                Text("\(frames)").tag(UInt32?(frames))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 96)
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

    /// The equaliser changes the sound: a live band with gain, or a shape that filters at any gain.
    private var isEQActive: Bool {
        settings.eq.contains { !$0.bypass && ($0.gainDB != 0 || !$0.type.isFlatAtZeroGain) }
    }

    /// The monitor is on and there is no microphone in the mix, so it carries nothing.
    private var isMonitorSilent: Bool {
        settings.monitor && !model.settings.inputs.values.contains(where: \.enabled)
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

private extension FilterType {
    /// Passes the signal through untouched at 0 dB. The other shapes filter whatever the gain is.
    var isFlatAtZeroGain: Bool {
        switch self {
        case .parametric, .lowShelf, .highShelf, .resonantLowShelf, .resonantHighShelf: true
        default: false
        }
    }
}
