//  Plays a tone into each virtual device and checks that the same tone comes back: through the
//  shared object for `Myco`, through the input stream for `Myco Mic`.
//  The tests skip when the driver is not installed in /Library/Audio/Plug-Ins/HAL.
//
//  Reading an input device needs microphone permission, and the process that owns the terminal
//  grants it. Run these from Terminal.app; a terminal without that permission captures silence.

import CoreAudio
import XCTest

@testable import MycoEngine

final class DriverLoopbackTests: XCTestCase {

    private static let outputUID = "com.myco.output"
    private static let micUID = "com.myco.mic"

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

    /// Plays a 1 kHz sine into the device for `seconds` and answers the root mean square of what
    /// was written and of what the driver's shared ring holds afterwards.
    private func feedLoopback(deviceID: AudioObjectID, seconds: Double) throws -> (written: Double, captured: Double) {
        let feed = try SharedFeed.open()
        defer { feed.unmap() }
        let rate = try sampleRate(of: deviceID)
        XCTAssertEqual(feed.sampleRate, rate, "the header carries the device's rate")

        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let writtenSum = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let writtenCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        phase.pointee = 0
        writtenSum.pointee = 0
        writtenCount.pointee = 0
        defer {
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

        XCTAssertEqual(AudioDeviceStart(deviceID, writer), noErr, "start writer")
        //  The first tenth of a second covers the cycles before the writer has filled the ring.
        Thread.sleep(forTimeInterval: 0.1)
        let first = feed.writeFrame
        Thread.sleep(forTimeInterval: seconds)
        let last = feed.writeFrame
        AudioDeviceStop(deviceID, writer)
        AudioDeviceDestroyIOProcID(deviceID, writer!)

        let counted = Int(last - first)
        XCTAssertGreaterThan(counted, Int(rate * 0.2), "frames the driver wrote")
        XCTAssertLessThanOrEqual(counted, feed.ringFrames, "the ring wrapped before it was read")

        var block = [Float](repeating: 0, count: counted * 2)
        block.withUnsafeMutableBufferPointer { feed.read(from: first, into: $0.baseAddress!, frames: counted) }
        var capturedSum = 0.0
        for index in 0..<counted {
            capturedSum += Double(block[index * 2]) * Double(block[index * 2])
        }

        XCTAssertGreaterThan(writtenCount.pointee, 0, "written frames")
        return (written: (writtenSum.pointee / Double(writtenCount.pointee)).squareRoot(),
                captured: (capturedSum / Double(counted)).squareRoot())
    }

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

    private func assertLevels(_ levels: (written: Double, captured: Double)) {
        XCTAssertGreaterThan(levels.captured, 0.001, "captured signal is silent")
        let difference = 20.0 * log10(levels.captured / levels.written)
        XCTAssertLessThan(abs(difference), 3.0,
                          "captured \(levels.captured) against written \(levels.written), \(difference) dB apart")
    }

    private func deviceOrSkip(_ uid: String) throws -> AudioObjectID {
        guard let deviceID = device(uid: uid) else {
            throw XCTSkip("\(uid) is absent; run make install first")
        }
        return deviceID
    }

    // MARK: - Tests

    func testOutputDeviceReachesTheSharedFeed() throws {
        assertLevels(try feedLoopback(deviceID: try deviceOrSkip(Self.outputUID), seconds: 0.5))
    }

    func testMicDeviceLoopsBack() throws {
        assertLevels(try loopback(deviceID: try deviceOrSkip(Self.micUID), seconds: 0.5))
    }

    func testDeviceStaysHiddenForOtherProcesses() throws {
        let deviceID = try deviceOrSkip(Self.outputUID)

        var proc: AudioDeviceIOProcID?
        XCTAssertEqual(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) { _, _, _, _, _ in }, noErr)
        XCTAssertEqual(AudioDeviceStart(deviceID, proc), noErr)
        defer {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc!)
        }

        XCTAssertEqual(isHidden(deviceID), 1, "the test process is not com.myco.app, so the device stays hidden")
    }
}
