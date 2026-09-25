import SwiftUI

struct OnboardingAPIScreen: View {
    @ObservedObject var aiService: AIService

    let contentMaxWidth: CGFloat
    let providerOptions: [AIProvider]
    @Binding var selectedProvider: AIProvider
    let isSelectedProviderVerified: Bool
    let canContinue: Bool
    @Binding var isShowingSkipWarning: Bool
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void
    let onRequestSkip: () -> Void
    let onConfirmSkip: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .api,
            contentMaxWidth: contentMaxWidth
        ) {
            if selectedProvider == .openAI {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Start with GPT Live")
                        .font(.headline)
                    Text("Add your own OpenAI API key for live transcription and optional AI actions. Your key stays in macOS Keychain; OpenAI bills your API account directly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.subheadline)
                }
            }
            AIProviderVerificationCard(
                aiService: aiService,
                providerOptions: providerOptions,
                selectedProvider: $selectedProvider,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: primaryButtonTitle,
                isPrimaryEnabled: isPrimaryEnabled,
                onLeading: onBack,
                onPrimary: primaryAction
            )
        }
        .alert("Skip API setup?", isPresented: $isShowingSkipWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Skip API setup", role: .destructive) {
                onConfirmSkip()
            }
        } message: {
            Text("Enhancement modes and AI actions will stay off. You can always set it up later in the app.")
        }
    }

    private var primaryButtonTitle: String {
        isSelectedProviderVerified ? "Continue" : "Skip API Setup"
    }

    private var isPrimaryEnabled: Bool {
        canContinue || !isSelectedProviderVerified
    }

    private func primaryAction() {
        if isSelectedProviderVerified {
            onContinue()
        } else {
            onRequestSkip()
        }
    }
}
