import AppKit
import SwiftUI

/// The menu bar window: master level on top, then everything the audio passes through on its way
/// out and in.
struct Popover: View {
    @Bindable var model: AppModel
    let actions: Actions

    /// The master position while the thumb is held. The engine answers through the driver, which
    /// takes a moment, and a slider that springs back mid-drag is unusable.
    @State private var masterDraft: Float?
    @State private var showsSettings = false

    private var outputs: [DeviceEntry] { model.devices.outputs.routable }
    private var inputs: [DeviceEntry] { model.devices.inputs.routable }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header
            master
            if !model.driver.isReady {
                DriverRow(status: model.driver, actions: actions)
            }
            Divider().opacity(0.6)
            // A short list lets the popover grow to fit; a long one scrolls at a fixed height.
            if outputs.count + inputs.count <= 8 {
                deviceStack
            } else {
                ScrollView { deviceStack }.frame(height: 420)
            }
            Divider().opacity(0.6)
            footer
        }
        .padding(14)
        .frame(width: Theme.popoverWidth)
    }

    private var header: some View {
        HStack(spacing: 7) {
            MixanimoMark(isLive: model.driver.isReady)
                .frame(width: 13, height: 12)
            Text("Mixanimo")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.driver.isReady {
                Circle().fill(Theme.signal).frame(width: 5, height: 5)
                Text(model.driver.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var master: some View {
        HStack(spacing: 10) {
            GlyphToggle(
                label: "Mute everything",
                symbol: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                isOn: Binding(get: { model.masterMuted }, set: { model.setMasterMuted($0) }))
            Slider(
                value: Binding(
                    get: { masterDraft ?? model.master },
                    set: { masterDraft = $0; model.setMaster($0) }),
                in: 0...1,
                onEditingChanged: { editing in if !editing { masterDraft = nil } })
                .controlSize(.small)
                .tint(model.masterMuted ? Color.secondary : Theme.signal)
                .accessibilityLabel("Master level")
                .accessibilityValue("\(Readout.percent(masterDraft ?? model.master)) percent")
            Text(Readout.percent(masterDraft ?? model.master))
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(model.masterMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 32, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .opacity(model.masterMuted ? 0.65 : 1)
    }

    private var deviceStack: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            devices
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var devices: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Outputs", detail: onCount(outputs.count, model.settings.outputs.values.filter(\.enabled).count))
            if outputs.isEmpty {
                EmptyLane(text: "No output devices are attached.")
            } else {
                ForEach(outputs) { OutputRow(model: model, entry: $0) }
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Microphones", detail: onCount(inputs.count, model.settings.inputs.values.filter(\.enabled).count))
            if inputs.isEmpty {
                EmptyLane(text: "No microphones are attached.")
            } else {
                ForEach(inputs) { InputRow(model: model, entry: $0) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Virtual rate", selection: $model.settings.virtualRate) {
                    ForEach(Settings.availableRates, id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 104)
                .accessibilityLabel("Rate of the Mixanimo output device")
                Spacer()
                Toggle("Align outputs", isOn: $model.settings.sync)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.signal)
                    .font(.system(size: 11))
                    .help("Delays every output to match the slowest one.")
            }

            DisclosureGroup("Settings", isExpanded: $showsSettings) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep Mixanimo as the system device", isOn: $model.settings.pinDefaults)
                    Toggle("Open at login", isOn: $model.settings.launchAtLogin)
                    if model.driver.isReady {
                        Button("Remove driver") { actions.run(actions.uninstall) }
                            .buttonStyle(.link)
                            .disabled(actions.uninstall == nil || actions.isWorking)
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .padding(.top, 6)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button("Quit Mixanimo") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }

    private func onCount(_ total: Int, _ on: Int) -> String {
        total == 0 ? "none" : "\(min(on, total)) of \(total) on"
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1000)
    }
}

/// The one line that says whether Mixanimo can carry audio at all, with the fix attached.
private struct DriverRow: View {
    let status: DriverStatus
    let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(status.tint).frame(width: 6, height: 6)
            Text(status.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if actions.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else if let title = status.actionTitle {
                Button(title) { actions.run(actions.install) }
                    .controlSize(.small)
                    .disabled(actions.install == nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(status.isReady ? Color.clear : status.tint.opacity(0.12), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Driver")
        .accessibilityValue(status.message)
    }
}

/// A lane with nothing in it. Says what would fill it.
private struct EmptyLane: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .rail(.off)
    }
}

extension DriverStatus {
    var isReady: Bool { if case .ready = self { true } else { false } }

    var message: String {
        switch self {
        case .unknown: "Looking for the driver"
        case .notInstalled: "The audio driver is not installed yet"
        case .outdated(let installed, let bundled): "Driver \(installed) is older than \(bundled)"
        case .ready(let version): "Driver \(version) is ready"
        }
    }

    var actionTitle: String? {
        switch self {
        case .notInstalled: "Install"
        case .outdated: "Update"
        case .unknown, .ready: nil
        }
    }

    var tint: Color {
        switch self {
        case .unknown: Theme.track
        case .notInstalled: Theme.stopped
        case .outdated: Theme.caution
        case .ready: Theme.signal
        }
    }
}
