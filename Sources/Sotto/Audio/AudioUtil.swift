import AVFoundation
import CoreMedia

/// Everything funnels into Whisper's expected input: 16 kHz, mono, Float32.
enum AudioUtil {
    static let whisperSampleRate: Double = 16_000

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: whisperSampleRate,
        channels: 1,
        interleaved: false
    )!

    static func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        AVAudioConverter(from: format, to: targetFormat)
    }

    // MARK: - Manual mic-path resampling

    // The mic path deliberately avoids AVAudioConverter: with Voice Processing IO
    // enabled the input node can deliver buffers whose channel layout doesn't match
    // the tap format (9 channels observed in the wild). AVAudioConverter either
    // crashes (EXC_BAD_ACCESS on the render thread) or "succeeds" while writing
    // near-silence (~-90 dB). Taking channel 0 and resampling by hand sidesteps both.

    /// Linearly resample `input` at `inputRate` to 16 kHz into `out`.
    /// `out` grows only when too small (steady-state: zero allocation).
    /// Returns the number of valid samples written to `out`.
    static func resampleLinearTo16k(
        _ input: UnsafeBufferPointer<Float>,
        inputRate: Double,
        into out: inout [Float]
    ) -> Int {
        let n = input.count
        guard n > 0, inputRate > 0 else { return 0 }

        let ratio = inputRate / whisperSampleRate
        let outCount = max(1, Int(Double(n) / ratio))
        if out.count < outCount {
            out.append(contentsOf: repeatElement(0, count: outCount - out.count))
        }

        out.withUnsafeMutableBufferPointer { dst in
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let idx = min(Int(pos), n - 1)
                let next = min(idx + 1, n - 1)
                let frac = Float(pos - Double(idx))
                dst[i] = input[idx] + (input[next] - input[idx]) * frac
            }
        }
        return outCount
    }

    /// Real-time-safe mic conversion: channel 0 only, tolerates any channel
    /// count or layout, resampled to 16 kHz. Returns 0 (never crashes) when
    /// the buffer isn't non-interleaved Float32.
    static func resampleChannel0To16k(
        _ buffer: AVAudioPCMBuffer,
        into out: inout [Float]
    ) -> Int {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let input = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        return resampleLinearTo16k(input, inputRate: buffer.format.sampleRate, into: &out)
    }

    // MARK: - Level measurement

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        return Float((sumSq / Double(samples.count)).squareRoot())
    }

    /// Amplitude (peak or RMS, linear 0...1) to decibels full scale.
    static func dbFS(_ amplitude: Float) -> Float {
        20 * log10(max(amplitude, 1e-9))
    }

    // MARK: - Speech regions

    struct SpeechRegion: Equatable {
        /// Sample indices to transcribe.
        let range: Range<Int>
        /// Where the region starts in the track — add to Whisper timestamps
        /// so they stay aligned with the full recording.
        let startSeconds: Double
    }

    /// Split a track into regions of signal separated by real silence.
    ///
    /// Whisper's timestamps can't be trusted across a long quiet stretch: fed
    /// a clip that opens with several silent seconds, it emits one segment
    /// starting at t=0 that swallows the whole pause, which then sorts ahead
    /// of everything the other channel said in the meantime. Transcribing each
    /// region on its own keeps every timestamp anchored to where the speech
    /// actually is. Gaps shorter than `minGapSeconds` stay inside a region so
    /// ordinary between-sentence pauses don't fragment it.
    ///
    /// Pass the opposite track as `leakageOf` to have windows that are merely
    /// bleed of it count as silence. That has to happen here, per window,
    /// rather than per finished region: bleed that runs up to within a
    /// sentence pause of real speech would otherwise be bridged into the same
    /// region and inherit its start.
    static func speechRegions(
        _ samples: [Float],
        leakageOf other: [Float]? = nil,
        sampleRate: Double = whisperSampleRate,
        windowSeconds: Double = 0.5,
        thresholdDBFS: Float = -55,
        minGapSeconds: Double = 1.5,
        padSeconds: Double = 0.25
    ) -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        let window = max(1, Int(windowSeconds * sampleRate))
        let minGapWindows = max(1, Int((minGapSeconds / windowSeconds).rounded()))

        var voiced: [Bool] = []
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + window, samples.count)
            var isVoiced = dbFS(rms(samples[cursor..<end])) >= thresholdDBFS
            if isVoiced, let other, isLeakage(samples, of: other, in: cursor..<end) {
                isVoiced = false
            }
            voiced.append(isVoiced)
            cursor = end
        }

        // Runs of voiced windows, bridging gaps below the minimum.
        var runs: [Range<Int>] = []
        var runStart: Int?
        var gap = 0
        for (index, isVoiced) in voiced.enumerated() {
            if isVoiced {
                if runStart == nil { runStart = index }
                gap = 0
            } else if let start = runStart {
                gap += 1
                if gap >= minGapWindows {
                    runs.append(start..<(index - gap + 1))
                    runStart = nil
                    gap = 0
                }
            }
        }
        if let start = runStart {
            runs.append(start..<(voiced.count - gap))
        }

        let pad = Int(padSeconds * sampleRate)
        return runs.compactMap { run in
            let start = max(0, run.lowerBound * window - pad)
            let end = min(samples.count, run.upperBound * window + pad)
            guard start < end else { return nil }
            return SpeechRegion(range: start..<end, startSeconds: Double(start) / sampleRate)
        }
    }

    /// True when `track` over `range` sits far enough below `other` to be
    /// leakage of it rather than speech of its own.
    ///
    /// The mic hears the call through the speakers whenever echo cancellation
    /// doesn't fully cancel it (measured at 20–38 dB below the system track).
    /// Genuine speech runs level with or above the other side even when both
    /// talk at once, because the mic is far closer to its own speaker than to
    /// the leaking one.
    static func isLeakage(
        _ track: [Float],
        of other: [Float],
        in range: Range<Int>,
        marginDB: Float = 10
    ) -> Bool {
        let trackRange = range.clamped(to: 0..<track.count)
        let otherRange = range.clamped(to: 0..<other.count)
        guard !trackRange.isEmpty, !otherRange.isEmpty else { return false }
        return dbFS(rms(track[trackRange])) <= dbFS(rms(other[otherRange])) - marginDB
    }

    /// Convert an arbitrary PCM buffer to 16 kHz mono Float32 samples.
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> [Float] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    /// Bridge ScreenCaptureKit's CMSampleBuffer into AVAudioPCMBuffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }

    /// Write mono Float32 samples as a 16-bit PCM WAV.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        try writeWAV([samples], to: url)
    }

    /// Write one Float32 track per channel as a 16-bit PCM WAV.
    /// Shorter tracks are zero-padded to the longest one.
    static func writeWAV(_ channels: [[Float]], to url: URL) throws {
        let frames = channels.map(\.count).max() ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: whisperSampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (i, samples) in channels.enumerated() {
            let dst = buffer.floatChannelData![i]
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: samples.count)
                }
            }
            // Buffer memory is not guaranteed zeroed — pad the tail explicitly.
            if samples.count < frames {
                (dst + samples.count).update(repeating: 0, count: frames - samples.count)
            }
        }
        try file.write(from: buffer)
    }
}
