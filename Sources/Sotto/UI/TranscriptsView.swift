import SwiftUI
import AppKit

struct TranscriptsView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var recorder: RecordingController
    @State private var selection: Recording.ID?

    private var selected: Recording? {
        store.recordings.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(store.recordings, selection: $selection) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.delete(recording) }
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecordControls()
                    .padding(12)
                    .background(.thinMaterial)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if store.recordings.isEmpty {
                    VStack(spacing: 14) {
                        AnimatedBarsMark(phase: BarsMarkPhase.breathing(at:))
                            .frame(width: 88)
                            .opacity(0.3)
                        Text("No recordings yet")
                            .font(.headline)
                        Text("Start one from the menu bar icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } detail: {
            Group {
                if let recording = selected {
                    TranscriptDetail(recording: recording)
                } else if recorder.isRecording {
                    LiveDraftDetail()
                } else {
                    VStack(spacing: 14) {
                        BarsMark()
                            .frame(width: 72)
                            .opacity(0.2)
                        Text("Select a recording")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.sottoPaper)
        }
        .navigationTitle("sotto")
        .sottoWindowStyle()
    }

    /// The mark and wordmark live at the top of the sidebar.
    private var brandHeader: some View {
        HStack(spacing: 9) {
            BarsMark()
                .frame(width: 30)
            Text("sotto")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Detail pane while a recording runs and nothing is selected: header plus
/// the live draft. Disappears on stop, when the normal transcribing flow
/// takes over.
private struct LiveDraftDetail: View {
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.sottoRecord)
                    .frame(width: 8, height: 8)
                Text("Recording now")
                    .font(.headline)
                Text(RecordingStore.formatDuration(recorder.elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            if recorder.draft.isEmpty {
                VStack(spacing: 10) {
                    Text("Listening — the live draft appears here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveDraftView()
            }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(RecordingStore.formatDuration(recording.duration))
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform.badge.magnifyingglass")
                .foregroundStyle(Color.sottoAccent)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.sottoRecord)
        case .recorded:
            Label("Audio only", systemImage: "mic")
        case .done:
            EmptyView()
        }
    }
}

private struct TranscriptDetail: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var models: ModelManager
    let recording: Recording

    private var isTranscribing: Bool { recording.status == .transcribing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let warning = recording.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // A re-run keeps the old transcript on screen while it works,
                // so say what's happening.
                if isTranscribing, recording.transcript != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Re-transcribing…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let transcript = recording.transcript {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { index, segment in
                        // Stagger caps at 20 rows so long transcripts don't
                        // keep late rows invisible for seconds.
                        SegmentRow(
                            segment: segment,
                            appearDelay: min(Double(index) * SottoMotion.segmentStagger, 1.6)
                        )
                    }
                } else if recording.status == .transcribing {
                    VStack(spacing: 12) {
                        AnimatedBarsMark(phase: BarsMarkPhase.transcribing(at:))
                            .frame(width: 88)
                        Text("Transcribing on device…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        Text("Not transcribed yet.")
                            .foregroundStyle(.secondary)
                        Button("Transcribe now") { recorder.transcribe(recording) }
                            .disabled(!models.isInstalled)
                        if !models.isInstalled {
                            Text("Install a model in Settings → Models first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            // Re-create rows per recording so each transcript staggers in on
            // first view; row state then persists, so scrolling never replays.
            .id(recording.id)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(recording.transcript == nil)

                Button {
                    exportMarkdown()
                } label: {
                    Label("Export .md", systemImage: "square.and.arrow.up")
                }
                .disabled(recording.transcript == nil)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)])
                } label: {
                    Label("Reveal audio", systemImage: "folder")
                }

                Button {
                    recorder.transcribe(recording)
                } label: {
                    Label("Re-transcribe", systemImage: "arrow.clockwise")
                }
                .disabled(isTranscribing || !models.isInstalled)
                .help(retranscribeHelp)
            }
        }
    }

    private var retranscribeHelp: String {
        guard let model = models.activeModel else {
            return "Install a model in Settings → Models first"
        }
        return "Transcribe this recording again with \(model.displayName)"
    }

    private func copyToClipboard() {
        guard let transcript = recording.transcript else { return }
        let text = transcript.map { segment in
            (segment.speaker.map { "\($0.displayName): " } ?? "") + segment.text
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.title.replacingOccurrences(of: " ", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.markdown(for: recording).write(to: url, atomically: true, encoding: .utf8)
    }
}
