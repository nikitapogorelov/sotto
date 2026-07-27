import Testing
import Foundation
@testable import Sotto

@MainActor
struct StaleStatusRepairTests {
    private func recording(
        _ status: RecordingStatus, transcript: [TranscriptSegment]?
    ) -> Recording {
        Recording(
            id: UUID(),
            title: "Call",
            date: Date(),
            duration: 10,
            status: status,
            transcript: transcript,
            audioFileName: "audio.wav"
        )
    }

    private let segment = TranscriptSegment(start: 0, end: 1, text: "hi", speaker: .me)

    @Test func interruptedFirstPassBecomesAudioOnly() {
        let repaired = RecordingStore.repairingStaleStatus([
            recording(.transcribing, transcript: nil)
        ])
        #expect(repaired.first?.status == .recorded)
    }

    /// A re-run that was cut short still has the transcript it started with.
    @Test func interruptedRerunKeepsItsTranscriptAndStaysDone() throws {
        let repaired = RecordingStore.repairingStaleStatus([
            recording(.transcribing, transcript: [segment])
        ])
        let result = try #require(repaired.first)
        #expect(result.status == .done)
        #expect(result.transcript == [segment])
    }

    @Test func emptyTranscriptIsNotATranscript() {
        let repaired = RecordingStore.repairingStaleStatus([
            recording(.transcribing, transcript: [])
        ])
        #expect(repaired.first?.status == .recorded)
    }

    @Test func settledStatusesAreUntouched() {
        let input = [
            recording(.done, transcript: [segment]),
            recording(.failed, transcript: nil),
            recording(.recorded, transcript: nil),
        ]
        #expect(RecordingStore.repairingStaleStatus(input).map(\.status) == [.done, .failed, .recorded])
    }
}
