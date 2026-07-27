import Foundation
import Testing
@testable import Sotto

// MARK: - Fixtures

private func proc(
    _ bundleID: String,
    pid: pid_t = 1,
    input: Bool = false,
    output: Bool = false
) -> CallSourceAggregator.RawProcess {
    CallSourceAggregator.RawProcess(
        pid: pid, bundleID: bundleID, inputRunning: input, outputRunning: output
    )
}

private func source(
    _ id: String,
    kind: CallSource.Kind = .app,
    name: String = "Zoom",
    input: Bool = false,
    output: Bool = false
) -> CallSource {
    CallSource(id: id, kind: kind, name: name, inputRunning: input, outputRunning: output)
}

private let zoomBusy = source("us.zoom.xos", input: true, output: true)
private let zoomIdle = source("us.zoom.xos")
private let chromeBusy = source(
    "com.google.Chrome", kind: .browser, name: "Chrome", input: true, output: true
)

// MARK: - Title rules

struct BrowserCallRulesTests {
    @Test func meetingCodeNamesTheService() {
        #expect(BrowserCallRules.service(forTitle: "Meet – abc-defg-hij") == "Google Meet")
        #expect(BrowserCallRules.service(forTitle: "abc-defg-hij - Google Chrome") == "Google Meet")
        #expect(BrowserCallRules.service(forTitle: "Meet") == "Google Meet")
    }

    @Test func codeMustStandAlone() {
        // A hyphen is a word boundary, so \b alone would match the middle of
        // this filename — the rule uses lookarounds instead.
        #expect(BrowserCallRules.service(forTitle: "my-abc-defg-hij-notes") == nil)
        #expect(BrowserCallRules.service(forTitle: "abcd-efgh-ijk") == nil)
        #expect(BrowserCallRules.service(forTitle: "ab-cdef-ghi") == nil)
        #expect(BrowserCallRules.service(forTitle: "123-4567-890") == nil)
    }

    @Test func codeIsCaseSensitive() {
        #expect(BrowserCallRules.service(forTitle: "ABC-DEFG-HIJ") == nil)
    }

    @Test func bareMeetMustBeTheWholeTitle() {
        #expect(BrowserCallRules.service(forTitle: "Meeting notes - Google Docs") == nil)
        #expect(BrowserCallRules.service(forTitle: "Let's Meet - Notes") == nil)
        #expect(BrowserCallRules.service(forTitle: "Meet the Team — Acme") == nil)
        #expect(BrowserCallRules.service(forTitle: "Meet-cute (film) - Wikipedia") == nil)
        #expect(BrowserCallRules.service(forTitle: "Meet: the app") == nil)
        // The landing page isn't a call — joining one adds the code.
        #expect(BrowserCallRules.service(forTitle: "Google Meet: Online Web and Video Conferencing Calls") == nil)
    }

    @Test func ordinaryBrowsingNamesNothing() {
        #expect(BrowserCallRules.service(forTitle: "GitHub - sotto - Google Chrome") == nil)
        #expect(BrowserCallRules.service(forTitle: "") == nil)
    }

    @Test func firstMatchAcrossWindows() {
        let titles = ["Inbox - Gmail", "Meet – abc-defg-hij", "GitHub"]
        #expect(BrowserCallRules.service(inTitles: titles) == "Google Meet")
        #expect(BrowserCallRules.service(inTitles: ["Inbox - Gmail"]) == nil)
        #expect(BrowserCallRules.service(inTitles: []) == nil)
    }
}

// MARK: - Browser candidate lifecycle

struct BrowserCallCandidateTrackerTests {
    @Test func stoppedMicInvalidatesDelayedTitleResult() {
        var tracker = BrowserCallCandidateTracker()
        let token = tracker.begin(chromeBusy)

        tracker.end(chromeBusy.id)

        let delayed = tracker.resolveTitle(
            token,
            service: "Google Meet",
            fallbackEnabled: true
        )
        #expect(delayed == nil)
        #expect(tracker.isEmpty)
    }

    @Test func rapidRestartAcceptsOnlyNewestGeneration() {
        var tracker = BrowserCallCandidateTracker()
        let first = tracker.begin(chromeBusy)
        let second = tracker.begin(chromeBusy)

        let stale = tracker.resolveTitle(
            first,
            service: "Google Meet",
            fallbackEnabled: true
        )
        let current = tracker.resolveTitle(
            second,
            service: "Google Meet",
            fallbackEnabled: true
        )
        let duplicate = tracker.resolveTitle(
            second,
            service: "Google Meet",
            fallbackEnabled: true
        )

        #expect(stale == nil)
        #expect(current == .service(source: chromeBusy, name: "Google Meet"))
        #expect(duplicate == nil)
    }

    @Test func laterExactMatchWorksWithFallbackDisabled() {
        var tracker = BrowserCallCandidateTracker()
        let token = tracker.begin(chromeBusy)

        let backgroundTab = tracker.resolveTitle(
            token,
            service: nil,
            fallbackEnabled: false
        )
        let foregroundMeet = tracker.resolveTitle(
            token,
            service: "Google Meet",
            fallbackEnabled: false
        )

        #expect(backgroundTab == nil)
        #expect(foregroundMeet == .service(source: chromeBusy, name: "Google Meet"))
    }

    @Test func disablingFallbackCancelsOnlyGenericResolution() {
        var tracker = BrowserCallCandidateTracker()
        let token = tracker.begin(chromeBusy)
        _ = tracker.resolveTitle(token, service: nil, fallbackEnabled: true)
        _ = tracker.markFallbackMatured(chromeBusy.id)
        tracker.clearGenericFallback()

        // Even if the setting is enabled again immediately, the old matured
        // fallback must not come back to life without a fresh sustain.
        let cancelledGeneric = tracker.resolveTitle(
            token,
            service: nil,
            fallbackEnabled: true
        )
        let laterExact = tracker.resolveTitle(
            token,
            service: "Google Meet",
            fallbackEnabled: false
        )

        #expect(cancelledGeneric == nil)
        #expect(laterExact == .service(source: chromeBusy, name: "Google Meet"))
    }

    @Test func maturedFallbackClaimsCandidateOnce() {
        var tracker = BrowserCallCandidateTracker()
        let token = tracker.begin(chromeBusy)
        _ = tracker.resolveTitle(token, service: nil, fallbackEnabled: true)
        _ = tracker.markFallbackMatured(chromeBusy.id)

        let generic = tracker.resolveTitle(
            token,
            service: nil,
            fallbackEnabled: true
        )
        let duplicate = tracker.resolveTitle(
            token,
            service: nil,
            fallbackEnabled: true
        )

        #expect(generic == .generic(source: chromeBusy))
        #expect(duplicate == nil)
    }
}

// MARK: - Process aggregation

struct AudioProcessSnapshotTrackerTests {
    @Test func ignoresDuplicateAndReorderedSnapshots() {
        let chrome = proc("com.google.Chrome.helper", pid: 1, input: true)
        let arc = proc("company.thebrowser.browser.helper", pid: 2, output: true)
        var tracker = AudioProcessSnapshotTracker()

        tracker.seed([chrome, arc])

        #expect(tracker.consume([chrome, arc]) == nil)
        #expect(tracker.consume([arc, chrome]) == nil)
    }

    @Test func reportsFlagChangesAndDisappearance() {
        let idle = proc("company.thebrowser.browser.helper", input: false, output: false)
        let busy = proc("company.thebrowser.browser.helper", input: true, output: true)
        var tracker = AudioProcessSnapshotTracker()

        tracker.seed([idle])

        #expect(tracker.consume([busy]) == [busy])
        #expect(tracker.consume([busy]) == nil)
        #expect(tracker.consume([]) == [])
        #expect(tracker.consume([]) == nil)
    }

    @Test func resetAndReseedSuppressesStateAlreadyActiveAtRestart() {
        let idle = proc("company.thebrowser.browser.helper")
        let busy = proc(
            "company.thebrowser.browser.helper",
            input: true,
            output: true
        )
        var tracker = AudioProcessSnapshotTracker()

        tracker.seed([idle])
        #expect(tracker.consume([busy]) == [busy])

        tracker.reset()
        tracker.seed([busy])

        #expect(tracker.consume([busy]) == nil)
        #expect(tracker.consume([idle]) == [idle])
        #expect(tracker.consume([busy]) == [busy])
    }
}

struct CallSourceAggregatorTests {
    @Test func helpersCollapseIntoOneSource() {
        let sources = CallSourceAggregator.sources(from: [
            proc("com.google.Chrome.helper", pid: 1, input: true),
            proc("com.google.Chrome.helper.Renderer", pid: 2),
        ])
        #expect(sources.count == 1)
        #expect(sources.first?.id == "com.google.Chrome")
        #expect(sources.first?.kind == .browser)
        #expect(sources.first?.name == "Chrome")
    }

    @Test func familyMatchIgnoresCase() {
        // Arc ships company.thebrowser.Browser but its helper is
        // company.thebrowser.browser.helper — observed live.
        let sources = CallSourceAggregator.sources(from: [
            proc("company.thebrowser.browser.helper", input: true)
        ])
        #expect(sources.first?.name == "Arc")
    }

    @Test func inputAndOutputMergeAcrossHelpers() {
        // Chromium captures in one helper and plays back in another; only the
        // merged view reads as duplex.
        let sources = CallSourceAggregator.sources(from: [
            proc("com.google.Chrome.helper", pid: 1, input: true),
            proc("com.google.Chrome.helper", pid: 2, output: true),
        ])
        #expect(sources.count == 1)
        #expect(sources.first?.duplex == true)
    }

    @Test func prefixMatchStopsAtComponentBoundary() {
        // A real shipping bundle ID that a raw hasPrefix would fold into Chrome.
        #expect(CallSourceAggregator.family(for: "com.google.chromeremotedesktop") == nil)
    }

    @Test func teamsVariantsStaySeparate() {
        let sources = CallSourceAggregator.sources(from: [
            proc("com.microsoft.teams2", input: true),
            proc("com.microsoft.teams", input: true),
        ])
        #expect(sources.map(\.id) == ["com.microsoft.teams", "com.microsoft.teams2"])
    }

    @Test func unattributableProcessesAreDropped() {
        #expect(CallSourceAggregator.family(for: "") == nil)
        // Safari's audio process is shared with Mail, Notes and every WKWebView
        // host, so it can't be attributed to a browser.
        #expect(CallSourceAggregator.family(for: "com.apple.WebKit.GPU") == nil)
        #expect(CallSourceAggregator.family(for: "com.anthropic.claudefordesktop.helper") == nil)
    }

    @Test func nativeCallAppsAreApps() {
        let sources = CallSourceAggregator.sources(from: [proc("us.zoom.xos", input: true)])
        #expect(sources.first?.kind == .app)
        #expect(sources.first?.name == "Zoom")
    }
}

// MARK: - Duplex sustain

struct DuplexSustainTrackerTests {
    @Test func maturesOnceAfterSustain() {
        var tracker = DuplexSustainTracker(sustainSeconds: 15)
        tracker.observe("chrome", duplex: true, at: 0)
        let early = tracker.matured(at: 5)
        #expect(early.isEmpty)
        let ready = tracker.matured(at: 15)
        #expect(ready == ["chrome"])
        let again = tracker.matured(at: 16)
        #expect(again.isEmpty)
    }

    @Test func brokenDuplexRestartsTheClock() {
        var tracker = DuplexSustainTracker(sustainSeconds: 15)
        tracker.observe("chrome", duplex: true, at: 0)
        tracker.observe("chrome", duplex: false, at: 8)
        tracker.observe("chrome", duplex: true, at: 8)
        let atOriginalDeadline = tracker.matured(at: 15)
        #expect(atOriginalDeadline.isEmpty)
        let atNewDeadline = tracker.matured(at: 23)
        #expect(atNewDeadline == ["chrome"])
    }

    @Test func inputOnlyNeverMatures() {
        var tracker = DuplexSustainTracker(sustainSeconds: 15)
        tracker.observe("chrome", duplex: false, at: 0)
        let ready = tracker.matured(at: 100)
        #expect(ready.isEmpty)
    }

    @Test func forgetResets() {
        var tracker = DuplexSustainTracker(sustainSeconds: 15)
        tracker.observe("chrome", duplex: true, at: 0)
        tracker.forget("chrome")
        let afterForget = tracker.matured(at: 100)
        #expect(afterForget.isEmpty)
        tracker.observe("chrome", duplex: true, at: 100)
        let restarted = tracker.matured(at: 115)
        #expect(restarted == ["chrome"])
    }
}

// MARK: - Per-source coordination

struct CallDetectionCoordinatorTests {
    @Test func cooldownsAreIndependentPerSource() {
        var coordinator = CallDetectionCoordinator(cooldownSeconds: 60)
        let first = coordinator.step(snapshot: [zoomBusy], at: 100).evaluate
        #expect(first.map(\.id) == ["us.zoom.xos"])
        coordinator.noteNotified("us.zoom.xos", at: 100)

        _ = coordinator.step(snapshot: [zoomIdle], at: 105)
        // Zoom is inside its cooldown, but Chrome has one of its own.
        let mixed = coordinator.step(snapshot: [zoomBusy, chromeBusy], at: 110).evaluate
        #expect(mixed.map(\.id) == ["com.google.Chrome"])
    }

    @Test func recordingSuppressesSourcesFirstSeenAfterwards() {
        var coordinator = CallDetectionCoordinator()
        coordinator.setRecording(true, at: 100)
        // Zoom's process object shows up only now — it must still inherit the
        // suppression, or our own capture gets blamed on it.
        let during = coordinator.step(snapshot: [zoomBusy], at: 101).evaluate
        #expect(during.isEmpty)
    }

    @Test func selfNoiseWindowAppliesToNewSources() {
        var coordinator = CallDetectionCoordinator(selfNoiseSeconds: 2)
        coordinator.setRecording(true, at: 100)
        coordinator.setRecording(false, at: 200)
        let nearStop = coordinator.step(snapshot: [zoomBusy], at: 201).evaluate
        #expect(nearStop.isEmpty)

        _ = coordinator.step(snapshot: [zoomIdle], at: 210)
        let realCall = coordinator.step(snapshot: [zoomBusy], at: 300).evaluate
        #expect(realCall.map(\.id) == ["us.zoom.xos"])
    }

    @Test func seedingSilencesCallsAlreadyInProgress() {
        var coordinator = CallDetectionCoordinator()
        coordinator.seed(with: [zoomBusy])
        let atLaunch = coordinator.step(snapshot: [zoomBusy], at: 100).evaluate
        #expect(atLaunch.isEmpty)

        _ = coordinator.step(snapshot: [zoomIdle], at: 110)
        let nextCall = coordinator.step(snapshot: [zoomBusy], at: 120).evaluate
        #expect(nextCall.map(\.id) == ["us.zoom.xos"])
    }

    @Test func departedSourcesAreReported() {
        var coordinator = CallDetectionCoordinator()
        _ = coordinator.step(snapshot: [zoomBusy], at: 100)
        let ended = coordinator.step(snapshot: [], at: 110).ended
        #expect(ended == ["us.zoom.xos"])
    }
}

// MARK: - Notification copy

struct CallNotificationCopyTests {
    @Test func eachSubjectReadsDifferently() {
        let subjects: [CallNotificationSubject] = [
            .app("Zoom"),
            .browserService(browser: "Chrome", service: "Google Meet"),
            .browserUnknown("Chrome"),
        ]
        let bodies = subjects.map(CallNotificationCopy.body(for:))
        #expect(Set(bodies).count == 3)
        #expect(bodies.allSatisfy { !$0.isEmpty })
        #expect(subjects.allSatisfy { !CallNotificationCopy.title(for: $0).isEmpty })
    }

    @Test func genericBrowserCopyNamesNoService() {
        // This path fires on sustained duplex audio alone. Naming a service it
        // never identified would be a lie.
        let body = CallNotificationCopy.body(for: .browserUnknown("Chrome"))
        #expect(body.contains("Chrome"))
        #expect(!body.contains("Meet"))
        #expect(!body.contains("Google"))
    }

    @Test func recognizedServiceLeadsTheTitle() {
        let subject = CallNotificationSubject.browserService(browser: "Chrome", service: "Google Meet")
        #expect(CallNotificationCopy.title(for: subject) == "Google Meet call?")
        #expect(CallNotificationCopy.body(for: subject).contains("Chrome"))
    }
}
