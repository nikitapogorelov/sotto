import SwiftUI
import AppKit

/// Record button, elapsed time, errors, and the model download banner —
/// shared by the menu bar popover and the main window.
struct RecordControls: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var models: ModelManager
    @State private var pressCount = 0

    var body: some View {
        VStack(spacing: 12) {
            recordButton

            if recorder.isRecording {
                Text(RecordingStore.formatDuration(recorder.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let error = recorder.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.sottoRecord)
                    .multilineTextAlignment(.center)
            }

            if let warning = recorder.lastWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if recorder.needsScreenRecordingHint {
                screenRecordingBanner
            }

            if !models.isInstalled {
                modelBanner
            }
        }
    }

    private var recordButton: some View {
        Button {
            pressCount += 1
            Task { await recorder.toggle() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.isRecording ? Color.white : Color.sottoRecord)
                    .frame(width: 10, height: 10)
                    .phaseAnimator([false, true], trigger: pressCount) { view, pulsed in
                        view.scaleEffect(pulsed ? 1.35 : 1)
                    } animation: { _ in SottoMotion.pressSpring }
                Text(recorder.isRecording ? "Stop recording" : "Start recording")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(recorder.isRecording ? .sottoRecord : .sottoAccent)
        .buttonStyle(.borderedProminent)
    }

    private var screenRecordingBanner: some View {
        VStack(spacing: 6) {
            Text("Sotto needs Screen Recording permission to hear system audio (video is discarded).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelBanner: some View {
        VStack(spacing: 6) {
            if models.isDownloading {
                ModelDownloadMark(markWidth: 84)
                Button("Cancel") { models.cancelDownload() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Text("Whisper model not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download \(models.selected.displayName)") {
                    Task { await models.download() }
                }
            }
            if let error = models.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.sottoRecord)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
