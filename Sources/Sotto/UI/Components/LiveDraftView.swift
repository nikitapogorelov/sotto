import SwiftUI

/// The live draft transcript while a recording runs. Committed segments render
/// normally; the provisional tail (still being re-transcribed) is dimmed.
/// `compact` shows just the last few lines for the menu bar popover.
struct LiveDraftView: View {
    var compact = false

    @EnvironmentObject private var recorder: RecordingController

    private var visibleSegments: [(offset: Int, segment: TranscriptSegment)] {
        let all = Array(recorder.draft.enumerated())
        guard compact else { return all.map { (offset: $0.offset, segment: $0.element) } }
        return all.suffix(3).map { (offset: $0.offset, segment: $0.element) }
    }

    private func isProvisional(_ index: Int) -> Bool {
        index >= recorder.draft.count - recorder.draftProvisionalCount
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleSegments, id: \.segment) { item in
                    compactRow(item.segment, provisional: isProvisional(item.offset))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleSegments, id: \.segment) { item in
                            SegmentRow(segment: item.segment)
                                .opacity(isProvisional(item.offset) ? 0.45 : 1)
                                .id(item.offset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: recorder.draft.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private func compactRow(_ segment: TranscriptSegment, provisional: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let speaker = segment.speaker {
                Text(speaker.displayName)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.caption)
                .lineLimit(2)
        }
        .opacity(provisional ? 0.45 : 1)
    }
}
