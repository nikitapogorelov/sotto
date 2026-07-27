import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case model
    case testDrive
}

/// Forward-only step machine for the setup assistant.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        withAnimation(SottoMotion.appear) { step = next }
    }
}
