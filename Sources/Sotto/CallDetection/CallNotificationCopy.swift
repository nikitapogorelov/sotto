import Foundation

/// What a detected call turned out to be. Determines the notification wording.
enum CallNotificationSubject: Equatable {
    /// A native call app, e.g. Zoom.
    case app(String)
    /// A recognized service in a browser, e.g. Google Meet in Chrome.
    case browserService(browser: String, service: String)
    /// A browser that has been duplex long enough to look like a call, with no
    /// idea which service. Never names one — see `CallNotificationCopy.body`.
    case browserUnknown(String)
}

enum CallNotificationCopy {
    static func title(for subject: CallNotificationSubject) -> String {
        switch subject {
        case .app, .browserUnknown:
            return "Call started?"
        case .browserService(_, let service):
            return "\(service) call?"
        }
    }

    static func body(for subject: CallNotificationSubject) -> String {
        switch subject {
        case .app(let name):
            return "\(name) appears to be using the microphone."
        case .browserService(let browser, let service):
            return "A \(service) call looks like it's running in \(browser)."
        case .browserUnknown(let browser):
            // Deliberately vague: this path fires on sustained duplex audio
            // alone, so it knows a call is likely but not which one. Guessing
            // a service here would be worse than saying nothing.
            return "\(browser) has been using the mic and speakers for a while — looks like a call."
        }
    }
}

enum MeetingEndNotificationCopy {
    static let title = "Psst… it’s quiet"
    static let body = "It looks like the meeting is over. Want me to stop the recording for you?"
}
