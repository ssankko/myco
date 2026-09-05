import Foundation

/// Per-output configuration, keyed by device UID in `Settings`.
struct OutputSettings: Codable, Equatable, Sendable {
    var enabled = false
    var gainDB: Float = 0
    /// nil means the transport default: 256 frames for Bluetooth, 128 otherwise.
    var bufferFrames: UInt32?
    var monitor = false
    var monitorGainDB: Float = 0
    /// Added on top of the computed sync delay when sync is on.
    var syncTrimMilliseconds: Double = 0
    var eq: [BandSettings] = OutputSettings.defaultEQ

    /// Ten parametric bands at ISO octave centres, all flat.
    static let defaultEQ: [BandSettings] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map {
        BandSettings(type: .parametric, frequency: $0, gainDB: 0, bandwidth: 1, bypass: false)
    }
}

/// Per-input configuration, keyed by device UID in `Settings`.
struct InputSettings: Codable, Equatable, Sendable {
    var enabled = false
    var gainDB: Float = 0
    var muted = false
}

/// Everything the user configures. Persisted as JSON in `UserDefaults`.
struct Settings: Codable, Equatable, Sendable {
    var outputs: [String: OutputSettings] = [:]
    var inputs: [String: InputSettings] = [:]
    /// Nominal rate of the virtual output device.
    var virtualRate: Double = 88200
    var sync = false
    var pinDefaults = true
    var launchAtLogin = false

    static let availableRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    private static let key = "settings"

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Settings.key)
    }
}
