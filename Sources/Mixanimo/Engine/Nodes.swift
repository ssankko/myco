import Accelerate
import CoreAudio
import Foundation

/// The rate the mic mix runs at, fixed by the `Mixanimo Mic` device.
let micMixRate: Double = 48000

/// Weight of one block in the running average of a ring's fill, which spans about a second.
let fillSmoothing = 0.002

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
/// held near one consumer block, which is the shortest the monitor path can run without gaps.
struct MonitorTap: @unchecked Sendable {
    struct State {
        var resampler: Resampler
        var fill: Double
        var primed: Bool
    }

    /// One ring per enabled input, in the engine's input order.
    let rings: UnsafeMutableBufferPointer<RingBuffer>

    private let drift: DriftController
    private let baseRatio: Double
    private let primeLevel: Double
    private let capacity: Int
    private let summed: UnsafeMutablePointer<Float>
    private let part: UnsafeMutablePointer<Float>
    private let state: UnsafeMutablePointer<State>

    /// `rate` and `frames` describe the consumer's IO cycle.
    init(inputs: Int, rate: Double, frames: Int) {
        baseRatio = micMixRate / rate
        let resampler = Resampler(
            channels: 1, ratio: baseRatio, maxDownsampleFactor: max(1, (baseRatio * 1.01).rounded(.up)))
        capacity = Int((Double(frames) * baseRatio * 1.01).rounded(.up)) + 2 * resampler.tapsPerSide + 8
        // One pull, plus a second one of margin and room for one input block, is the shortest the
        // monitor can run without gaps; the fill sweeps down half a block between input writes, so
        // the average sits there.
        let pull = Double(frames) * baseRatio + Double(resampler.tapsPerSide) + 1
        primeLevel = 2 * pull + 256
        drift = DriftController(targetFillFrames: primeLevel - 128)

        rings = .allocate(capacity: inputs)
        let ringFrames = nextPowerOfTwo(max(4 * (Int(primeLevel) + capacity), 2048))
        for index in 0..<inputs {
            rings[index] = RingBuffer(capacityFrames: ringFrames, channels: 1)
        }
        summed = .allocate(capacity: capacity)
        summed.initialize(repeating: 0, count: capacity)
        part = .allocate(capacity: capacity)
        part.initialize(repeating: 0, count: capacity)
        state = .allocate(capacity: 1)
        state.initialize(to: State(resampler: resampler, fill: drift.targetFillFrames, primed: false))
    }

    func deallocate() {
        for ring in rings { ring.deallocate() }
        rings.deallocate()
        state.pointee.resampler.deallocate()
        state.deallocate()
        summed.deallocate()
        part.deallocate()
    }

    /// Writes `frames` mono frames at the consumer's rate. False means the mix has not filled yet
    /// and the caller should stay silent. Audio thread only.
    func render(into destination: UnsafeMutablePointer<Float>, frames count: Int) -> Bool {
        guard rings.count > 0, count > 0 else { return false }
        var fill = Int.max
        for ring in rings { fill = min(fill, ring.fillLevel) }
        if !state.pointee.primed {
            guard Double(fill) >= primeLevel else { return false }
            state.pointee.primed = true
            fill = Int.max
            for ring in rings {
                fill = min(fill, drop(ring, above: Int(primeLevel), through: part, capacity: capacity))
            }
            state.pointee.fill = drift.targetFillFrames
        }

        // The fill jumps by a whole producer block every cycle; the ratio follows its average, so
        // the correction tracks the clock difference instead of the block pattern.
        state.pointee.fill += fillSmoothing * (Double(fill) - state.pointee.fill)
        state.pointee.resampler.ratio = baseRatio * drift.ratioMultiplier(fillFrames: state.pointee.fill)
        let need = min(state.pointee.resampler.inputFramesNeeded(forOutput: count), capacity)
        var short = false
        var first = true
        for ring in rings {
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

/// The one read of the `Mixanimo` device's input stream, copied into every enabled output's ring.
@MainActor
final class FeedNode {
    /// Frames read from the virtual device since the proc started.
    let frames = AtomicCounter()

    private let rings: UnsafeMutableBufferPointer<RingBuffer>
    private let scratch: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var proc: IOProc?

    init(device: AudioDevice, rings destinations: [RingBuffer]) throws {
        capacity = 8192
        rings = .allocate(capacity: destinations.count)
        for (index, ring) in destinations.enumerated() { rings[index] = ring }
        scratch = .allocate(capacity: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)

        nonisolated(unsafe) let rings = self.rings
        nonisolated(unsafe) let scratch = self.scratch
        let capacity = self.capacity
        let counter = frames
        proc = try IOProc(device: device) { _, input, _, _, _ in
            guard let input else { return }
            let count = min(bufferListFrames(input), capacity)
            guard count > 0 else { return }
            mixToStereo(input, frames: count, into: scratch)
            for ring in rings { ring.write(scratch, frames: count) }
            counter.add(count)
        }
    }

    func start() throws { try proc?.start() }

    /// Destroys the proc first, so no callback can be in flight while the buffers go away.
    func stop() {
        proc = nil
        rings.deallocate()
        scratch.deallocate()
        frames.deallocate()
    }
}

/// One enabled physical output: the ring the feed writes, the chain its IO callback runs and the
/// handles the control thread pushes parameters through.
@MainActor
final class OutputNode {
    struct State {
        var resampler: Resampler
        var fill: Double
        var gain: SmoothedGain
        var monitorGain: SmoothedGain
        var master: SmoothedGain
        var primed: Bool
    }

    let uid: String
    let device: AudioDevice
    let sampleRate: Double
    let bufferFrames: Int
    let latency: OutputLatency
    /// Written by the feed at the virtual rate.
    let ring: RingBuffer
    let eq: Equalizer
    let delay: DelayLine
    let tap: MonitorTap?

    let gainTarget = AtomicFloat(1)
    let monitorGainTarget = AtomicFloat(1)
    let masterTarget = AtomicFloat(1)
    let underruns = AtomicCounter()

    private let state: UnsafeMutablePointer<State>
    private let feedScratch: UnsafeMutablePointer<Float>
    private let mix: UnsafeMutablePointer<Float>
    private let monitor: UnsafeMutablePointer<Float>
    private var proc: IOProc?

    init(
        uid: String, device: AudioDevice, settings: OutputSettings, virtualRate: Double,
        feedBlockFrames: Int, inputs: Int
    ) throws {
        self.uid = uid
        self.device = device
        sampleRate = try device.nominalSampleRate

        let wanted = settings.bufferFrames ?? OutputNode.defaultBufferFrames(device.transportType)
        if let range = try? device.bufferFrameSizeRange {
            try? device.setBufferFrameSize(min(max(wanted, range.lowerBound), range.upperBound))
        }
        bufferFrames = Int((try? device.bufferFrameSize) ?? wanted)
        latency = OutputLatency(
            deviceLatency: Int((try? device.latency(scope: .output)) ?? 0),
            safetyOffset: Int((try? device.safetyOffset(scope: .output)) ?? 0),
            streamLatency: Int((try? device.streamLatency(scope: .output)) ?? 0),
            bufferSize: bufferFrames,
            sampleRate: sampleRate)

        let baseRatio = virtualRate / sampleRate
        let resampler = Resampler(
            channels: 2, ratio: baseRatio, maxDownsampleFactor: max(1, (baseRatio * 1.01).rounded(.up)))
        let feedCapacity =
            Int((Double(bufferFrames) * baseRatio * 1.01).rounded(.up)) + 2 * resampler.tapsPerSide + 8
        // The feed arrives one whole feed block at a time, so the ring waits for that much plus two
        // output blocks before it plays; anything less runs dry at the end of every feed cycle.
        let primeFrames = Double(feedBlockFrames) + 2 * Double(feedCapacity)
        // Between two feed cycles the fill sweeps a whole feed block, so its average sits half a
        // block below the level that started it; aiming there leaves the ratio at rest. The gain is
        // a tenth of the default because the averaged fill still wanders tens of frames, and this
        // keeps that wander under a tenth of a per cent of pitch instead of an audible slow wow.
        let drift = DriftController(
            targetFillFrames: primeFrames - Double(feedBlockFrames) / 2, gain: 1e-5)
        ring = RingBuffer(
            capacityFrames: nextPowerOfTwo(max(4 * (Int(primeFrames) + feedCapacity), 4096)),
            channels: 2)
        eq = Equalizer(sampleRate: sampleRate, channels: 2)
        delay = DelayLine(
            maxDelayFrames: max(1024, Int(sampleRate / 2)), channels: 2, crossfadeFrames: 256)
        tap = (settings.monitor && inputs > 0)
            ? MonitorTap(inputs: inputs, rate: sampleRate, frames: bufferFrames) : nil

        feedScratch = .allocate(capacity: feedCapacity * 2)
        feedScratch.initialize(repeating: 0, count: feedCapacity * 2)
        mix = .allocate(capacity: bufferFrames * 2)
        mix.initialize(repeating: 0, count: bufferFrames * 2)
        monitor = .allocate(capacity: bufferFrames)
        monitor.initialize(repeating: 0, count: bufferFrames)
        state = .allocate(capacity: 1)
        state.initialize(
            to: State(
                resampler: resampler,
                fill: drift.targetFillFrames,
                gain: SmoothedGain(sampleRate: sampleRate, decibels: settings.gainDB),
                monitorGain: SmoothedGain(sampleRate: sampleRate, decibels: settings.monitorGainDB),
                master: SmoothedGain(sampleRate: sampleRate),
                primed: false))

        nonisolated(unsafe) let state = self.state
        nonisolated(unsafe) let feedScratch = self.feedScratch
        nonisolated(unsafe) let mix = self.mix
        nonisolated(unsafe) let monitor = self.monitor
        let ring = self.ring
        let eq = self.eq
        let delay = self.delay
        let tap = self.tap
        let underruns = self.underruns
        let gainTarget = self.gainTarget
        let monitorGainTarget = self.monitorGainTarget
        let masterTarget = self.masterTarget
        let bufferFrames = self.bufferFrames

        proc = try IOProc(device: device) { _, _, _, output, _ in
            guard let output else { return }
            let count = min(bufferListFrames(output), bufferFrames)
            guard count > 0 else { return }

            var fill = ring.fillLevel
            if !state.pointee.primed {
                guard Double(fill) >= primeFrames else {
                    silence(output)
                    return
                }
                state.pointee.primed = true
                // Starting at the priming level and not above it leaves the drift correction with
                // nothing to walk back, so the pitch is right from the first block.
                fill = drop(ring, above: Int(primeFrames), through: feedScratch, capacity: feedCapacity)
                state.pointee.fill = drift.targetFillFrames
            }

            // The feed arrives a block at a time, so the ratio follows the average fill; the
            // instantaneous one would swing the pitch by the whole block every cycle.
            state.pointee.fill += fillSmoothing * (Double(fill) - state.pointee.fill)
            state.pointee.resampler.ratio = baseRatio * drift.ratioMultiplier(fillFrames: state.pointee.fill)
            let need = min(state.pointee.resampler.inputFramesNeeded(forOutput: count), feedCapacity)
            if ring.read(into: feedScratch, frames: need) < need {
                underruns.add(1)
                // A ring that still holds audio keeps playing; only a dry one waits to fill again.
                if fill == 0 { state.pointee.primed = false }
            }
            let produced = state.pointee.resampler
                .process(input: feedScratch, frames: need, output: mix, capacity: count).produced
            if produced < count {
                mix.advanced(by: produced * 2).update(repeating: 0, count: (count - produced) * 2)
            }

            if let tap, tap.render(into: monitor, frames: count) {
                state.pointee.monitorGain.setTarget(linear: monitorGainTarget.value)
                state.pointee.monitorGain.apply(monitor, frames: count, channels: 1)
                vDSP_vadd(mix, 2, monitor, 1, mix, 2, vDSP_Length(count))
                vDSP_vadd(mix + 1, 2, monitor, 1, mix + 1, 2, vDSP_Length(count))
            }

            eq.process(mix, frames: count)
            delay.process(mix, frames: count)
            state.pointee.gain.setTarget(linear: gainTarget.value)
            state.pointee.gain.apply(mix, frames: count, channels: 2)
            state.pointee.master.setTarget(linear: masterTarget.value)
            state.pointee.master.apply(mix, frames: count, channels: 2)
            scatterStereo(mix, frames: count, into: output)
        }
    }

    /// 256 frames for Bluetooth, which cannot keep up with less, and 128 for everything else.
    static func defaultBufferFrames(_ transport: AudioDevice.TransportType) -> UInt32 {
        transport == .bluetooth || transport == .bluetoothLE ? 256 : 128
    }

    func start() throws { try proc?.start() }

    func stop() {
        proc = nil
        tap?.deallocate()
        state.pointee.resampler.deallocate()
        state.deallocate()
        ring.deallocate()
        eq.deallocate()
        delay.deallocate()
        feedScratch.deallocate()
        mix.deallocate()
        monitor.deallocate()
        gainTarget.deallocate()
        monitorGainTarget.deallocate()
        masterTarget.deallocate()
        underruns.deallocate()
    }
}

/// One enabled physical input: mono-summed, gained, resampled to the mic mix rate and written into
/// one ring per consumer.
@MainActor
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
                gain: SmoothedGain(sampleRate: rate, decibels: settings.muted ? silenceDecibels : settings.gainDB)))

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

/// Writes the mic mix into the `Mixanimo Mic` device, which is where other apps read it.
@MainActor
final class MicDrainNode {
    let tap: MonitorTap

    private let mono: UnsafeMutablePointer<Float>
    private let blockFrames: Int
    private var proc: IOProc?

    init(device: AudioDevice, inputs: Int) throws {
        let cycleFrames = Int((try? device.bufferFrameSize) ?? 512)
        blockFrames = 2 * max(cycleFrames, 512)
        tap = MonitorTap(inputs: inputs, rate: micMixRate, frames: cycleFrames)
        mono = .allocate(capacity: blockFrames)
        mono.initialize(repeating: 0, count: blockFrames)

        let tapCopy = tap
        nonisolated(unsafe) let mono = self.mono
        let blockFrames = self.blockFrames
        proc = try IOProc(device: device) { _, _, _, output, _ in
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
