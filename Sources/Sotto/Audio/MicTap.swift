import Foundation
import AVFoundation
import os

/// Captures the user's microphone via AVAudioEngine and resamples to
/// 16 kHz mono Float32. Requires the Microphone permission.
///
/// Voice Processing IO (Apple's acoustic echo cancellation) is enabled so the
/// remote voice played through speakers doesn't re-enter the mic track.
final class MicTap {
    private static let logger = Logger(subsystem: "dev.sotto", category: "audio")

    private let engine = AVAudioEngine()
    // Only ever touched from the single audio render thread — no lock needed.
    private var scratch: [Float] = []

    /// Called on the audio render thread with 16 kHz mono Float32 chunks and
    /// the chunk's host-clock time in seconds (nil when the driver provides
    /// only sample time — VPIO does occasionally).
    var onSamples: (([Float], Double?) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode

        // VPIO must be toggled while the engine is stopped and before the tap
        // is installed. The engine is reused across start/stop cycles, so skip
        // if already enabled (re-toggling reconfigures the IO unit — flaky).
        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                // Can fail on unusual aggregate devices; record without AEC.
                Self.logger.error("Voice processing unavailable, continuing without AEC: \(error.localizedDescription)")
            }
        }

        if input.isVoiceProcessingEnabled {
            // VPIO ducks all other audio by default, which also guts the
            // ScreenCaptureKit system-audio capture (~-50 dB). Turn it off.
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }

        // Re-read after enabling VPIO: the node's output format changes.
        let format = input.outputFormat(forBus: 0)

        // Pre-size so even the first callback doesn't grow the scratch buffer.
        // VPIO may ignore the requested tap buffer size, but never exceeds it.
        scratch = [Float](repeating: 0, count: Int(4096.0 * AudioUtil.whisperSampleRate / max(format.sampleRate, 1)) + 16)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let n = AudioUtil.resampleChannel0To16k(buffer, into: &self.scratch)
            if n > 0 {
                let hostSeconds = when.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
                self.onSamples?(Array(self.scratch[0..<n]), hostSeconds)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Leave voice processing enabled — toggling per cycle is the flaky path.
    }
}
