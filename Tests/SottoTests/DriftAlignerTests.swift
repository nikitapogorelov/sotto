import Testing
@testable import Sotto

struct DriftAlignerTests {
    private let rate = 16_000.0

    private func timing(
        first: Double?, firstIndex: Int = 0, last: Double? = nil, lastIndex: Int = 0
    ) -> TrackTiming {
        TrackTiming(
            firstHostSeconds: first, firstSampleIndex: firstIndex,
            lastHostSeconds: last, lastSampleIndex: lastIndex
        )
    }

    // MARK: - Lead padding

    @Test func micStartingLaterPadsMic() {
        let pad = DriftAligner.leadPadFrames(
            mic: timing(first: 100.5), system: timing(first: 100.0), sampleRate: rate
        )
        #expect(pad == (mic: 8000, system: 0))
    }

    @Test func systemStartingLaterPadsSystem() {
        let pad = DriftAligner.leadPadFrames(
            mic: timing(first: 100.0), system: timing(first: 100.25), sampleRate: rate
        )
        #expect(pad == (mic: 0, system: 4000))
    }

    @Test func zeroDeltaPadsNothing() {
        let pad = DriftAligner.leadPadFrames(
            mic: timing(first: 42.0), system: timing(first: 42.0), sampleRate: rate
        )
        #expect(pad == (mic: 0, system: 0))
    }

    @Test func missingAnchorPadsNothing() {
        let pad = DriftAligner.leadPadFrames(
            mic: timing(first: nil), system: timing(first: 100.0), sampleRate: rate
        )
        #expect(pad == (mic: 0, system: 0))
    }

    @Test func implausibleDeltaIsIgnored() {
        let pad = DriftAligner.leadPadFrames(
            mic: timing(first: 100.0 + DriftAligner.maxLeadPadSeconds + 1),
            system: timing(first: 100.0),
            sampleRate: rate
        )
        #expect(pad == (mic: 0, system: 0))
    }

    // MARK: - Rate ratio

    @Test func ratioFromSyntheticAnchors() throws {
        // Mic delivers exactly 16 000 samples/s; system runs 100 ppm slow.
        let mic = timing(first: 0, firstIndex: 0, last: 100, lastIndex: 1_600_000)
        let system = timing(first: 0, firstIndex: 0, last: 100, lastIndex: 1_599_840)
        let ratio = try #require(DriftAligner.rateRatio(mic: mic, system: system))
        #expect(abs(ratio - 1_600_000.0 / 1_599_840.0) < 1e-9)
    }

    @Test func shortAnchorSpanGivesNoRatio() {
        let mic = timing(first: 0, last: 5, lastIndex: 80_000)
        let system = timing(first: 0, last: 5, lastIndex: 80_000)
        #expect(DriftAligner.rateRatio(mic: mic, system: system) == nil)
    }

    @Test func implausibleRatioIsRejected() {
        // System "clock" off by 10% — a broken anchor, not drift.
        let mic = timing(first: 0, last: 100, lastIndex: 1_600_000)
        let system = timing(first: 0, last: 100, lastIndex: 1_440_000)
        #expect(DriftAligner.rateRatio(mic: mic, system: system) == nil)
    }

    @Test func missingAnchorsGiveNoRatio() {
        let mic = timing(first: nil)
        let system = timing(first: 0, last: 100, lastIndex: 1_600_000)
        #expect(DriftAligner.rateRatio(mic: mic, system: system) == nil)
    }

    // MARK: - Stretch

    @Test func stretchIdentityAtRatioOne() {
        let samples: [Float] = [0, 0.5, 1, 0.5, 0]
        #expect(DriftAligner.stretch(samples, byRatio: 1.0) == samples)
    }

    @Test func stretchChangesLengthProportionally() {
        let samples = [Float](repeating: 0.5, count: 160_000)
        let ratio = 1.0001
        let stretched = DriftAligner.stretch(samples, byRatio: ratio)
        #expect(stretched.count == Int((Double(samples.count) * ratio).rounded()))
        // Constant signal stays constant under linear interpolation.
        #expect(stretched.allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test func stretchPreservesEndpoints() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        let stretched = DriftAligner.stretch(samples, byRatio: 1.2)
        #expect(abs(stretched.first! - 0) < 1e-6)
        #expect(abs(stretched.last! - 9) < 1e-6)
    }

    // MARK: - align()

    @Test func alignWithoutAnchorsIsIdentity() {
        let mic = [Float](repeating: 0.1, count: 32_000)
        let system = [Float](repeating: 0.2, count: 32_000)
        let result = DriftAligner.align(
            mic: mic, system: system, micTiming: TrackTiming(), systemTiming: TrackTiming()
        )
        #expect(result.mic == mic)
        #expect(result.system == system)
        #expect(result.appliedRatio == nil)
        #expect(result.appliedLeadPad == (0, 0))
    }

    @Test func alignPadsLaterTrack() {
        let mic = [Float](repeating: 0.1, count: 16_000)
        let system = [Float](repeating: 0.2, count: 24_000)
        let result = DriftAligner.align(
            mic: mic, system: system,
            micTiming: timing(first: 10.5), systemTiming: timing(first: 10.0)
        )
        #expect(result.mic.count == mic.count + 8000)
        #expect(result.mic[0..<8000].allSatisfy { $0 == 0 })
        #expect(result.system == system)
    }

    @Test func subThresholdDriftIsNotStretched() {
        // 10 ppm over 60 s predicts ~0.6 ms skew — below the 30 ms threshold.
        let count = 960_000
        let mic = [Float](repeating: 0.1, count: count)
        let system = [Float](repeating: 0.2, count: count)
        let result = DriftAligner.align(
            mic: mic, system: system,
            micTiming: timing(first: 0, last: 60, lastIndex: count),
            systemTiming: timing(first: 0, last: 60, lastIndex: count - 10)
        )
        #expect(result.appliedRatio == nil)
        #expect(result.system.count == count)
    }

    @Test func audibleDriftIsStretched() throws {
        // 1000 ppm over 60 s predicts 60 ms skew — must be corrected.
        let count = 960_000
        let mic = [Float](repeating: 0.1, count: count)
        let system = [Float](repeating: 0.2, count: count - 960)
        let result = DriftAligner.align(
            mic: mic, system: system,
            micTiming: timing(first: 0, last: 60, lastIndex: count),
            systemTiming: timing(first: 0, last: 60, lastIndex: count - 960)
        )
        let ratio = try #require(result.appliedRatio)
        #expect(ratio > 1)
        // Stretched system should land within a few samples of the mic length.
        #expect(abs(result.system.count - mic.count) < 8)
    }
}
