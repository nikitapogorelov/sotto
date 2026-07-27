import SwiftUI
import KeyboardShortcuts

/// The settings pane (app menu → Settings). Onboarding cannot be re-run once
/// completed — permissions are reviewed and re-granted here instead.
struct SottoSettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480)
        .background(Color.sottoPaper)
        .sottoWindowStyle()
    }
}

private struct GeneralTab: View {
    @AppStorage(CallDetector.enabledKey) private var callDetectionEnabled = true
    @AppStorage(CallDetector.browserFallbackKey) private var browserFallbackEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcut")
                .font(.title3.weight(.semibold))
            Text("Start or stop recording from anywhere, even when Sotto is in the background.")
                .font(.callout)
                .foregroundStyle(Color.sottoHush)

            KeyboardShortcuts.Recorder("Start / stop recording", name: .toggleRecording)

            Divider()
                .padding(.vertical, 4)

            Text("Call detection")
                .font(.title3.weight(.semibold))
            Toggle(
                "Notify me when a call starts using the microphone",
                isOn: $callDetectionEnabled
            )
            Text("Works with Zoom, Slack, Teams, FaceTime, Discord, and Webex, plus Google Meet in Chrome, Edge, Brave, Arc, or Vivaldi. Recording never starts on its own — the notification just offers a shortcut.")
                .font(.caption)
                .foregroundStyle(Color.sottoHush)

            Toggle(
                "Also notify for unrecognized browser calls",
                isOn: $browserFallbackEnabled
            )
            .disabled(!callDetectionEnabled)
            Text("Sotto names the service by reading the browser window's title, which only shows the active tab. With this on, a browser that holds the mic and speakers for a while is treated as a call anyway — occasionally that's something else.")
                .font(.caption)
                .foregroundStyle(Color.sottoHush)
        }
        .padding(24)
    }
}

private struct ModelsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcription model")
                .font(.title3.weight(.semibold))
            Text("Transcription runs on this Mac — each model downloads once and stays local.")
                .font(.callout)
                .foregroundStyle(Color.sottoHush)

            ModelsPanel()
        }
        .padding(24)
    }
}

private struct PermissionsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions")
                .font(.title3.weight(.semibold))
            Text("Both are required for recording — your voice and the system audio of the call.")
                .font(.callout)
                .foregroundStyle(Color.sottoHush)

            PermissionsPanel()

            Text("If recording stopped working after an update, remove Sotto from the screen recording list in System Settings and add it back.")
                .font(.caption)
                .foregroundStyle(Color.sottoHush)
        }
        .padding(24)
    }
}
