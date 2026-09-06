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

/// A section title with the one fact worth knowing about the section on the right.
struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// How the device is wired, at a glance. Bluetooth is drawn because SF Symbols has no rune for it.
struct TransportGlyph: View {
    let transport: AudioDevice.TransportType

    var body: some View {
        Group {
            switch transport {
            case .bluetooth, .bluetoothLE: BluetoothRune().stroke(style: .init(lineWidth: 1.2, lineJoin: .round))
            default: Image(systemName: symbol).imageScale(.small)
            }
        }
        .frame(width: 11, height: 12)
        .foregroundStyle(.tertiary)
        .accessibilityLabel(name)
    }

    private var symbol: String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .usb: "cable.connector"
        case .virtual: "circle.dotted"
        case .aggregate: "square.stack.3d.up"
        case .airPlay: "airplayaudio"
        case .continuity: "iphone"
        default: "speaker.wave.2"
        }
    }

    private var name: String {
        switch transport {
        case .builtIn: "Built in"
        case .bluetooth, .bluetoothLE: "Bluetooth"
        case .usb: "USB"
        case .virtual: "Virtual"
        case .aggregate: "Aggregate"
        case .airPlay: "AirPlay"
        case .continuity: "Continuity"
        default: "Other connection"
        }
    }
}

/// The Bluetooth rune: a vertical stem crossed twice, with two flags to the upper and lower right.
private struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX, w = rect.width, y = rect.minY, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.15, y: y + h * 0.28))
        path.addLine(to: CGPoint(x: x + w * 0.85, y: y + h * 0.72))
        path.addLine(to: CGPoint(x: x + w * 0.5, y: y + h))
        path.addLine(to: CGPoint(x: x + w * 0.5, y: y))
        path.addLine(to: CGPoint(x: x + w * 0.85, y: y + h * 0.28))
        path.addLine(to: CGPoint(x: x + w * 0.15, y: y + h * 0.72))
        return path
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

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step)
                .controlSize(.mini)
                .tint(Theme.signal)
                .accessibilityLabel(label)
                .accessibilityValue(readout)
            Text(readout)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: readoutWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// A glyph that toggles, for mute and monitor. The button style carries the on state to
/// VoiceOver by itself.
struct GlyphToggle: View {
    let label: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Image(systemName: symbol).imageScale(.small).frame(width: 14)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(Theme.signal)
        .foregroundStyle(isOn ? Theme.signal : Color.secondary)
        .help(label)
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
