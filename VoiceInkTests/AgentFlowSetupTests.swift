import Testing
@testable import VoiceInkPlusPlus

struct AgentFlowSetupTests {
    @Test func newSetupUsesGPTLiveWhenOwnOpenAIKeyIsPresent() {
        #expect(StarterModeFactory.recommendedTranscriptionModelName(hasOpenAIKey: true)
                == OpenAITranscriptionConfiguration.liveModelName)
    }

    @Test func newSetupKeepsLocalFallbackWithoutOpenAIKey() {
        #expect(StarterModeFactory.recommendedTranscriptionModelName(hasOpenAIKey: false)
                == "parakeet-tdt-0.6b-v3")
    }
}
