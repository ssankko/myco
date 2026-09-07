import CoreAudio
import XCTest

@testable import MycoEngine

@MainActor
final class CoreAudioDeviceTests: XCTestCase {
    /// The first built-in device with streams in `scope`, or a skip when the machine has none.
    private func builtIn(_ scope: AudioDevice.Scope) throws -> AudioDevice {
        let devices = try AudioDevice.all.filter {
            $0.transportType == .builtIn
                && (scope == .output ? $0.hasOutput : $0.hasInput)
        }
        guard let device = devices.first else {
            throw XCTSkip("No built-in \(scope) device on this machine.")
        }
        return device
    }

    func testBuiltInSpeakersAreEnumerated() throws {
        let speakers = try builtIn(.output)
        XCTAssertEqual(speakers.transportType, .builtIn)
        XCTAssertTrue(speakers.hasOutput)
        XCTAssertGreaterThan(speakers.outputChannelCount, 0)
        XCTAssertFalse(speakers.name.isEmpty)
        XCTAssertTrue(speakers.isAlive)
    }

    func testBuiltInMicrophoneHasInput() throws {
        let microphone = try builtIn(.input)
        XCTAssertTrue(microphone.hasInput)
        XCTAssertGreaterThan(microphone.inputChannelCount, 0)
    }

    func testFindByUIDRoundTrips() throws {
        let speakers = try builtIn(.output)
        let uid = try speakers.uid
        XCTAssertFalse(uid.isEmpty)
        let found = try XCTUnwrap(AudioDevice.find(uid: uid))
        XCTAssertEqual(found.id, speakers.id)
        XCTAssertEqual(try found.uid, uid)
        XCTAssertNil(try AudioDevice.find(uid: "com.ssankko.myco.no-such-device"))
    }

    func testBufferFrameSizeRoundTrips() throws {
        let speakers = try builtIn(.output)
        let range = try speakers.bufferFrameSizeRange
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
        XCTAssertGreaterThan(range.upperBound, 0)

        let original = try speakers.bufferFrameSize
        let wanted = min(max(256, range.lowerBound), range.upperBound)
        try speakers.setBufferFrameSize(wanted)
        XCTAssertEqual(try speakers.bufferFrameSize, wanted)
        try speakers.setBufferFrameSize(original)
    }

    func testLatencyAndSafetyOffsetOnEveryDevice() throws {
        for device in try AudioDevice.all {
            for scope in AudioDevice.Scope.allCases where device.channelCount(scope: scope) > 0 {
                XCTAssertNoThrow(try device.latency(scope: scope), device.name)
                XCTAssertNoThrow(try device.safetyOffset(scope: scope), device.name)
                XCTAssertNoThrow(try device.streamLatency(scope: scope), device.name)
                XCTAssertNoThrow(try device.streamFormat(scope: scope), device.name)
            }
            XCTAssertNoThrow(try device.nominalSampleRate, device.name)
        }
    }

    func testIOProcReceivesSilentCallback() throws {
        let speakers = try builtIn(.output)
        let original = try speakers.bufferFrameSize
        defer { try? speakers.setBufferFrameSize(original) }

        // The IO thread writes here; the test thread reads it after the semaphore.
        nonisolated(unsafe) let frames = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        frames.initialize(to: 0)
        defer { frames.deallocate() }
        let arrived = DispatchSemaphore(value: 0)

        let proc = try IOProc(device: speakers, bufferFrameSize: 512) { _, _, _, output, _ in
            guard let output, let first = output.first else { return }
            for buffer in output { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            guard frames.pointee == 0 else { return }
            frames.pointee = first.mDataByteSize / max(1, first.mNumberChannels * 4)
            arrived.signal()
        }

        try proc.start()
        XCTAssertTrue(proc.isRunning)
        XCTAssertEqual(arrived.wait(timeout: .now() + 1), .success, "No IO callback within one second.")
        try proc.stop()
        XCTAssertFalse(proc.isRunning)
        XCTAssertGreaterThan(frames.pointee, 0)
    }

    /// Reads only: the machine's own volume must not move because of a test run.
    func testVolumeAndMuteRead() throws {
        let speakers = try builtIn(.output)
        if let volume = try speakers.volumeScalar(scope: .output) {
            XCTAssertTrue((0...1).contains(volume), "Volume \(volume) outside 0...1.")
        }
        XCTAssertNoThrow(try speakers.mute(scope: .output))
    }

    func testMonitorListsDevices() throws {
        let monitor = DeviceMonitor()
        XCTAssertFalse(monitor.outputs.isEmpty)
        XCTAssertEqual(monitor.outputs.count, try AudioDevice.all.filter(\.hasOutput).count)
        XCTAssertEqual(monitor.defaultOutput?.id, try AudioDevice.defaultOutput?.id)
    }
}
