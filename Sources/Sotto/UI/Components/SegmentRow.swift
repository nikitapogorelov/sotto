import SwiftUI

/// One transcript segment line, appearing with the staggered fade-up.
/// `shown` is per-row state, so a row animates once when it first exists and
/// never replays on scroll or unrelated re-renders.
struct SegmentRow: View {
    let segment: TranscriptSegment
    var appearDelay: Double = 0

    @State private var shown = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(RecordingStore.formatTimestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let speaker = segment.speaker {
                Text(speaker.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .textSelection(.enabled)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            withAnimation(SottoMotion.appear(delay: appearDelay)) { shown = true }
        }
    }
}
