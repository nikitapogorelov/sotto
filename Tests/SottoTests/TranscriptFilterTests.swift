import Testing
@testable import Sotto

struct TranscriptFilterTests {
    @Test func bracketedMarkersDropped() {
        #expect(TranscriptFilter.isHallucination("[Music]"))
        #expect(TranscriptFilter.isHallucination("[BLANK_AUDIO]"))
        #expect(TranscriptFilter.isHallucination("[silence]"))
        #expect(TranscriptFilter.isHallucination("  [no speech]  "))
    }

    @Test func parenthesizedMarkersDropped() {
        #expect(TranscriptFilter.isHallucination("(applause)"))
        #expect(TranscriptFilter.isHallucination("(soft music)"))
        #expect(TranscriptFilter.isHallucination("(inaudible)"))
    }

    @Test func denylistIsCaseInsensitive() {
        #expect(TranscriptFilter.isHallucination("Thank you."))
        #expect(TranscriptFilter.isHallucination("THANK YOU"))
        #expect(TranscriptFilter.isHallucination("Thanks for watching!"))
    }

    @Test func emptyAndWhitespaceDropped() {
        #expect(TranscriptFilter.isHallucination(""))
        #expect(TranscriptFilter.isHallucination("   \n"))
    }

    @Test func realSentencesPass() {
        #expect(!TranscriptFilter.isHallucination("Let's sync on the roadmap tomorrow."))
        #expect(!TranscriptFilter.isHallucination("Can you hear me now?"))
        // "thank you" embedded in an actual sentence must survive.
        #expect(!TranscriptFilter.isHallucination("Thank you for sending the report yesterday."))
        // Brackets that don't enclose the whole segment are real content.
        #expect(!TranscriptFilter.isHallucination("The budget [in USD] looks fine."))
    }
}
