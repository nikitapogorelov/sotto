import Foundation
import Combine
import os

/// Watches which processes are running microphone input and, when one of them
/// looks like a call, posts a notification offering to start recording.
/// Never auto-starts.
///
/// Attribution is per-process (`AudioProcessMonitor`), so "the mic is busy and
/// Zoom happens to be open" is no longer enough — the audio has to be Zoom's.
/// Browsers take more than that again: either a window title names the service
/// (`BrowserCallRules`) or the browser holds mic and speakers long enough to
/// give itself away (`DuplexSustainTracker`).
@MainActor
final class CallDetector: ObservableObject {
    private static let logger = Logger(subsystem: "dev.sotto", category: "call-detection")
    static let enabledKey = "callDetectionEnabled"
    static let browserFallbackKey = "browserCallFallbackEnabled"

    /// How often to re-check titles and the duplex sustain. The timer only runs
    /// while at least one active browser microphone session is unresolved.
    private static let browserTickSeconds: TimeInterval = 5

    private let notifications: NotificationManager
    private let processes = AudioProcessMonitor()
    private var coordinator = CallDetectionCoordinator()
    private var sustain = DuplexSustainTracker()
    private var browserCandidates = BrowserCallCandidateTracker()

    private struct TitleProbe {
        let token: BrowserCallCandidateTracker.Token
        let task: Task<Void, Never>
    }

    /// At most one ScreenCaptureKit read per browser. Its token prevents a late
    /// result from clearing or resolving a newer microphone session.
    private var titleProbes: [String: TitleProbe] = [:]
    private var browserTimer: Timer?
    private var recording = false
    /// Call sources whose microphone was active at any point in this recording.
    /// A stable transition of all of them to inactive means the call likely ended.
    private var recordingCallSourceIDs: Set<String> = []
    private var meetingEndTask: Task<Void, Never>?
    private var meetingEndPromptShown = false
    private var cancellables: Set<AnyCancellable> = []

    /// Off switch lives in Settings → General (defaults to on). Also gated on
    /// onboarding — no call notifications before permissions are sorted out.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
            && (UserDefaults.standard.object(forKey: enabledKey) == nil
                || UserDefaults.standard.bool(forKey: enabledKey))
    }

    /// The unnamed-browser-call path, separately switchable: it runs on audio
    /// shape alone, so it's the one that can misfire (dictating in one tab
    /// while a video plays in another looks identical).
    static var isBrowserFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: browserFallbackKey) == nil
            || UserDefaults.standard.bool(forKey: browserFallbackKey)
    }

    init(recorder: RecordingController, notifications: NotificationManager) {
        self.notifications = notifications

        notifications.onStartRecording = { [weak recorder] in
            guard let recorder, !recorder.isRecording else { return }
            Task { await recorder.start() }
        }
        notifications.onStopRecording = { [weak recorder] in
            guard let recorder, recorder.isRecording else { return }
            Task { await recorder.stop() }
        }

        // Sotto's own capture runs mic input like anything else — teach the
        // debounce about it so we never notify on ourselves.
        recorder.$isRecording
            .sink { [weak self] recording in
                self?.recordingChanged(recording)
            }
            .store(in: &cancellables)

        // @AppStorage writes through UserDefaults. Observe those writes so
        // switching detection or its generic fallback off invalidates pending
        // work immediately rather than waiting for the next five-second tick.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.detectionSettingsChanged()
            }
            .store(in: &cancellables)
    }

    func start() {
        processes.onChange = { [weak self] raw in
            self?.processesChanged(raw)
        }
        guard processes.start() else { return }
        // Seed from the state at launch: a call already in progress never
        // produced a rising edge, so it shouldn't produce a notification.
        let seeded = CallSourceAggregator.sources(from: processes.snapshot())
        coordinator.seed(with: seeded)
        let browsers = Self.browserStateDescription(seeded)
        Self.logger.info("Seeded call detector; browsers=\(browsers, privacy: .public)")
    }

    func stop() {
        processes.stop()
        resetBrowserDetection()
    }

    // MARK: - Detection

    private func processesChanged(
        _ raw: [CallSourceAggregator.RawProcess],
        recheckTitles: Bool = false
    ) {
        let now = Self.now()
        let sources = CallSourceAggregator.sources(from: raw)
        let browsers = Self.browserStateDescription(sources)
        let origin = recheckTitles ? "timer" : "audio-event"
        Self.logger.info(
            "Browser snapshot origin=\(origin, privacy: .public) states=\(browsers, privacy: .public)"
        )

        // Step the state machine even when detection is switched off, so
        // toggling it back on doesn't fire on a call that started meanwhile.
        let (evaluate, ended) = coordinator.step(snapshot: sources, at: now)

        for id in ended {
            sustain.forget(id)
            endBrowserCandidate(id)
        }
        for source in sources where source.kind == .browser {
            sustain.observe(source.id, duplex: source.duplex, at: now)
            if !source.inputRunning {
                endBrowserCandidate(source.id)
            }
        }

        if recording {
            observeRecordedCallSources(sources)
        }

        guard Self.isEnabled, !recording else {
            // Switched off or recording started mid-read: cancel every token so
            // an already-running title probe cannot notify when it returns.
            resetBrowserDetection()
            return
        }

        if !Self.isBrowserFallbackEnabled {
            clearGenericFallback()
        }

        for source in evaluate {
            switch source.kind {
            case .app:
                notify(.app(source.name), for: source, at: now)
            case .browser:
                evaluateBrowser(source)
            }
        }

        matureBrowserCalls(at: now)

        if recheckTitles {
            // Exact recognition remains active even when the generic audio
            // fallback is off. This catches a Meet tab brought to the front
            // after the microphone's original rising edge.
            for id in browserCandidates.ids {
                requestTitleProbe(for: id)
            }
        }
        updateBrowserTimer()
    }

    /// Browser mic use is ambiguous on its own, so it has to earn a
    /// notification. Window titles are the strong signal: a Meet code in a
    /// title is about as unambiguous as this gets.
    private func evaluateBrowser(_ source: CallSource) {
        cancelTitleProbe(for: source.id)
        let token = browserCandidates.begin(source)
        Self.logger.info(
            "Browser candidate started id=\(source.id, privacy: .public) generation=\(token.generation)"
        )
        requestTitleProbe(token)
        updateBrowserTimer()
    }

    /// Browsers that have now held mic and speakers long enough to look like a
    /// call despite telling us nothing.
    private func matureBrowserCalls(at now: Double) {
        guard Self.isBrowserFallbackEnabled else { return }

        for id in sustain.matured(at: now) {
            // Always take one more look at the titles before using generic copy.
            // If a regular re-check is already in flight, its token carries the
            // matured flag and will make the same exact-vs-generic decision.
            guard let token = browserCandidates.markFallbackMatured(id) else { continue }
            Self.logger.info(
                "Browser fallback matured id=\(id, privacy: .public) generation=\(token.generation)"
            )
            requestTitleProbe(token)
        }
    }

    private func notify(_ subject: CallNotificationSubject, for source: CallSource, at now: Double) {
        coordinator.noteNotified(source.id, at: now)
        Self.logger.info("Call detected in \(source.name, privacy: .public) — notifying")
        Task { await notifications.notifyCallDetected(subject) }
    }

    // MARK: - Browser candidate lifecycle

    private func requestTitleProbe(for id: String) {
        guard let token = browserCandidates.token(for: id) else { return }
        requestTitleProbe(token)
    }

    private func requestTitleProbe(_ token: BrowserCallCandidateTracker.Token) {
        guard browserCandidates.isCurrent(token), titleProbes[token.id] == nil else { return }

        let task = Task { [weak self] in
            Self.logger.info(
                "Reading browser titles id=\(token.id, privacy: .public) generation=\(token.generation)"
            )
            let titles = await WindowTitleProbe.titles(forBundleFamily: token.id)
            guard !Task.isCancelled else { return }
            self?.titleProbeFinished(titles, token: token)
        }
        titleProbes[token.id] = TitleProbe(token: token, task: task)
    }

    private func titleProbeFinished(
        _ titles: [String],
        token: BrowserCallCandidateTracker.Token
    ) {
        // A stale read must not clear the in-flight marker of a newer token.
        guard titleProbes[token.id]?.token == token else { return }
        titleProbes[token.id] = nil

        guard browserCandidates.isCurrent(token),
              Self.isEnabled,
              !recording,
              let liveSource = liveBrowserSource(token.id),
              liveSource.inputRunning
        else {
            endBrowserCandidate(token.id)
            return
        }

        let service = BrowserCallRules.service(inTitles: titles)
        let serviceDescription = service ?? "none"
        Self.logger.info(
            "Browser titles resolved id=\(token.id, privacy: .public) generation=\(token.generation) count=\(titles.count) service=\(serviceDescription, privacy: .public)"
        )

        let resolution = browserCandidates.resolveTitle(
            token,
            service: service,
            fallbackEnabled: Self.isBrowserFallbackEnabled
        )

        switch resolution {
        case .service(_, let service):
            finishBrowserCandidate(
                token,
                subject: .browserService(browser: liveSource.name, service: service),
                source: liveSource
            )
        case .generic:
            finishBrowserCandidate(
                token,
                subject: .browserUnknown(liveSource.name),
                source: liveSource
            )
        case nil:
            updateBrowserTimer()
        }
    }

    /// Re-reads CoreAudio before claiming an asynchronous result. This closes
    /// the gap where the mic stopped but its callback is still queued behind the
    /// ScreenCaptureKit task on the main actor.
    private func liveBrowserSource(_ id: String) -> CallSource? {
        CallSourceAggregator.sources(from: processes.snapshot()).first {
            $0.id == id && $0.kind == .browser
        }
    }

    private func finishBrowserCandidate(
        _ token: BrowserCallCandidateTracker.Token,
        subject: CallNotificationSubject,
        source: CallSource
    ) {
        // `resolveTitle` already claimed this token atomically. Cleaning the
        // remaining runtime state before notifying prevents a parallel path
        // from producing a second notification.
        cancelTitleProbe(for: token.id)
        sustain.forget(token.id)
        updateBrowserTimer()
        notify(subject, for: source, at: Self.now())
    }

    private func endBrowserCandidate(_ id: String) {
        browserCandidates.end(id)
        cancelTitleProbe(for: id)
        sustain.forget(id)
        updateBrowserTimer()
    }

    private func cancelTitleProbe(for id: String) {
        titleProbes[id]?.task.cancel()
        titleProbes[id] = nil
    }

    private func resetBrowserDetection() {
        for probe in titleProbes.values {
            probe.task.cancel()
        }
        titleProbes.removeAll()
        browserCandidates.removeAll()
        sustain.removeAll()
        browserTimer?.invalidate()
        browserTimer = nil
    }

    private func clearGenericFallback() {
        browserCandidates.clearGenericFallback()
        // Re-enabling fallback during the same microphone session starts a new
        // full 15-second sustain instead of reviving an old matured candidate.
        sustain.removeAll()
    }

    private func recordingChanged(_ isRecording: Bool) {
        recording = isRecording
        coordinator.setRecording(isRecording, at: Self.now())
        if isRecording {
            resetBrowserDetection()
            recordingCallSourceIDs = Set(
                CallSourceAggregator.sources(from: processes.snapshot())
                    .filter(\.inputRunning)
                    .map(\.id)
            )
            meetingEndPromptShown = false
            meetingEndTask?.cancel()
            meetingEndTask = nil
        } else {
            recordingCallSourceIDs.removeAll()
            meetingEndPromptShown = false
            meetingEndTask?.cancel()
            meetingEndTask = nil
            notifications.dismissMeetingEndNotification()
        }
    }

    /// Tracks the call app/browser independently of recorded audio. A falling
    /// microphone flag is the same CoreAudio signal used to detect call start;
    /// a short grace period filters device handoffs and transient flag flaps.
    private func observeRecordedCallSources(_ sources: [CallSource]) {
        let activeIDs = Set(sources.filter(\.inputRunning).map(\.id))
        recordingCallSourceIDs.formUnion(activeIDs)
        guard !recordingCallSourceIDs.isEmpty else { return }

        if !recordingCallSourceIDs.isDisjoint(with: activeIDs) {
            meetingEndTask?.cancel()
            meetingEndTask = nil
            if meetingEndPromptShown {
                meetingEndPromptShown = false
                notifications.dismissMeetingEndNotification()
            }
            return
        }

        guard meetingEndTask == nil, !meetingEndPromptShown else { return }
        meetingEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.verifyRecordedCallEnded()
        }
    }

    private func verifyRecordedCallEnded() {
        meetingEndTask = nil
        guard recording, !meetingEndPromptShown, !recordingCallSourceIDs.isEmpty else { return }

        let activeIDs = Set(
            CallSourceAggregator.sources(from: processes.snapshot())
                .filter(\.inputRunning)
                .map(\.id)
        )
        recordingCallSourceIDs.formUnion(activeIDs)
        guard recordingCallSourceIDs.isDisjoint(with: activeIDs) else { return }

        meetingEndPromptShown = true
        Self.logger.info("Recorded call source became inactive — notifying")
        Task { await notifications.notifyMeetingMayHaveEnded() }
    }

    private func detectionSettingsChanged() {
        guard Self.isEnabled else {
            resetBrowserDetection()
            return
        }
        if !Self.isBrowserFallbackEnabled {
            clearGenericFallback()
        }
        updateBrowserTimer()
    }

    // MARK: - Browser timer

    /// Both title changes and duplex maturity happen without a CoreAudio edge,
    /// so unresolved active candidates share one lightweight timer.
    private func updateBrowserTimer() {
        guard !browserCandidates.isEmpty else {
            browserTimer?.invalidate()
            browserTimer = nil
            return
        }
        guard browserTimer == nil else { return }

        browserTimer = Timer.scheduledTimer(
            withTimeInterval: Self.browserTickSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.processesChanged(
                    self.processes.snapshot(),
                    recheckTitles: true
                )
            }
        }
    }

    private static func now() -> Double {
        Date().timeIntervalSinceReferenceDate
    }

    private static func browserStateDescription(_ sources: [CallSource]) -> String {
        let states = sources
            .filter { $0.kind == .browser }
            .map { "\($0.name):input=\($0.inputRunning),output=\($0.outputRunning)" }
        return states.isEmpty ? "none" : states.joined(separator: ";")
    }
}
