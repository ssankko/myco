import MycoEngine
import SwiftUI

/// One microphone in the mix that other apps hear as Myco Mic.
struct InputRow: View {
    let model: AppModel
    let entry: DeviceEntry

    @State private var isHovered = false

    private var settings: InputSettings { model.input(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Toggle("Mix in \(entry.name)", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.signal)
                    .labelsHidden()
                    .accessibilityLabel("Mix in \(entry.name)")
                HStack(spacing: 6) {
                    DeviceIcon(
                        name: entry.name, transport: entry.device.transportType, isInput: true,
                        isOn: settings.enabled)
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.enabled ? .primary : .secondary)
                }
                .contentShape(.rect)
                .onTapGesture { model.updateInput(entry.id) { $0.enabled.toggle() } }
                .accessibilityHidden(true)
                Spacer(minLength: 6)
                TransportTag(transport: entry.device.transportType)
            }
            if settings.enabled {
                HStack(spacing: 8) {
                    MeterSlider(
                        label: "\(entry.name) gain", value: gain, range: -60...24, step: 0.5,
                        readout: "\(Readout.decibels(settings.gainDB)) dB", readoutWidth: 58,
                        reset: 0)
                    GlyphToggle(
                        label: "Mute \(entry.name)",
                        symbol: settings.muted ? "mic.slash" : "mic",
                        isOn: binding(\.muted))
                }
            }
        }
        .padding(.trailing, 9)
        .padding(.vertical, settings.enabled ? Theme.cardPadding : 5)
        .rail(settings.enabled ? (settings.muted ? .armed : .live) : .off)
        .background(fill, in: .rect(cornerRadius: Theme.cardRadius))
        .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if settings.enabled { return isHovered ? Theme.cardFillHover : Theme.cardFill }
        return isHovered ? Theme.rowFillHover : .clear
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
