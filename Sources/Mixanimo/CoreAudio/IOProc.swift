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
    /// affects this process only; pass a value inside `device.bufferFrameSizeRange`.
    init(device: AudioDevice, bufferFrameSize: UInt32? = nil, callback: @escaping Callback) throws {
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
