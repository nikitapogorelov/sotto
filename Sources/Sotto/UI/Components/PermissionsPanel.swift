import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// Microphone and screen recording rows with live status polling and grant
/// actions. Shared by the onboarding permissions step and the settings pane.
struct PermissionsPanel: View {
    /// Reports `micGranted && screenGranted` whenever it changes.
    var onStatusChange: ((Bool) -> Void)?

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var screenProbeFailed = false

    /// Survives the relaunch that a screen recording grant usually requires,
    /// so the panel can silently re-probe instead of waiting for another tap.
    @AppStorage("screenPermissionRequested") private var screenPermissionRequested = false

    private var bothGranted: Bool { micGranted && screenGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionRow(
                icon: "mic",
                title: "Microphone",
                explanation: "records your side of the call",
                granted: micGranted
            ) {
                _ = await MicTap.requestPermission()
                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            }

            PermissionRow(
                icon: "display",
                title: "Screen recording",
                explanation: "unlocks system audio — Sotto discards the video",
                granted: screenGranted
            ) {
                screenPermissionRequested = true
                await probeScreenAccess()
            }

            if screenProbeFailed && !screenGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Open System Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        NSWorkspace.shared.open(url)
                    }
                    Text("If Sotto is not listed, click the plus button and add it manually. You may need to quit and reopen Sotto after granting.")
                        .font(.caption)
                        .foregroundStyle(Color.sottoHush)
                }
            }
        }
        .onChange(of: bothGranted) { _, granted in onStatusChange?(granted) }
        .task {
            // After the relaunch a screen recording grant usually needs,
            // preflight can stay false for ad-hoc builds — re-probe silently
            // (no prompt reappears once the user has answered it).
            if screenPermissionRequested && !screenGranted {
                await probeScreenAccess()
            }
            onStatusChange?(bothGranted)
            // Poll while visible — a grant made in System Settings lands
            // without any button press. Never downgrade a grant a successful
            // probe has already proven.
            while !Task.isCancelled {
                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if CGPreflightScreenCaptureAccess() { screenGranted = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Probing shareable content triggers the TCC prompt on first ask; once
    /// answered it succeeds or throws silently. Success is the ground truth —
    /// preflight false-negatives on ad-hoc signed builds.
    private func probeScreenAccess() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            screenGranted = true
        } catch {
            screenProbeFailed = true
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let explanation: String
    let granted: Bool
    let request: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.sottoAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.sottoAccent)
                    .transition(
                        SottoMotion.enabled ? .scale.combined(with: .opacity) : .opacity
                    )
            } else {
                Button("Allow") { Task { await request() } }
            }
        }
        .animation(SottoMotion.pressSpring, value: granted)
        .padding(12)
        .background(Color.sottoInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
