import SwiftUI
import AppKit

/// Every animation duration and curve lives here so motion can be tuned in one place.
enum SottoMotion {
    /// The single Reduce Motion gate. Views and renderers query this (or the
    /// Animation tokens below, which already degrade) — never the raw
    /// accessibility setting.
    static var enabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Durations and staggers, in seconds.
    static let barOscillation = 1.0
    static let barStagger = 0.15
    static let dotPulse = 1.2
    static let shimmer = 1.4
    static let shimmerStagger = 0.2
    static let segmentAppear = 0.5
    static let segmentStagger = 0.08
    static let breathe = 3.0
    static let assembleStagger = 0.12
    static let reducedFade = 0.2

    static var pressSpring: Animation {
        enabled ? .spring(response: 0.35, dampingFraction: 0.6) : .easeOut(duration: reducedFade)
    }

    static func pressSpring(delay: Double) -> Animation {
        enabled ? pressSpring.delay(delay) : pressSpring
    }

    static var appear: Animation {
        .easeOut(duration: enabled ? segmentAppear : reducedFade)
    }

    static func appear(delay: Double) -> Animation {
        enabled ? appear.delay(delay) : appear
    }
}

/// Republishes Reduce Motion changes so looping views pause and resume live.
@MainActor
final class MotionMonitor: ObservableObject {
    static let shared = MotionMonitor()

    @Published private(set) var reduceMotion = !SottoMotion.enabled

    private init() {
        // This notification only arrives via the workspace's own center.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reduceMotion = !SottoMotion.enabled }
        }
    }
}
