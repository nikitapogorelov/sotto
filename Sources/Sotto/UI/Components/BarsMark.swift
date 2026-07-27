import SwiftUI

/// Geometry of the Sotto mark (assets/mark.svg), shared by the SwiftUI view and
/// the AppKit menu bar renderer. Unit space is the SVG content box: 110 wide by
/// 76 tall — bars at x 0/24/48/72, width 14; dot center x 101, radius 9;
/// everything vertically centered.
enum BarsMarkGeometry {
    static let heightRatios: [CGFloat] = [1.0, 0.7, 0.45, 0.28]
    static let unitSize = CGSize(width: 110, height: 76)
    static let barWidth: CGFloat = 14
    static let barPitch: CGFloat = 24
    static let dotCenterX: CGFloat = 101
    static let dotRadius: CGFloat = 9
    static let aspect: CGFloat = unitSize.width / unitSize.height

    static func barRect(_ index: Int, in size: CGSize) -> CGRect {
        let scale = size.width / unitSize.width
        let height = unitSize.height * heightRatios[index] * scale
        return CGRect(
            x: CGFloat(index) * barPitch * scale,
            y: (size.height - height) / 2,
            width: barWidth * scale,
            height: height
        )
    }

    static func dotRect(in size: CGSize) -> CGRect {
        let scale = size.width / unitSize.width
        let radius = dotRadius * scale
        return CGRect(
            x: dotCenterX * scale - radius,
            y: size.height / 2 - radius,
            width: radius * 2,
            height: radius * 2
        )
    }
}

/// Everything animatable about the mark, as one value.
struct BarsMarkState: Equatable {
    var barScaleY: [CGFloat] = [1, 1, 1, 1]
    var barOpacity: [Double] = [1, 1, 1, 1]
    var barFill: [CGFloat] = [1, 1, 1, 1]   // bottom-up fill fraction (download progress)
    var barOffsetY: [CGFloat] = [0, 0, 0, 0]
    var dotScale: CGFloat = 1
    var dotOpacity: Double = 1
    var dotColor: Color = .sottoRecord
    var barColor: Color = .sottoInk

    static let idle = BarsMarkState()
}

/// Pure functions of time so the same math drives both the SwiftUI
/// TimelineView loops and the AppKit menu bar timer.
enum BarsMarkPhase {
    /// Soft equalizer: scaleY 0.45–1.0 per bar, staggered; dot pulses red.
    static func recording(at t: TimeInterval) -> BarsMarkState {
        var state = BarsMarkState()
        for i in 0..<4 {
            let phase = (t - Double(i) * SottoMotion.barStagger) / SottoMotion.barOscillation
            state.barScaleY[i] = 0.725 + 0.275 * CGFloat(sin(2 * .pi * phase))
        }
        state.dotColor = .sottoRecord
        state.dotOpacity = 0.625 + 0.375 * sin(2 * .pi * t / SottoMotion.dotPulse)
        return state
    }

    /// Static heights; an opacity highlight (0.35–1.0) travels left to right.
    static func transcribing(at t: TimeInterval) -> BarsMarkState {
        var state = BarsMarkState()
        state.dotColor = .sottoHush
        for i in 0..<4 {
            var p = ((t - Double(i) * SottoMotion.shimmerStagger) / SottoMotion.shimmer)
                .truncatingRemainder(dividingBy: 1)
            if p < 0 { p += 1 }
            let bump = pow(max(0, sin(2 * .pi * p)), 2)
            state.barOpacity[i] = 0.35 + 0.65 * bump
        }
        return state
    }

    /// Whole mark breathes scaleY 0.92–1.0. The view applies the 30% opacity.
    static func breathing(at t: TimeInterval) -> BarsMarkState {
        var state = BarsMarkState()
        let scale = 0.96 + 0.04 * CGFloat(sin(2 * .pi * t / SottoMotion.breathe))
        state.barScaleY = [scale, scale, scale, scale]
        return state
    }

    /// Bars fill bottom-up, 25% of total bytes each; the in-progress bar shimmers.
    static func downloading(fraction: Double, at t: TimeInterval) -> BarsMarkState {
        var state = BarsMarkState()
        state.dotColor = .sottoHush
        for i in 0..<4 {
            state.barFill[i] = CGFloat(min(max(fraction * 4 - Double(i), 0), 1))
        }
        if SottoMotion.enabled, fraction < 1 {
            let current = min(Int(fraction * 4), 3)
            state.barOpacity[current] = 0.55 + 0.45 * sin(2 * .pi * t / SottoMotion.shimmer)
        }
        return state
    }
}

/// The mark as discrete shapes (not Canvas) so per-shape springs and
/// transitions work — onboarding assembly, dot flips, breathing.
struct BarsMark: View {
    var state: BarsMarkState = .idle

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { i in
                    let rect = BarsMarkGeometry.barRect(i, in: size)
                    Capsule()
                        .fill(state.barColor)
                        .frame(width: rect.width, height: rect.height)
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: max(0, rect.height * state.barFill[i]))
                        }
                        .scaleEffect(x: 1, y: state.barScaleY[i], anchor: .center)
                        .opacity(state.barOpacity[i])
                        .offset(x: rect.minX, y: rect.minY + state.barOffsetY[i])
                }
                let dot = BarsMarkGeometry.dotRect(in: size)
                Circle()
                    .fill(state.dotColor)
                    .frame(width: dot.width, height: dot.height)
                    .scaleEffect(state.dotScale)
                    .opacity(state.dotOpacity)
                    .offset(x: dot.minX, y: dot.minY)
            }
        }
        .aspectRatio(BarsMarkGeometry.aspect, contentMode: .fit)
    }
}

/// Loop driver: renders a phase function over time, frozen to a static state
/// under Reduce Motion.
struct AnimatedBarsMark: View {
    let phase: (TimeInterval) -> BarsMarkState
    var reducedState: BarsMarkState = .idle

    @ObservedObject private var motion = MotionMonitor.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: motion.reduceMotion)) { context in
            BarsMark(state: motion.reduceMotion
                ? reducedState
                : phase(context.date.timeIntervalSinceReferenceDate))
        }
    }
}
