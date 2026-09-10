import Foundation
import MycoDSP

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
    /// The title of the preset `eq` and `gainDB` were set from; nil once a band is edited by hand.
    package var presetName: String?
    /// The gains of `eq` per device volume, for a preset that follows it; nil for a fixed one.
    package var eqVolumes: [EQVolumeStep]?

    /// The bands that play at `volume`: `eq` with its gains moved between the two nearest steps.
    package func eq(atVolume volume: Double) -> [BandSettings] {
        EQPreset.bands(eq, volumes: eqVolumes ?? [], at: volume)
    }

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

/// The settings of a device the user has not touched yet.
extension OutputSettings { package static let fresh = OutputSettings() }
extension InputSettings { package static let fresh = InputSettings() }

/// A global keyboard shortcut. `key` is what the key prints, for display; `keyCode` and
/// `modifiers` (NSEvent flag bits) are what gets registered.
package struct Hotkey: Codable, Equatable, Sendable {
    package var keyCode: UInt16
    package var modifiers: UInt
    package var key: String

    package init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// A named snapshot of every device setting, by UID. The active profile is what the engine
/// plays; a device the profile knows but that is not connected is on the moment it appears.
package struct Profile: Codable, Equatable, Sendable, Identifiable {
    package var id = UUID()
    package var name: String
    package var outputs: [String: OutputSettings] = [:]
    package var inputs: [String: InputSettings] = [:]
    package var hotkey: Hotkey?

    package init(name: String, outputs: [String: OutputSettings] = [:], inputs: [String: InputSettings] = [:]) {
        self.name = name
        self.outputs = outputs
        self.inputs = inputs
    }

    /// The UIDs that are on, whether or not the device is connected.
    package var enabledOutputs: Set<String> { Set(outputs.filter(\.value.enabled).keys) }
    package var enabledInputs: Set<String> { Set(inputs.filter(\.value.enabled).keys) }
}

/// Everything the user configures. Persisted as JSON in `UserDefaults`.
package struct Settings: Codable, Equatable, Sendable {
    /// Never empty: the first one is called Default.
    package var profiles: [Profile] = [Profile(name: "Default")]
    package var activeProfileID: UUID
    /// Nominal rate of the virtual output device.
    package var virtualRate: Double = 88200
    package var sync = false
    package var pinDefaults = true
    package var launchAtLogin = false
    /// The output that plays while no enabled output is connected.
    package var fallbackOutput: String?
    /// The profile window lists only connected devices while this is on.
    package var showOnlyConnected = true
    /// The name of every device seen so far, by UID, so a profile can show one that is not
    /// connected.
    package var outputNames: [String: String] = [:]
    package var inputNames: [String: String] = [:]

    package static let availableRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    private static let key = "settings"

    package init() {
        activeProfileID = profiles[0].id
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, activeProfileID, virtualRate, sync, pinDefaults, launchAtLogin
        case fallbackOutput, showOnlyConnected, outputNames, inputNames
        /// Written by builds before profiles: the devices of the one profile there was.
        case outputs, inputs
    }

    /// Every key is optional on the way in, so settings saved by an older build still load.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        if profiles.isEmpty {
            profiles = [
                Profile(
                    name: "Default",
                    outputs: try c.decodeIfPresent([String: OutputSettings].self, forKey: .outputs) ?? [:],
                    inputs: try c.decodeIfPresent([String: InputSettings].self, forKey: .inputs) ?? [:])
            ]
        }
        self.profiles = profiles
        let active = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        activeProfileID = profiles.contains { $0.id == active } ? active! : profiles[0].id
        virtualRate = try c.decodeIfPresent(Double.self, forKey: .virtualRate) ?? 88200
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? false
        pinDefaults = try c.decodeIfPresent(Bool.self, forKey: .pinDefaults) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        fallbackOutput = try c.decodeIfPresent(String.self, forKey: .fallbackOutput)
        showOnlyConnected = try c.decodeIfPresent(Bool.self, forKey: .showOnlyConnected) ?? true
        outputNames = try c.decodeIfPresent([String: String].self, forKey: .outputNames) ?? [:]
        inputNames = try c.decodeIfPresent([String: String].self, forKey: .inputNames) ?? [:]
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(activeProfileID, forKey: .activeProfileID)
        try c.encode(virtualRate, forKey: .virtualRate)
        try c.encode(sync, forKey: .sync)
        try c.encode(pinDefaults, forKey: .pinDefaults)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encodeIfPresent(fallbackOutput, forKey: .fallbackOutput)
        try c.encode(showOnlyConnected, forKey: .showOnlyConnected)
        try c.encode(outputNames, forKey: .outputNames)
        try c.encode(inputNames, forKey: .inputNames)
    }

    package var activeIndex: Int {
        profiles.firstIndex { $0.id == activeProfileID } ?? 0
    }

    package var active: Profile {
        get { profiles[activeIndex] }
        set { profiles[activeIndex] = newValue }
    }

    /// The device settings the engine plays: those of the active profile.
    package var outputs: [String: OutputSettings] {
        get { active.outputs }
        set { active.outputs = newValue }
    }

    package var inputs: [String: InputSettings] {
        get { active.inputs }
        set { active.inputs = newValue }
    }

    package var enabledOutputs: Set<String> { active.enabledOutputs }
    package var enabledInputs: Set<String> { active.enabledInputs }

    /// A copy of the active profile under a new name, so volumes and EQs carry over.
    @discardableResult
    package mutating func addProfile() -> Profile {
        var profile = active
        profile.id = UUID()
        profile.hotkey = nil
        let taken = Set(profiles.map(\.name))
        var number = profiles.count + 1
        while taken.contains("Profile \(number)") { number += 1 }
        profile.name = "Profile \(number)"
        profiles.append(profile)
        return profile
    }

    /// The last profile stays; removing the active one activates the first.
    package mutating func removeProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if id == activeProfileID { activeProfileID = profiles[0].id }
    }

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
