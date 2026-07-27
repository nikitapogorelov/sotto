import AppKit
import Combine
import SwiftUI

/// Renders the mark into an NSImage for the MenuBarExtra label. MenuBarExtra
/// labels don't run arbitrary SwiftUI animations reliably, so animated states
/// redraw on a ~10 fps timer instead; the timer is stopped whenever the app is
/// idle (or Reduce Motion is on) so the label costs nothing at rest.
@MainActor
final class MenuBarIconRenderer: ObservableObject {
    @Published private(set) var image: NSImage

    private var activity: AppActivity = .idle
    private var flourishUntil: Date?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        image = Self.render(for: .idle, at: 0)
    }

    func bind(to recorder: RecordingController) {
        recorder.$isRecording
            .combineLatest(recorder.$activeTranscriptions)
            .map { isRecording, transcriptions -> AppActivity in
                if isRecording { return .recording }
                return transcriptions > 0 ? .transcribing : .idle
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.setActivity($0) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Briefly runs the recording oscillation to draw the eye to the menu bar
    /// (the popover itself cannot be opened programmatically on macOS 14).
    func flourish(duration: TimeInterval = 1.5) {
        guard SottoMotion.enabled, activity == .idle else { return }
        flourishUntil = Date().addingTimeInterval(duration)
        refresh()
    }

    private func setActivity(_ new: AppActivity) {
        activity = new
        flourishUntil = nil
        refresh()
    }

    /// Activity the label should show right now (a flourish borrows the recording look).
    private var displayActivity: AppActivity {
        if activity == .idle, let until = flourishUntil, until > Date() { return .recording }
        return activity
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        image = Self.render(for: displayActivity, at: Date.timeIntervalSinceReferenceDate)
        guard displayActivity != .idle, SottoMotion.enabled else {
            flourishUntil = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.03
        self.timer = timer
    }

    private func tick() {
        if let until = flourishUntil, until <= Date() {
            flourishUntil = nil
            refresh() // back to idle: renders the static frame and stops the timer
            return
        }
        image = Self.render(for: displayActivity, at: Date.timeIntervalSinceReferenceDate)
    }

    /// Draws bars + dot in template black; the image stays a template except
    /// while recording, where the dot is intentionally the real Record red.
    private static func render(for activity: AppActivity, at t: TimeInterval) -> NSImage {
        let state: BarsMarkState
        if SottoMotion.enabled {
            switch activity {
            case .idle: state = .idle
            case .recording: state = BarsMarkPhase.recording(at: t)
            case .transcribing: state = BarsMarkPhase.transcribing(at: t)
            }
        } else {
            state = .idle // static frames; recording still shows a solid red dot below
        }

        let canvas = NSSize(width: 22, height: 16)
        let markSize = CGSize(width: 18, height: 18 / BarsMarkGeometry.aspect)
        let origin = CGPoint(
            x: (canvas.width - markSize.width) / 2,
            y: (canvas.height - markSize.height) / 2
        )

        let image = NSImage(size: canvas, flipped: false) { _ in
            for i in 0..<4 {
                let rect = BarsMarkGeometry.barRect(i, in: markSize)
                    .offsetBy(dx: origin.x, dy: origin.y)
                let height = rect.height * state.barScaleY[i]
                let scaled = CGRect(
                    x: rect.minX, y: rect.midY - height / 2,
                    width: rect.width, height: height
                )
                NSColor.black.withAlphaComponent(state.barOpacity[i]).setFill()
                NSBezierPath(
                    roundedRect: scaled,
                    xRadius: scaled.width / 2, yRadius: scaled.width / 2
                ).fill()
            }

            let dot = BarsMarkGeometry.dotRect(in: markSize).offsetBy(dx: origin.x, dy: origin.y)
            let dotColor: NSColor = activity == .recording
                ? .sottoRecord.withAlphaComponent(SottoMotion.enabled ? state.dotOpacity : 1)
                : .black.withAlphaComponent(0.55) // Hush weight within a template image
            dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = (activity != .recording)
        return image
    }
}
