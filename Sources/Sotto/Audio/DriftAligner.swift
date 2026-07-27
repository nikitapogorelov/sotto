import Foundation

/// Host-clock anchors collected while a track records: the accumulated
/// 16 kHz sample position at the first and last timestamped chunk.
struct TrackTiming: Equatable, Sendable {
    var firstHostSeconds: Double?
    var firstSampleIndex: Int = 0
    var lastHostSeconds: Double?
    var lastSampleIndex: Int = 0

    /// Record an anchor for a chunk that begins at `sampleIndex` (the track's
    /// accumulated sample count before the chunk is appended).
    mutating func addAnchor(hostSeconds: Double, sampleIndex: Int) {
        if firstHostSeconds == nil {
            firstHostSeconds = hostSeconds
            firstSampleIndex = sampleIndex
        }
        lastHostSeconds = hostSeconds
        lastSampleIndex = sampleIndex
    }
}

/// Aligns the mic and system tracks using host-clock anchors: pads the
/// later-starting track so both share a t0, and corrects clock-rate drift by
/// linearly stretching the system channel. Pure functions — fully testable.
/// Missing or degenerate anchors degrade to identity (today's behavior).
enum DriftAligner {
    /// Ignore t0 deltas beyond this — a bogus anchor, not real start skew.
    static let maxLeadPadSeconds = 5.0
    /// Ignore rate ratios beyond ±0.5% — real clock drift is ppm-scale.
    static let maxRateDeviation = 0.005
    /// Skip the stretch when the predicted end-of-recording misalignment
    /// is below this — inaudible, not worth resampling.
    static let minCorrectableSkewSeconds = 0.030
    /// Anchors closer together than this can't measure rate reliably.
    static let minAnchorSpanSeconds = 10.0

    /// Zero samples to prepend to each track so both start at the same host time.
    static func leadPadFrames(
        mic: TrackTiming, system: TrackTiming, sampleRate: Double
    ) -> (mic: Int, system: Int) {
        guard let micStart = mic.firstHostSeconds,
              let systemStart = system.firstHostSeconds else { return (0, 0) }
        let delta = micStart - systemStart
        guard abs(delta) <= maxLeadPadSeconds else { return (0, 0) }
        let frames = Int((abs(delta) * sampleRate).rounded())
        return delta >= 0 ? (mic: frames, system: 0) : (mic: 0, system: frames)
    }

    /// Effective samples-per-host-second of one track, nil when anchors are
    /// missing or too close together.
    static func effectiveRate(_ timing: TrackTiming) -> Double? {
        guard let first = timing.firstHostSeconds, let last = timing.lastHostSeconds else { return nil }
        let span = last - first
        guard span >= minAnchorSpanSeconds else { return nil }
        return Double(timing.lastSampleIndex - timing.firstSampleIndex) / span
    }

    /// mic-rate / system-rate, clamped to sanity bounds; nil when either
    /// rate is unmeasurable.
    static func rateRatio(mic: TrackTiming, system: TrackTiming) -> Double? {
        guard let micRate = effectiveRate(mic), let systemRate = effectiveRate(system),
              micRate > 0, systemRate > 0 else { return nil }
        let ratio = micRate / systemRate
        guard abs(ratio - 1) <= maxRateDeviation else { return nil }
        return ratio
    }

    /// Linearly resample `samples` to `count * ratio` samples.
    static func stretch(_ samples: [Float], byRatio ratio: Double) -> [Float] {
        guard ratio != 1.0, samples.count > 1 else { return samples }
        let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        let step = Double(samples.count - 1) / Double(max(outCount - 1, 1))
        var out = [Float](repeating: 0, count: outCount)
        out.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                for i in 0..<outCount {
                    let pos = Double(i) * step
                    let idx = min(Int(pos), src.count - 2)
                    let frac = Float(pos - Double(idx))
                    dst[i] = src[idx] + (src[idx + 1] - src[idx]) * frac
                }
            }
        }
        return out
    }

    /// Result of aligning the two tracks, with the corrections that were
    /// applied (for logging).
    struct Result {
        var mic: [Float]
        var system: [Float]
        var appliedLeadPad: (mic: Int, system: Int) = (0, 0)
        var appliedRatio: Double?
    }

    static func align(
        mic: [Float], system: [Float],
        micTiming: TrackTiming, systemTiming: TrackTiming,
        sampleRate: Double = AudioUtil.whisperSampleRate
    ) -> Result {
        var result = Result(mic: mic, system: system)

        // Rate first: the stretch maps the system channel onto the mic clock,
        // and the t0 pad below is expressed in samples of that common clock.
        if let ratio = rateRatio(mic: micTiming, system: systemTiming) {
            let duration = Double(max(mic.count, system.count)) / sampleRate
            if abs(ratio - 1) * duration >= minCorrectableSkewSeconds {
                result.system = stretch(system, byRatio: ratio)
                result.appliedRatio = ratio
            }
        }

        let pad = leadPadFrames(mic: micTiming, system: systemTiming, sampleRate: sampleRate)
        if pad.mic > 0 {
            result.mic = [Float](repeating: 0, count: pad.mic) + result.mic
        }
        if pad.system > 0 {
            result.system = [Float](repeating: 0, count: pad.system) + result.system
        }
        result.appliedLeadPad = pad
        return result
    }
}
