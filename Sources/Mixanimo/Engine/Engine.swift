import CoreAudio
import Foundation
import Observation
import ServiceManagement
import os

/// The actor the engine and its nodes run on, so a device that takes its time to start or stop
/// never holds the main thread.
@globalActor
actor EngineActor {
    static let shared = EngineActor()

    static func run<T: Sendable>(_ body: @EngineActor @Sendable () throws -> T) async rethrows -> T {
        try await body()
    }
}

/// The running audio graph.
///
/// Every enabled output has one IO proc, which reads the driver's shared ring directly and pulls it
/// through a resampler, the mic monitor, the EQ, the delay and the gains. Enabled inputs are summed
/// to the mic mix at 48 kHz, which the `Mixanimo Mic` device publishes and every output's monitor
/// tap reads.
///
/// The engine takes a copy of `model.settings` whenever it changes and reconciles the graph against
/// it. A change to the outputs rebuilds the whole graph; a change to the inputs rebuilds the inputs
/// under the running outputs; gains, EQ bands and delays are pushed into the running DSP objects.
@EngineActor
final class Engine {
    /// Everything that decides the shape of the graph.
    private struct Plan: Equatable {
        struct Output: Equatable {
            var uid: String
            var deviceID: AudioDeviceID
            var sampleRate: Double
            /// What the device will run at, already clamped to its range.
            var bufferFrames: UInt32
        }

        struct Input: Equatable {
            var uid: String
            var deviceID: AudioDeviceID
            var sampleRate: Double
            /// One IO cycle of this input, in mic mix frames.
            var blockFrames: Int
        }

        /// The rate the shared ring runs at, which the engine sets from `settings.virtualRate`.
        var virtualRate: Double = 0
        var outputs: [Output] = []
        var inputs: [Input] = []

        /// The largest block any input writes into a monitor ring at once.
        var inputBlockFrames: Int { inputs.map(\.blockFrames).max() ?? 0 }

        /// True when the outputs, and so everything hanging off them, must be built anew.
        func rebuildsOutputs(from old: Plan) -> Bool {
            virtualRate != old.virtualRate || outputs != old.outputs
        }
    }

    /// Everything `makePlan` reads out of the settings. A change that leaves this alone moves a
    /// parameter in the running graph and never queries the HAL.
    private struct PlanInputs: Equatable {
        var virtualRate: Double
        /// Every enabled output and the buffer size it asks for.
        var outputs: [String: UInt32?]
        var inputs: Set<String>

        init(_ settings: Settings) {
            virtualRate = settings.virtualRate
            outputs = settings.outputs.filter(\.value.enabled).mapValues(\.bufferFrames)
            inputs = Set(settings.inputs.filter(\.value.enabled).keys)
        }
    }

    private let model: AppModel
    private let managesDefaults: Bool
    private let log = Logger(subsystem: AppModel.appBundleID, category: "engine")
    /// Thread-safe by contract, which the SDK does not spell out.
    nonisolated(unsafe) private let defaultsStore: UserDefaults
    lazy var defaultDevices = DefaultDevices(store: defaultsStore)

    private var running = false
    private var settings = Settings()
    private var master: Float = 1
    private var masterMuted = false
    private var plan = Plan()
    /// What the current plan was made from; nil until the first one.
    private var planInputs: PlanInputs?
    /// The bands each output last took, so a move of another slider pushes no coefficients.
    private var pushedEQ: [String: [BandSettings]] = [:]
    private var feed: SharedFeed?
    private(set) var outputs: [OutputNode] = []
    private var inputs: [InputNode] = []
    private var micDrain: MicDrainNode?
    private var outputStatus: [String: OutputStatus] = [:]
    private var listeners: [AudioObjectPropertyListener] = []
    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var launchAtLoginApplied: Bool?
    /// UIDs already reported as playing, so the log line lands once per graph.
    private var playing: Set<String> = []

    /// `managesDefaults` off leaves the machine's default devices alone, which is what a test that
    /// must not disturb the running system wants.
    nonisolated init(model: AppModel, managesDefaults: Bool = true, defaultsStore: UserDefaults = .standard) {
        self.model = model
        self.managesDefaults = managesDefaults
        self.defaultsStore = defaultsStore
    }

    // MARK: Lifecycle

    func start() async {
        guard !running else { return }
        running = true
        await publishDriver()

        if managesDefaults {
            defaultDevices.capture()
            defaultDevices.pin()
        }
        await watchVirtualDevice()
        await readMaster()

        let events = await model.devices.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await handle(event)
            }
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.pollCounters()
            }
        }

        await observeSettings()
        await apply(model.settings)
    }

    func stop() async {
        guard running else { return }
        running = false
        eventTask?.cancel()
        eventTask = nil
        statusTask?.cancel()
        statusTask = nil
        listeners = []
        await teardown()
        feed?.unmap()
        feed = nil
        plan = Plan()
        planInputs = nil
        outputStatus = [:]
        await publishStatus()
        if managesDefaults { defaultDevices.restore() }
    }

    /// Installs the bundled driver and reports what the machine has afterwards. The device list
    /// settles inside the installer, so the answer is the new state.
    func installDriver() async throws {
        defer { Task { await publishDriver() } }
        try await DriverInstaller.install()
    }

    func uninstallDriver() async throws {
        defer { Task { await publishDriver() } }
        try await DriverInstaller.uninstall()
    }

    /// Every change to the settings is handed to the engine as a copy, which decides how much of
    /// the graph it touches.
    @MainActor
    private func observeSettings() {
        withObservationTracking {
            _ = model.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observeSettings()
                await apply(model.settings)
            }
        }
    }

    private func handle(_ event: DeviceMonitor.Event) async {
        switch event {
        case .arrived, .departed:
            await publishDriver()
            await apply(settings, replan: true)
        case .aliveChanged, .sampleRateChanged:
            await apply(settings, replan: true)
        case .defaultChanged:
            if managesDefaults, settings.pinDefaults { defaultDevices.pin() }
        }
    }

    // MARK: Reconciliation

    /// `replan` asks the HAL again for a device that arrived, went away or changed its rate; a
    /// settings change plans anew only when it moves something the plan is made of.
    private func apply(_ wanted: Settings, replan: Bool = false) async {
        guard running else { return }
        settings = wanted
        applyLaunchAtLogin()
        let inputs = PlanInputs(wanted)
        if replan || inputs != planInputs {
            planInputs = inputs
            await applyVirtualRate()
            let next = makePlan()
            if next.rebuildsOutputs(from: plan) {
                await rebuilding {
                    await teardown()
                    plan = next
                    build()
                }
            } else if next.inputs != plan.inputs {
                await rebuilding {
                    await teardownInputs()
                    plan = next
                    buildInputs()
                }
            }
        }
        pushParameters()
        await publishStatus()
    }

    /// Holds the flag the popover shows a spinner for while nodes are stopped and started. A
    /// change that only moves a parameter never gets here, so a slider drag leaves it alone.
    private func rebuilding(_ body: @EngineActor () async -> Void) async {
        await MainActor.run { model.isApplying = true }
        await body()
        await MainActor.run { model.isApplying = false }
    }

    private var virtualDevice: AudioDevice? { (try? AudioDevice.find(uid: AppModel.outputDeviceUID)) ?? nil }
    private var micDevice: AudioDevice? { (try? AudioDevice.find(uid: AppModel.micDeviceUID)) ?? nil }

    /// The virtual device is the one device the engine sets the rate on; a physical device keeps
    /// whatever rate it is at.
    private func applyVirtualRate() async {
        guard let device = virtualDevice else { return }
        let wanted = settings.virtualRate
        guard (try? device.nominalSampleRate) != wanted else { return }
        do {
            try device.setNominalSampleRate(wanted)
        } catch {
            log.error("virtual rate \(wanted): \(String(describing: error), privacy: .public)")
            return
        }
        // The HAL performs the change on its own thread; the graph is built against the new rate.
        for _ in 0..<50 where (try? device.nominalSampleRate) != wanted {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePlan() -> Plan {
        // The rate in the header is the rate the samples in the ring were written at, so a change
        // still in flight rebuilds the graph against what the driver really does.
        guard virtualDevice != nil, let feed = openFeed() else { return Plan() }
        var wanted = Plan(virtualRate: feed.sampleRate)

        let outputUIDs = Set(settings.outputs.filter(\.value.enabled).keys)
        for uid in Engine.ordered(outputUIDs) {
            guard uid != AppModel.outputDeviceUID, let device = Engine.present(uid) else { continue }
            wanted.outputs.append(
                Plan.Output(
                    uid: uid, deviceID: device.id,
                    sampleRate: (try? device.nominalSampleRate) ?? 0,
                    bufferFrames: OutputNode.effectiveBufferFrames(device, output(uid).bufferFrames)))
        }
        let inputUIDs = Set(settings.inputs.filter(\.value.enabled).keys)
        for uid in Engine.ordered(inputUIDs) where wanted.inputs.count < MonitorTap.maxInputs {
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
        return wanted
    }

    /// The mapped ring, opened once and kept for as long as the engine runs. A driver that
    /// publishes no ring, or one this build cannot read, is a driver the app has to replace.
    private func openFeed() -> SharedFeed? {
        if let feed { return feed }
        do {
            feed = try SharedFeed.open()
        } catch {
            log.error("shared feed: \(String(describing: error), privacy: .public)")
            let status = DriverInstaller.installedVersion().map {
                DriverStatus.outdated(installed: $0, bundled: DriverInstaller.bundledVersion)
            } ?? .notInstalled
            Task { @MainActor in model.driver = status }
        }
        return feed
    }

    /// `wanted` in the order the HAL lists them, followed by the ones the HAL hides from this
    /// process; a hidden device still works by UID.
    private nonisolated static func ordered(_ wanted: Set<String>) -> [String] {
        var uids = ((try? AudioDevice.all) ?? []).compactMap { device -> String? in
            guard let uid = try? device.uid, wanted.contains(uid) else { return nil }
            return uid
        }
        uids.append(contentsOf: wanted.subtracting(uids).sorted())
        return uids
    }

    /// The device behind a UID, when the HAL still has it and it is alive.
    private nonisolated static func present(_ uid: String) -> AudioDevice? {
        guard let device = (try? AudioDevice.find(uid: uid)) ?? nil, device.isAlive else { return nil }
        return device
    }

    private func output(_ uid: String) -> OutputSettings { settings.outputs[uid] ?? OutputSettings() }
    private func input(_ uid: String) -> InputSettings { settings.inputs[uid] ?? InputSettings() }

    private func build() {
        guard let feed = openFeed() else { return }
        for item in plan.outputs {
            do {
                outputs.append(
                    try OutputNode(
                        uid: item.uid, device: AudioDevice(id: item.deviceID),
                        settings: output(item.uid), virtualRate: plan.virtualRate, feed: feed))
            } catch {
                log.error("output \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Consumers first, so a producer never writes into a ring nobody drains.
        for output in outputs { try? output.start() }
        outputStatus = Dictionary(
            uniqueKeysWithValues: outputs.map {
                ($0.uid, OutputStatus(isActive: true, sampleRate: $0.sampleRate))
            })
        buildInputs()
    }

    /// Points every output's monitor tap at the planned inputs and starts them, under outputs that
    /// keep playing.
    private func buildInputs() {
        let count = plan.inputs.count
        let block = plan.inputBlockFrames
        for output in outputs { output.tap.configure(inputs: count, producerFrames: block) }
        guard count > 0 else { return }

        if let mic = micDevice {
            micDrain = try? MicDrainNode(device: mic, inputs: count, inputBlockFrames: block)
        }
        for (index, item) in plan.inputs.enumerated() {
            var rings: [RingBuffer] = []
            if let micDrain { rings.append(micDrain.tap.rings[index]) }
            for output in outputs { rings.append(output.tap.rings[index]) }
            do {
                inputs.append(
                    try InputNode(
                        uid: item.uid, device: AudioDevice(id: item.deviceID),
                        settings: input(item.uid), destinations: rings))
            } catch {
                log.error("input \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        try? micDrain?.start()
        for input in inputs { try? input.start() }
    }

    /// Tears the graph down producer first, so nothing writes into a ring that is already gone.
    private func teardown() async {
        await fade(outputs: outputs, inputs: inputs)
        stopInputs()
        for output in outputs { output.stop() }
        outputs = []
        outputStatus = [:]
        pushedEQ = [:]
        playing = []
    }

    private func teardownInputs() async {
        await fade(outputs: [], inputs: inputs)
        stopInputs()
        for output in outputs { output.tap.configure(inputs: 0, producerFrames: 0) }
    }

    private func stopInputs() {
        for input in inputs { input.stop() }
        inputs = []
        micDrain?.stop()
        micDrain = nil
    }

    /// Ramps the given nodes to silence and waits for the ramp to play out, so a proc that stops
    /// does not cut a waveform in the middle.
    private func fade(outputs: [OutputNode], inputs: [InputNode]) async {
        guard !outputs.isEmpty || !inputs.isEmpty else { return }
        for node in outputs { node.masterTarget.value = 0 }
        for node in inputs { node.gainTarget.value = 0 }
        // Two IO cycles at the largest buffer a device runs, plus the gain ramp.
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Parameters

    private func pushParameters() {
        let master = masterMuted ? 0 : Engine.masterLinear(master)
        for node in outputs {
            let settings = output(node.uid)
            node.gainTarget.value = decibelsToLinear(settings.gainDB)
            node.monitorGainTarget.value =
                settings.monitor && !plan.inputs.isEmpty ? decibelsToLinear(settings.monitorGainDB) : 0
            node.masterTarget.value = master
            if settings.eq.count == Equalizer.bandCount, pushedEQ[node.uid] != settings.eq {
                node.eq.setBands(settings.eq)
                pushedEQ[node.uid] = settings.eq
            }
        }
        for node in inputs {
            let settings = input(node.uid)
            node.gainTarget.value = settings.muted ? 0 : decibelsToLinear(settings.gainDB)
        }
        applyDelays()
    }

    /// Sync on delays every output to the slowest one and adds its trim; sync off means no delay.
    private func applyDelays() {
        let sync = settings.sync
        let aligned = sync
            ? alignmentDelays(outputs.map(\.latency))
            : Array(repeating: 0, count: outputs.count)
        for (index, node) in outputs.enumerated() {
            let trim = sync ? output(node.uid).syncTrimMilliseconds : 0
            let frames = max(0, aligned[index] + Int((trim / 1000 * node.sampleRate).rounded()))
            node.delay.setDelay(frames: frames)
            var status = outputStatus[node.uid] ?? OutputStatus()
            status.isActive = true
            status.sampleRate = node.sampleRate
            status.latencyMilliseconds = node.latency.seconds * 1000
            status.delayMilliseconds = node.sampleRate > 0 ? Double(frames) / node.sampleRate * 1000 : 0
            outputStatus[node.uid] = status
        }
    }

    /// Copies what the IO threads counted into the status the UI reads.
    func pollCounters() async {
        for node in outputs {
            outputStatus[node.uid]?.underruns = node.underruns.value
            let frames = node.frames.value
            if frames > 0, playing.insert(node.uid).inserted {
                log.info("output \(node.uid, privacy: .public) is playing, \(frames) frames read")
            }
        }
        await publishStatus()
    }

    /// Hands the status to the model only when it changed, because writing the same value again
    /// still tells every view that reads it to lay out anew.
    private func publishStatus() async {
        let status = outputStatus
        await MainActor.run {
            if model.outputStatus != status { model.outputStatus = status }
        }
    }

    private func publishDriver() async {
        let status = DriverInstaller.status()
        await MainActor.run { model.driver = status }
    }

    private func applyLaunchAtLogin() {
        // Only the shipped app may register itself; a test host must not end up in the login items.
        guard Bundle.main.bundleIdentifier == AppModel.appBundleID else { return }
        let wanted = settings.launchAtLogin
        guard wanted != launchAtLoginApplied else { return }
        launchAtLoginApplied = wanted
        // The service refuses an unregister it never registered, so a setting that already matches
        // the login items is left alone rather than pushed again.
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
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
    nonisolated static func masterLinear(_ scalar: Float) -> Float {
        let clamped = min(max(scalar, 0), 1)
        return clamped * clamped * clamped
    }

    /// Keeps the master gain in step with the virtual device's volume control.
    private func watchVirtualDevice() async {
        guard let device = virtualDevice else { return }
        let master: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute,
        ]
        listeners = await MainActor.run {
            master.compactMap { selector in
                try? AudioObjectPropertyListener(
                    device.id,
                    AudioObjectPropertyAddress(
                        selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard)
                ) { [weak self] _ in
                    Task { await self?.readMaster() }
                }
            }
        }
    }

    private func readMaster() async {
        guard let device = virtualDevice else { return }
        if let scalar = (try? device.volumeScalar(scope: .output)) ?? nil { master = scalar }
        if let muted = (try? device.mute(scope: .output)) ?? nil { masterMuted = muted }
        let (scalar, muted) = (master, masterMuted)
        await MainActor.run {
            model.master = scalar
            model.masterMuted = muted
        }
        pushParameters()
    }
}
