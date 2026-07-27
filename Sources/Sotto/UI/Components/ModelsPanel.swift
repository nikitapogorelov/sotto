import SwiftUI

/// One row per Whisper model preset: selection, size/quality blurb, and
/// install state (download / progress / installed + delete). Lives in the
/// Models tab of Settings.
struct ModelsPanel: View {
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(WhisperModel.allCases) { model in
                ModelRow(model: model)
            }

            if let error = models.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.sottoRecord)
            }

            if models.activeModel != models.selected, let active = models.activeModel {
                Text("\(models.selected.displayName) is not installed yet — transcription uses \(active.displayName) until it is.")
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            }
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel

    @EnvironmentObject private var models: ModelManager

    private var isSelected: Bool { models.selected == model }
    private var isDownloading: Bool { models.downloadingModel == model }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                models.selected = model
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.sottoAccent : Color.sottoHush)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(model.displayName)")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.displayName) · \(model.sizeLabel)")
                    .font(.headline)
                Text(model.qualityBlurb)
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            }

            Spacer()

            trailing
        }
        .padding(12)
        .background(Color.sottoInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloading {
            HStack(spacing: 8) {
                if let fraction = models.downloadFraction {
                    ProgressView(value: fraction)
                        .frame(width: 72)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { models.cancelDownload() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        } else if models.isInstalled(model) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.sottoAccent)
                Button {
                    models.delete(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.sottoHush)
                .accessibilityLabel("Delete \(model.displayName)")
            }
        } else {
            Button("Download") {
                Task { await models.download(model) }
            }
            .disabled(models.isDownloading)
        }
    }
}
