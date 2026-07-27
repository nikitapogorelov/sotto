import Foundation

/// The fallback signal for browser calls we can't name.
///
/// A browser holding the mic *and* the speakers for a stretch is almost always
/// a call: a permission probe or a "test your microphone" widget is over in a
/// second or two, and dictation doesn't play anything back. Sustain is what
/// makes it credible, so the tracker only reports a source once it has been
/// duplex continuously for `sustainSeconds`.
///
/// Timestamps are injected rather than read from the clock, so the whole
/// behaviour is testable without waiting.
struct DuplexSustainTracker {
    let sustainSeconds: Double

    private struct Entry {
        var since: Double
        var matured: Bool
    }

    private var entries: [String: Entry] = [:]

    init(sustainSeconds: Double = 15) {
        self.sustainSeconds = sustainSeconds
    }

    /// Feed a source's current duplex state. Losing duplex restarts the clock —
    /// a call that dropped and resumed has to earn the full sustain again.
    mutating func observe(_ id: String, duplex: Bool, at now: Double) {
        guard duplex else {
            entries[id] = nil
            return
        }
        if entries[id] == nil {
            entries[id] = Entry(since: now, matured: false)
        }
    }

    /// Sources that have now been duplex long enough. Each is reported once;
    /// it takes a break in duplex to make one eligible again.
    mutating func matured(at now: Double) -> [String] {
        let ready = entries
            .filter { !$0.value.matured && now - $0.value.since >= sustainSeconds }
            .keys
            .sorted()
        for id in ready {
            entries[id]?.matured = true
        }
        return ready
    }

    mutating func forget(_ id: String) {
        entries[id] = nil
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
