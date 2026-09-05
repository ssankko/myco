//  Plays a tone into each virtual device and checks that the same tone comes back.
//  The tests skip when the driver is not installed in /Library/Audio/Plug-Ins/HAL.

import CoreAudio
import XCTest

final class DriverLoopbackTests: XCTestCase {

    private static let outputUID = "com.mixanimo.output"
    private static let micUID = "com.mixanimo.mic"

    // MARK: - Property helpers

    private func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID)
        }
        return (status == noErr && deviceID != AudioObjectID(kAudioObjectUnknown)) ? deviceID : nil
    }

    private func sampleRate(of deviceID: AudioObjectID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        XCTAssertEqual(status, noErr, "nominal sample rate")
        return rate
    }

    private func isHidden(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var hidden = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &hidden), noErr)
        return hidden
    }

    // MARK: - Loopback

    /// Writes a 1 kHz sine through one IOProc, captures the input side through another, and
    /// answers the root mean square of each side.
    private func loopback(deviceID: AudioObjectID, seconds: Double) throws -> (written: Double, captured: Double) {
        let rate = try sampleRate(of: deviceID)
        let capacity = Int(rate * (seconds + 1.0)) * 2

        let capture = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        capture.initialize(repeating: 0, count: capacity)
        let captured = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let writtenSum = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let writtenCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        captured.pointee = 0
        phase.pointee = 0
        writtenSum.pointee = 0
        writtenCount.pointee = 0
        defer {
            capture.deallocate()
            captured.deallocate()
            phase.deallocate()
            writtenSum.deallocate()
            writtenCount.deallocate()
        }

        let step = 2.0 * Double.pi * 1000.0 / rate

        var writer: AudioDeviceIOProcID?
        let writerStatus = AudioDeviceCreateIOProcIDWithBlock(&writer, deviceID, nil) { _, _, _, outData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outData) {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                for frame in 0..<frames {
                    let value = Float(0.5 * sin(phase.pointee))
                    phase.pointee += step
                    if phase.pointee > 2.0 * Double.pi { phase.pointee -= 2.0 * Double.pi }
                    for channel in 0..<channels {
                        samples[frame * channels + channel] = value
                    }
                    writtenSum.pointee += Double(value) * Double(value)
                    writtenCount.pointee += 1
                }
            }
        }
        XCTAssertEqual(writerStatus, noErr, "create writer IOProc")

        var reader: AudioDeviceIOProcID?
        let readerStatus = AudioDeviceCreateIOProcIDWithBlock(&reader, deviceID, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for buffer in list {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                for frame in 0..<frames where captured.pointee < capacity {
                    capture[captured.pointee] = samples[frame * channels]
                    captured.pointee += 1
                }
            }
        }
        XCTAssertEqual(readerStatus, noErr, "create reader IOProc")

        XCTAssertEqual(AudioDeviceStart(deviceID, reader), noErr, "start reader")
        XCTAssertEqual(AudioDeviceStart(deviceID, writer), noErr, "start writer")
        Thread.sleep(forTimeInterval: seconds)
        AudioDeviceStop(deviceID, writer)
        AudioDeviceStop(deviceID, reader)
        AudioDeviceDestroyIOProcID(deviceID, writer!)
        AudioDeviceDestroyIOProcID(deviceID, reader!)

        //  The first tenth of a second covers the cycles before the writer's audio reaches the
        //  input side, so the level is measured after it.
        let skip = min(captured.pointee, Int(rate * 0.1))
        let counted = captured.pointee - skip
        XCTAssertGreaterThan(counted, Int(rate * 0.2), "captured frames")

        var capturedSum = 0.0
        for index in skip..<captured.pointee {
            capturedSum += Double(capture[index]) * Double(capture[index])
        }

        XCTAssertGreaterThan(writtenCount.pointee, 0, "written frames")
        return (written: (writtenSum.pointee / Double(writtenCount.pointee)).squareRoot(),
                captured: (capturedSum / Double(counted)).squareRoot())
    }

    private func assertLoopback(uid: String) throws {
        guard let deviceID = device(uid: uid) else {
            throw XCTSkip("\(uid) is absent; run make install first")
        }
        let levels = try loopback(deviceID: deviceID, seconds: 0.5)
        XCTAssertGreaterThan(levels.captured, 0.001, "captured signal is silent")
        let difference = 20.0 * log10(levels.captured / levels.written)
        XCTAssertLessThan(abs(difference), 3.0,
                          "captured \(levels.captured) against written \(levels.written), \(difference) dB apart")
    }

    // MARK: - Tests

    func testOutputDeviceLoopsBack() throws {
        try assertLoopback(uid: Self.outputUID)
    }

    func testMicDeviceLoopsBack() throws {
        try assertLoopback(uid: Self.micUID)
    }

    func testDeviceStaysHiddenForOtherProcesses() throws {
        guard let deviceID = device(uid: Self.outputUID) else {
            throw XCTSkip("\(Self.outputUID) is absent; run make install first")
        }

        var proc: AudioDeviceIOProcID?
        XCTAssertEqual(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) { _, _, _, _, _ in }, noErr)
        XCTAssertEqual(AudioDeviceStart(deviceID, proc), noErr)
        defer {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc!)
        }

        XCTAssertEqual(isHidden(deviceID), 1, "the test process is not com.mixanimo.app, so the device stays hidden")
    }
}
