import Foundation
import UserNotifications
import os

/// Posts recording lifecycle notifications with explicit start/stop actions.
///
/// UNUserNotificationCenter requires a real app bundle — calling it from a
/// bare `swift run` binary crashes — so everything is gated on having a
/// bundle identifier; unbundled runs silently no-op.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "dev.sotto", category: "notifications")

    nonisolated static let callCategoryID = "CALL_DETECTED"
    nonisolated static let startActionID = "START_RECORDING"
    nonisolated static let meetingEndCategoryID = "MEETING_MAY_HAVE_ENDED"
    nonisolated static let stopActionID = "STOP_RECORDING"
    nonisolated static let meetingEndRequestID = "MEETING_MAY_HAVE_ENDED"

    /// Fired on the main actor when the user hits "Start recording".
    var onStartRecording: (() -> Void)?
    /// Fired on the main actor when the user hits "Stop recording".
    var onStopRecording: (() -> Void)?

    private let available = Bundle.main.bundleIdentifier != nil

    /// Register the category/action and take the delegate. Call once at launch.
    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: Self.startActionID,
            title: "Start recording",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.callCategoryID,
            actions: [start],
            intentIdentifiers: [],
            options: []
        )
        let stop = UNNotificationAction(
            identifier: Self.stopActionID,
            title: "Stop recording",
            options: []
        )
        let meetingEndCategory = UNNotificationCategory(
            identifier: Self.meetingEndCategoryID,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category, meetingEndCategory])
    }

    /// Authorization is requested lazily, the first time a call is detected —
    /// the moment the permission prompt actually makes sense to the user.
    func notifyCallDetected(_ subject: CallNotificationSubject) async {
        guard available else { return }
        let center = UNUserNotificationCenter.current()

        let authorization = await center.notificationSettings().authorizationStatus
        Self.logger.info(
            "Call notification authorization status=\(String(describing: authorization), privacy: .public)"
        )

        switch authorization {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            Self.logger.info("Call notification authorization requested; granted=\(granted)")
            guard granted else { return }
        case .denied:
            Self.logger.error("Call notification suppressed: authorization denied")
            return
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = CallNotificationCopy.title(for: subject)
        content.body = CallNotificationCopy.body(for: subject)
        content.categoryIdentifier = Self.callCategoryID
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        do {
            try await center.add(request)
            Self.logger.info("Call notification submitted to Notification Center")
        } catch {
            Self.logger.error(
                "Could not submit call notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Offers to stop after the recorded call source releases its microphone.
    /// The stable identifier replaces an older prompt instead of stacking them.
    func notifyMeetingMayHaveEnded() async {
        guard available else { return }
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        Self.logger.info(
            """
            Meeting-end notification settings \
            authorization=\(String(describing: settings.authorizationStatus), privacy: .public) \
            alert=\(String(describing: settings.alertSetting), privacy: .public) \
            style=\(String(describing: settings.alertStyle), privacy: .public) \
            center=\(String(describing: settings.notificationCenterSetting), privacy: .public) \
            sound=\(String(describing: settings.soundSetting), privacy: .public) \
            timeSensitive=\(String(describing: settings.timeSensitiveSetting), privacy: .public)
            """
        )
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            Self.logger.info("Meeting-end notification authorization requested; granted=\(granted)")
            guard granted else { return }
        case .denied:
            Self.logger.error("Meeting-end notification suppressed: authorization denied")
            return
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = MeetingEndNotificationCopy.title
        content.body = MeetingEndNotificationCopy.body
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = Self.meetingEndCategoryID
        let request = UNNotificationRequest(
            identifier: Self.meetingEndRequestID,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Self.logger.info("Meeting-end notification submitted to Notification Center")
        } catch {
            Self.logger.error(
                "Could not submit meeting-end notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Removes a stale prompt when recording stops by any other route.
    func dismissMeetingEndNotification() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingEndRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingEndRequestID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only explicit actions change recording state; clicking a notification
        // body just opens the app as usual.
        switch response.actionIdentifier {
        case Self.startActionID:
            await MainActor.run { self.onStartRecording?() }
        case Self.stopActionID:
            await MainActor.run { self.onStopRecording?() }
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
