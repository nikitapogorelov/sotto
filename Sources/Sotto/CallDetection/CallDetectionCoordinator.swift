import Foundation

/// Runs one `CallDetectionLogic` per call source, so Zoom's notification can't
/// mute Chrome's ten seconds later.
///
/// Works by diffing whole snapshots rather than trusting event payloads: the
/// CoreAudio callbacks that drive this hop through the main actor, so two rapid
/// edges can arrive out of order. Re-reading live state on every step makes
/// that harmless — the worst case is a redundant no-op pass.
struct CallDetectionCoordinator {
    let cooldownSeconds: Double
    let selfNoiseSeconds: Double

    private var logics: [String: CallDetectionLogic] = [:]
    private var recording = false
    private var lastOwnActivityAt: Double?

    init(cooldownSeconds: Double = 60, selfNoiseSeconds: Double = 2) {
        self.cooldownSeconds = cooldownSeconds
        self.selfNoiseSeconds = selfNoiseSeconds
    }

    /// Track Sotto's own recording across every source, present and future.
    mutating func setRecording(_ isRecording: Bool, at now: Double) {
        recording = isRecording
        lastOwnActivityAt = now
        for id in Array(logics.keys) {
            logics[id]?.setRecording(isRecording, at: now)
        }
    }

    /// Seed from the state at launch so calls already in progress stay quiet.
    mutating func seed(with snapshot: [CallSource]) {
        for source in snapshot {
            logics[source.id] = makeLogic(inputInitiallyRunning: source.inputRunning)
        }
    }

    /// Diff a snapshot against the last one.
    ///
    /// - Returns: `evaluate` — sources whose input just came up and passed the
    ///   debounce, for the caller to investigate; `ended` — sources that have
    ///   left the process list entirely.
    mutating func step(
        snapshot: [CallSource],
        at now: Double
    ) -> (evaluate: [CallSource], ended: [String]) {
        let present = Set(snapshot.map(\.id))
        let ended = logics.keys.filter { !present.contains($0) }.sorted()
        for id in ended {
            logics[id] = nil
        }

        var evaluate: [CallSource] = []
        for source in snapshot {
            var logic = logics[source.id] ?? makeLogic(inputInitiallyRunning: false)
            if logic.shouldEvaluate(inputRunning: source.inputRunning, at: now) {
                evaluate.append(source)
            }
            logics[source.id] = logic
        }
        return (evaluate, ended)
    }

    /// Arm `id`'s cooldown, once a notification has actually been shown.
    mutating func noteNotified(_ id: String, at now: Double) {
        logics[id]?.noteNotified(at: now)
    }

    private func makeLogic(inputInitiallyRunning: Bool) -> CallDetectionLogic {
        var logic = CallDetectionLogic(
            inputInitiallyRunning: inputInitiallyRunning,
            cooldownSeconds: cooldownSeconds,
            selfNoiseSeconds: selfNoiseSeconds
        )
        // A source first seen *after* Sotto started recording has to inherit
        // the suppression, otherwise our own capture gets attributed to
        // whichever process happens to show up next.
        if let own = lastOwnActivityAt {
            logic.setRecording(recording, at: own)
        }
        return logic
    }
}
