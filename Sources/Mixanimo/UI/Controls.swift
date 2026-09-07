import AppKit
import SwiftUI

/// A device paired with the UID its settings are stored under.
struct DeviceEntry: Identifiable {
    let id: String
    let device: AudioDevice
    var name: String { device.name.isEmpty ? id : device.name }
}

extension Array where Element == AudioDevice {
    /// Drops the devices with no UID and Mixanimo's own virtual pair, which the user never routes.
    @MainActor var routable: [DeviceEntry] {
        compactMap { device in
            guard let uid = try? device.uid,
                  uid != AppModel.outputDeviceUID, uid != AppModel.micDeviceUID
            else { return nil }
            return DeviceEntry(id: uid, device: device)
        }
    }
}

/// The lane down the left of every device row. The list reads as a patch bay: a continuous
/// hairline with the working devices lit.
struct Rail: View {
    enum Level { case off, armed, live }
    let level: Level

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch level {
        case .off: Theme.track
        case .armed: Theme.signal.opacity(0.35)
        case .live: Theme.signal
        }
    }
}

extension View {
    /// Hangs the row off its rail. An overlay, so the rail takes the row's height instead of
    /// setting it.
    func rail(_ level: Rail.Level) -> some View {
        padding(.leading, Theme.rowGap + 2)
            .overlay(alignment: .leading) { Rail(level: level) }
    }
}

/// A section title, what the section does to the audio, and how much of it is on.
struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the device is, from the name it reports and the way it is wired: the picture that finds a
/// pair of headphones in a list faster than its name does.
struct DeviceIcon: View {
    let name: String
    let transport: AudioDevice.TransportType
    var isInput = false
    var isOn = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .frame(width: 18, height: 15)
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        let lowered = name.lowercased()
        if lowered.contains("airpod") { return "airpods" }
        if isInput { return "mic" }
        if ["headphone", "headset", "earphone", "buds", "beats"].contains(where: lowered.contains) {
            return "headphones"
        }
        switch transport {
        case .builtIn: return "hifispeaker"
        case .bluetooth, .bluetoothLE: return "headphones"
        case .usb: return "cable.connector"
        case .airPlay: return "airplayaudio"
        case .continuity: return "iphone"
        case .aggregate: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}

/// How the device is wired, in a word.
struct TransportTag: View {
    let transport: AudioDevice.TransportType

    var body: some View {
        Text(transport.title)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Connected over \(transport.title)")
    }
}

extension AudioDevice.TransportType {
    var title: String {
        switch self {
        case .builtIn: "Built in"
        case .bluetooth, .bluetoothLE: "Bluetooth"
        case .usb: "USB"
        case .virtual: "Virtual"
        case .aggregate: "Aggregate"
        case .airPlay: "AirPlay"
        case .continuity: "Continuity"
        default: "Other"
        }
    }
}

/// A slider with its number pinned to a fixed-width column, so a stack of them lines up.
struct MeterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    var readoutWidth: CGFloat = 52
    /// Where a double click on the readout puts the value.
    var reset: Double?

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step)
                .controlSize(.mini)
                .tint(Theme.signal)
                .accessibilityLabel(label)
                .accessibilityValue(readout)
            number
        }
    }

    @ViewBuilder
    private var number: some View {
        let text = Text(readout)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: readoutWidth, alignment: .trailing)
            .accessibilityHidden(true)
        if let reset {
            text
                .contentShape(.rect)
                .onTapGesture(count: 2) { value = reset }
                .help("Double-click to reset")
        } else {
            text
        }
    }
}

/// The box every small button in a card wears: a hairline border, and the accent filled in while
/// the control is on.
extension View {
    func glyphChrome(isOn: Bool = false, tint: Color = .secondary) -> some View {
        padding(.horizontal, 5)
            .frame(height: Theme.glyphHeight)
            .foregroundStyle(isOn ? .white : tint)
            .background(isOn ? Theme.signal : .clear, in: .rect(cornerRadius: Theme.glyphRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.glyphRadius)
                    .strokeBorder(isOn ? Theme.signal : Theme.border, lineWidth: 1)
            }
    }
}

/// A glyph that toggles, for mute and monitor. The button style carries the on state to
/// VoiceOver by itself.
struct GlyphToggle: View {
    let label: String
    let symbol: String
    @Binding var isOn: Bool
    /// The tooltip, when the state needs more than the label says.
    var help: String?

    var body: some View {
        Toggle(isOn: $isOn) {
            Image(systemName: symbol)
                .imageScale(.small)
                .frame(width: 14)
                .glyphChrome(isOn: isOn)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Mixanimo's mark: three faders at rest, at half, and up. Dimmed while the driver is not ready.
struct MixanimoMark: View {
    var isLive = true

    var body: some View {
        Canvas { context, size in
            let heights: [CGFloat] = [0.45, 1.0, 0.7]
            let barWidth = size.width / 5
            for (index, fraction) in heights.enumerated() {
                let height = size.height * fraction
                let rect = CGRect(
                    x: CGFloat(index) * barWidth * 2, y: size.height - height,
                    width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.primary))
            }
        }
        .opacity(isLive ? 1 : 0.4)
    }

    /// The same three bars as a template image. A status item draws only text or an image, so
    /// the menu bar label cannot be the Canvas above.
    static let statusImage: NSImage = {
        let image = NSImage(size: NSSize(width: 15, height: 13), flipped: false) { rect in
            let heights: [CGFloat] = [0.45, 1.0, 0.7]
            let barWidth = rect.width / 5
            for (index, fraction) in heights.enumerated() {
                let bar = NSRect(
                    x: CGFloat(index) * barWidth * 2, y: 0,
                    width: barWidth, height: rect.height * fraction)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
