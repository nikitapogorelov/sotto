import Testing
@testable import Sotto

struct CallAppsTests {
    @Test func knownCallAppsMatch() {
        #expect(CallApps.entry(forBundleID: "us.zoom.xos")?.name == "Zoom")
        #expect(CallApps.entry(forBundleID: "com.tinyspeck.slackmacgap")?.name == "Slack")
        #expect(CallApps.entry(forBundleID: "com.microsoft.teams2")?.name == "Microsoft Teams")
        #expect(CallApps.entry(forBundleID: "com.apple.FaceTime")?.name == "FaceTime")
    }

    @Test func helperProcessesResolveToTheirApp() {
        // Electron call apps run audio in helpers, never under the main ID.
        let helper = CallApps.entry(forBundleID: "com.tinyspeck.slackmacgap.helper")
        #expect(helper?.bundleID == "com.tinyspeck.slackmacgap")
    }

    @Test func unknownAppsDoNotMatch() {
        #expect(CallApps.entry(forBundleID: "com.apple.Finder") == nil)
        #expect(CallApps.entry(forBundleID: "com.apple.Safari") == nil)
        #expect(CallApps.entry(forBundleID: "") == nil)
    }
}

struct CallDetectionLogicTests {
    // #expect can't call mutating members inline — results go through lets.

    @Test func risingEdgeNotifiesOnce() {
        var logic = CallDetectionLogic()
        let first = logic.shouldEvaluate(inputRunning: true, at: 100)
        #expect(first)
        logic.noteNotified(at: 100)
        // Property may fire repeatedly while the state stays "in use".
        let second = logic.shouldEvaluate(inputRunning: true, at: 101)
        let third = logic.shouldEvaluate(inputRunning: true, at: 102)
        #expect(!second && !third)
    }

    @Test func fallingEdgeRearmsAfterCooldown() {
        var logic = CallDetectionLogic(cooldownSeconds: 60)
        let first = logic.shouldEvaluate(inputRunning: true, at: 100)
        #expect(first)
        logic.noteNotified(at: 100)
        let falling = logic.shouldEvaluate(inputRunning: false, at: 200)
        #expect(!falling)
        // Cooldown elapsed — the next call notifies again.
        let next = logic.shouldEvaluate(inputRunning: true, at: 300)
        #expect(next)
    }

    @Test func cooldownSuppressesRapidReNotification() {
        var logic = CallDetectionLogic(cooldownSeconds: 60)
        let first = logic.shouldEvaluate(inputRunning: true, at: 100)
        #expect(first)
        logic.noteNotified(at: 100)
        _ = logic.shouldEvaluate(inputRunning: false, at: 110)
        // Flapping device: rising edge again 20 s later — suppressed.
        let flap = logic.shouldEvaluate(inputRunning: true, at: 120)
        #expect(!flap)
        // But re-armed and past cooldown → notify.
        _ = logic.shouldEvaluate(inputRunning: false, at: 130)
        let later = logic.shouldEvaluate(inputRunning: true, at: 161)
        #expect(later)
    }

    @Test func evaluationWithoutNotificationLeavesCooldownUnarmed() {
        var logic = CallDetectionLogic(cooldownSeconds: 60)
        let first = logic.shouldEvaluate(inputRunning: true, at: 100)
        #expect(first)
        // Nothing was shown — e.g. a browser whose window titles named no
        // service and whose audio never sustained. Arming the cooldown here
        // would swallow the notification this very edge is meant to produce.
        _ = logic.shouldEvaluate(inputRunning: false, at: 105)
        let again = logic.shouldEvaluate(inputRunning: true, at: 110)
        #expect(again)
    }

    @Test func ownRecordingSuppressesNotification() {
        var logic = CallDetectionLogic()
        logic.setRecording(true, at: 100)
        let during = logic.shouldEvaluate(inputRunning: true, at: 100.5)
        #expect(!during)
        // Still recording — even later edges stay quiet.
        _ = logic.shouldEvaluate(inputRunning: false, at: 200)
        let later = logic.shouldEvaluate(inputRunning: true, at: 300)
        #expect(!later)
    }

    @Test func edgesNearOwnStopAreSuppressed() {
        var logic = CallDetectionLogic(selfNoiseSeconds: 2)
        logic.setRecording(true, at: 100)
        logic.setRecording(false, at: 200)
        // Our own capture teardown flips the state within the noise window.
        _ = logic.shouldEvaluate(inputRunning: false, at: 200.1)
        let nearStop = logic.shouldEvaluate(inputRunning: true, at: 201)
        #expect(!nearStop)
        // A genuinely later call still notifies.
        _ = logic.shouldEvaluate(inputRunning: false, at: 210)
        let realCall = logic.shouldEvaluate(inputRunning: true, at: 300)
        #expect(realCall)
    }

    @Test func inputAlreadyRunningAtLaunchDoesNotNotify() {
        var logic = CallDetectionLogic(inputInitiallyRunning: true)
        // Repeated "in use" callbacks for the pre-existing state: no edge.
        let preExisting = logic.shouldEvaluate(inputRunning: true, at: 100)
        #expect(!preExisting)
        // The call ends, then a new one starts — that's a real edge.
        _ = logic.shouldEvaluate(inputRunning: false, at: 200)
        let newCall = logic.shouldEvaluate(inputRunning: true, at: 300)
        #expect(newCall)
    }
}
