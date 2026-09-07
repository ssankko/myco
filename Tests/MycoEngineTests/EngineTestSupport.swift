//  Signal sources and captures the engine tests hang on real devices.
//
//  Reading any input stream needs microphone permission, which macOS gives to the process that owns
//  the terminal. Run these from Terminal.app; anywhere else they capture silence.

import CoreAudio
import XCTest

@testable import MycoEngine

/// Plays a sine into a device's output stream, on every channel.
@MainActor
final class SineSource {
    private var proc: IOProc?

    /// The phase follows the device's own sample time, so a skipped IO cycle leaves no step in the
    /// tone the device records.
    init(device: AudioDevice, frequency: Double, amplitude: Float) throws {
        let step = 2 * Double.pi * frequency / (try device.nominalSampleRate)
        proc = try IOProc(device: device) { _, _, _, output, outputTime in
            guard let output else { return }
            let start = outputTime.pointee.mSampleTime
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                for frame in 0..<frames {
                    let value = amplitude * Float(sin(step * (start + Double(frame))))
                    for channel in 0..<channels { samples[frame * channels + channel] = value }
                }
            }
        }
    }

    func start() throws { try proc?.start() }

    func stop() { proc = nil }
}

/// Records the first channel of a device's input stream.
@MainActor
final class Capture {
    private let samples: UnsafeMutablePointer<Float>
    private let written: UnsafeMutablePointer<Int>
    private let capacity: Int
    private var proc: IOProc?

    init(device: AudioDevice, seconds: Double) throws {
        capacity = Int((try device.nominalSampleRate) * seconds)
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
        nonisolated(unsafe) let samples = self.samples
        nonisolated(unsafe) let written = self.written
        let capacity = self.capacity
        proc = try IOProc(device: device) { _, input, _, _, _ in
            guard let input, let buffer = input.first else { return }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let source = buffer.mData?.assumingMemoryBound(to: Float.self)
            else { return }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            for frame in 0..<frames where written.pointee < capacity {
                samples[written.pointee] = source[frame * channels]
                written.pointee += 1
            }
        }
    }

    func start() throws { try proc?.start() }

    /// Stops the proc and answers what it recorded.
    func stop() -> [Float] {
        proc = nil
        let recorded = Array(UnsafeBufferPointer(start: samples, count: written.pointee))
        samples.deallocate()
        written.deallocate()
        return recorded
    }
}

/// The strongest tone in `range` and its amplitude, searched around `around` by projecting the
/// signal onto a sine and cosine at each candidate.
func dominantTone(
    _ samples: [Float], around: Double, sampleRate: Double, channels: Int = 1, range: Range<Int>
) -> (frequency: Double, amplitude: Double) {
    var best = (frequency: around, amplitude: 0.0)
    var step = around / 100
    var centre = around
    //  Three passes: a tenth of the centre frequency wide, then a tenth of that, and so on.
    for _ in 0..<3 {
        for index in -10...10 {
            let frequency = centre + Double(index) * step
            let amplitude = toneAmplitude(
                samples, frequency: frequency, sampleRate: sampleRate, channels: channels, range: range)
            if amplitude > best.amplitude { best = (frequency, amplitude) }
        }
        centre = best.frequency
        step /= 10
    }
    return best
}

func toneAmplitude(
    _ samples: [Float], frequency: Double, sampleRate: Double, channels: Int = 1, range: Range<Int>
) -> Double {
    let step = 2 * Double.pi * frequency / sampleRate
    var cosine = 0.0
    var sine = 0.0
    for index in range {
        let phase = step * Double(index)
        let value = Double(samples[index * channels])
        cosine += value * cos(phase)
        sine += value * sin(phase)
    }
    let count = Double(range.count)
    return (pow(2 * cosine / count, 2) + pow(2 * sine / count, 2)).squareRoot()
}

/// A second output device that exists on any machine with the driver and plays nowhere: an
/// aggregate over one of Myco's own devices, visible to this process only.
final class PrivateAggregate {
    let id: AudioDeviceID
    let uid: String

    init(over device: AudioDevice) throws {
        uid = "com.myco.tests.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Myco test output",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: try device.uid]],
        ]
        var id = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else { throw XCTSkip("aggregate device: \(status)") }
        self.id = id
        // The HAL builds the aggregate's streams after the call returns.
        Thread.sleep(forTimeInterval: 0.5)
    }

    func destroy() { AudioHardwareDestroyAggregateDevice(id) }
}
