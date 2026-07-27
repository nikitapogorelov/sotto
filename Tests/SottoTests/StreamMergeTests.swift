import Testing
@testable import Sotto

struct StreamMergeTests {
    private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test func segmentsBeforeStabilityMarginCommit() {
        let result = StreamMerge.integrate(
            window: [seg(0, 2, "hello"), seg(2.5, 11.5, "still talking")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: StreamMergeState()
        )
        #expect(result.state.committed.map(\.text) == ["hello"])
        #expect(result.state.committedUntil == 2)
        #expect(result.provisional.map(\.text) == ["still talking"])
    }

    @Test func committedSegmentsAreNotRecommittedByLaterWindows() {
        // Window 1: 0–12 s commits "hello" (0–2 s).
        var state = StreamMerge.integrate(
            window: [seg(0, 2, "hello")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: StreamMergeState()
        ).state

        // Window 2: 3–15 s re-transcribes the overlap; the re-heard "hello"
        // starts well behind committedUntil and must be dropped, the new
        // segment commits.
        let result = StreamMerge.integrate(
            window: [seg(-2.95, -1, "hello again"), seg(1, 9, "next phrase")],
            windowStart: 3, windowEnd: 15,
            speaker: .me, into: state
        )
        state = result.state
        #expect(state.committed.map(\.text) == ["hello", "next phrase"])
        #expect(state.committedUntil == 12)
        #expect(result.provisional.isEmpty)
    }

    @Test func provisionalIsReplacedWholesaleEachWindow() {
        let first = StreamMerge.integrate(
            window: [seg(10.5, 11.8, "unstab")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: StreamMergeState()
        )
        #expect(first.provisional.map(\.text) == ["unstab"])

        // Next window re-reads the same speech with more context; it's still
        // inside the new window's stability margin, so it stays provisional —
        // the old provisional text is simply gone.
        let second = StreamMerge.integrate(
            window: [seg(9.5, 11.2, "unstable audio, cleaned up")],
            windowStart: 3, windowEnd: 15,
            speaker: .me, into: first.state
        )
        #expect(second.provisional.map(\.text) == ["unstable audio, cleaned up"])
        #expect(second.state.committed.isEmpty)
    }

    @Test func epsilonToleratesBoundaryJitter() {
        var state = StreamMergeState()
        state.committedUntil = 5.0

        // Starts 0.1 s before the cutoff — within epsilon, so it's new speech
        // with a jittered boundary, not a duplicate.
        let result = StreamMerge.integrate(
            window: [seg(4.9, 7, "boundary")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: state
        )
        #expect(result.state.committed.map(\.text) == ["boundary"])

        // Starts clearly before the cutoff — a re-transcribed duplicate.
        let dup = StreamMerge.integrate(
            window: [seg(4.0, 7, "duplicate")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: state
        )
        #expect(dup.state.committed.isEmpty)
    }

    @Test func committedUntilNeverRegresses() {
        var state = StreamMerge.integrate(
            window: [seg(0, 8, "long")],
            windowStart: 0, windowEnd: 12,
            speaker: .me, into: StreamMergeState()
        ).state
        #expect(state.committedUntil == 8)

        // A later window commits a short segment that ends earlier in call
        // time than the previous commit — the cutoff must not move backwards.
        state = StreamMerge.integrate(
            window: [seg(4.5, 5.0, "short")],
            windowStart: 3, windowEnd: 15,
            speaker: .me, into: state
        ).state
        #expect(state.committedUntil == 8)
    }

    @Test func mergedDraftInterleavesChannelsAndAppendsProvisional() {
        var mic = StreamMergeState()
        mic.committed = [
            TranscriptSegment(start: 0, end: 2, text: "me first", speaker: .me),
            TranscriptSegment(start: 6, end: 8, text: "me later", speaker: .me),
        ]
        var system = StreamMergeState()
        system.committed = [
            TranscriptSegment(start: 3, end: 5, text: "them middle", speaker: .them)
        ]
        let provisional = [
            TranscriptSegment(start: 9, end: 11, text: "them unstable", speaker: .them)
        ]

        let merged = StreamMerge.mergedDraft(mic: mic, system: system, provisional: provisional)
        #expect(merged.map(\.text) == ["me first", "them middle", "me later", "them unstable"])
    }

    @Test func speakerIsTaggedOnIntegration() {
        let result = StreamMerge.integrate(
            window: [seg(0, 2, "hi")],
            windowStart: 0, windowEnd: 12,
            speaker: .them, into: StreamMergeState()
        )
        #expect(result.state.committed.first?.speaker == .them)
    }

    @Test func windowTimestampsShiftIntoCallTime() {
        let result = StreamMerge.integrate(
            window: [seg(1, 3, "shifted")],
            windowStart: 30, windowEnd: 42,
            speaker: .me, into: StreamMergeState()
        )
        #expect(result.state.committed.first?.start == 31)
        #expect(result.state.committed.first?.end == 33)
    }
}
