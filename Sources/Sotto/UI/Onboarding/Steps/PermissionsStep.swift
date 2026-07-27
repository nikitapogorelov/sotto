import SwiftUI

struct PermissionsStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @State private var bothGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.weight(.semibold))
            Text("Sotto records your voice and the other side of the call.")
                .foregroundStyle(Color.sottoHush)

            PermissionsPanel { bothGranted = $0 }

            Spacer()

            if !bothGranted {
                Text("Recording will not work until both permissions are granted.")
                    .font(.caption)
                    .foregroundStyle(Color.sottoHush)
            }

            HStack {
                Button("Skip for now") { model.advance() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sottoHush)
                Spacer()
                Button("Continue") { model.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(.sottoAccent)
                    .controlSize(.large)
                    .disabled(!bothGranted)
            }
        }
        .padding(36)
    }
}
