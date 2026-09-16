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
                    if channelCount > 1 { channelPicker }
                }
            }
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

    private var channelCount: Int { entry.device.inputChannelCount }
    private var chosenChannels: [Int] { settings.channels(available: channelCount) }

    /// Which of the device's channels go into the mix, one check per channel.
    private var channelPicker: some View {
        let names = entry.device.inputChannelNames
        return Menu {
            ForEach(0..<channelCount, id: \.self) { channel in
                let name = channel < names.count ? names[channel] : ""
                Toggle(name.isEmpty ? "Channel \(channel + 1)" : "\(channel + 1)  \(name)", isOn: channelBinding(channel))
            }
        } label: {
            Text("Ch " + chosenChannels.map { String($0 + 1) }.joined(separator: "+"))
                .font(.system(size: 11).monospacedDigit())
        }
        .controlSize(.small)
        .fixedSize()
        .help(
            "Channels of \(entry.name) that go into the mix. Leave the loopback or mix channels of an audio interface off, or other people hear themselves.")
        .accessibilityLabel("Channels of \(entry.name) in the mix")
    }

    /// The last chosen channel stays on, so the mix never goes silent by accident.
    private func channelBinding(_ channel: Int) -> Binding<Bool> {
        Binding(
            get: { model.input(entry.id).channels(available: channelCount).contains(channel) },
            set: { on in
                model.updateInput(entry.id) { settings in
                    var chosen = Set(settings.channels(available: channelCount))
                    if on { chosen.insert(channel) } else if chosen.count > 1 { chosen.remove(channel) }
                    settings.channels = chosen.sorted()
                }
            })
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
