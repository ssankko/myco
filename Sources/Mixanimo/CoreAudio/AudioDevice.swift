import CoreAudio
import Foundation

/// A typed view of one HAL audio device. Holds only the device ID, so a value stays valid for as
/// long as the HAL keeps that ID; ask `isAlive` when in doubt. Accessors that describe the device
/// answer with a neutral value when the property is missing; accessors the caller acts on throw.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID

    init(id: AudioDeviceID) {
        self.id = id
    }

    enum Scope: Sendable, Hashable, CaseIterable {
        case output, input

        var property: AudioObjectPropertyScope {
            self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        }
    }

    enum TransportType: Sendable, Hashable {
        case builtIn, bluetooth, bluetoothLE, usb, virtual, aggregate, airPlay, continuity
        case other(UInt32)

        init(raw: UInt32) {
            switch raw {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
            case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeContinuityCaptureWired,
                kAudioDeviceTransportTypeContinuityCaptureWireless:
                self = .continuity
            default: self = .other(raw)
            }
        }

        var raw: UInt32 {
            switch self {
            case .builtIn: kAudioDeviceTransportTypeBuiltIn
            case .bluetooth: kAudioDeviceTransportTypeBluetooth
            case .bluetoothLE: kAudioDeviceTransportTypeBluetoothLE
            case .usb: kAudioDeviceTransportTypeUSB
            case .virtual: kAudioDeviceTransportTypeVirtual
            case .aggregate: kAudioDeviceTransportTypeAggregate
            case .airPlay: kAudioDeviceTransportTypeAirPlay
            case .continuity: kAudioDeviceTransportTypeContinuityCaptureWireless
            case .other(let raw): raw
            }
        }
    }

    // MARK: Identity

    /// The persistent identifier used to key saved settings.
    var uid: String {
        get throws { try id.string(AudioObjectPropertyAddress(kAudioDevicePropertyDeviceUID)) }
    }

    var name: String {
        (try? id.string(AudioObjectPropertyAddress(kAudioObjectPropertyName))) ?? ""
    }

    var manufacturer: String {
        (try? id.string(AudioObjectPropertyAddress(kAudioObjectPropertyManufacturer))) ?? ""
    }

    var transportType: TransportType {
        TransportType(raw: flag(kAudioDevicePropertyTransportType))
    }

    var isAlive: Bool { flag(kAudioDevicePropertyDeviceIsAlive) == 1 }

    var isHidden: Bool { flag(kAudioDevicePropertyIsHidden) == 1 }

    func canBeDefault(scope: Scope) -> Bool {
        flag(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope.property) == 1
    }

    /// Reads a `UInt32`-valued property, answering 0 when the device does not publish it.
    private func flag(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32 {
        do {
            let value: UInt32 = try id.value(AudioObjectPropertyAddress(selector, scope))
            return value
        } catch {
            return 0
        }
    }

    // MARK: Channels

    var hasOutput: Bool { outputChannelCount > 0 }
    var hasInput: Bool { inputChannelCount > 0 }
    var outputChannelCount: Int { channelCount(scope: .output) }
    var inputChannelCount: Int { channelCount(scope: .input) }

    func channelCount(scope: Scope) -> Int {
        let address = AudioObjectPropertyAddress(
            kAudioDevicePropertyStreamConfiguration, scope.property)
        let count = try? id.bufferList(address) { buffers in
            buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        return count ?? 0
    }

    // MARK: Sample rate

    var nominalSampleRate: Double {
        get throws { try id.value(AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)) }
    }

    func setNominalSampleRate(_ rate: Double) throws {
        try id.setValue(AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate), rate)
    }

    /// The rates the device accepts. A discrete rate appears as a range whose bounds are equal.
    var availableSampleRates: [ClosedRange<Double>] {
        get throws {
            let ranges: [AudioValueRange] = try id.array(
                AudioObjectPropertyAddress(kAudioDevicePropertyAvailableNominalSampleRates))
            return ranges.map { min($0.mMinimum, $0.mMaximum)...max($0.mMinimum, $0.mMaximum) }
        }
    }

    // MARK: Buffer size

    var bufferFrameSize: UInt32 {
        get throws { try id.value(AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSize)) }
    }

    /// Sets the IO buffer size for this process only.
    func setBufferFrameSize(_ frames: UInt32) throws {
        try id.setValue(AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSize), frames)
    }

    var bufferFrameSizeRange: ClosedRange<UInt32> {
        get throws {
            let range: AudioValueRange = try id.value(
                AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSizeRange))
            return UInt32(range.mMinimum)...UInt32(range.mMaximum)
        }
    }

    // MARK: Latency

    func latency(scope: Scope) throws -> UInt32 {
        try id.value(AudioObjectPropertyAddress(kAudioDevicePropertyLatency, scope.property))
    }

    func safetyOffset(scope: Scope) throws -> UInt32 {
        try id.value(AudioObjectPropertyAddress(kAudioDevicePropertySafetyOffset, scope.property))
    }

    /// The latency of the streams in `scope`, summed. Devices publish one stream per direction in
    /// the common case, so the sum is that stream's latency.
    func streamLatency(scope: Scope) throws -> UInt32 {
        try streams(scope: scope).reduce(0) { total, stream in
            let latency: UInt32 = (try? stream.value(AudioObjectPropertyAddress(kAudioStreamPropertyLatency))) ?? 0
            return total + latency
        }
    }

    // MARK: Streams

    func streams(scope: Scope) throws -> [AudioObjectID] {
        try id.array(AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope.property))
    }

    /// The format of the first stream in `scope`, which is the format the IO callback sees.
    func streamFormat(scope: Scope) throws -> AudioStreamBasicDescription {
        guard let stream = try streams(scope: scope).first else {
            throw AudioObjectError(
                status: kAudioHardwareUnknownPropertyError, selector: kAudioDevicePropertyStreams,
                objectID: id)
        }
        return try stream.value(AudioObjectPropertyAddress(kAudioStreamPropertyVirtualFormat))
    }

    // MARK: Volume and mute

    /// The device gain in 0...1, or nil when the device publishes no volume control.
    /// Falls back to the average of the per-channel controls when the main element has none.
    func volumeScalar(scope: Scope) throws -> Float? {
        let main = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope.property)
        if id.has(main) { return try id.value(main) as Float }
        let values = try volumeChannels(scope: scope).map { try id.value($0) as Float }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    func setVolumeScalar(_ value: Float, scope: Scope) throws {
        let value = min(max(value, 0), 1)
        let main = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope.property)
        if id.has(main) { return try id.setValue(main, value) }
        for address in try volumeChannels(scope: scope) { try id.setValue(address, value) }
    }

    func mute(scope: Scope) throws -> Bool? {
        let main = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope.property)
        if id.has(main) { return try id.value(main) as UInt32 == 1 }
        let values = try muteChannels(scope: scope).map { try id.value($0) as UInt32 }
        return values.isEmpty ? nil : values.allSatisfy { $0 == 1 }
    }

    func setMute(_ muted: Bool, scope: Scope) throws {
        let value: UInt32 = muted ? 1 : 0
        let main = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope.property)
        if id.has(main) { return try id.setValue(main, value) }
        for address in try muteChannels(scope: scope) { try id.setValue(address, value) }
    }

    private func volumeChannels(scope: Scope) throws -> [AudioObjectPropertyAddress] {
        channelElements(kAudioDevicePropertyVolumeScalar, scope: scope)
    }

    private func muteChannels(scope: Scope) throws -> [AudioObjectPropertyAddress] {
        channelElements(kAudioDevicePropertyMute, scope: scope)
    }

    private func channelElements(
        _ selector: AudioObjectPropertySelector, scope: Scope
    ) -> [AudioObjectPropertyAddress] {
        (1...max(channelCount(scope: scope), 1))
            .map { AudioObjectPropertyAddress(selector, scope.property, AudioObjectPropertyElement($0)) }
            .filter { id.has($0) }
    }

    // MARK: Enumeration

    static var all: [AudioDevice] {
        get throws {
            let ids: [AudioDeviceID] = try AudioObjectID.system.array(
                AudioObjectPropertyAddress(kAudioHardwarePropertyDevices))
            return ids.map(AudioDevice.init(id:))
        }
    }

    static func find(uid: String) throws -> AudioDevice? {
        let found: AudioDeviceID = try AudioObjectID.system.value(
            AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice),
            qualifier: uid as CFString)
        return found == kAudioObjectUnknown ? nil : AudioDevice(id: found)
    }

    // MARK: Default devices

    static var defaultOutput: AudioDevice? {
        get throws { try systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    }

    static var defaultInput: AudioDevice? {
        get throws { try systemDevice(kAudioHardwarePropertyDefaultInputDevice) }
    }

    /// The device that plays alerts and interface sounds.
    static var defaultSystemOutput: AudioDevice? {
        get throws { try systemDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) }
    }

    static func setDefaultOutput(_ device: AudioDevice) throws {
        try setSystemDevice(kAudioHardwarePropertyDefaultOutputDevice, device)
    }

    static func setDefaultInput(_ device: AudioDevice) throws {
        try setSystemDevice(kAudioHardwarePropertyDefaultInputDevice, device)
    }

    static func setDefaultSystemOutput(_ device: AudioDevice) throws {
        try setSystemDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) throws -> AudioDevice? {
        let found: AudioDeviceID = try AudioObjectID.system.value(
            AudioObjectPropertyAddress(selector))
        return found == kAudioObjectUnknown ? nil : AudioDevice(id: found)
    }

    private static func setSystemDevice(
        _ selector: AudioObjectPropertySelector, _ device: AudioDevice
    ) throws {
        try AudioObjectID.system.setValue(AudioObjectPropertyAddress(selector), device.id)
    }
}
