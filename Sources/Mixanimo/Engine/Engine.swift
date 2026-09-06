import CoreAudio
import Foundation
import Observation
import ServiceManagement
import os

/// The running audio graph.
///
/// One IO proc reads the `Mixanimo` device and copies the feed into a ring per enabled output; each
/// output's own IO proc pulls that ring through a resampler, the mic monitor, the EQ, the delay and
/// the gains. Enabled inputs are summed to the mic mix at 48 kHz, which the `Mixanimo Mic` device
/// publishes and every monitoring output taps directly.
///
/// The engine watches `model.settings` and the device list and reconciles the graph against them.
/// Anything that changes the shape of the graph rebuilds it; gains, EQ bands and delays are pushed
/// into the running DSP objects instead.
@MainActor
final class Engine {
    /// Everything that decides the shape of the graph. A difference here is a rebuild.
    private struct Plan: Equatable {
        struct Output: Equatable {
            var uid: String
            var deviceID: AudioDeviceID
            var sampleRate: Double
            /// What the device will run at, already clamped to its range.
            var bufferFrames: UInt32
            var monitor: Bool
        }

        struct Input: Equatable {
            var uid: String
            var deviceID: AudioDeviceID
            var sampleRate: Double
            /// One IO cycle of this input, in mic mix frames.
            var blockFrames: Int
        }

        var virtualRate: Double = 0
        var feedFrames: Int = 0
        var outputs: [Output] = []
        var inputs: [Input] = []

        /// The largest block any input writes into a monitor ring at once.
        var inputBlockFrames: Int { inputs.map(\.blockFrames).max() ?? 0 }
    }

    private let model: AppModel
    private let managesDefaults: Bool
    private let log = Logger(subsystem: AppModel.appBundleID, category: "engine")
    let defaultDevices: DefaultDevices

    private var running = false
    private var plan = Plan()
    private var feed: FeedNode?
    private var outputs: [OutputNode] = []
    private var inputs: [InputNode] = []
    private var micDrain: MicDrainNode?
    private var listeners: [AudioObjectPropertyListener] = []
    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var launchAtLoginApplied: Bool?

    /// Frames the feed has read from the virtual device since the graph was last built.
    var feedFrames: Int { feed?.frames.value ?? 0 }

    /// One IO cycle of the feed, in virtual frames, as the virtual device took it.
    private(set) var feedBlockFrames = 0

    /// `managesDefaults` off leaves the machine's default devices alone, which is what a test that
    /// must not disturb the running system wants.
    init(model: AppModel, managesDefaults: Bool = true, defaultsStore: UserDefaults = .standard) {
        self.model = model
        self.managesDefaults = managesDefaults
        self.defaultDevices = DefaultDevices(store: defaultsStore)
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        model.driver = DriverInstaller.status()

        if managesDefaults {
            defaultDevices.capture()
            defaultDevices.pin()
        }
        watchVirtualDevice()
        readMaster()

        eventTask = Task { [weak self] in
            guard let events = self?.model.devices.events() else { return }
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.pollCounters()
            }
        }

        observeSettings()
        apply()
    }

    func stop() {
        guard running else { return }
        running = false
        eventTask?.cancel()
        eventTask = nil
        statusTask?.cancel()
        statusTask = nil
        listeners = []
        teardown()
        plan = Plan()
        model.outputStatus = [:]
        if managesDefaults { defaultDevices.restore() }
    }

    /// Installs the bundled driver and reports what the machine has afterwards. The device list
    /// settles inside the installer, so the answer is the new state.
    func installDriver() async throws {
        defer { model.driver = DriverInstaller.status() }
        try await DriverInstaller.install()
    }

    func uninstallDriver() async throws {
        defer { model.driver = DriverInstaller.status() }
        try await DriverInstaller.uninstall()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, running else { return }
                observeSettings()
                apply()
            }
        }
    }

    private func handle(_ event: DeviceMonitor.Event) {
        switch event {
        case .arrived, .departed:
            model.driver = DriverInstaller.status()
            apply()
        case .aliveChanged, .sampleRateChanged:
            apply()
        case .defaultChanged:
            if managesDefaults, model.settings.pinDefaults { defaultDevices.pin() }
        }
    }

    // MARK: Reconciliation

    private func apply() {
        guard running else { return }
        applyLaunchAtLogin()
        applyVirtualRate()
        let wanted = makePlan()
        if wanted != plan {
            teardown()
            plan = wanted
            build()
        }
        pushParameters()
    }

    private var virtualDevice: AudioDevice? { (try? AudioDevice.find(uid: AppModel.outputDeviceUID)) ?? nil }
    private var micDevice: AudioDevice? { (try? AudioDevice.find(uid: AppModel.micDeviceUID)) ?? nil }

    /// The virtual device is the one device the engine sets the rate on; a physical device keeps
    /// whatever rate it is at.
    private func applyVirtualRate() {
        guard let device = virtualDevice else { return }
        let wanted = model.settings.virtualRate
        guard (try? device.nominalSampleRate) != wanted else { return }
        do {
            try device.setNominalSampleRate(wanted)
        } catch {
            log.error("virtual rate \(wanted): \(String(describing: error), privacy: .public)")
            return
        }
        // The HAL performs the change on its own thread; the graph is built against the new rate.
        for _ in 0..<50 where (try? device.nominalSampleRate) != wanted {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func makePlan() -> Plan {
        guard let virtual = virtualDevice else { return Plan() }
        var wanted = Plan(virtualRate: model.settings.virtualRate)

        let outputUIDs = Set(model.settings.outputs.filter(\.value.enabled).keys)
        for uid in Engine.ordered(outputUIDs, listed: model.devices.outputs) {
            guard uid != AppModel.outputDeviceUID, let device = Engine.present(uid) else { continue }
            let settings = model.output(uid)
            wanted.outputs.append(
                Plan.Output(
                    uid: uid, deviceID: device.id,
                    sampleRate: (try? device.nominalSampleRate) ?? 0,
                    bufferFrames: OutputNode.effectiveBufferFrames(device, settings.bufferFrames),
                    monitor: settings.monitor))
        }
        let inputUIDs = Set(model.settings.inputs.filter(\.value.enabled).keys)
        for uid in Engine.ordered(inputUIDs, listed: model.devices.inputs) {
            guard uid != AppModel.micDeviceUID, uid != AppModel.outputDeviceUID,
                let device = Engine.present(uid)
            else { continue }
            let rate = (try? device.nominalSampleRate) ?? 0
            let block = Int((try? device.bufferFrameSize) ?? 512)
            wanted.inputs.append(
                Plan.Input(
                    uid: uid, deviceID: device.id, sampleRate: rate,
                    blockFrames: rate > 0
                        ? Int((Double(block) * micMixRate / rate).rounded(.up)) : block))
        }
        wanted.feedFrames = Engine.feedFrames(
            for: wanted.outputs, virtualRate: wanted.virtualRate,
            range: try? virtual.bufferFrameSizeRange)
        return wanted
    }

    /// The feed block, in virtual frames: the shortest block any enabled output pulls, so a wired
    /// output at 32 frames is not held to the process default. Without an output there is nothing to
    /// feed, and 512 keeps the virtual device on the size the HAL hands a client by default.
    private static func feedFrames(
        for outputs: [Plan.Output], virtualRate: Double, range: ClosedRange<UInt32>?
    ) -> Int {
        let blocks = outputs.compactMap { output -> UInt32? in
            guard output.sampleRate > 0 else { return nil }
            return UInt32((Double(output.bufferFrames) * virtualRate / output.sampleRate).rounded(.up))
        }
        guard let smallest = blocks.min() else { return 512 }
        guard let range else { return Int(smallest) }
        return Int(min(max(smallest, range.lowerBound), range.upperBound))
    }

    /// `wanted` in the order the device list shows them, followed by the ones the list leaves out
    /// because the HAL hides them from this process; a hidden device still works by UID.
    private static func ordered(_ wanted: Set<String>, listed: [AudioDevice]) -> [String] {
        var uids = listed.compactMap { device -> String? in
            guard let uid = try? device.uid, wanted.contains(uid) else { return nil }
            return uid
        }
        uids.append(contentsOf: wanted.subtracting(uids).sorted())
        return uids
    }

    /// The device behind a UID, when the HAL still has it and it is alive.
    private static func present(_ uid: String) -> AudioDevice? {
        guard let device = (try? AudioDevice.find(uid: uid)) ?? nil, device.isAlive else { return nil }
        return device
    }

    private func build() {
        guard let virtual = virtualDevice else { return }

        // Every output ring is topped up one feed block at a time and primes against it, so the feed
        // takes its size before the outputs are sized, and they follow what the device really gives.
        try? virtual.setBufferFrameSize(UInt32(plan.feedFrames))
        feedBlockFrames = Int((try? virtual.bufferFrameSize) ?? UInt32(plan.feedFrames))

        for item in plan.outputs {
            do {
                outputs.append(
                    try OutputNode(
                        uid: item.uid, device: AudioDevice(id: item.deviceID),
                        settings: model.output(item.uid), virtualRate: plan.virtualRate,
                        feedBlockFrames: feedBlockFrames, inputs: plan.inputs.count,
                        inputBlockFrames: plan.inputBlockFrames))
            } catch {
                log.error("output \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if !plan.inputs.isEmpty, let mic = micDevice {
            micDrain = try? MicDrainNode(
                device: mic, inputs: plan.inputs.count, inputBlockFrames: plan.inputBlockFrames)
        }

        for (index, item) in plan.inputs.enumerated() {
            var rings: [RingBuffer] = []
            if let micDrain { rings.append(micDrain.tap.rings[index]) }
            for output in outputs { if let tap = output.tap { rings.append(tap.rings[index]) } }
            do {
                inputs.append(
                    try InputNode(
                        uid: item.uid, device: AudioDevice(id: item.deviceID),
                        settings: model.input(item.uid), destinations: rings))
            } catch {
                log.error("input \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        feed = try? FeedNode(device: virtual, rings: outputs.map(\.ring))

        // Consumers first, so a producer never writes into a ring nobody drains.
        for output in outputs { try? output.start() }
        try? micDrain?.start()
        for input in inputs { try? input.start() }
        try? feed?.start()

        model.outputStatus = Dictionary(
            uniqueKeysWithValues: outputs.map {
                ($0.uid, OutputStatus(isActive: true, sampleRate: $0.sampleRate))
            })
    }

    /// Tears the graph down producer first, so nothing writes into a ring that is already gone.
    private func teardown() {
        feed?.stop()
        feed = nil
        for input in inputs { input.stop() }
        inputs = []
        micDrain?.stop()
        micDrain = nil
        for output in outputs { output.stop() }
        outputs = []
        feedBlockFrames = 0
    }

    // MARK: Parameters

    private func pushParameters() {
        let master = model.masterMuted ? 0 : Engine.masterLinear(model.master)
        for node in outputs {
            let settings = model.output(node.uid)
            node.gainTarget.value = decibelsToLinear(settings.gainDB)
            node.monitorGainTarget.value = decibelsToLinear(settings.monitorGainDB)
            node.masterTarget.value = master
            if settings.eq.count == Equalizer.bandCount { node.eq.setBands(settings.eq) }
        }
        for node in inputs {
            let settings = model.input(node.uid)
            node.gainTarget.value = settings.muted ? 0 : decibelsToLinear(settings.gainDB)
        }
        applyDelays()
    }

    /// Sync on delays every output to the slowest one and adds its trim; sync off means no delay.
    private func applyDelays() {
        let sync = model.settings.sync
        let aligned = sync
            ? alignmentDelays(outputs.map(\.latency))
            : Array(repeating: 0, count: outputs.count)
        for (index, node) in outputs.enumerated() {
            let trim = sync ? model.output(node.uid).syncTrimMilliseconds : 0
            let frames = max(0, aligned[index] + Int((trim / 1000 * node.sampleRate).rounded()))
            node.delay.setDelay(frames: frames)
            model.outputStatus[node.uid, default: OutputStatus()].isActive = true
            model.outputStatus[node.uid]?.sampleRate = node.sampleRate
            model.outputStatus[node.uid]?.latencyMilliseconds = node.latency.seconds * 1000
            model.outputStatus[node.uid]?.delayMilliseconds =
                node.sampleRate > 0 ? Double(frames) / node.sampleRate * 1000 : 0
        }
    }

    /// Copies what the IO threads counted into the status the UI reads.
    func pollCounters() {
        for node in outputs {
            model.outputStatus[node.uid]?.underruns = node.underruns.value
        }
    }

    private func applyLaunchAtLogin() {
        // Only the shipped app may register itself; a test host must not end up in the login items.
        guard Bundle.main.bundleIdentifier == AppModel.appBundleID else { return }
        let wanted = model.settings.launchAtLogin
        guard wanted != launchAtLoginApplied else { return }
        launchAtLoginApplied = wanted
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("launch at login \(wanted): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Master

    /// The driver's volume slider is a cube taper, so the scalar cubed is the gain it shows.
    static func masterLinear(_ scalar: Float) -> Float {
        let clamped = min(max(scalar, 0), 1)
        return clamped * clamped * clamped
    }

    /// Keeps the master gain in step with the virtual device's volume control.
    private func watchVirtualDevice() {
        guard let device = virtualDevice else { return }
        let master: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute,
        ]
        listeners = master.compactMap { selector in
            try? AudioObjectPropertyListener(
                device.id,
                AudioObjectPropertyAddress(
                    selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard)
            ) { [weak self] _ in
                self?.readMaster()
            }
        }
    }

    private func readMaster() {
        guard let device = virtualDevice else { return }
        if let scalar = (try? device.volumeScalar(scope: .output)) ?? nil { model.master = scalar }
        if let muted = (try? device.mute(scope: .output)) ?? nil { model.masterMuted = muted }
        pushParameters()
    }
}
