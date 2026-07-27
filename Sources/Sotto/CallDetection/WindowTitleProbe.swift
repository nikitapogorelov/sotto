import Foundation
import CoreGraphics
import ScreenCaptureKit
import os

/// Reads a browser's on-screen window titles — the difference between "Chrome
/// has the microphone" and "you're in a Google Meet".
///
/// Titles are the cheapest window into what a tab is doing. Reading the URL
/// instead would mean the Accessibility permission or per-browser Automation
/// prompts, neither of which Sotto asks for; titles ride on the Screen
/// Recording grant `SystemAudioTap` already needs.
enum WindowTitleProbe {
    private static let logger = Logger(subsystem: "dev.sotto", category: "window-titles")

    /// Titles come back nil without Screen Recording, so check before asking.
    static var isAvailable: Bool { CGPreflightScreenCaptureAccess() }

    /// Titles of the on-screen windows belonging to `root`'s app family.
    ///
    /// Note the asymmetry with audio: the process running the mic is a helper
    /// (`com.google.Chrome.helper`), but windows belong to the *main* browser
    /// process, so the family root matches here directly.
    ///
    /// A browser window's title reflects only its **active tab**, so this is
    /// point-in-time evidence. An empty result means "couldn't tell", never
    /// "not a call" — callers must fall through to the audio heuristic.
    static func titles(forBundleFamily root: String) async -> [String] {
        // SCShareableContent triggers the TCC prompt. Firing that off the back
        // of a stray microphone edge, outside onboarding, would be a lousy way
        // to meet the user.
        guard isAvailable else {
            logger.info("Window titles unavailable: Screen Recording is not granted")
            return []
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            logger.error(
                "Could not read shareable windows: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }

        let titles: [String] = content.windows.compactMap { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier,
                  BundleFamily.contains(bundleID, root: root),
                  let title = window.title,
                  !title.isEmpty
            else { return nil }
            return title
        }
        logger.info(
            "Read \(titles.count) non-empty title(s) for \(root, privacy: .public)"
        )
        return titles
    }
}
