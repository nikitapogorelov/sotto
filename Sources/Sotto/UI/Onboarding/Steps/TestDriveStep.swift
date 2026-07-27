import SwiftUI

struct TestDriveStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var iconRenderer: MenuBarIconRenderer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private enum Phase {
        case ready
        case recording
        case transcribing
        case verdict(TestDriveResult)
        case failed(String)
    }

    @State private var phase: Phase = .ready

    var body: some View {
        VStack(spacing: 14) {
            Text("Test drive")
                .font(.title2.weight(.semibold))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button("Finish") { finish() }
                .buttonStyle(.borderedProminent)
                .tint(.sottoAccent)
                .controlSize(.large)
            Text("Sotto lives in your menu bar — click the mark to start recording.")
                .font(.caption)
                .foregroundStyle(Color.sottoHush)
        }
        .padding(36)
        .onChange(of: recorder.isRecording) { _, isRecording in
            if case .recording = phase, !isRecording { phase = .transcribing }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            VStack(spacing: 10) {
                Text("Say something — Sotto will record 10 seconds and transcribe it.")
                    .multilineTextAlignment(.center)
                Text("Play any sound too — music, a video — so the system audio path gets exercised.")
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
                    .multilineTextAlignment(.center)
                if !models.isInstalled {
                    Text("The test needs the model from the previous step to transcribe.")
                        .font(.caption)
                        .foregroundStyle(Color.sottoRecord)
                }
                Button("Start test") { startTest() }
                    .buttonStyle(.borderedProminent)
                    .tint(.sottoAccent)
                    .controlSize(.large)
                    .disabled(!models.isInstalled)
                    .padding(.top, 8)
            }
        case .recording:
            VStack(spacing: 12) {
                AnimatedBarsMark(
                    phase: BarsMarkPhase.recording(at:),
                    reducedState: .idle
                )
                .frame(width: 140)
                Text("\(max(0, Int((10 - recorder.elapsed).rounded(.up))))s")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(Color.sottoHush)
            }
        case .transcribing:
            VStack(spacing: 12) {
                AnimatedBarsMark(phase: BarsMarkPhase.transcribing(at:))
                    .frame(width: 140)
                Text("Transcribing on device…")
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            }
        case .verdict(let result):
            verdictView(result)
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .foregroundStyle(Color.sottoRecord)
                    .multilineTextAlignment(.center)
                Button("Run again") { phase = .ready }
            }
        }
    }

    @ViewBuilder
    private func verdictView(_ result: TestDriveResult) -> some View {
        if result.verified {
            VStack(alignment: .leading, spacing: 10) {
                Label("Pipeline verified", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                            SegmentRow(
                                segment: segment,
                                appearDelay: Double(index) * SottoMotion.segmentStagger
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(Color.sottoInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if result.micSilent {
                    Label(
                        "The microphone track was silent. Check your input device in System Settings → Sound.",
                        systemImage: "mic.slash"
                    )
                }
                if result.systemSilent {
                    Label(
                        "No system audio was captured. Check the screen recording permission and your output device.",
                        systemImage: "speaker.slash"
                    )
                    Text("If the permission looks granted, remove Sotto from the screen recording list and add it back — a rebuilt copy loses the grant even though it still shows as allowed.")
                        .font(.caption)
                        .foregroundStyle(Color.sottoHush)
                }
                Button("Run again") { phase = .ready }
                    .frame(maxWidth: .infinity)
            }
            .font(.callout)
        }
    }

    private func startTest() {
        phase = .recording
        Task {
            do {
                let result = try await recorder.runTestDrive(duration: 10)
                phase = .verdict(result)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
        openWindow(id: WindowID.transcripts)
        iconRenderer.flourish()
    }
}
