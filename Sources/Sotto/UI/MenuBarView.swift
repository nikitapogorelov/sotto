import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var models: ModelManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            RecordControls()

            if recorder.isRecording && !recorder.draft.isEmpty {
                LiveDraftView(compact: true)
            }

            Divider()

            Button {
                openWindow(id: WindowID.transcripts)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Sotto (\(store.recordings.count))", systemImage: "text.quote")
                    .frame(maxWidth: .infinity)
            }

            Button("Quit Sotto") {
                NSApp.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
    }
}
