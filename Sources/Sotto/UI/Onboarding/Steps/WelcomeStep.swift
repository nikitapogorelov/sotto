import SwiftUI

struct WelcomeStep: View {
    @EnvironmentObject private var model: OnboardingModel

    @State private var markState: BarsMarkState = {
        var state = BarsMarkState()
        state.barOpacity = [0, 0, 0, 0]
        state.barOffsetY = [10, 10, 10, 10]
        state.dotOpacity = 0
        state.dotScale = 0.4
        return state
    }()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            BarsMark(state: markState)
                .frame(width: 150)

            Text("sotto")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .padding(.top, 28)

            Text("no cloud. no drivers. yours.")
                .font(.callout)
                .foregroundStyle(Color.sottoHush)
                .padding(.top, 6)

            Spacer()

            Button("Get started") { model.advance() }
                .buttonStyle(.borderedProminent)
                .tint(.sottoAccent)
                .controlSize(.large)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
        .onAppear(perform: assemble)
    }

    /// Shapes fade up in sequence; the dot lands last with the press spring.
    private func assemble() {
        for i in 0..<4 {
            withAnimation(SottoMotion.appear(delay: Double(i) * SottoMotion.assembleStagger)) {
                markState.barOpacity[i] = 1
                markState.barOffsetY[i] = 0
            }
        }
        let dotDelay = SottoMotion.enabled ? 4 * SottoMotion.assembleStagger + 0.1 : 0
        withAnimation(SottoMotion.pressSpring(delay: dotDelay)) {
            markState.dotOpacity = 1
            markState.dotScale = 1
        }
    }
}
