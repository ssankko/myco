import AppKit
import IOBluetooth
import MycoEngine
import SwiftUI

/// Profiles on the left, the selected one's devices on the right. Every device a profile knows
/// is listed, connected or not, with the settings the profile keeps for it.
struct ProfilesPanel: View {
    @Bindable var model: AppModel
    let panels: Panels
    /// The panel's height, set by the column beside it; the device list scrolls inside what is left.
    let height: CGFloat

    @State private var selected: UUID?

    private var index: Int? {
        model.settings.profiles.firstIndex { $0.id == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            PanelHeader(title: "Profiles", panels: panels) {}
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 150)
                Divider()
                if let index {
                    editor(index)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
        .frame(width: 560, height: height, alignment: .topLeading)
        .onAppear { selected = selected ?? model.settings.activeProfileID }
        .onChange(of: model.settings.profiles.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selected }) { selected = model.settings.activeProfileID }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.settings.profiles) { profile in
                Button { selected = profile.id } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(profile.id == model.settings.activeProfileID ? Theme.signal : .clear)
                            .frame(width: 5, height: 5)
                        Text(profile.name).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let hotkey = profile.hotkey {
                            Text(hotkey.display).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        profile.id == selected ? Theme.cardFill : .clear,
                        in: .rect(cornerRadius: Theme.glyphRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(profile.id == model.settings.activeProfileID ? "The active profile" : "")
            }
            Spacer()
            HStack(spacing: 6) {
                Button {
                    selected = model.settings.addProfile().id
                } label: {
                    Image(systemName: "plus").imageScale(.small).frame(width: 14).glyphChrome()
                }
                .help("Add a profile with these devices")
                .accessibilityLabel("Add profile")
                Button {
                    if let selected { model.settings.removeProfile(selected) }
                } label: {
                    Image(systemName: "minus").imageScale(.small).frame(width: 14).glyphChrome()
                }
                .disabled(model.settings.profiles.count < 2)
                .help("Remove this profile")
                .accessibilityLabel("Remove profile")
                Spacer()
                Button("Use") {
                    if let selected { model.settings.activeProfileID = selected }
                }
                .controlSize(.small)
                .disabled(selected == model.settings.activeProfileID)
                .help("Switch to this profile now")
            }
            .buttonStyle(.borderless)
        }
    }

    private func editor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Name", text: $model.settings.profiles[index].name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 12))
                HotkeyRecorder(hotkey: $model.settings.profiles[index].hotkey)
            }
            Toggle("Only connected devices", isOn: $model.settings.showOnlyConnected)
                .toggleStyle(.checkbox)
                .tint(Theme.signal)
                .controlSize(.small)
                .font(.system(size: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    devices(
                        "Outputs", known: model.settings.outputNames,
                        connected: model.devices.outputs.routable,
                        settings: $model.settings.profiles[index].outputs
                    ) { name, settings in
                        MeterSlider(
                            label: "\(name) volume", value: settings.gainDB.asDouble,
                            range: -60...12, step: 0.5,
                            readout: "\(Readout.decibels(settings.wrappedValue.gainDB)) dB",
                            readoutWidth: 58, reset: 0)
                        GlyphToggle(
                            label: "Monitor microphones on \(name)", symbol: "ear",
                            isOn: settings.monitor)
                    }
                    devices(
                        "Inputs", known: model.settings.inputNames,
                        connected: model.devices.inputs.routable,
                        settings: $model.settings.profiles[index].inputs
                    ) { name, settings in
                        MeterSlider(
                            label: "\(name) gain", value: settings.gainDB.asDouble,
                            range: -60...24, step: 0.5,
                            readout: "\(Readout.decibels(settings.wrappedValue.gainDB)) dB",
                            readoutWidth: 58, reset: 0)
                        GlyphToggle(
                            label: "Mute \(name)",
                            symbol: settings.wrappedValue.muted ? "mic.slash" : "mic",
                            isOn: settings.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per device the profile could turn on, with the controls the profile keeps for it
    /// once it is on. A device that is away shows its name and a tag, so it can be set up before
    /// it connects.
    private func devices<S: DeviceSettingsLike, Controls: View>(
        _ title: String, known: [String: String], connected: [DeviceEntry],
        settings: Binding<[String: S]>,
        @ViewBuilder controls: @escaping (String, Binding<S>) -> Controls
    ) -> some View {
        let live = Dictionary(uniqueKeysWithValues: connected.map { ($0.id, $0.name) })
        var names: [String: String] = [:]
        if !model.settings.showOnlyConnected {
            for uid in settings.wrappedValue.keys { names[uid] = DeviceNames.guess(uid) }
            names.merge(known) { _, seen in seen }
        }
        names.merge(live) { _, current in current }
        let rows = names.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
            if rows.isEmpty {
                Text("None").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 9)
            }
            ForEach(rows, id: \.key) { uid, name in
                ProfileDeviceRow(
                    name: name, isConnected: live[uid] != nil,
                    settings: Binding(
                        get: { settings.wrappedValue[uid] ?? S.fresh },
                        set: { settings.wrappedValue[uid] = $0 })
                ) { controls(name, $0) }
            }
        }
    }
}

/// A device inside a profile: the on switch and its name, then the controls once it is on.
private struct ProfileDeviceRow<S: DeviceSettingsLike, Controls: View>: View {
    let name: String
    let isConnected: Bool
    @Binding var settings: S
    @ViewBuilder let controls: (Binding<S>) -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Toggle(name, isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.signal)
                    .labelsHidden()
                    .accessibilityLabel("\(name) in this profile")
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(settings.enabled ? .primary : .secondary)
                Spacer(minLength: 6)
                if !isConnected {
                    Text("Not connected")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            if settings.enabled {
                HStack(spacing: 8) { controls($settings) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, settings.enabled ? Theme.cardPadding : 5)
        .background(settings.enabled ? Theme.cardFill : .clear, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// What the profile panel needs from a device's settings: the on switch and a fresh default.
protocol DeviceSettingsLike {
    static var fresh: Self { get }
    var enabled: Bool { get set }
}

extension OutputSettings: DeviceSettingsLike {}
extension InputSettings: DeviceSettingsLike {}

extension Binding where Value == Float {
    /// The same value for a slider, which reads doubles.
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Float($0) })
    }
}

/// Shows a shortcut and records a new one: click, then press the keys. Escape cancels, Delete
/// clears.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press keys" : hotkey?.display ?? "Set shortcut")
                .font(.system(size: 11, weight: .medium))
                .frame(minWidth: 90)
                .glyphChrome(isOn: isRecording)
        }
        .buttonStyle(.borderless)
        .help("A global shortcut that switches to this profile")
        .accessibilityLabel("Shortcut")
        .accessibilityValue(hotkey?.display ?? "none")
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: break
                case 51, 117: hotkey = nil
                default:
                    guard let pressed = Hotkey(event: event) else { return }
                    hotkey = pressed
                }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// A name for a device that is away and was never seen by this app.
enum DeviceNames {
    private static let builtIn = [
        "BuiltInSpeakerDevice": "Built-in Speakers",
        "BuiltInHeadphoneOutputDevice": "Built-in Headphones",
        "BuiltInMicrophoneDevice": "Built-in Microphone",
    ]

    /// A Bluetooth UID is the device address plus a direction; macOS knows the paired device's
    /// name. Anything else falls back to the UID itself.
    static func guess(_ uid: String) -> String {
        if let name = builtIn[uid] { return name }
        let address = uid.split(separator: ":").first.map(String.init) ?? uid
        let isAddress = address.count == 17 && address.split(separator: "-").count == 6
        if isAddress, let name = IOBluetoothDevice(addressString: address)?.name, !name.isEmpty {
            return name
        }
        return uid
    }
}
