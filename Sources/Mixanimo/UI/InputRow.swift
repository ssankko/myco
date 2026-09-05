import SwiftUI

/// One microphone in the mix that other apps hear as Mixanimo Mic.
struct InputRow: View {
    let model: AppModel
    let entry: DeviceEntry

    private var settings: InputSettings { model.input(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("Mix in \(entry.name)", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.signal)
                    .labelsHidden()
                    .accessibilityLabel("Mix in \(entry.name)")
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(settings.enabled ? .primary : .secondary)
                TransportGlyph(transport: entry.device.transportType)
                Spacer(minLength: 0)
            }
            if settings.enabled {
                HStack(spacing: 8) {
                    MeterSlider(
                        label: "\(entry.name) gain", value: gain, range: -60...24, step: 0.5,
                        readout: "\(Readout.decibels(settings.gainDB)) dB", readoutWidth: 58)
                    GlyphToggle(
                        label: "Mute \(entry.name)",
                        symbol: settings.muted ? "mic.slash" : "mic",
                        isOn: binding(\.muted))
                }
            }
        }
        .padding(.vertical, 5)
        .rail(settings.enabled ? (settings.muted ? .armed : .live) : .off)
        .animation(.snappy(duration: 0.18), value: settings.enabled)
    }

    private func binding<T>(_ key: WritableKeyPath<InputSettings, T>) -> Binding<T> {
        Binding(
            get: { model.input(entry.id)[keyPath: key] },
            set: { value in model.updateInput(entry.id) { $0[keyPath: key] = value } })
    }

    private var gain: Binding<Double> {
        Binding(
            get: { Double(model.input(entry.id).gainDB) },
            set: { value in model.updateInput(entry.id) { $0.gainDB = Float(value) } })
    }
}
