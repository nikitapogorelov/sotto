import Testing
import Foundation
@testable import Sotto

private let sr = AudioUtil.whisperSampleRate

/// Sine at `amplitude`, `seconds` long, at 16 kHz.
private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
    let count = Int(seconds * sr)
    return (0..<count).map { amplitude * sinf(2 * .pi * 440 * Float($0) / Float(sr)) }
}

private func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * sr))
}

struct SpeechRegionTests {
    @Test func emptyInputHasNoRegions() {
        #expect(AudioUtil.speechRegions([]).isEmpty)
    }

    @Test func allSilentHasNoRegions() {
        #expect(AudioUtil.speechRegions(silence(5)).isEmpty)
    }

    @Test func leadingSilenceIsExcludedFromTheRegion() throws {
        let samples = silence(4) + tone(3)
        let regions = AudioUtil.speechRegions(samples)
        let region = try #require(regions.first)
        #expect(regions.count == 1)
        // Region opens just before the tone (0.25 s of padding), not at zero.
        #expect(abs(region.startSeconds - 3.75) < 0.05)
    }

    @Test func trailingSilenceIsExcluded() throws {
        let samples = tone(3) + silence(4)
        let region = try #require(AudioUtil.speechRegions(samples).first)
        #expect(region.startSeconds < 0.05)
        #expect(abs(Double(region.range.upperBound) / sr - 3.25) < 0.05)
    }

    @Test func shortPauseKeepsOneRegion() {
        // 0.5 s between sentences must not split the speech.
        let samples = tone(2) + silence(0.5) + tone(2)
        #expect(AudioUtil.speechRegions(samples).count == 1)
    }

    @Test func longPauseSplitsIntoRegions() throws {
        let samples = tone(2) + silence(6) + tone(2)
        let regions = AudioUtil.speechRegions(samples)
        #expect(regions.count == 2)
        #expect(try #require(regions.first).startSeconds < 0.05)
        // Second region starts near 8 s — the timestamp offset that keeps the
        // second utterance from sorting ahead of the other channel.
        #expect(abs(try #require(regions.last).startSeconds - 7.75) < 0.1)
    }

    @Test func quietNoiseBelowThresholdIsNotSpeech() {
        let noise = (0..<Int(5 * sr)).map { _ in Float.random(in: -0.0005...0.0005) }
        #expect(AudioUtil.speechRegions(noise).isEmpty)
    }

    @Test func regionsStayInsideTheTrack() {
        let samples = tone(3)
        for region in AudioUtil.speechRegions(samples) {
            #expect(region.range.lowerBound >= 0)
            #expect(region.range.upperBound <= samples.count)
        }
    }
}

struct LeakageTests {
    @Test func quietTrackAgainstLoudOtherIsLeakage() {
        // The failing recording measured the mic ~20 dB under the system
        // track while a video played through the speakers.
        let mic = tone(3, amplitude: 0.05)
        let system = tone(3, amplitude: 0.5)
        #expect(AudioUtil.isLeakage(mic, of: system, in: 0..<mic.count))
    }

    @Test func speechOverSilentOtherIsNotLeakage() {
        let mic = tone(3, amplitude: 0.5)
        let system = silence(3)
        #expect(!AudioUtil.isLeakage(mic, of: system, in: 0..<mic.count))
    }

    @Test func simultaneousSpeechIsNotLeakage() {
        // Both sides talking: the mic is slightly quieter but nowhere near
        // the leakage margin.
        let mic = tone(3, amplitude: 0.3)
        let system = tone(3, amplitude: 0.5)
        #expect(!AudioUtil.isLeakage(mic, of: system, in: 0..<mic.count))
    }

    @Test func missingOtherTrackIsNotLeakage() {
        let mic = tone(3, amplitude: 0.05)
        #expect(!AudioUtil.isLeakage(mic, of: [], in: 0..<mic.count))
    }

    @Test func rangeBeyondTheOtherTrackIsNotLeakage() {
        let mic = tone(6, amplitude: 0.05)
        let system = tone(3, amplitude: 0.5)
        let tail = Int(4 * sr)..<mic.count
        #expect(!AudioUtil.isLeakage(mic, of: system, in: tail))
    }
}

/// The reported bug: play a video, pause it, then speak. The voice must not
/// sort ahead of the video.
struct TimelineOrderingRegressionTests {
    @Test func speechAfterAPausedVideoStaysAfterIt() throws {
        // System: video for 10 s, then digital silence.
        let system = tone(10, amplitude: 0.5) + silence(18)
        // Mic: 10 s of speaker leakage 20 dB down, then real speech.
        let mic = tone(10, amplitude: 0.05) + silence(1) + tone(17, amplitude: 0.5)

        let micRegions = AudioUtil.speechRegions(mic, leakageOf: system)
        let systemRegions = AudioUtil.speechRegions(system)

        // The leakage stretch is gone; what's left starts after the video.
        let firstMic = try #require(micRegions.first)
        let firstSystem = try #require(systemRegions.first)
        #expect(micRegions.count == 1)
        #expect(firstMic.startSeconds > 10)
        #expect(firstSystem.startSeconds < firstMic.startSeconds)
    }

    /// The gap between leakage and speech can be shorter than the pause that
    /// splits regions — the two must still not merge.
    @Test func leakageAbuttingSpeechDoesNotDragItsStartBack() throws {
        let system = tone(10, amplitude: 0.5) + silence(10)
        let mic = tone(10, amplitude: 0.05) + silence(0.2) + tone(9.8, amplitude: 0.5)

        let region = try #require(AudioUtil.speechRegions(mic, leakageOf: system).first)
        #expect(region.startSeconds > 9.5)
    }

    @Test func withoutTheOtherTrackLeakageIsKept() {
        let system = tone(10, amplitude: 0.5) + silence(10)
        let mic = tone(10, amplitude: 0.05) + silence(0.2) + tone(9.8, amplitude: 0.5)
        // Sanity check that the gate — not the region logic — is what moves
        // the start: without it the leakage merges into the speech region.
        let ungated = AudioUtil.speechRegions(mic)
        #expect(ungated.first?.startSeconds ?? 99 < 0.5)
    }
}
