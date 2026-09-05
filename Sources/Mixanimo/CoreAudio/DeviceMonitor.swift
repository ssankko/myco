import CoreAudio
import Foundation
import Observation

/// The live picture of the machine's audio devices: the split device lists, the current default
/// devices, and a stream of the changes as they happen. Listeners live for as long as the monitor.
@MainActor
@Observable
final class DeviceMonitor {
    enum Event: Sendable, Hashable {
        case arrived(uid: String, device: AudioDevice)
        case departed(uid: String)
        case defaultChanged(scope: AudioDevice.Scope, device: AudioDevice?)
        case aliveChanged(uid: String, isAlive: Bool)
        case sampleRateChanged(uid: String, rate: Double)
    }

    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioDevice?
    private(set) var defaultInput: AudioDevice?

    /// UIDs of the devices seen at the last refresh, including devices now gone from the HAL, so a
    /// departure can still name its device.
    @ObservationIgnored private var uids: [AudioDeviceID: String] = [:]
    @ObservationIgnored private var hardwareListeners: [AudioObjectPropertyListener] = []
    @ObservationIgnored private var deviceListeners: [AudioDeviceID: [AudioObjectPropertyListener]] = [:]
    @ObservationIgnored nonisolated(unsafe) private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    init() {
        refreshDevices(emitEvents: false)
        refreshDefaults(emitEvents: false)
        hardwareListeners = [
            (kAudioHardwarePropertyDevices, { [weak self] in self?.refreshDevices(emitEvents: true) }),
            (kAudioHardwarePropertyDefaultOutputDevice, { [weak self] in self?.refreshDefaults(emitEvents: true) }),
            (kAudioHardwarePropertyDefaultInputDevice, { [weak self] in self?.refreshDefaults(emitEvents: true) }),
        ].compactMap { selector, action in
            try? AudioObjectPropertyListener(.system, AudioObjectPropertyAddress(selector)) { _ in action() }
        }
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    /// A stream of every change. Each caller gets its own stream; all of them see every event.
    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let key = UUID()
            continuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[key] = nil }
            }
        }
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func refreshDevices(emitEvents: Bool) {
        let devices = (try? AudioDevice.all) ?? []
        var current: [AudioDeviceID: String] = [:]
        for device in devices {
            if let uid = try? device.uid { current[device.id] = uid }
        }

        outputs = devices.filter(\.hasOutput)
        inputs = devices.filter(\.hasInput)

        if emitEvents {
            let known = Set(uids.values)
            for device in devices {
                guard let uid = current[device.id], !known.contains(uid) else { continue }
                emit(.arrived(uid: uid, device: device))
            }
            for uid in known.subtracting(current.values) {
                emit(.departed(uid: uid))
            }
        }
        uids = current
        updateDeviceListeners(devices)
    }

    private func refreshDefaults(emitEvents: Bool) {
        let output = (try? AudioDevice.defaultOutput) ?? nil
        let input = (try? AudioDevice.defaultInput) ?? nil
        if output != defaultOutput {
            defaultOutput = output
            if emitEvents { emit(.defaultChanged(scope: .output, device: output)) }
        }
        if input != defaultInput {
            defaultInput = input
            if emitEvents { emit(.defaultChanged(scope: .input, device: input)) }
        }
    }

    /// Keeps one alive listener and one sample rate listener per present device.
    private func updateDeviceListeners(_ devices: [AudioDevice]) {
        for id in deviceListeners.keys where !devices.contains(where: { $0.id == id }) {
            deviceListeners[id] = nil
        }
        for device in devices where deviceListeners[device.id] == nil {
            let uid = uids[device.id] ?? ""
            let alive = try? AudioObjectPropertyListener(
                device.id, AudioObjectPropertyAddress(kAudioDevicePropertyDeviceIsAlive)
            ) { [weak self] _ in
                self?.emit(.aliveChanged(uid: uid, isAlive: device.isAlive))
            }
            let rate = try? AudioObjectPropertyListener(
                device.id, AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
            ) { [weak self] _ in
                guard let value = try? device.nominalSampleRate else { return }
                self?.emit(.sampleRateChanged(uid: uid, rate: value))
            }
            deviceListeners[device.id] = [alive, rate].compactMap { $0 }
        }
    }
}
