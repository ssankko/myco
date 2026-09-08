//  The engine against the real driver. The tests skip when it is not installed, and none of them
//  touches the machine's default devices or plays through a physical output.

import CoreAudio
import MycoTestSupport
import XCTest

@testable import MycoEngine

/// A store of its own, so a test never reads or writes what the app saved.
private let testSuite = "com.ssankko.myco.tests"

@MainActor
final class EngineTests: XCTestCase {
    private nonisolated func emptyStore() -> UserDefaults {
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

    /// The driver's ring is what every output hangs off, and the engine reaches it without an IO
    /// proc of its own on the virtual device.
    func testTheSharedRingCarriesWhatIsPlayedIntoTheVirtualDevice() async throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let model = AppModel(settings: settings(virtualRate: 48000))
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }

        let feed = try SharedFeed.open()
        defer { feed.unmap() }
        XCTAssertEqual(feed.sampleRate, 48000, "the engine set the rate the header reports")

        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try source.start()
        let first = feed.writeFrame
        try await Task.sleep(for: .seconds(0.5))
        let last = feed.writeFrame
        source.stop()

        XCTAssertTrue(model.outputStatus.isEmpty, "no output is enabled")
        XCTAssertGreaterThan(Int(last - first), Int(48000 * 0.2), "frames the driver wrote")
        XCTAssertGreaterThan(feed.writeBlockFrames, 0, "the block the driver last took")
    }

    /// The whole output chain end to end: a tone written into `Myco` at 88200 comes out of the
    /// engine's output proc on `Myco Mic` at 48000, at the level it went in.
    func testEnabledOutputCarriesTheResampledFeed() async throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        try virtual.setVolumeScalar(1, scope: .output)
        try virtual.setMute(false, scope: .output)

        var settings = settings(virtualRate: 88200)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true)
        let store = emptyStore()
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: store)
        await engine.start()
        addTeardownBlock { await engine.stop() }
        XCTAssertEqual(model.master, 1, "the driver's volume control")
        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.isActive, true)

        let capture = try Capture(device: mic, seconds: 1.5)
        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try capture.start()
        try source.start()
        try await Task.sleep(for: .seconds(1.0))
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

    /// A 32-frame output reads the shared ring at its own size without running dry, and the tone
    /// still comes out.
    func testSmallOutputBufferPlaysWithoutUnderruns() async throws {
        let virtual = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        try virtual.setVolumeScalar(1, scope: .output)
        try virtual.setMute(false, scope: .output)

        var settings = settings(virtualRate: 88200)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, bufferFrames: 32)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }

        XCTAssertEqual(Int(try mic.bufferFrameSize), 32, "the output runs at the size it was given")

        let capture = try Capture(device: mic, seconds: 1.5)
        let source = try SineSource(device: virtual, frequency: 1000, amplitude: 0.5)
        try capture.start()
        try source.start()
        try await Task.sleep(for: .seconds(1.0))
        //  Counted while the source still plays: the last partial pull a source that stops leaves
        //  behind is one more underrun, and it says nothing about the second the output ran.
        await engine.pollCounters()
        source.stop()
        let recorded = capture.stop()

        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.underruns, 0)
        //  The first half second covers the ring priming and the gain ramps.
        let range = 24000..<min(recorded.count, 48000)
        XCTAssertGreaterThan(range.count, 12000, "captured frames")
        let tone = dominantTone(recorded, around: 1000, sampleRate: 48000, range: range)
        XCTAssertEqual(tone.frequency, 1000, accuracy: 2, "the resampled tone drifted off 1 kHz")
        XCTAssertEqual(decibels(tone.amplitude / 0.5), 0, accuracy: 1, "the tone's own level")

        //  What the output holds in the shared ring is most of what it waits for, so the reported
        //  latency has to carry it; 32 frames of buffer alone would be a fifth of a millisecond.
        let status = try XCTUnwrap(model.outputStatus[AppModel.micDeviceUID])
        XCTAssertGreaterThan(status.latencyMilliseconds, 3, "the target fill is missing from it")
    }

    /// Sync publishes the alignment delay and the measured latency per output; the only output has
    /// nothing to wait for, so its delay is its own trim.
    func testSyncPublishesDelayAndLatency() async throws {
        _ = try device(AppModel.outputDeviceUID)
        _ = try device(AppModel.micDeviceUID)

        var synced = settings(virtualRate: 48000)
        synced.sync = true
        synced.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, syncTrimMilliseconds: 10)
        let store = emptyStore()
        let model = AppModel(settings: synced)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: store)
        await engine.start()
        let status = try XCTUnwrap(model.outputStatus[AppModel.micDeviceUID])
        await engine.stop()

        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.sampleRate, 48000)
        XCTAssertEqual(status.delayMilliseconds, 10, accuracy: 0.05)
        XCTAssertGreaterThan(status.latencyMilliseconds, 0)

        var free = synced
        free.sync = false
        let unsyncedModel = AppModel(settings: free)
        let unsynced = Engine(model: unsyncedModel, managesDefaults: false, defaultsStore: store)
        await unsynced.start()
        let without = try XCTUnwrap(unsyncedModel.outputStatus[AppModel.micDeviceUID])
        await unsynced.stop()

        XCTAssertEqual(without.delayMilliseconds, 0, "sync off means no delay")
        XCTAssertEqual(without.latencyMilliseconds, status.latencyMilliseconds, accuracy: 0.001)
    }

    /// The input path end to end: an enabled microphone reaches `Myco Mic`, which is where
    /// other apps read the mix. Room noise is enough; the point is that the path carries audio.
    func testEnabledInputReachesTheMicDevice() async throws {
        _ = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        guard let source = try AudioDevice.all.first(where: { $0.transportType == .builtIn && $0.hasInput })
        else { throw XCTSkip("this machine has no built-in microphone") }

        var settings = settings(virtualRate: 48000)
        settings.inputs[try source.uid] = InputSettings(enabled: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }

        let capture = try Capture(device: mic, seconds: 1.5)
        try capture.start()
        try await Task.sleep(for: .seconds(1.0))
        let recorded = capture.stop()

        XCTAssertGreaterThan(recorded.count, 24000, "captured frames")
        let level = rms(recorded, channel: 0, channels: 1, range: 24000..<recorded.count)
        XCTAssertGreaterThan(level, 0, "the mic mix reached the device as silence")
    }

    /// The microphones open only while something listens. Idle, the source device runs in no
    /// process, so macOS shows no microphone indicator; a reader on `Myco Mic` opens it. The
    /// engine's own writer on `Myco Mic` uses no input stream, so it counts as no reader even from
    /// a process that is not the app.
    func testInputsOpenOnlyWhileTheMicDeviceIsRead() async throws {
        _ = try device(AppModel.outputDeviceUID)
        let mic = try device(AppModel.micDeviceUID)
        guard let source = try AudioDevice.all.first(where: { $0.transportType == .builtIn && $0.hasInput })
        else { throw XCTSkip("this machine has no built-in microphone") }
        let running = AudioObjectPropertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        guard try source.id.value(running) as UInt32 == 0
        else { throw XCTSkip("another process holds the built-in microphone") }

        // A reader from the test before holds its slot in the driver for up to half a second.
        let readers = AudioObjectPropertyAddress(AudioObjectPropertySelector(0x6D78_6369))
        for _ in 0..<30 where (try? mic.id.string(readers)) != "0" {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try mic.id.string(readers), "0", "Myco Mic still has a reader from another test")

        var settings = settings(virtualRate: 48000)
        settings.inputs[try source.uid] = InputSettings(enabled: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try source.id.value(running) as UInt32, 0, "the microphone opened with nothing listening")

        let capture = try Capture(device: mic, seconds: 2)
        try capture.start()
        try await Task.sleep(for: .seconds(1.0))
        XCTAssertEqual(try source.id.value(running) as UInt32, 1, "a reader on Myco Mic left the microphone closed")
        _ = capture.stop()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(try source.id.value(running) as UInt32, 0, "the microphone stayed open after the reader left")
    }

    /// The monitor is heard while nothing plays into the virtual device: the output proc drains
    /// its tap every cycle, so the ring an input writes into stays near its priming level instead
    /// of filling up.
    func testMonitorRunsWhileTheVirtualDeviceIsIdle() async throws {
        _ = try device(AppModel.outputDeviceUID)
        _ = try device(AppModel.micDeviceUID)
        guard let source = try AudioDevice.all.first(where: { $0.transportType == .builtIn && $0.hasInput })
        else { throw XCTSkip("this machine has no built-in microphone") }

        var settings = settings(virtualRate: 48000)
        settings.inputs[try source.uid] = InputSettings(enabled: true)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, monitor: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }

        let tapRings = await engine.outputs.first?.tapRings
        let rings = try XCTUnwrap(tapRings, "the output carries a tap")
        XCTAssertEqual(rings.count, MonitorTap.maxInputs)
        try await Task.sleep(for: .seconds(1.0))
        let ring = rings[0]
        XCTAssertGreaterThan(ring.fillLevel, 0, "the input wrote nothing")
        XCTAssertLessThan(ring.fillLevel, ring.capacityFrames / 2, "the output never drained the tap")
    }

    /// An input that comes on joins the running outputs instead of rebuilding them: the same
    /// output node is still there afterwards, and its monitor tap is being written and drained.
    func testEnablingAnInputLeavesTheOutputsRunning() async throws {
        _ = try device(AppModel.outputDeviceUID)
        _ = try device(AppModel.micDeviceUID)
        guard let source = try AudioDevice.all.first(where: { $0.transportType == .builtIn && $0.hasInput })
        else { throw XCTSkip("this machine has no built-in microphone") }

        var settings = settings(virtualRate: 48000)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true, monitor: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }
        let before = await engine.outputs.map(ObjectIdentifier.init)
        XCTAssertEqual(before.count, 1)

        model.updateInput(try source.uid) { $0.enabled = true }
        try await Task.sleep(for: .seconds(1))

        let after = await engine.outputs.map(ObjectIdentifier.init)
        XCTAssertEqual(after, before, "the output was built anew")
        XCTAssertFalse(model.isApplying)
        let tapRings = await engine.outputs.first?.tapRings
        let ring = try XCTUnwrap(tapRings)[0]
        XCTAssertGreaterThan(ring.fillLevel, 0, "the input never reached the running output")
        XCTAssertLessThan(ring.fillLevel, ring.capacityFrames / 2, "the output never drained the tap")
    }

    /// A second output that comes on is built beside the first: the node that was playing keeps
    /// its identity and its status, and only the new device is started.
    func testEnablingASecondOutputLeavesTheFirstRunning() async throws {
        _ = try device(AppModel.outputDeviceUID)
        let second = try PrivateAggregate(over: try device(AppModel.micDeviceUID))
        defer { second.destroy() }

        var settings = settings(virtualRate: 48000)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }
        let before = await nodes(engine)
        XCTAssertEqual(before.count, 1)

        model.updateOutput(second.uid) { $0.enabled = true }
        try await Task.sleep(for: .seconds(1))

        let after = await nodes(engine)
        XCTAssertEqual(after.count, 2, "the second device never started")
        XCTAssertTrue(
            after.first { $0.uid == AppModel.micDeviceUID }?.node === before[0].node,
            "the playing output was built anew")
        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.isActive, true)
        XCTAssertEqual(model.outputStatus[second.uid]?.isActive, true)
        XCTAssertFalse(model.isApplying)
    }

    /// A buffer size a device has to be restarted for replaces that one node and leaves every
    /// other output where it is.
    func testChangingOneBufferSizeReplacesOnlyThatOutput() async throws {
        _ = try device(AppModel.outputDeviceUID)
        let second = try PrivateAggregate(over: try device(AppModel.micDeviceUID))
        defer { second.destroy() }
        let secondUID = second.uid

        var settings = settings(virtualRate: 48000)
        settings.outputs[AppModel.micDeviceUID] = OutputSettings(enabled: true)
        settings.outputs[secondUID] = OutputSettings(enabled: true)
        let model = AppModel(settings: settings)
        let engine = Engine(model: model, managesDefaults: false, defaultsStore: emptyStore())
        await engine.start()
        addTeardownBlock { await engine.stop() }
        let before = await nodes(engine)
        XCTAssertEqual(before.count, 2)

        model.updateOutput(AppModel.micDeviceUID) { $0.bufferFrames = 256 }
        try await Task.sleep(for: .seconds(1))

        let after = await nodes(engine)
        XCTAssertEqual(after.count, 2)
        XCTAssertFalse(
            after.first { $0.uid == AppModel.micDeviceUID }?.node
                === before.first { $0.uid == AppModel.micDeviceUID }?.node,
            "the resized output kept its node")
        XCTAssertTrue(
            after.first { $0.uid == secondUID }?.node === before.first { $0.uid == secondUID }?.node,
            "the untouched output was built anew")
        XCTAssertEqual(model.outputStatus[secondUID]?.isActive, true)
        XCTAssertEqual(model.outputStatus[AppModel.micDeviceUID]?.isActive, true)
        XCTAssertFalse(model.isApplying)
    }

    /// Every output node the engine runs, keyed by UID. The caller holds the nodes, so one built
    /// after a stop cannot land at the address of one that went and pass for it.
    private func nodes(_ engine: Engine) async -> [(uid: String, node: OutputNode)] {
        await EngineActor.run { engine.outputs.map { (uid: $0.uid, node: $0) } }
    }

    func testInstalledDriverReportsItsVersion() throws {
        guard let version = DriverInstaller.installedVersion() else {
            throw XCTSkip("the driver is not installed; run make install first")
        }
        XCTAssertEqual(version, "0.4.0")
        //  The test host is not the app bundle, so nothing is bundled to compare against.
        XCTAssertEqual(DriverInstaller.bundledVersion, "")
        XCTAssertEqual(DriverInstaller.status(), .ready(version: "0.4.0"))
    }

    /// A set left behind by a run that never restored is what the next run puts back, rather than
    /// the virtual devices it finds pinned.
    func testDefaultDevicesKeepAnUnrestoredSet() async throws {
        try await EngineActor.run {
            let store = UserDefaults(suiteName: testSuite)!
            store.removePersistentDomain(forName: testSuite)
            try Self.checkDefaultDevices(store: store)
        }
    }

    @EngineActor
    private static func checkDefaultDevices(store: UserDefaults) throws {
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
