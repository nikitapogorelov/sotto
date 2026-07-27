import Foundation

/// Pure debounce state machine for one source's "running mic input" edges.
/// One evaluation per rising edge, re-armed by the falling edge, with a
/// cooldown so a flapping process doesn't spam; edges caused by Sotto's own
/// capture are suppressed.
///
/// Deciding and notifying are two steps on purpose. A rising edge only earns
/// the right to *evaluate* — naming a browser call means reading window titles
/// and possibly waiting out a 15 s sustain, and plenty of evaluations end in
/// silence. If the edge armed the cooldown, it would swallow the very
/// notification it was supposed to produce. So the cooldown starts only when
/// something is actually shown, via `noteNotified`.
struct CallDetectionLogic {
    let cooldownSeconds: Double
    /// Edges this close to Sotto's own start/stop are our own capture
    /// flipping the state, not a call app.
    let selfNoiseSeconds: Double

    private var armed: Bool
    private var recording = false
    private var lastOwnActivityAt: Double?
    private var lastNotifiedAt: Double?

    /// `inputInitiallyRunning` seeds the edge detector — a call already running
    /// when Sotto launches never produces a rising edge, so no notification.
    init(
        inputInitiallyRunning: Bool = false,
        cooldownSeconds: Double = 60,
        selfNoiseSeconds: Double = 2
    ) {
        armed = !inputInitiallyRunning
        self.cooldownSeconds = cooldownSeconds
        self.selfNoiseSeconds = selfNoiseSeconds
    }

    /// Track Sotto's own recording so its capture doesn't look like a call.
    mutating func setRecording(_ isRecording: Bool, at now: Double) {
        recording = isRecording
        lastOwnActivityAt = now
    }

    /// Feed a source's current input state; returns true when the caller should
    /// work out whether this is a call worth mentioning.
    mutating func shouldEvaluate(inputRunning: Bool, at now: Double) -> Bool {
        guard inputRunning else {
            armed = true
            return false
        }
        guard armed else { return false }
        armed = false

        if recording { return false }
        if let own = lastOwnActivityAt, now - own < selfNoiseSeconds { return false }
        if let last = lastNotifiedAt, now - last < cooldownSeconds { return false }
        return true
    }

    /// Call only when a notification actually reached the user — this is what
    /// starts the cooldown.
    mutating func noteNotified(at now: Double) {
        lastNotifiedAt = now
    }
}
