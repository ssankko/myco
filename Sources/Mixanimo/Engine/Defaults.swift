import CoreAudio
import Foundation

/// The default output, system output and input the engine found before it pinned the virtual
/// devices, by UID.
struct SavedDefaults: Codable, Equatable, Sendable {
    var output: String?
    var systemOutput: String?
    var input: String?
}

/// Owns the machine's default devices while the engine runs: it remembers what was there, points
/// all three at the virtual devices, puts them back on stop and, while pinning is on, puts them
/// back whenever something else moves them.
///
/// The remembered set is persisted, so a run that ended in a crash still has somewhere to go back
/// to; the next `capture()` keeps it instead of remembering the virtual devices.
@MainActor
final class DefaultDevices {
    private static let key = "savedDefaults"

    private let store: UserDefaults
    private(set) var saved: SavedDefaults?

    init(store: UserDefaults = .standard) {
        self.store = store
        saved = store.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode(SavedDefaults.self, from: $0)
        }
    }

    /// What the HAL reports as the three defaults right now.
    static var current: SavedDefaults {
        SavedDefaults(
            output: uid(try? AudioDevice.defaultOutput),
            systemOutput: uid(try? AudioDevice.defaultSystemOutput),
            input: uid(try? AudioDevice.defaultInput))
    }

    /// Remembers where to go back to, unless an earlier run already left a set behind.
    func capture(current: SavedDefaults = DefaultDevices.current) {
        guard saved == nil else { return }
        saved = current
        if let data = try? JSONEncoder().encode(current) { store.set(data, forKey: Self.key) }
    }

    /// Points all three defaults at the virtual devices.
    func pin() {
        apply(
            SavedDefaults(
                output: AppModel.outputDeviceUID,
                systemOutput: AppModel.outputDeviceUID,
                input: AppModel.micDeviceUID))
    }

    /// Puts back what was remembered, skipping devices that are gone, and forgets it.
    func restore() {
        guard let saved else { return }
        apply(saved)
        self.saved = nil
        store.removeObject(forKey: Self.key)
    }

    private func apply(_ uids: SavedDefaults) {
        if let device = Self.device(uids.output) { try? AudioDevice.setDefaultOutput(device) }
        if let device = Self.device(uids.systemOutput) { try? AudioDevice.setDefaultSystemOutput(device) }
        if let device = Self.device(uids.input) { try? AudioDevice.setDefaultInput(device) }
    }

    private static func device(_ uid: String?) -> AudioDevice? {
        guard let uid, let device = (try? AudioDevice.find(uid: uid)) ?? nil, device.isAlive else {
            return nil
        }
        return device
    }

    private static func uid(_ device: AudioDevice??) -> String? {
        guard let device = device ?? nil else { return nil }
        return try? device.uid
    }
}
