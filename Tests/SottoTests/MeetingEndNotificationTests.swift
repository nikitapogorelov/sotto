import Testing
@testable import Sotto

struct MeetingEndNotificationTests {
    @Test func copyIsEnglishAndActionable() {
        #expect(MeetingEndNotificationCopy.title == "Psst… it’s quiet")
        #expect(MeetingEndNotificationCopy.body.contains("meeting"))
        #expect(MeetingEndNotificationCopy.body.contains("stop the recording"))
    }
}
