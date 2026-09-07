import Foundation
import MixanimoDSP

/// Per-output configuration, keyed by device UID in `Settings`.
package struct OutputSettings: Codable, Equatable, Sendable {
    package var enabled = false
    package var gainDB: Float = 0
    /// nil means the transport default: 256 frames for Bluetooth, 128 otherwise.
    package var bufferFrames: UInt32?
    package var monitor = false
    package var monitorGainDB: Float = 0
    /// Added on top of the computed sync delay when sync is on.
    package var syncTrimMilliseconds: Double = 0
    package var eq: [BandSettings] = OutputSettings.defaultEQ

    /// Ten parametric bands at ISO octave centres, all flat.
    package static let defaultEQ: [BandSettings] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map {
        BandSettings(type: .parametric, frequency: $0, gainDB: 0, bandwidth: 1, bypass: false)
    }
}

/// Per-input configuration, keyed by device UID in `Settings`.
package struct InputSettings: Codable, Equatable, Sendable {
    package var enabled = false
    package var gainDB: Float = 0
    package var muted = false
}

/// Everything the user configures. Persisted as JSON in `UserDefaults`.
package struct Settings: Codable, Equatable, Sendable {
    package var outputs: [String: OutputSettings] = [:]
    package var inputs: [String: InputSettings] = [:]
    /// Nominal rate of the virtual output device.
    package var virtualRate: Double = 88200
    package var sync = false
    package var pinDefaults = true
    package var launchAtLogin = false

    package static let availableRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    private static let key = "settings"

    package static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Settings.key)
    }
}
