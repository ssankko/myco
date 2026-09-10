import CoreAudio
import Foundation
import MycoDSP
import Observation
import os

/// The actor the engine and its nodes run on, so a device that takes its time to start or stop
/// never holds the main thread.
@globalActor
package actor EngineActor {
    package static let shared = EngineActor()

    static func run<T: Sendable>(_ body: @EngineActor @Sendable () throws -> T) async rethrows -> T {
        try await body()
    }
}

/// The running audio graph.
///
/// Every enabled output has one IO proc, which reads the driver's shared ring directly and pulls it
/// through a resampler, the mic monitor, the EQ, the delay and the gains. Enabled inputs are summed
/// to the mic mix at 48 kHz, which the `Myco Mic` device publishes and every output's monitor
/// tap reads.
///
/// The engine takes a copy of `model.settings` whenever it changes and reconciles the graph against
/// it. Only the outputs whose plan entry changed are stopped and built again, and a change to the
/// virtual rate replaces every one of them; a change to the inputs rebuilds the inputs under the
/// running outputs; gains, EQ bands and delays are pushed into the running DSP objects.
@EngineActor
package final class Engine {
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

        /// The UIDs whose output node `old` already runs and this plan leaves untouched. A
        /// different virtual rate keeps none of them, because every resampler is built against it.
        func keptOutputs(from old: Plan) -> Set<String> {
            guard virtualRate == old.virtualRate else { return [] }
            let previous = Dictionary(uniqueKeysWithValues: old.outputs.map { ($0.uid, $0) })
            return Set(outputs.filter { previous[$0.uid] == $0 }.map(\.uid))
        }
    }

    /// Everything `makePlan` reads out of the settings and the driver. A change that leaves this
    /// alone moves a parameter in the running graph and never queries the HAL.
    private struct PlanInputs: Equatable {
        var virtualRate: Double
        /// Every enabled output and the buffer size it asks for.
        var outputs: [String: UInt32?]
        var inputs: Set<String>
        /// The physical microphones open only while something listens: another process reading
        /// `Myco Mic`, or a monitor on an output that is running. Idle, they stay closed and macOS shows no
        /// microphone indicator for Myco.
        var inputsWanted: Bool
        var fallback: String?

        init(_ settings: Settings, micReaders: Int) {
            virtualRate = settings.virtualRate
            outputs = settings.outputs.filter(\.value.enabled).mapValues(\.bufferFrames)
            inputs = settings.enabledInputs
            fallback = settings.fallbackOutput
            inputsWanted = micReaders > 0 || settings.outputs.values.contains { $0.enabled && $0.monitor }
        }
    }

    private let model: AppModel
    private let managesDefaults: Bool
    private let log = Logger(subsystem: AppModel.appBundleID, category: "engine")
    /// UserDefaults is thread-safe by contract, which the SDK does not spell out.
    private struct DefaultsStore: @unchecked Sendable { let defaults: UserDefaults }
    private let defaultsStore: DefaultsStore
    lazy var defaultDevices = DefaultDevices(store: defaultsStore.defaults)

    private var running = false
    private var settings = Settings()
    private var master: Float = 1
    private var masterMuted = false
    private var plan = Plan()
    /// What the current plan was made from; nil until the first one.
    private var planInputs: PlanInputs?
    /// Processes other than Myco running IO on `Myco Mic`, as the driver counts them.
    private var micReaders = 0
    /// The bands each output last took, so a move of another slider pushes no coefficients.
    private var pushedEQ: [String: [BandSettings]] = [:]
    private var feed: SharedFeed?
    private(set) var outputs: [OutputNode] = []
    private var inputs: [InputNode] = []
    private var micDrain: MicDrainNode?
    private var outputStatus: [String: OutputStatus] = [:]
    private var listeners: [AudioObjectPropertyListener] = []
    /// One per running output with a volume control of its own, keyed by UID.
    private var volumeListeners: [String: AudioObjectPropertyListener] = [:]
    private var eventTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// UIDs already reported as playing, so the log line lands once per graph.
    private var playing: Set<String> = []

    /// `managesDefaults` off leaves the machine's default devices alone, which is what a test that
    /// must not disturb the running system wants.
    package nonisolated init(model: AppModel, managesDefaults: Bool = true, defaultsStore: UserDefaults = .standard) {
        self.model = model
        self.managesDefaults = managesDefaults
        self.defaultsStore = DefaultsStore(defaults: defaultsStore)
    }

    // MARK: Lifecycle

    package func start() async {
        guard !running else { return }
        running = true
        await publishDriver()

        if managesDefaults {
            defaultDevices.capture()
            defaultDevices.pin()
        }
        await watchVirtualDevice()
        await watchMicReaders()
        await readMaster()
        readMicReaders()

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

    package func stop() async {
        guard running else { return }
        running = false
        eventTask?.cancel()
        eventTask = nil
        statusTask?.cancel()
        statusTask = nil
        listeners = []
        volumeListeners = [:]
        await teardownInputs(fading: outputs)
        stopOutputs(outputs)
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
    package func installDriver() async throws {
        defer { Task { await publishDriver() } }
        try await DriverInstaller.install()
    }

    package func uninstallDriver() async throws {
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
                self.observeSettings()
                await self.apply(self.model.settings)
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
        case .serviceRestarted:
            // Every node, listener and event stream points at a dead coreaudiod. The restart runs
            // in its own task because stopping cancels the one delivering this event.
            Task { await stop(); await start() }
        }
    }

    // MARK: Reconciliation

    /// `replan` asks the HAL again for a device that arrived, went away or changed its rate; a
    /// settings change plans anew only when it moves something the plan is made of.
    private func apply(_ wanted: Settings, replan: Bool = false) async {
        guard running else { return }
        settings = wanted
        let inputs = PlanInputs(wanted, micReaders: micReaders)
        if replan || inputs != planInputs {
            planInputs = inputs
            await applyVirtualRate()
            let next = makePlan()
            let kept = next.keptOutputs(from: plan)
            let stopping = outputs.filter { !kept.contains($0.uid) }
            let running = Set(outputs.map(\.uid))
            // A planned UID with no node is a device that is new or one whose node failed to build.
            let building = next.outputs.contains { !running.contains($0.uid) }
            if !stopping.isEmpty || building {
                // The inputs point at the taps of the outputs that existed when they were built, so
                // any change to the set of outputs takes them down and puts them back.
                await rebuilding {
                    await teardownInputs(fading: stopping)
                    stopOutputs(stopping)
                    plan = next
                    buildOutputs()
                    await watchOutputVolumes()
                    buildInputs()
                }
            } else if next.inputs != plan.inputs {
                await rebuilding {
                    await teardownInputs()
                    plan = next
                    buildInputs()
                }
            } else {
                plan = next
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

        var outputUIDs = settings.enabledOutputs
        // With every enabled output unplugged, the stream goes to the fallback instead of nowhere.
        if let fallback = settings.fallbackOutput,
            !outputUIDs.contains(where: { Engine.present($0) != nil }) {
            outputUIDs = [fallback]
        }
        for uid in Engine.ordered(outputUIDs) {
            guard uid != AppModel.outputDeviceUID, let device = Engine.present(uid) else { continue }
            wanted.outputs.append(
                Plan.Output(
                    uid: uid, deviceID: device.id,
                    sampleRate: (try? device.nominalSampleRate) ?? 0,
                    bufferFrames: OutputNode.effectiveBufferFrames(device, output(uid).bufferFrames)))
        }
        // Only an output that really runs can monitor, so an away output with monitoring on
        // opens no microphone.
        let monitoring = wanted.outputs.contains { output($0.uid).monitor }
        guard micReaders > 0 || monitoring else { return wanted }
        for uid in Engine.ordered(settings.enabledInputs) where wanted.inputs.count < MonitorTap.maxInputs {
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

    /// Starts a node for every planned output that has none, and leaves `outputs` in the plan's
    /// order. A node that is already there is not touched.
    private func buildOutputs() {
        guard let feed = openFeed() else { return }
        var nodes = Dictionary(uniqueKeysWithValues: outputs.map { ($0.uid, $0) })
        var started: [OutputNode] = []
        for item in plan.outputs where nodes[item.uid] == nil {
            do {
                let node = try OutputNode(
                    uid: item.uid, device: AudioDevice(id: item.deviceID),
                    settings: output(item.uid), virtualRate: plan.virtualRate, feed: feed)
                nodes[item.uid] = node
                started.append(node)
            } catch {
                log.error("output \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Consumers first, so a producer never writes into a ring nobody drains.
        for node in started { try? node.start() }
        outputs = plan.outputs.compactMap { nodes[$0.uid] }
        for node in started {
            outputStatus[node.uid] = OutputStatus(isActive: true, sampleRate: node.sampleRate)
        }
    }

    /// Stops the given nodes and drops everything the engine holds per UID for them.
    private func stopOutputs(_ stopping: [OutputNode]) {
        let uids = Set(stopping.map(\.uid))
        guard !uids.isEmpty else { return }
        for node in stopping { node.stop() }
        outputs.removeAll { uids.contains($0.uid) }
        volumeListeners = volumeListeners.filter { !uids.contains($0.key) }
        outputStatus = outputStatus.filter { !uids.contains($0.key) }
        pushedEQ = pushedEQ.filter { !uids.contains($0.key) }
        playing.subtract(uids)
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

    /// Fades the inputs together with the outputs about to stop, then takes the inputs down and
    /// empties every tap, so nothing writes into a ring that is about to go.
    private func teardownInputs(fading stopping: [OutputNode] = []) async {
        await fade(outputs: stopping, inputs: inputs)
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
        let softwareMaster = masterMuted ? 0 : Engine.masterLinear(master)
        for node in outputs {
            let settings = output(node.uid)
            node.gainTarget.value = decibelsToLinear(settings.gainDB)
            node.monitorGainTarget.value =
                settings.monitor && !plan.inputs.isEmpty ? decibelsToLinear(settings.monitorGainDB) : 0
            if node.hasVolumeControl {
                setDeviceVolume(node, master)
                node.masterTarget.value = masterMuted ? 0 : 1
            } else {
                node.masterTarget.value = softwareMaster
            }
            let bands = settings.eq(atVolume: Double(master))
            if bands.count == Equalizer.bandCount, pushedEQ[node.uid] != bands {
                node.eq.setBands(bands)
                pushedEQ[node.uid] = bands
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
            let underruns = node.underruns.value
            if underruns != outputStatus[node.uid]?.underruns {
                log.info("output \(node.uid, privacy: .public) underruns \(underruns)")
            }
            outputStatus[node.uid]?.underruns = underruns
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

    /// A device's control moves in steps, an AirPods one in sixteen, so a value that reads back
    /// within this of the master is the master.
    private static let volumeTolerance: Float = 0.005

    /// Writes the master to a device's own control, unless it is already there.
    private func setDeviceVolume(_ node: OutputNode, _ scalar: Float) {
        guard let current = (try? node.device.volumeScalar(scope: .output)) ?? nil,
            abs(current - scalar) > Engine.volumeTolerance
        else { return }
        try? node.device.setVolumeScalar(scalar, scope: .output)
    }

    /// Follows the volume control of every running output that has one, so a level changed on
    /// the device itself, as a swipe on an AirPods stem does, becomes the master.
    private func watchOutputVolumes() async {
        for node in outputs where node.hasVolumeControl && volumeListeners[node.uid] == nil {
            let (id, uid) = (node.device.id, node.uid)
            let listener = await MainActor.run {
                try? AudioObjectPropertyListener(
                    id,
                    AudioObjectPropertyAddress(
                        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                        kAudioObjectPropertyElementWildcard)
                ) { [weak self] _ in
                    Task { await self?.deviceVolumeChanged(uid) }
                }
            }
            volumeListeners[uid] = listener
        }
    }

    /// The master follows the device: the virtual device's control takes the new level, and its
    /// own listener then carries it to the model and to every other output.
    private func deviceVolumeChanged(_ uid: String) {
        guard let node = outputs.first(where: { $0.uid == uid }), let virtual = virtualDevice,
            let scalar = (try? node.device.volumeScalar(scope: .output)) ?? nil,
            abs(scalar - master) > Engine.volumeTolerance
        else { return }
        try? virtual.setVolumeScalar(scalar, scope: .output)
    }

    /// `'mxci'`, the driver's count of clients other than the app running IO on a device.
    private nonisolated static let clientIOSelector = AudioObjectPropertySelector(0x6D78_6369)

    /// Follows the reader count of `Myco Mic`, so the microphones open when an app starts to
    /// listen and close when the last one stops. The HAL hands a client the value it last read
    /// until the driver posts a change, so the count is read only on a change.
    private func watchMicReaders() async {
        guard let device = micDevice else { return }
        let listener = await MainActor.run {
            try? AudioObjectPropertyListener(
                device.id, AudioObjectPropertyAddress(Engine.clientIOSelector)
            ) { [weak self] _ in
                Task { await self?.micReadersChanged() }
            }
        }
        if let listener { listeners.append(listener) }
    }

    private func micReadersChanged() async {
        readMicReaders()
        log.info("mic readers \(self.micReaders)")
        await apply(settings)
    }

    /// A driver without the property, one older than this app, keeps the microphones open.
    private func readMicReaders() {
        guard let device = micDevice else { return }
        micReaders = Int((try? device.id.string(AudioObjectPropertyAddress(Engine.clientIOSelector))) ?? "") ?? 1
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
