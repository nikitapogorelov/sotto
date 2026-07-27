import SwiftUI
import KeyboardShortcuts

@main
struct SottoApp: App {
    @StateObject private var store: RecordingStore
    @StateObject private var models: ModelManager
    @StateObject private var recorder: RecordingController
    @StateObject private var iconRenderer: MenuBarIconRenderer
    @StateObject private var callDetector: CallDetector

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        let store = RecordingStore()
        let models = ModelManager()
        let recorder = RecordingController(store: store, models: models)
        let iconRenderer = MenuBarIconRenderer()
        iconRenderer.bind(to: recorder)
        let notifications = NotificationManager()
        notifications.setup()
        let callDetector = CallDetector(recorder: recorder, notifications: notifications)
        callDetector.start()
        _store = StateObject(wrappedValue: store)
        _models = StateObject(wrappedValue: models)
        _recorder = StateObject(wrappedValue: recorder)
        _iconRenderer = StateObject(wrappedValue: iconRenderer)
        _callDetector = StateObject(wrappedValue: callDetector)

        // App-lifetime objects — strong capture is fine.
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in await recorder.toggle() }
        }
    }

    var body: some Scene {
        // First Window scene = the one macOS opens at launch. Until onboarding
        // is completed it immediately yields to the assistant.
        Window("sotto", id: WindowID.transcripts) {
            TranscriptsView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(models)
                .onAppear {
                    guard !hasCompletedOnboarding else { return }
                    openWindow(id: WindowID.onboarding)
                    dismissWindow(id: WindowID.transcripts)
                }
        }
        .defaultSize(width: 780, height: 540)

        // The menu bar mark stays as the quick control.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(recorder)
                .environmentObject(store)
                .environmentObject(models)
        } label: {
            Image(nsImage: iconRenderer.image)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Sotto", id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(recorder)
                .environmentObject(models)
                .environmentObject(iconRenderer)
        }
        .windowResizability(.contentSize)

        Settings {
            SottoSettingsView()
                .environmentObject(models)
                .environmentObject(recorder)
        }
    }
}

enum WindowID {
    static let transcripts = "transcripts"
    static let onboarding = "onboarding"
}
