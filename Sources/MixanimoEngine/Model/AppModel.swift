import CoreAudio
import Foundation
import Observation

/// Live facts about one output that the engine measures and the UI shows.
package struct OutputStatus: Equatable, Sendable {
    /// True while the engine has a running IO proc on the device.
    package var isActive = false
    /// Device latency, safety offset, stream latency and buffer, in milliseconds.
    package var latencyMilliseconds: Double = 0
    /// The delay the engine currently applies, in milliseconds.
    package var delayMilliseconds: Double = 0
    package var sampleRate: Double = 0
    package var underruns = 0

    package init(isActive: Bool = false, sampleRate: Double = 0) {
        self.isActive = isActive
        self.sampleRate = sampleRate
    }
}

package enum DriverStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    case outdated(installed: String, bundled: String)
    case ready(version: String)
}

/// The single source of truth shared by the UI and the engine.
///
/// The UI mutates `settings`; the engine observes `settings` and applies the difference. The
/// engine writes `outputStatus`, `master`, `masterMuted` and `driver`; the UI reads them.
@MainActor
@Observable
package final class AppModel {
    package nonisolated static let appBundleID = "com.mixanimo.app"
    package nonisolated static let outputDeviceUID = "com.mixanimo.output"
    package nonisolated static let micDeviceUID = "com.mixanimo.mic"

    package var settings: Settings {
        didSet { if settings != oldValue { settings.save() } }
    }

    package let devices = DeviceMonitor()

    /// Master gain as the driver's volume control scalar, 0 to 1. Written by the engine from the
    /// driver's notifications; the UI changes it through `setMaster`.
    package var master: Float = 1
    package var masterMuted = false

    package var outputStatus: [String: OutputStatus] = [:]
    package var driver: DriverStatus = .unknown
    /// True from a settings change until the engine has reshaped the graph to match it.
    package var isApplying = false

    package init(settings: Settings = .load()) {
        self.settings = settings
    }

    /// Writes the driver's volume control. The engine's listener then updates `master`.
    package func setMaster(_ scalar: Float) {
        guard let device = try? AudioDevice.find(uid: AppModel.outputDeviceUID) else { return }
        try? device.setVolumeScalar(max(0, min(1, scalar)), scope: .output)
    }

    package func setMasterMuted(_ muted: Bool) {
        guard let device = try? AudioDevice.find(uid: AppModel.outputDeviceUID) else { return }
        try? device.setMute(muted, scope: .output)
    }

    package func output(_ uid: String) -> OutputSettings {
        settings.outputs[uid] ?? OutputSettings()
    }

    package func input(_ uid: String) -> InputSettings {
        settings.inputs[uid] ?? InputSettings()
    }

    package func updateOutput(_ uid: String, _ change: (inout OutputSettings) -> Void) {
        var value = output(uid)
        change(&value)
        settings.outputs[uid] = value
    }

    package func updateInput(_ uid: String, _ change: (inout InputSettings) -> Void) {
        var value = input(uid)
        change(&value)
        settings.inputs[uid] = value
    }
}
