import SwiftUI

/// Model download progress as the mark: bars fill bottom-up, each bar 25% of
/// the total bytes, with the in-progress bar shimmering. Shared by the menu
/// popover banner and onboarding step 3.
struct ModelDownloadMark: View {
    var markWidth: CGFloat = 96

    @EnvironmentObject private var models: ModelManager
    @ObservedObject private var motion = MotionMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: motion.reduceMotion)) { context in
                BarsMark(state: state(at: context.date.timeIntervalSinceReferenceDate))
            }
            .frame(width: markWidth)
            Text(models.downloadStatusText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func state(at t: TimeInterval) -> BarsMarkState {
        if let fraction = models.downloadFraction {
            return BarsMarkPhase.downloading(fraction: fraction, at: t)
        }
        // Server sent no Content-Length — indeterminate, so shimmer all bars.
        var state = motion.reduceMotion ? BarsMarkState() : BarsMarkPhase.transcribing(at: t)
        state.dotColor = .sottoHush
        return state
    }
}
