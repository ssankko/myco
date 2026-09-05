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
            var bufferFrames: UInt32?
            var monitor: Bool
        }

        struct Input: Equatable {
            var uid: String
            var deviceID: AudioDeviceID
            var sampleRate: Double
        }

        var virtualRate: Double = 0
        var feedFrames: Int = 0
        var outputs: [Output] = []
        var inputs: [Input] = []
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
        var wanted = Plan(
            virtualRate: model.settings.virtualRate,
            feedFrames: Int((try? virtual.bufferFrameSize) ?? 512))

        for device in model.devices.outputs {
            guard let uid = try? device.uid, uid != AppModel.outputDeviceUID, device.isAlive else { continue }
            let settings = model.output(uid)
            guard settings.enabled else { continue }
            wanted.outputs.append(
                Plan.Output(
                    uid: uid, deviceID: device.id,
                    sampleRate: (try? device.nominalSampleRate) ?? 0,
                    bufferFrames: settings.bufferFrames, monitor: settings.monitor))
        }
        for device in model.devices.inputs {
            guard let uid = try? device.uid, uid != AppModel.micDeviceUID,
                uid != AppModel.outputDeviceUID, device.isAlive, model.input(uid).enabled
            else { continue }
            wanted.inputs.append(
                Plan.Input(
                    uid: uid, deviceID: device.id, sampleRate: (try? device.nominalSampleRate) ?? 0))
        }
        return wanted
    }

    private func build() {
        guard let virtual = virtualDevice else { return }

        for item in plan.outputs {
            do {
                outputs.append(
                    try OutputNode(
                        uid: item.uid, device: AudioDevice(id: item.deviceID),
                        settings: model.output(item.uid), virtualRate: plan.virtualRate,
                        feedBlockFrames: plan.feedFrames, inputs: plan.inputs.count))
            } catch {
                log.error("output \(item.uid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if !plan.inputs.isEmpty, let mic = micDevice {
            micDrain = try? MicDrainNode(device: mic, inputs: plan.inputs.count)
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

    private func pollCounters() {
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

    /// Keeps the master gain and the feed's block size in step with the virtual device.
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
        let sizes = try? AudioObjectPropertyListener(
            device.id, AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSize),
            handler: { [weak self] _ in self?.apply() })
        if let sizes { listeners.append(sizes) }
    }

    private func readMaster() {
        guard let device = virtualDevice else { return }
        if let scalar = (try? device.volumeScalar(scope: .output)) ?? nil { model.master = scalar }
        if let muted = (try? device.mute(scope: .output)) ?? nil { model.masterMuted = muted }
        pushParameters()
    }
}
