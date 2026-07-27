import Foundation
import SwiftUI
import AVFoundation
import os

@MainActor
final class RecordingController: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "dev.sotto", category: "recording")
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var activeTranscriptions = 0
    @Published var lastError: String?
    /// Non-fatal issue with the last recording (e.g. one silent track).
    @Published var lastWarning: String?
    /// Shown when system audio looks unobtainable — permission denied outright,
    /// or capture running but silent (macOS 15 "granted but broken" case).
    @Published private(set) var needsScreenRecordingHint = false

    /// Live-draft transcript while recording: committed segments first, then
    /// `draftProvisionalCount` still-unstable ones at the tail (dimmed in UI).
    /// Never persisted — the post-recording full pass is the real transcript.
    @Published private(set) var draft: [TranscriptSegment] = []
    @Published private(set) var draftProvisionalCount = 0

    /// Unified live state for the menu bar icon.
    var activity: AppActivity {
        if isRecording { return .recording }
        return activeTranscriptions > 0 ? .transcribing : .idle
    }

    private let store: RecordingStore
    private let models: ModelManager

    private let systemTap = SystemAudioTap()
    private let micTap = MicTap()

    // Sample accumulation happens off the main thread.
    private let buffers = CaptureBuffers()

    private var tickTimer: Timer?
    private var startedAt: Date?
    private var maxDuration: TimeInterval?
    private var streamTask: Task<Void, Never>?
    /// Recordings with a transcription pass in flight — guards re-entry.
    private var transcribingIDs: Set<Recording.ID> = []

    // Test-drive capture bypasses the store; stop() hands the samples back here.
    private enum CaptureMode { case normal, test }
    private var captureMode: CaptureMode = .normal
    private var testSamples: (mic: [Float], system: [Float])?

    init(store: RecordingStore, models: ModelManager) {
        self.store = store
        self.models = models

        systemTap.onSamples = { [buffers] chunk, hostSeconds in
            buffers.appendSystem(chunk, hostSeconds: hostSeconds)
        }
        micTap.onSamples = { [buffers] chunk, hostSeconds in
            buffers.appendMic(chunk, hostSeconds: hostSeconds)
        }
        systemTap.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = "System audio stopped: \(error.localizedDescription)"
                await self?.stop()
            }
        }
    }

    func toggle() async {
        isRecording ? await stop() : await start()
    }

    func start(maxDuration: TimeInterval? = nil) async {
        lastError = nil
        lastWarning = nil
        needsScreenRecordingHint = false

        guard await MicTap.requestPermission() else {
            lastError = "Microphone access denied. Enable it in System Settings → Privacy & Security."
            return
        }

        do {
            try await beginCapture()
        } catch {
            lastError = "Could not start capture: \(error.localizedDescription)"
            return
        }

        beginTiming(maxDuration: maxDuration)
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        tickTimer?.invalidate()
        tickTimer = nil
        maxDuration = nil

        await systemTap.stop()
        micTap.stop()

        // Wait the streaming session out so its whisper context is freed
        // before the final pass loads its own — never two models in memory.
        streamTask?.cancel()
        await streamTask?.value
        streamTask = nil
        draft = []
        draftProvisionalCount = 0

        let (rawSystem, rawMic, peaks, timing) = buffers.snapshot()

        if captureMode == .test {
            captureMode = .normal
            testSamples = (mic: rawMic, system: rawSystem)
            return
        }

        // Anchor-based alignment: pad the later-starting track and correct
        // clock-rate drift. Falls back to identity when anchors are missing.
        let aligned = DriftAligner.align(
            mic: rawMic, system: rawSystem,
            micTiming: timing.mic, systemTiming: timing.system
        )
        let mic = aligned.mic
        let system = aligned.system
        if aligned.appliedLeadPad != (0, 0) || aligned.appliedRatio != nil {
            Self.logger.info("""
                Drift correction: lead pad mic=\(aligned.appliedLeadPad.mic) \
                system=\(aligned.appliedLeadPad.system) frames, \
                rate ratio \(aligned.appliedRatio.map { String(format: "%.6f", $0) } ?? "n/a")
                """)
        }

        guard !mic.isEmpty || !system.isEmpty else {
            lastError = "Recording was empty."
            return
        }

        // One track silent while the other has signal is the documented
        // failure mode (silent converter output / ducked system capture) —
        // warn instead of silently saving a half-usable recording.
        let micDB = AudioUtil.dbFS(peaks.mic)
        let systemDB = AudioUtil.dbFS(peaks.system)
        var warning: String?
        if micDB < -60, systemDB >= -60 {
            warning = "Your side of the call may be silent — check the microphone input device."
        } else if systemDB < -60, micDB >= -60 {
            warning = "The other side of the call may be silent — check your output device and Screen Recording permission."
            needsScreenRecordingHint = true
        }
        lastWarning = warning

        let duration = Double(max(mic.count, system.count)) / AudioUtil.whisperSampleRate
        var recording = Recording(
            id: UUID(),
            title: Recording.defaultTitle(for: Date()),
            date: startedAt ?? Date(),
            duration: duration,
            status: .transcribing,
            transcript: nil,
            audioFileName: "audio.wav",
            warning: warning
        )

        do {
            let audioURL = store.audioURL(for: recording)
            // Channel order is a contract with transcribe(): 0 = mic (Me), 1 = system (Them).
            try AudioUtil.writeWAV([mic, system], to: audioURL)
            store.add(recording)
        } catch {
            lastError = "Could not save audio: \(error.localizedDescription)"
            return
        }

        guard models.isInstalled else {
            recording.status = .recorded
            store.update(recording)
            lastError = "Saved audio, but no Whisper model installed yet."
            return
        }

        transcribe(recording)
    }

    /// Records for `duration` seconds through the normal pipeline, transcribes
    /// in memory, and reports per-track signal. Nothing is saved to the library.
    func runTestDrive(duration: TimeInterval = 10) async throws -> TestDriveResult {
        guard !isRecording else { throw TestDriveError.busy }
        guard models.isInstalled else { throw TestDriveError.noModel }

        lastError = nil
        guard await MicTap.requestPermission() else { throw TestDriveError.micDenied }

        do {
            try await beginCapture()
        } catch {
            throw TestDriveError.captureFailed(error)
        }

        captureMode = .test
        testSamples = nil
        beginTiming(maxDuration: duration)

        // stop() (auto after `duration`, or the user's own stop) hands the
        // samples back through testSamples.
        while testSamples == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let (mic, system) = testSamples else { throw TestDriveError.busy }
        testSamples = nil

        let micSilent = Self.isNearSilent(mic)
        let systemSilent = Self.isNearSilent(system)
        guard !micSilent || !systemSilent else {
            return TestDriveResult(micSilent: true, systemSilent: true, segments: [])
        }

        guard let modelPath = models.activeModelURL?.path else { throw TestDriveError.noModel }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        let segments = try await Task.detached(priority: .userInitiated) {
            try Self.transcribeChannels(mic: mic, system: system, modelPath: modelPath)
        }.value
        return TestDriveResult(micSilent: micSilent, systemSilent: systemSilent, segments: segments)
    }

    /// Run (or re-run) transcription for an existing recording — after
    /// installing a model, or to redo one with a different model.
    func transcribe(_ recording: Recording) {
        guard let modelPath = models.activeModelURL?.path else { return }
        // Each pass loads its own copy of the model; two at once on the same
        // recording would waste gigabytes and race on the stored result.
        guard transcribingIDs.insert(recording.id).inserted else { return }

        var pending = recording
        pending.status = .transcribing
        store.update(pending)

        activeTranscriptions += 1
        let audioURL = store.audioURL(for: recording)

        Task.detached(priority: .userInitiated) { [store] in
            do {
                let channels = try WAVReader.readChannels16k(url: audioURL)
                let segments: [TranscriptSegment]
                if channels.count >= 2 {
                    // Stereo per-track recording: 0 = mic (Me), 1 = system (Them).
                    segments = try Self.transcribeChannels(
                        mic: channels[0], system: channels[1], modelPath: modelPath
                    )
                } else {
                    // Legacy mono recording: single unlabeled stream.
                    segments = try WhisperTranscriber(modelPath: modelPath)
                        .transcribe(channels.first ?? [])
                }
                await MainActor.run {
                    var done = pending
                    done.status = .done
                    done.transcript = segments
                    store.update(done)
                    self.activeTranscriptions -= 1
                    self.transcribingIDs.remove(pending.id)
                }
            } catch {
                await MainActor.run {
                    // The previous transcript, if any, is left in place —
                    // a failed re-run shouldn't cost the user what they had.
                    var failed = pending
                    failed.status = .failed
                    store.update(failed)
                    self.activeTranscriptions -= 1
                    self.transcribingIDs.remove(pending.id)
                }
            }
        }
    }

    /// Per-track transcription shared by the file path and the test drive.
    /// One transcriber (the model is ~1.6 GB), sequential passes.
    nonisolated static func transcribeChannels(
        mic: [Float], system: [Float], modelPath: String
    ) throws -> [TranscriptSegment] {
        let transcriber = try WhisperTranscriber(modelPath: modelPath)
        var merged: [TranscriptSegment] = []
        for (channel, other, speaker) in [(mic, system, Speaker.me), (system, mic, .them)] {
            // One pass per speech region rather than one over the whole track:
            // Whisper stretches a segment across any silence it is handed, and
            // that segment then sorts ahead of everything the other channel
            // said during the pause.
            // Only the mic can pick the other side up acoustically, so the
            // leakage gate is one-directional.
            let regions = AudioUtil.speechRegions(
                channel, leakageOf: speaker == .me ? other : nil
            )
            for region in regions {
                merged += try transcriber.transcribe(Array(channel[region.range])).map {
                    TranscriptSegment(
                        start: $0.start + region.startSeconds,
                        end: $0.end + region.startSeconds,
                        text: $0.text,
                        speaker: speaker
                    )
                }
            }
        }
        return merged.sorted { $0.start < $1.start }
    }

    private func beginCapture() async throws {
        buffers.reset()
        do {
            try await systemTap.start() // triggers Screen Recording TCC prompt on first run
            try micTap.start()
        } catch {
            await systemTap.stop()
            micTap.stop()
            if case SystemAudioTap.TapError.screenRecordingDenied = error {
                needsScreenRecordingHint = true
            }
            throw error
        }
    }

    private func beginTiming(maxDuration: TimeInterval?) {
        self.maxDuration = maxDuration
        startedAt = Date()
        elapsed = 0
        isRecording = true
        beginStreaming()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                // "Granted but broken" Screen Recording (macOS 15 + ad-hoc
                // signing): capture runs but delivers silence. Peak is a
                // queue-guarded scalar — reading it here is cheap.
                if self.isRecording, self.elapsed >= 5 {
                    self.needsScreenRecordingHint = self.buffers.systemPeak < 0.001 // ≈ −60 dBFS
                }
                if let cap = self.maxDuration, self.elapsed >= cap {
                    await self.stop()
                }
            }
        }
    }

    /// Sliding-window live draft: every ~3 s transcribe the last 12 s of each
    /// channel and publish the merged result. Latest-wins — a slow cycle just
    /// means the next window starts later; capture is never affected. Any
    /// failure disables the draft silently and leaves the recording intact.
    private func beginStreaming() {
        guard captureMode == .normal, streamTask == nil,
              let modelPath = models.activeModelURL?.path else { return }
        let buffers = self.buffers
        streamTask = Task.detached(priority: .utility) { [weak self] in
            let session: StreamingSession
            do {
                session = try StreamingSession(modelPath: modelPath)
            } catch {
                Self.logger.error("Live draft disabled: \(error.localizedDescription)")
                return
            }
            while !Task.isCancelled {
                let cycleStart = ContinuousClock.now
                let tail = buffers.tail(seconds: 12)
                do {
                    let draft = try await session.process(
                        micWindow: tail.mic,
                        micStart: Double(tail.micStartIndex) / AudioUtil.whisperSampleRate,
                        systemWindow: tail.system,
                        systemStart: Double(tail.systemStartIndex) / AudioUtil.whisperSampleRate
                    )
                    guard !Task.isCancelled else { break }
                    await MainActor.run { [weak self] in
                        guard let self, self.isRecording else { return }
                        self.draft = draft.segments
                        self.draftProvisionalCount = draft.provisionalCount
                    }
                } catch {
                    Self.logger.error("Live draft stopped: \(error.localizedDescription)")
                    break
                }
                let elapsed = cycleStart.duration(to: .now)
                if elapsed < .seconds(3) {
                    try? await Task.sleep(for: .seconds(3) - elapsed)
                }
            }
        }
    }

    /// Whisper hallucinates on silence — skip channels with no signal.
    nonisolated static func isNearSilent(_ samples: [Float]) -> Bool {
        samples.allSatisfy { abs($0) < 0.001 }
    }
}

/// Per-track sample accumulation off the main actor. All state is guarded by
/// one serial queue: tap callbacks hop onto it (async — never blocking the
/// audio thread), readers use sync. Running peaks are updated on append so
/// level checks never rescan the arrays.
private final class CaptureBuffers: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sotto.buffers")
    private var system: [Float] = []
    private var mic: [Float] = []
    private var systemPeakValue: Float = 0
    private var micPeakValue: Float = 0
    private var systemTiming = TrackTiming()
    private var micTiming = TrackTiming()

    func appendSystem(_ chunk: [Float], hostSeconds: Double?) {
        queue.async {
            if let hostSeconds {
                self.systemTiming.addAnchor(hostSeconds: hostSeconds, sampleIndex: self.system.count)
            }
            self.system.append(contentsOf: chunk)
            self.systemPeakValue = chunk.reduce(self.systemPeakValue) { max($0, abs($1)) }
        }
    }

    func appendMic(_ chunk: [Float], hostSeconds: Double?) {
        queue.async {
            if let hostSeconds {
                self.micTiming.addAnchor(hostSeconds: hostSeconds, sampleIndex: self.mic.count)
            }
            self.mic.append(contentsOf: chunk)
            self.micPeakValue = chunk.reduce(self.micPeakValue) { max($0, abs($1)) }
        }
    }

    func reset() {
        queue.sync {
            system.removeAll()
            mic.removeAll()
            systemPeakValue = 0
            micPeakValue = 0
            systemTiming = TrackTiming()
            micTiming = TrackTiming()
        }
    }

    /// Cheap scalar read for the live silent-system check.
    var systemPeak: Float {
        queue.sync { systemPeakValue }
    }

    /// The last `seconds` of each track plus where those windows start
    /// (samples from track start) — the live-draft transcription input.
    func tail(seconds: Double) -> (
        mic: [Float], micStartIndex: Int, system: [Float], systemStartIndex: Int
    ) {
        let n = Int(seconds * AudioUtil.whisperSampleRate)
        return queue.sync {
            let micStart = max(0, mic.count - n)
            let systemStart = max(0, system.count - n)
            return (
                mic: Array(mic[micStart...]), micStartIndex: micStart,
                system: Array(system[systemStart...]), systemStartIndex: systemStart
            )
        }
    }

    func snapshot() -> (
        system: [Float], mic: [Float],
        peaks: (system: Float, mic: Float),
        timing: (system: TrackTiming, mic: TrackTiming)
    ) {
        queue.sync {
            (
                system: system, mic: mic,
                peaks: (system: systemPeakValue, mic: micPeakValue),
                timing: (system: systemTiming, mic: micTiming)
            )
        }
    }
}

struct TestDriveResult {
    let micSilent: Bool
    let systemSilent: Bool
    let segments: [TranscriptSegment]

    var verified: Bool { !micSilent && !systemSilent }
}

enum TestDriveError: LocalizedError {
    case busy
    case noModel
    case micDenied
    case captureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A recording is already in progress."
        case .noModel:
            return "The Whisper model is not installed yet."
        case .micDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy & Security."
        case .captureFailed(let error):
            return "Could not start capture: \(error.localizedDescription)"
        }
    }
}

/// Minimal reader for the WAVs we write ourselves
/// (16 kHz PCM16; mono pre-per-track, stereo since).
enum WAVReader {
    /// Returns one Float32 array per channel.
    static func readChannels16k(url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let channelCount = file.processingFormat.channelCount
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        return (0..<Int(channelCount)).map {
            Array(UnsafeBufferPointer(start: channels[$0], count: frameLength))
        }
    }
}
