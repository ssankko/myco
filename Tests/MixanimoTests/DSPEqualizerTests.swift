import XCTest
@testable import Mixanimo

final class DSPEqualizerTests: XCTestCase {
    private let sampleRate = 48000.0
    private let frames = 8192

    private func bypassedBands() -> [BandSettings] {
        [BandSettings](repeating: BandSettings(bypass: true), count: Equalizer.bandCount)
    }

    /// Level of a steady sine after the settling transient, against the sine's own level.
    private func gainDecibels(of band: BandSettings, at frequency: Double) -> Double {
        var bands = bypassedBands()
        bands[0] = band
        let equalizer = Equalizer(sampleRate: sampleRate, channels: 2)
        defer { equalizer.deallocate() }
        equalizer.setBands(bands)

        let input = makeSine(frequency: frequency, sampleRate: sampleRate, frames: frames)
        var output = input
        output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
        let steady = (frames / 2)..<frames
        return decibels(rms(output, range: steady) / rms(input, range: steady))
    }

    func testHighShelfCutsAboveItsCornerAndLeavesTheBassAlone() {
        let shelf = BandSettings(type: .highShelf, frequency: 8000, gainDB: -6)
        XCTAssertEqual(gainDecibels(of: shelf, at: 12000), -6, accuracy: 1.0)
        XCTAssertEqual(gainDecibels(of: shelf, at: 1000), 0, accuracy: 0.1)
    }

    func testBypassedBandsPassThroughBitExactly() {
        let equalizer = Equalizer(sampleRate: sampleRate, channels: 2)
        defer { equalizer.deallocate() }
        var bands = bypassedBands()
        bands[3] = BandSettings(type: .parametric, frequency: 1000, gainDB: 9, bandwidth: 0.5, bypass: true)
        equalizer.setBands(bands)

        let input = makeNoise(frames: frames)
        var output = input
        output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
        XCTAssertEqual(output, input)
    }

    func testEveryFilterTypeStaysFiniteOnNoise() {
        for type in FilterType.allCases {
            let equalizer = Equalizer(sampleRate: sampleRate, channels: 2)
            defer { equalizer.deallocate() }
            var bands = bypassedBands()
            bands[0] = BandSettings(type: type, frequency: 2000, gainDB: 9, bandwidth: 0.7)
            bands[1] = BandSettings(type: type, frequency: 120, gainDB: -12, bandwidth: 2)
            bands[2] = BandSettings(type: type, frequency: 18000, gainDB: 6, bandwidth: 0.2)
            equalizer.setBands(bands)

            var output = makeNoise(frames: frames)
            output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
            XCTAssertTrue(output.allSatisfy { $0.isFinite }, "\(type) produced a non-finite sample")
            XCTAssertLessThan(output.map { abs($0) }.max() ?? 0, 100, "\(type) blew up")
        }
    }

    func testChannelsAreFilteredIndependently() {
        let equalizer = Equalizer(sampleRate: sampleRate, channels: 2)
        defer { equalizer.deallocate() }
        var bands = bypassedBands()
        bands[0] = BandSettings(type: .lowPass, frequency: 500)
        equalizer.setBands(bands)

        var output = makeSine(frequency: 6000, sampleRate: sampleRate, frames: frames)
        output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
        let steady = (frames / 2)..<frames
        XCTAssertEqual(
            rms(output, channel: 0, range: steady),
            rms(output, channel: 1, range: steady),
            accuracy: 1e-9
        )
    }

    func testPublishedCoefficientsReachTheAudioThread() {
        let equalizer = Equalizer(sampleRate: sampleRate, channels: 2)
        defer { equalizer.deallocate() }
        equalizer.setBands(bypassedBands())

        let input = makeSine(frequency: 12000, sampleRate: sampleRate, frames: frames)
        var output = input
        output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
        XCTAssertEqual(output, input)

        var bands = bypassedBands()
        bands[0] = BandSettings(type: .highShelf, frequency: 8000, gainDB: -6)
        equalizer.setBands(bands)
        output = input
        output.withUnsafeMutableBufferPointer { equalizer.process($0, frames: frames) }
        let steady = (frames / 2)..<frames
        XCTAssertEqual(
            decibels(rms(output, range: steady) / rms(input, range: steady)),
            -6,
            accuracy: 1.0
        )
    }

    func testBandwidthNarrowsTheParametricPeak() {
        let wide = BandSettings(type: .parametric, frequency: 1000, gainDB: 12, bandwidth: 2)
        let narrow = BandSettings(type: .parametric, frequency: 1000, gainDB: 12, bandwidth: 0.25)
        XCTAssertEqual(gainDecibels(of: wide, at: 1000), 12, accuracy: 0.2)
        XCTAssertEqual(gainDecibels(of: narrow, at: 1000), 12, accuracy: 0.2)
        XCTAssertGreaterThan(gainDecibels(of: wide, at: 2000), gainDecibels(of: narrow, at: 2000) + 3)
    }
}
