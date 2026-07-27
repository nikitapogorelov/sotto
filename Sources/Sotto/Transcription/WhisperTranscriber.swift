import Foundation
import whisper

enum Speaker: String, Codable, Hashable {
    case me    // microphone track
    case them  // system-audio track

    var displayName: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

struct TranscriptSegment: Codable, Hashable {
    let start: Double // seconds
    let end: Double
    let text: String
    // Optional so transcripts from pre-per-track recordings keep decoding.
    var speaker: Speaker? = nil
}

/// Thin wrapper over whisper.cpp's C API. Runs fully on-device;
/// on Apple Silicon inference goes through Metal automatically.
final class WhisperTranscriber {
    enum WhisperError: LocalizedError {
        case modelLoadFailed(String)
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Could not load Whisper model at \(path)"
            case .transcriptionFailed: return "Whisper failed to transcribe the audio"
            }
        }
    }

    private let context: OpaquePointer

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Input: 16 kHz mono Float32 samples. Language is auto-detected,
    /// which handles mixed ru/en calls well on large-v3 class models.
    func transcribe(_ samples: [Float]) throws -> [TranscriptSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        // Not implemented at pinned v1.7.2 (whisper.h marks it TODO), and
        // whisper_full_get_segment_no_speech_prob doesn't exist at this pin,
        // so segment-level no-speech skipping isn't possible. Harmless now,
        // becomes active if the pin ever moves. TranscriptFilter below is the
        // working defense against silence hallucinations.
        params.no_speech_thold = 0.6

        // "auto" → let Whisper detect (and switch) language.
        let language = strdup("auto")
        defer { free(language) }
        params.language = UnsafePointer(language)

        let status = samples.withUnsafeBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return whisper_full(context, params, base, Int32(samples.count))
        }
        guard status == 0 else { throw WhisperError.transcriptionFailed }

        var segments: [TranscriptSegment] = []
        let count = whisper_full_n_segments(context)
        for i in 0..<count {
            // t0/t1 are in centiseconds.
            let start = Double(whisper_full_get_segment_t0(context, i)) / 100.0
            let end = Double(whisper_full_get_segment_t1(context, i)) / 100.0
            guard let cText = whisper_full_get_segment_text(context, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !TranscriptFilter.isHallucination(text) {
                segments.append(TranscriptSegment(start: start, end: end, text: text))
            }
        }
        return segments
    }
}
