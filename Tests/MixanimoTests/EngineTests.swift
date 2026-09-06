//  The engine against the real driver. The tests skip when it is not installed, and none of them
//  touches the machine's default devices or plays through a physical output.

import CoreAudio
import XCTest

@testable import Mixanimo

/// A store of its own, so a test never reads or writes what the app saved.
private let testSuite = "com.mixanimo.tests"

@MainActor
final class EngineTests: XCTestCase {
    private func emptyStore() -> UserDefaults {
        let store = UserDefaults(suiteName: testSuite)!
        store.removePersistentDomain(forName: testSuite)
        return store
    }

    private func device(_ uid: String) throws -> AudioDevice {
        guard let device = try AudioDevice.find(uid: uid) else {
            throw XCTSkip("\(uid) is absent; run make install first")
        }
        return device
    }

    private func settings(virtualRate: Double) -> Settings {
        var settings = Settings()
        settings.virtualRate = virtualRate
        settings.pinDefaults = false
        return settings
    }

    /// The feed reads the virtual device even with nothing enabled, which is the one path every
    /// output hangs off.
    func testFeedReadsTheVirtualDevice() throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let store = emptyStore()
        let model = AppModel(settings: settings(virtualRate: 48000))
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: store)
        engine.start()
        defer { engine.stop() }

        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try source.start()
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()

        XCTAssertTrue(model.outputStatus.isEmpty, "no output is enabled")
        XCTAssertGreaterThan(engine.feedFrames, Int(48000 * 0.2), "frames the feed read")
    }

    /// The whole output chain end to end: a tone written into `Mixanimo` at 88200 comes out of the
    /// engine's output proc on `Mixanimo Mic` at 48000, at the level it went in.
    func testEnabledOutputCarriesTheResampledFeed() throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        try virtual.setVolumeScalar(1, scope: .output)
        try virtual.setMute(false, scope: .output)

        var settings = settings(virtualRate: 88200)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true)
        let store = emptyStore()
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: store)
        engine.start()
        defer { engine.stop() }
        XCTAssertEqual(model.master, 1, "the driver's volume control")
        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.isActive, true)

        let capture = try Capture(device: mic, seconds: 1.5)
        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try capture.start()
        try source.start()
        Thread.sleep(forTimeInterval: 1.0)
        source.stop()
        let recorded = capture.stop()

        //  The first half second covers the ring priming and the gain ramps.
        let range = 24000..<min(recorded.count, 48000)
        XCTAssertGreaterThan(range.count, 12000, "captured frames")
        let level = rms(recorded, channel: 0, channels: 1, range: range)
        XCTAssertEqual(
            decibels(level / (0.5 / 2.0.squareRoot())), 0, accuracy: 3, "level against the source")

        //  The tone sits where the two clocks put it, so the search says which frequency arrived and
        //  the residual says the chain left nothing else behind.
        let tone = dominantTone(recorded, around: 1000, sampleRate: 48000, range: range)
        XCTAssertEqual(tone.frequency, 1000, accuracy: 2, "the resampled tone drifted off 1 kHz")
        XCTAssertEqual(decibels(tone.amplitude / 0.5), 0, accuracy: 1, "the tone's own level")
        XCTAssertLessThan(
            totalDistortionDecibels(
                recorded, frequency: tone.frequency, sampleRate: 48000, channel: 0, channels: 1,
                range: range),
            -20, "the captured tone carries more than the source did")
    }

    /// A 32-frame output is not held to the process default feed block: the feed shrinks to the one
    /// output pull, the ring stays fed at that size, and the tone still comes out.
    func testSmallOutputBufferShrinksTheFeed() throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        try virtual.setVolumeScalar(1, scope: .output)
        try virtual.setMute(false, scope: .output)

        var settings = settings(virtualRate: 88200)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, bufferFrames: 32)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        engine.start()
        defer { engine.stop() }

        XCTAssertEqual(Int(try mic.bufferFrameSize), 32, "the output runs at the size it was given")
        XCTAssertEqual(engine.feedBlockFrames, 59, "32 output frames at 48000 are 59 at 88200")

        let capture = try Capture(device: mic, seconds: 1.5)
        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try capture.start()
        try source.start()
        Thread.sleep(forTimeInterval: 1.0)
        source.stop()
        let recorded = capture.stop()
        engine.pollCounters()

        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.underruns, 0)
        //  The first half second covers the ring priming and the gain ramps.
        let range = 24000..<min(recorded.count, 48000)
        XCTAssertGreaterThan(range.count, 12000, "captured frames")
        let tone = dominantTone(recorded, around: 1000, sampleRate: 48000, range: range)
        XCTAssertEqual(tone.frequency, 1000, accuracy: 2, "the resampled tone drifted off 1 kHz")
        XCTAssertEqual(decibels(tone.amplitude / 0.5), 0, accuracy: 1, "the tone's own level")

        //  The ring the feed fills is most of what this output waits for, so the reported latency
        //  has to carry it; 32 frames of buffer alone would be a fifth of a millisecond.
        let status = try XCTUnwrap(model.outputStatus[AppModel.micDeviceUID])
        XCTAssertGreaterThan(status.latencyMilliseconds, 3, "the ring prime is missing from it")
        XCTAssertLessThan(status.latencyMilliseconds, 12)
    }

    /// Sync publishes the alignment delay and the measured latency per output; the only output has
    /// nothing to wait for, so its delay is its own trim.
    func testSyncPublishesDelayAndLatency() throws {
        _ = try device(AppModel.outputDeviceUID)
        _ = try device(AppModel.micDeviceUID)

        var synced = settings(virtualRate: 48000)
        synced.sync = true
        synced.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, syncTrimMilliseconds: 10)
        let store = emptyStore()
        let model = AppModel(settings: synced)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: store)
        engine.start()
        let status = try XCTUnwrap(model.outputStatus[AppModel.micDeviceUID])
        engine.stop()

        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.sampleRate, 48000)
        XCTAssertEqual(status.delayMilliseconds, 10, accuracy: 0.05)
        XCTAssertGreaterThan(status.latencyMilliseconds, 0)

        var free = synced
        free.sync = false
        let unsyncedModel = AppModel(settings: free)
        let unsynced = Engine(model: unsyncedModel, managesDefaults: false, defaultsStore: store)
        unsynced.start()
        let without = try XCTUnwrap(unsyncedModel.outputStatus[AppModel.micDeviceUID])
        unsynced.stop()

        XCTAssertEqual(without.delayMilliseconds, 0, "sync off means no delay")
        XCTAssertEqual(without.latencyMilliseconds, status.latencyMilliseconds, accuracy: 0.001)
    }

    /// The input path end to end: an enabled microphone reaches `Mixanimo Mic`, which is where
    /// other apps read the mix. Room noise is enough; the point is that the path carries audio.
    func testEnabledInputReachesTheMicDevice() throws {
        _ = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        guard let source = try AudioDevice.all.first(where: { $0.transportType == .builtIn && $0.hasInput })
        else { throw XCTSkip("this machine has no built-in microphone") }

        var settings = settings(virtualRate: 48000)
        settings.inputs[try source.uid] = InputSettings(enabled: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        engine.start()
        defer { engine.stop() }

        let capture = try Capture(device: mic, seconds: 1.5)
        try capture.start()
        Thread.sleep(forTimeInterval: 1.0)
        let recorded = capture.stop()

        XCTAssertGreaterThan(recorded.count, 24000, "captured frames")
        let level = rms(recorded, channel: 0, channels: 1, range: 24000..<recorded.count)
        XCTAssertGreaterThan(level, 0, "the mic mix reached the device as silence")
    }

    func testInstalledDriverReportsItsVersion() throws {
        guard let version = DriverInstaller.installedVersion() else {
            throw XCTSkip("the driver is not installed; run make install first")
        }
        XCTAssertEqual(version, "0.2.0")
        //  The test host is not the app bundle, so nothing is bundled to compare against.
        XCTAssertEqual(DriverInstaller.bundledVersion, "")
        XCTAssertEqual(DriverInstaller.status(), .ready(version: "0.2.0"))
    }

    /// A set left behind by a run that never restored is what the next run puts back, rather than
    /// the virtual devices it finds pinned.
    func testDefaultDevicesKeepAnUnrestoredSet() throws {
        let store = emptyStore()
        let remembered = SavedDefaults(
            output: "test.output", systemOutput: "test.system", input: "test.input")

        let first = DefaultDevices(store: store)
        XCTAssertNil(first.saved)
        first.capture(current: remembered)
        XCTAssertEqual(first.saved, remembered)

        let afterCrash = DefaultDevices(store: store)
        XCTAssertEqual(afterCrash.saved, remembered)
        afterCrash.capture(
            current: SavedDefaults(
                output: AppModel.outputDeviceUID, systemOutput: AppModel.outputDeviceUID,
                input: AppModel.micDeviceUID))
        XCTAssertEqual(afterCrash.saved, remembered, "the pinned devices must not overwrite it")

        //  These UIDs name no device on this machine, so restoring only clears the memory.
        afterCrash.restore()
        XCTAssertNil(afterCrash.saved)
        XCTAssertNil(DefaultDevices(store: store).saved)
    }
}
