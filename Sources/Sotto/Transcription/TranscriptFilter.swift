import Foundation

/// Filters Whisper hallucinations: on silence or noise the model fabricates
/// bracketed pseudo-captions ("[Music]", "(applause)") and polite filler
/// ("Thank you."). Single home for the denylist — keep it here, not inline.
enum TranscriptFilter {
    /// Lowercased exact matches (after trimming) that are never real speech
    /// in a call recording.
    static let denylist: Set<String> = [
        "thank you",
        "thank you.",
        "thanks for watching",
        "thanks for watching!",
        "thanks for watching.",
        "you",
        "music",
        "silence",
        "blank_audio",
        "no speech",
        "inaudible",
        "subtitles by the amara.org community",
    ]

    /// True when a trimmed segment text is a known hallucination:
    /// empty, fully bracketed `[...]`/`(...)`, or on the denylist.
    static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Any fully enclosed bracket marker counts — covers every
        // "[Music]"/"(applause)"-style variant without enumerating them.
        if let first = trimmed.first, let last = trimmed.last,
           (first == "[" && last == "]") || (first == "(" && last == ")") {
            return true
        }

        return denylist.contains(trimmed.lowercased())
    }
}
