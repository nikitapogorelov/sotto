import Foundation

/// Live-draft transcription during a recording: owns its own whisper context
/// (not thread-safe — the actor serializes all calls) and per-channel merge
/// state. Discarded on stop, before the final full pass loads its own context,
/// so two model instances never coexist.
actor StreamingSession {
    /// Windows quieter than this are skipped — Whisper hallucinates on
    /// silence, and skipping halves average compute (one side talks at a time).
    static let silenceThresholdDBFS: Float = -55

    struct Draft: Sendable {
        /// Committed segments first, provisional tail last (see StreamMerge).
        var segments: [TranscriptSegment] = []
        /// How many segments at the end of `segments` are provisional.
        var provisionalCount = 0
    }

    private let transcriber: WhisperTranscriber
    private var micState = StreamMergeState()
    private var systemState = StreamMergeState()

    init(modelPath: String) throws {
        transcriber = try WhisperTranscriber(modelPath: modelPath)
    }

    /// Transcribe the current tail window of each channel and fold the result
    /// into the draft. `micStart`/`systemStart` are the window positions in
    /// seconds from track start.
    func process(
        micWindow: [Float], micStart: Double,
        systemWindow: [Float], systemStart: Double
    ) throws -> Draft {
        var provisional: [TranscriptSegment] = []

        for (window, start, speaker) in [
            (micWindow, micStart, Speaker.me),
            (systemWindow, systemStart, .them),
        ] {
            guard !window.isEmpty,
                  AudioUtil.dbFS(AudioUtil.rms(window[...])) >= Self.silenceThresholdDBFS
            else { continue }

            // The mic picks the call up through the speakers; transcribing
            // that would label the other side's words "Me".
            if speaker == .me,
               AudioUtil.isLeakage(window, of: systemWindow, in: 0..<window.count) { continue }

            let windowEnd = start + Double(window.count) / AudioUtil.whisperSampleRate
            let segments = try transcriber.transcribe(window)
            let state = speaker == .me ? micState : systemState
            let result = StreamMerge.integrate(
                window: segments, windowStart: start, windowEnd: windowEnd,
                speaker: speaker, into: state
            )
            if speaker == .me { micState = result.state } else { systemState = result.state }
            provisional += result.provisional
        }

        let merged = StreamMerge.mergedDraft(
            mic: micState, system: systemState, provisional: provisional
        )
        return Draft(segments: merged, provisionalCount: provisional.count)
    }
}
