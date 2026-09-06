import CoreAudio
import Foundation
import Observation

/// Live facts about one output that the engine measures and the UI shows.
struct OutputStatus: Equatable, Sendable {
    /// True while the engine has a running IO proc on the device.
    var isActive = false
    /// Device latency, safety offset, stream latency and buffer, in milliseconds.
    var latencyMilliseconds: Double = 0
    /// The delay the engine currently applies, in milliseconds.
    var delayMilliseconds: Double = 0
    var sampleRate: Double = 0
    var underruns = 0
    /// The loudest sample of the last poll, 0 to 1, and the mark that falls back behind it.
    var peak: Float = 0
    var peakHold: Float = 0
}

/// Live facts about one microphone in the mix.
struct InputStatus: Equatable, Sendable {
    /// The loudest sample of the last poll, 0 to 1, and the mark that falls back behind it.
    var peak: Float = 0
    var peakHold: Float = 0
}

enum DriverStatus: Equatable, Sendable {
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
final class AppModel {
    static let appBundleID = "com.mixanimo.app"
    static let outputDeviceUID = "com.mixanimo.output"
    static let micDeviceUID = "com.mixanimo.mic"

    var settings: Settings {
        didSet { if settings != oldValue { settings.save() } }
    }

    let devices = DeviceMonitor()

    /// Master gain as the driver's volume control scalar, 0 to 1. Written by the engine from the
    /// driver's notifications; the UI changes it through `setMaster`.
    var master: Float = 1
    var masterMuted = false

    var outputStatus: [String: OutputStatus] = [:]
    var inputStatus: [String: InputStatus] = [:]
    var driver: DriverStatus = .unknown

    /// True while the popover shows the level meters. The engine measures levels only then.
    var isMetering = false

    init(settings: Settings = .load()) {
        self.settings = settings
    }

    /// Writes the driver's volume control. The engine's listener then updates `master`.
    func setMaster(_ scalar: Float) {
        guard let device = try? AudioDevice.find(uid: AppModel.outputDeviceUID) else { return }
        try? device.setVolumeScalar(max(0, min(1, scalar)), scope: .output)
    }

    func setMasterMuted(_ muted: Bool) {
        guard let device = try? AudioDevice.find(uid: AppModel.outputDeviceUID) else { return }
        try? device.setMute(muted, scope: .output)
    }

    func output(_ uid: String) -> OutputSettings {
        settings.outputs[uid] ?? OutputSettings()
    }

    func input(_ uid: String) -> InputSettings {
        settings.inputs[uid] ?? InputSettings()
    }

    func updateOutput(_ uid: String, _ change: (inout OutputSettings) -> Void) {
        var value = output(uid)
        change(&value)
        settings.outputs[uid] = value
    }

    func updateInput(_ uid: String, _ change: (inout InputSettings) -> Void) {
        var value = input(uid)
        change(&value)
        settings.inputs[uid] = value
    }
}
