import Foundation

/// Per-channel accumulation of live-draft segments across sliding windows.
struct StreamMergeState: Equatable, Sendable {
    /// Call time (seconds from track start) up to which segments are final.
    var committedUntil: Double = 0
    var committed: [TranscriptSegment] = []
}

/// Deduplicates segments across overlapping transcription windows. A segment
/// is committed once it ends before the window's tail stability margin — the
/// region a later window will re-transcribe with more context. Everything
/// after that is provisional and replaced wholesale on the next cycle.
enum StreamMerge {
    /// Segments ending within this many seconds of the window's end are still
    /// unstable (speech may continue past the window edge).
    static let stabilityMargin = 2.0
    /// Tolerance when comparing a segment's start against `committedUntil` —
    /// re-transcribed boundaries jitter by a few tens of milliseconds.
    static let epsilon = 0.25

    /// Fold one window's transcription into the channel state.
    /// `window` timestamps are window-relative; `windowStart`/`windowEnd` are
    /// the window's position in call time.
    static func integrate(
        window: [TranscriptSegment],
        windowStart: Double,
        windowEnd: Double,
        speaker: Speaker,
        into state: StreamMergeState,
        stabilityMargin: Double = stabilityMargin,
        epsilon: Double = epsilon
    ) -> (state: StreamMergeState, provisional: [TranscriptSegment]) {
        var state = state
        var provisional: [TranscriptSegment] = []
        let commitCutoff = windowEnd - stabilityMargin

        for segment in window.sorted(by: { $0.start < $1.start }) {
            let shifted = TranscriptSegment(
                start: segment.start + windowStart,
                end: segment.end + windowStart,
                text: segment.text,
                speaker: speaker
            )
            // Already covered by a previous window's commit.
            guard shifted.start >= state.committedUntil - epsilon else { continue }
            if shifted.end <= commitCutoff {
                state.committed.append(shifted)
                state.committedUntil = max(state.committedUntil, shifted.end)
            } else {
                provisional.append(shifted)
            }
        }
        return (state, provisional)
    }

    /// Both channels' committed segments merged in call time, with the
    /// (cross-channel) provisional tail appended last so the UI can dim it.
    static func mergedDraft(
        mic: StreamMergeState,
        system: StreamMergeState,
        provisional: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        (mic.committed + system.committed).sorted { $0.start < $1.start }
            + provisional.sorted { $0.start < $1.start }
    }
}
