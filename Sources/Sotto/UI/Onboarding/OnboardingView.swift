import SwiftUI

struct OnboardingView: View {
    @StateObject private var model = OnboardingModel()

    var body: some View {
        ZStack {
            Color.sottoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                stepIndicator
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 580)
        .sottoWindowStyle()
        .environmentObject(model)
        .onAppear(perform: bringToFront)
    }

    /// Make sure the assistant lands above the main window at launch.
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first {
                $0.identifier?.rawValue.contains(WindowID.onboarding) == true
                    || $0.title == "Welcome to Sotto"
            }?.makeKeyAndOrderFront(nil)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch model.step {
            case .welcome: WelcomeStep()
            case .permissions: PermissionsStep()
            case .model: ModelStep()
            case .testDrive: TestDriveStep()
            }
        }
        .transition(stepTransition)
    }

    private var stepTransition: AnyTransition {
        SottoMotion.enabled
            ? .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
            : .opacity
    }

    /// The mark again: four tiny bars, filled once the step is completed.
    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(indicatorColor(for: step))
                    .frame(width: 4, height: 12)
            }
        }
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private func indicatorColor(for step: OnboardingStep) -> Color {
        if step.rawValue < model.step.rawValue { return .sottoInk }
        if step == model.step { return .sottoInk.opacity(0.35) }
        return .sottoHush.opacity(0.3)
    }
}
