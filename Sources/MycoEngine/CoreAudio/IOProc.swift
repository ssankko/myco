import CoreAudio
import Foundation

/// One IO callback registered on a device.
///
/// The closure runs on the HAL's own realtime IO thread, not on any queue of ours. It must not
/// allocate, lock, log or touch main-actor state; do only buffer arithmetic in it. `input` and
/// `output` are nil when the device has no stream in that direction.
final class IOProc {
    typealias Callback = @Sendable (
        _ now: UnsafePointer<AudioTimeStamp>,
        _ input: UnsafeMutableAudioBufferListPointer?,
        _ inputTime: UnsafePointer<AudioTimeStamp>,
        _ output: UnsafeMutableAudioBufferListPointer?,
        _ outputTime: UnsafePointer<AudioTimeStamp>
    ) -> Void

    let device: AudioDevice
    private(set) var isRunning = false
    nonisolated(unsafe) private var procID: AudioDeviceIOProcID?

    /// Creates the IO proc. `bufferFrameSize`, when given, is applied to the device first, which
    /// affects this process only; pass a value inside `device.bufferFrameSizeRange`. With
    /// `usesInput` false the HAL does no input work for this proc, and a driver that counts the
    /// readers of a device does not count it.
    init(
        device: AudioDevice, bufferFrameSize: UInt32? = nil, usesInput: Bool = true,
        callback: @escaping Callback
    ) throws {
        self.device = device
        if let bufferFrameSize { try device.setBufferFrameSize(bufferFrameSize) }
        let block: AudioDeviceIOBlock = { now, inputData, inputTime, outputData, outputTime in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            callback(
                now, input.count > 0 ? input : nil, inputTime,
                output.count > 0 ? output : nil, outputTime)
        }
        try device.id.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil, block),
            AudioObjectPropertyAddress(kAudioDevicePropertyIOProcStreamUsage))
        if !usesInput { try turnOffInputStreams() }
    }

    /// The usage record is a header followed by one flag per stream, so it is built in raw memory.
    private func turnOffInputStreams() throws {
        let count = (try? device.streams(scope: .input).count) ?? 0
        guard count > 0, let procID else { return }
        let bytes =
            MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
            + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        var address = AudioObjectPropertyAddress(
            kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try device.id.check(
            AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(bytes), raw), address)
    }

    func start() throws {
        guard !isRunning, let procID else { return }
        try device.id.check(
            AudioDeviceStart(device.id, procID),
            AudioObjectPropertyAddress(kAudioDevicePropertyDeviceIsRunning))
        isRunning = true
    }

    func stop() throws {
        guard isRunning, let procID else { return }
        try device.id.check(
            AudioDeviceStop(device.id, procID),
            AudioObjectPropertyAddress(kAudioDevicePropertyDeviceIsRunning))
        isRunning = false
    }

    deinit {
        guard let procID else { return }
        AudioDeviceStop(device.id, procID)
        AudioDeviceDestroyIOProcID(device.id, procID)
    }
}
