import Testing
import Foundation
@testable import VoiceInkPlusPlus

struct AgentFlowSetupTests {
    @Test func publicDisplayNameKeepsStableTechnicalIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("VoiceInk/Info.plist")),
            format: nil
        ) as? [String: Any]
        let project = try String(contentsOf: root.appendingPathComponent("VoiceInk.xcodeproj/project.pbxproj"))
        #expect(info?["CFBundleName"] as? String == "Agent Flow")
        #expect(project.components(separatedBy: "INFOPLIST_KEY_CFBundleDisplayName = \"Agent Flow\";").count == 3)
        // A spelling preference is not a migration: changing either identity would split
        // existing settings, Keychain access, permissions, and release/install paths.
        #expect(project.components(separatedBy: "PRODUCT_NAME = AgentFlow;").count == 3)
        #expect(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = com.ethansk.VoiceInkPlusPlus;").count == 3)
        #expect(AgentFlowResourceURLs.website.path == "/AgentFlow")
    }

    @Test func newSetupUsesGPTLiveWhenOwnOpenAIKeyIsPresent() {
        #expect(StarterModeFactory.recommendedTranscriptionModelName(hasOpenAIKey: true)
                == OpenAITranscriptionConfiguration.liveModelName)
    }

    @Test func newSetupKeepsLocalFallbackWithoutOpenAIKey() {
        #expect(StarterModeFactory.recommendedTranscriptionModelName(hasOpenAIKey: false)
                == "parakeet-tdt-0.6b-v3")
    }
}
