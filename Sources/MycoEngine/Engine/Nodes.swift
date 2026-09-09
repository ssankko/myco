import Accelerate
import CoreAudio
import Foundation
import MycoDSP

/// The rate the mic mix runs at, fixed by the `Myco Mic` device.
let micMixRate: Double = 48000

/// Weight of one block in the running average of a ring's fill, which spans about a second.
private let fillSmoothing = 0.002

/// Follows a producer's clock through the fill level of what it writes, and yields the resample
/// ratio that holds that fill at its target.
///
/// The producer writes a whole block at a time, so the fill jumps by that block at every write and
/// the ratio follows its running average; the instantaneous fill would swing the pitch every cycle.
struct ClockFollower {
    var drift: DriftController
    /// The running average the ratio is taken from.
    private(set) var fill: Double

    init(targetFillFrames: Double, gain: Double = 1e-4) {
        drift = DriftController(targetFillFrames: targetFillFrames, gain: gain)
        fill = targetFillFrames
    }

    /// Aims at a reader that starts `target` frames behind a producer writing `producerBlock` at a
    /// time. The fill sweeps a whole block between two writes, so its average sits half a block
    /// below where the reader starts, and aiming there leaves the ratio at rest.
    mutating func aim(target: Double, producerBlock: Double) {
        drift.targetFillFrames = max(0, target - producerBlock / 2)
        fill = drift.targetFillFrames
    }

    /// Drops the average and starts it at the target, for a reader that took a fresh position.
    mutating func restart() { fill = drift.targetFillFrames }

    /// The ratio for this cycle: `base` nudged by how far the average fill sits from the target.
    mutating func ratio(base: Double, fill sample: Double) -> Double {
        fill += fillSmoothing * (sample - fill)
        return base * drift.ratioMultiplier(fillFrames: fill)
    }
}

/// Throws away whatever a ring holds above `level` and answers what is left. Audio thread only:
/// only the reader may drop frames.
@inline(__always)
func drop(
    _ ring: RingBuffer, above level: Int, through scratch: UnsafeMutablePointer<Float>, capacity: Int
) -> Int {
    var fill = ring.fillLevel
    while fill > level {
        let taken = ring.read(into: scratch, frames: min(fill - level, capacity))
        guard taken > 0 else { break }
        fill -= taken
    }
    return fill
}

/// The mic mix as one consumer sees it: one block from every enabled input's ring, summed and
/// resampled to the consumer's rate.
///
/// Each input writes its own ring here, so every ring has one writer and one reader. The fill is
/// held near one consumer block, which is the shortest the monitor path can run without gaps. The
/// set of inputs changes while the consumer runs: `configure` publishes the new count and the
/// render drains every ring and primes again when it sees it.
struct MonitorTap: @unchecked Sendable {
    /// Rings every tap carries, so an input can come and go without rebuilding the consumer.
    static let maxInputs = 8

    struct State {
        var resampler: Resampler
        var follower: ClockFollower
        var primed: Bool
        var inputs: Int
        var primeLevel: Double
    }

    /// `maxInputs` rings, of which the first `configure`d count are live.
    let rings: UnsafeMutableBufferPointer<RingBuffer>

    private let baseRatio: Double
    private let pull: Double
    private let capacity: Int
    private let summed: UnsafeMutablePointer<Float>
    private let part: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<State>
    private let wantedInputs: AtomicCounter
    private let wantedPrimeLevel: AtomicFloat

    /// `rate` and `frames` describe the consumer's IO cycle.
    init(rate: Double, frames: Int) {
        baseRatio = micMixRate / rate
        let resampler = Resampler(
            channels: 1, ratio: baseRatio, maxDownsampleFactor: max(1, (baseRatio * 1.01).rounded(.up)))
        capacity = Int((Double(frames) * baseRatio * 1.01).rounded(.up)) + 2 * resampler.tapsPerSide + 8
        pull = Double(frames) * baseRatio + Double(resampler.tapsPerSide) + 1

        rings = .allocate(capacity: MonitorTap.maxInputs)
        // Room for the largest input block the HAL hands over, twice, on top of the priming level.
        let ringFrames = nextPowerOfTwo(max(3 * 4096 + capacity, 2048))
        for index in 0..<MonitorTap.maxInputs {
            rings[index] = RingBuffer(capacityFrames: ringFrames, channels: 1)
        }
        summed = .allocate(capacity: capacity)
        summed.initialize(repeating: 0, count: capacity)
        part = .allocate(capacity: capacity)
        part.initialize(repeating: 0, count: capacity)
        state = .allocate(capacity: 1)
        state.initialize(
            to: State(
                resampler: resampler, follower: ClockFollower(targetFillFrames: 0), primed: false,
                inputs: 0, primeLevel: 0))
        wantedInputs = AtomicCounter()
        wantedPrimeLevel = AtomicFloat(0)
    }

    func deallocate() {
        for ring in rings { ring.deallocate() }
        rings.deallocate()
        state.pointee.resampler.deallocate()
        state.deallocate()
        summed.deallocate()
        part.deallocate()
        wantedInputs.deallocate()
        wantedPrimeLevel.deallocate()
    }

    /// Control thread: the first `inputs` rings are live, and `producerFrames` is the largest block
    /// an input writes at once, in mic mix frames.
    func configure(inputs: Int, producerFrames: Int) {
        // An input arrives one whole block at a time, so the ring waits for that much plus two pulls
        // before it plays; anything less runs dry at the end of every input cycle.
        wantedPrimeLevel.value = Float(Double(producerFrames) + 2 * pull)
        wantedInputs.set(min(inputs, MonitorTap.maxInputs))
    }

    /// Throws away everything the rings hold and primes again on the next render. Audio thread
    /// only; a consumer that does not want the mix still calls this so the rings never fill up.
    func discard() {
        for ring in rings { _ = drop(ring, above: 0, through: part, capacity: capacity) }
        state.pointee.primed = false
    }

    /// Writes `frames` mono frames at the consumer's rate. False means the mix has not filled yet
    /// and the caller should stay silent. Audio thread only.
    func render(into destination: UnsafeMutablePointer<Float>, frames count: Int) -> Bool {
        guard count > 0 else { return false }
        let inputs = wantedInputs.value
        if inputs != state.pointee.inputs {
            discard()
            state.pointee.inputs = inputs
            state.pointee.primeLevel = Double(wantedPrimeLevel.value)
            state.pointee.follower.aim(
                target: state.pointee.primeLevel,
                producerBlock: state.pointee.primeLevel - 2 * pull)
        }
        guard inputs > 0 else { return false }
        let live = rings.prefix(inputs)
        let primeLevel = state.pointee.primeLevel

        var fill = Int.max
        for ring in live { fill = min(fill, ring.fillLevel) }
        if !state.pointee.primed {
            guard Double(fill) >= primeLevel else { return false }
            state.pointee.primed = true
            fill = Int.max
            for ring in live {
                fill = min(fill, drop(ring, above: Int(primeLevel), through: part, capacity: capacity))
            }
            state.pointee.follower.restart()
        }

        state.pointee.resampler.ratio =
            state.pointee.follower.ratio(base: baseRatio, fill: Double(fill))
        let need = min(state.pointee.resampler.inputFramesNeeded(forOutput: count), capacity)
        var short = false
        var first = true
        for ring in live {
            if first {
                short = ring.read(into: summed, frames: need) < need
                first = false
            } else {
                if ring.read(into: part, frames: need) < need { short = true }
                vDSP_vadd(summed, 1, part, 1, summed, 1, vDSP_Length(need))
            }
        }
        if short && fill == 0 { state.pointee.primed = false }

        let produced = state.pointee.resampler
            .process(input: summed, frames: need, output: destination, capacity: count).produced
        if produced < count {
            destination.advanced(by: produced).update(repeating: 0, count: count - produced)
        }
        return true
    }
}

/// One output's IO cycle: its place in the driver's shared ring, the chain it pulls the ring
/// through and the handles the control thread pushes parameters into.
///
/// All state lives in allocations this value owns, so a copy of it is another handle: the IO proc
/// keeps one and the node keeps one. Call `deallocate()` once the proc has gone.
struct OutputRender: @unchecked Sendable {
    struct State {
        var resampler: Resampler
        var reader: FeedReader
        var follower: ClockFollower
        var gain: SmoothedGain
        var monitorGain: SmoothedGain
        var master: SmoothedGain
    }

    let tap: MonitorTap
    let eq: Equalizer
    let delay: DelayLine

    let gainTarget = AtomicFloat(1)
    /// Zero while the monitor is off; the ramp to and from it is what keeps a toggle silent.
    let monitorGainTarget = AtomicFloat(0)
    let masterTarget = AtomicFloat(1)
    let underruns = AtomicCounter()
    /// Frames taken from the shared ring since the proc started.
    let frames = AtomicCounter()
    /// What the reader holds in the shared ring, in the device's frames, which is part of the
    /// latency the output reports.
    let ringFill: Int

    private let feed: SharedFeed
    private let baseRatio: Double
    private let bufferFrames: Int
    /// Frames of the shared ring one IO cycle can ask for.
    private let pull: Int
    private let feedScratch: UnsafeMutablePointer<Float>
    private let mix: UnsafeMutablePointer<Float>
    private let monitor: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<State>

    /// Pulls of margin an underrun can earn in total. A Bluetooth output starts with all of them:
    /// its link already holds a hundred milliseconds or more, so the margin costs nothing audible,
    /// and it spares the clicks a jittery writer would otherwise pay to earn it.
    static let maxSlackPulls = 8

    init(
        feed: SharedFeed, virtualRate: Double, sampleRate: Double, bufferFrames: Int, gainDB: Float,
        wideMargin: Bool = false
    ) {
        self.feed = feed
        self.bufferFrames = bufferFrames
        baseRatio = virtualRate / sampleRate
        let resampler = Resampler(
            channels: 2, ratio: baseRatio, maxDownsampleFactor: max(1, (baseRatio * 1.01).rounded(.up)))
        // One IO cycle of this output, in the ring's frames, plus what the resampler needs around it.
        pull =
            Int((Double(bufferFrames) * baseRatio * 1.01).rounded(.up)) + 2 * resampler.tapsPerSide + 8
        let slack = wideMargin ? OutputRender.maxSlackPulls * pull : 0
        // The drift gain is a tenth of the default because the averaged fill still wanders tens of
        // frames, and this keeps that wander under a tenth of a per cent of pitch instead of an
        // audible slow wow. The target itself follows the driver's block at every resync.
        let follower = ClockFollower(
            targetFillFrames: Double(
                FeedReader.targetFill(writeBlock: feed.writeBlockFrames, pull: pull) + slack),
            gain: 1e-5)
        ringFill = Int((follower.drift.targetFillFrames / baseRatio).rounded())

        eq = Equalizer(sampleRate: sampleRate, channels: 2)
        delay = DelayLine(
            maxDelayFrames: max(1024, Int(sampleRate / 2)), channels: 2, crossfadeFrames: 256)
        tap = MonitorTap(rate: sampleRate, frames: bufferFrames)

        feedScratch = .allocate(capacity: pull * 2)
        feedScratch.initialize(repeating: 0, count: pull * 2)
        mix = .allocate(capacity: bufferFrames * 2)
        mix.initialize(repeating: 0, count: bufferFrames * 2)
        monitor = .allocate(capacity: bufferFrames)
        monitor.initialize(repeating: 0, count: bufferFrames)
        state = .allocate(capacity: 1)
        state.initialize(
            to: State(
                resampler: resampler,
                reader: FeedReader(slack: slack),
                follower: follower,
                gain: SmoothedGain(sampleRate: sampleRate, decibels: gainDB),
                monitorGain: SmoothedGain(sampleRate: sampleRate, decibels: silenceDecibels),
                // Silent at first, so a proc that starts mid-waveform ramps in instead of clicking.
                master: SmoothedGain(sampleRate: sampleRate, decibels: silenceDecibels)))
    }

    func deallocate() {
        tap.deallocate()
        state.pointee.resampler.deallocate()
        state.deallocate()
        eq.deallocate()
        delay.deallocate()
        feedScratch.deallocate()
        mix.deallocate()
        monitor.deallocate()
        gainTarget.deallocate()
        monitorGainTarget.deallocate()
        masterTarget.deallocate()
        underruns.deallocate()
        frames.deallocate()
    }

    /// Fills one IO cycle of the device. Audio thread only.
    func render(into output: UnsafeMutableAudioBufferListPointer) {
        let count = min(bufferListFrames(output), bufferFrames)
        guard count > 0 else { return }
        var playing = pullFeed(count)
        if mixMonitor(count) { playing = true }
        guard playing else {
            silence(output)
            return
        }

        eq.process(mix, frames: count)
        delay.process(mix, frames: count)
        state.pointee.gain.setTarget(linear: gainTarget.value)
        state.pointee.gain.apply(mix, frames: count, channels: 2)
        state.pointee.master.setTarget(linear: masterTarget.value)
        state.pointee.master.apply(mix, frames: count, channels: 2)
        scatterStereo(mix, frames: count, into: output)
    }

    /// Resamples what the shared ring holds into the mix. False leaves the mix silent: nothing
    /// plays into the virtual device, and only the mic monitor can still come through.
    private func pullFeed(_ count: Int) -> Bool {
        // The write position is read first: the block that published it is already there, while
        // the other order can pair a fresh position with the block before it.
        let write = feed.writeFrame
        let writeBlock = feed.writeBlockFrames
        let target = FeedReader.targetFill(writeBlock: writeBlock, pull: pull)
        guard
            let step = state.pointee.reader.step(
                write: write, generation: feed.generation, target: target)
        else {
            mix.update(repeating: 0, count: count * 2)
            return false
        }
        if step.resynced {
            state.pointee.follower.aim(target: Double(step.fill), producerBlock: Double(writeBlock))
        }

        state.pointee.resampler.ratio =
            state.pointee.follower.ratio(base: baseRatio, fill: Double(step.fill))
        let need = min(state.pointee.resampler.inputFramesNeeded(forOutput: count), pull)
        let taken = min(need, step.fill)
        feed.read(from: state.pointee.reader.readFrame, into: feedScratch, frames: taken)
        if taken < need {
            underruns.add(1)
            state.pointee.reader.widen(by: pull, upTo: OutputRender.maxSlackPulls * pull)
            feedScratch.advanced(by: taken * 2).update(repeating: 0, count: (need - taken) * 2)
        }
        state.pointee.reader.advance(taken)
        frames.add(taken)
        let produced = state.pointee.resampler
            .process(input: feedScratch, frames: need, output: mix, capacity: count).produced
        if produced < count {
            mix.advanced(by: produced * 2).update(repeating: 0, count: (count - produced) * 2)
        }
        return true
    }

    /// Sums the mic monitor into the mix. The tap is drained every cycle, so its rings never fill
    /// up while the music pauses or the monitor is off.
    private func mixMonitor(_ count: Int) -> Bool {
        state.pointee.monitorGain.setTarget(linear: monitorGainTarget.value)
        if state.pointee.monitorGain.target == 0 && state.pointee.monitorGain.current == 0 {
            tap.discard()
            return false
        }
        guard tap.render(into: monitor, frames: count) else { return false }
        state.pointee.monitorGain.apply(monitor, frames: count, channels: 1)
        vDSP_vadd(mix, 2, monitor, 1, mix, 2, vDSP_Length(count))
        vDSP_vadd(mix + 1, 2, monitor, 1, mix + 1, 2, vDSP_Length(count))
        return true
    }
}

/// One enabled physical output: the device, what it measures, and the IO proc that renders into it.
@EngineActor
package final class OutputNode {
    let uid: String
    let device: AudioDevice
    let sampleRate: Double
    let bufferFrames: Int
    let latency: OutputLatency
    let render: OutputRender
    /// True when the device has a volume control of its own, which then carries the master level.
    let hasVolumeControl: Bool

    var tap: MonitorTap { render.tap }
    var eq: Equalizer { render.eq }
    var delay: DelayLine { render.delay }
    var gainTarget: AtomicFloat { render.gainTarget }
    var monitorGainTarget: AtomicFloat { render.monitorGainTarget }
    var masterTarget: AtomicFloat { render.masterTarget }
    var underruns: AtomicCounter { render.underruns }
    /// Frames taken from the shared ring since the proc started.
    var frames: AtomicCounter { render.frames }
    /// The tap's rings, for a test that watches them drain.
    nonisolated var tapRings: UnsafeMutableBufferPointer<RingBuffer> { render.tap.rings }

    private var proc: IOProc?

    init(
        uid: String, device: AudioDevice, settings: OutputSettings, virtualRate: Double,
        feed: SharedFeed
    ) throws {
        self.uid = uid
        self.device = device
        sampleRate = try device.nominalSampleRate

        let wanted = OutputNode.effectiveBufferFrames(device, settings.bufferFrames)
        try? device.setBufferFrameSize(wanted)
        bufferFrames = Int((try? device.bufferFrameSize) ?? wanted)
        hasVolumeControl = ((try? device.volumeScalar(scope: .output)) ?? nil) != nil

        let render = OutputRender(
            feed: feed, virtualRate: virtualRate, sampleRate: sampleRate,
            bufferFrames: bufferFrames, gainDB: settings.gainDB,
            wideMargin: OutputNode.isBluetooth(device.transportType))
        self.render = render
        latency = OutputLatency(
            deviceLatency: Int((try? device.latency(scope: .output)) ?? 0),
            safetyOffset: Int((try? device.safetyOffset(scope: .output)) ?? 0),
            streamLatency: Int((try? device.streamLatency(scope: .output)) ?? 0),
            bufferSize: bufferFrames,
            ringFill: render.ringFill,
            sampleRate: sampleRate)

        // Input usage off: a device with a microphone of its own, AirPods say, must not have it
        // opened by an output, which would light the indicator and drop Bluetooth to the headset codec.
        proc = try IOProc(device: device, usesInput: false) { _, _, _, output, _ in
            guard let output else { return }
            render.render(into: output)
        }
    }

    nonisolated static func isBluetooth(_ transport: AudioDevice.TransportType) -> Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }

    /// 256 frames for Bluetooth, which cannot keep up with less, and 128 for everything else.
    package nonisolated static func defaultBufferFrames(_ transport: AudioDevice.TransportType) -> UInt32 {
        isBluetooth(transport) ? 256 : 128
    }

    /// The size the device runs at once this node has it: the setting or the transport default,
    /// clamped to what the device accepts. The plan carries it, so it is answered before the node
    /// exists.
    static func effectiveBufferFrames(_ device: AudioDevice, _ wanted: UInt32?) -> UInt32 {
        let frames = wanted ?? defaultBufferFrames(device.transportType)
        guard let range = try? device.bufferFrameSizeRange else { return frames }
        return min(max(frames, range.lowerBound), range.upperBound)
    }

    func start() throws { try proc?.start() }

    func stop() {
        proc = nil
        render.deallocate()
    }
}

/// One enabled physical input: mono-summed, gained, resampled to the mic mix rate and written into
/// one ring per consumer.
@EngineActor
final class InputNode {
    struct State {
        var resampler: Resampler
        var gain: SmoothedGain
    }

    let uid: String
    let device: AudioDevice
    let gainTarget = AtomicFloat(1)

    private let destinations: UnsafeMutableBufferPointer<RingBuffer>
    private let mono: UnsafeMutablePointer<Float>
    private let resampled: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<State>
    private var proc: IOProc?

    init(uid: String, device: AudioDevice, settings: InputSettings, destinations rings: [RingBuffer]) throws {
        self.uid = uid
        self.device = device
        let rate = try device.nominalSampleRate
        // The HAL may hand a larger block than the device reports, so the scratch carries headroom.
        let blockFrames = 2 * max(Int((try? device.bufferFrameSize) ?? 512), 512)
        let ratio = rate / micMixRate
        let resampler = Resampler(
            channels: 1, ratio: ratio, maxDownsampleFactor: max(1, (ratio * 1.01).rounded(.up)))
        let outCapacity = Int((Double(blockFrames) / ratio * 1.01).rounded(.up)) + 8

        destinations = .allocate(capacity: rings.count)
        for (index, ring) in rings.enumerated() { destinations[index] = ring }
        mono = .allocate(capacity: blockFrames)
        mono.initialize(repeating: 0, count: blockFrames)
        resampled = .allocate(capacity: outCapacity)
        resampled.initialize(repeating: 0, count: outCapacity)
        state = .allocate(capacity: 1)
        state.initialize(
            to: State(
                resampler: resampler,
                gain: SmoothedGain(sampleRate: rate, decibels: silenceDecibels)))

        nonisolated(unsafe) let destinationsCopy = destinations
        nonisolated(unsafe) let mono = self.mono
        nonisolated(unsafe) let resampled = self.resampled
        nonisolated(unsafe) let state = self.state
        let gainTarget = self.gainTarget

        proc = try IOProc(device: device) { _, input, _, _, _ in
            guard let input else { return }
            let count = min(bufferListFrames(input), blockFrames)
            guard count > 0 else { return }
            mixToMono(input, frames: count, into: mono)
            state.pointee.gain.setTarget(linear: gainTarget.value)
            state.pointee.gain.apply(mono, frames: count, channels: 1)
            let produced = state.pointee.resampler
                .process(input: mono, frames: count, output: resampled, capacity: outCapacity).produced
            for ring in destinationsCopy { ring.write(resampled, frames: produced) }
        }
    }

    func start() throws { try proc?.start() }

    func stop() {
        proc = nil
        destinations.deallocate()
        state.pointee.resampler.deallocate()
        state.deallocate()
        mono.deallocate()
        resampled.deallocate()
        gainTarget.deallocate()
    }
}

/// Writes the mic mix into the `Myco Mic` device, which is where other apps read it.
@EngineActor
final class MicDrainNode {
    let tap: MonitorTap

    private let mono: UnsafeMutablePointer<Float>
    private let blockFrames: Int
    private var proc: IOProc?

    init(device: AudioDevice, inputs: Int, inputBlockFrames: Int) throws {
        let cycleFrames = Int((try? device.bufferFrameSize) ?? 512)
        blockFrames = 2 * max(cycleFrames, 512)
        tap = MonitorTap(rate: micMixRate, frames: cycleFrames)
        tap.configure(inputs: inputs, producerFrames: inputBlockFrames)
        mono = .allocate(capacity: blockFrames)
        mono.initialize(repeating: 0, count: blockFrames)

        let tapCopy = tap
        nonisolated(unsafe) let mono = self.mono
        let blockFrames = self.blockFrames
        proc = try IOProc(device: device, usesInput: false) { _, _, _, output, _ in
            guard let output else { return }
            let count = min(bufferListFrames(output), blockFrames)
            guard count > 0 else { return }
            guard tapCopy.render(into: mono, frames: count) else {
                silence(output)
                return
            }
            scatterMono(mono, frames: count, into: output)
        }
    }

    func start() throws { try proc?.start() }

    func stop() {
        proc = nil
        tap.deallocate()
        mono.deallocate()
    }
}
