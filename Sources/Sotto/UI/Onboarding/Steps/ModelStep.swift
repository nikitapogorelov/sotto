import SwiftUI

struct ModelStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @EnvironmentObject private var models: ModelManager

    @State private var completed = false
    @State private var completedState: BarsMarkState = {
        var state = BarsMarkState()
        state.dotColor = .sottoHush
        return state
    }()

    var body: some View {
        VStack(spacing: 14) {
            Text("Transcription model")
                .font(.title2.weight(.semibold))
            Text("\(models.selected.displayName) · about \(models.selected.sizeLabel)")
                .foregroundStyle(Color.sottoHush)

            Spacer()

            if completed {
                BarsMark(state: completedState)
                    .frame(width: 140)
                Text("Model ready")
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            } else if models.isDownloading {
                ModelDownloadMark(markWidth: 140)
                Button("Cancel") { models.cancelDownload() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sottoHush)
            } else {
                Text("Sotto transcribes on this Mac — the model downloads once and stays local.")
                    .font(.callout)
                    .foregroundStyle(Color.sottoHush)
                    .multilineTextAlignment(.center)
                Button(models.error == nil ? "Download" : "Try again") {
                    Task { await models.download() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.sottoAccent)
                .controlSize(.large)
            }

            if let error = models.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.sottoRecord)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(36)
        .onAppear {
            if models.isInstalled { finish(advanceAfter: 1.0) }
        }
        .onChange(of: models.installed) { _, _ in
            if models.isInstalled { finish(advanceAfter: 0.8) }
        }
    }

    /// Show the filled mark, flip the dot from gray to Record with the press
    /// spring, then move on.
    private func finish(advanceAfter delay: TimeInterval) {
        guard !completed else { return }
        completed = true
        withAnimation(SottoMotion.pressSpring) {
            completedState.dotColor = .sottoRecord
            completedState.dotScale = 1.35
        }
        withAnimation(SottoMotion.pressSpring(delay: SottoMotion.enabled ? 0.15 : 0)) {
            completedState.dotScale = 1
        }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            model.advance()
        }
    }
}
