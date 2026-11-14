import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct ChatGPTVoiceAccessibilityPreparationTests {
    @Test func oneRequestPerProcessBirth() {
        let requests = ChatGPTVoiceAccessibilityRequests()
        let identity = ChatGPTVoiceAccessibilityProcess(pid: 7, launchedAt: Date(timeIntervalSince1970: 100))
        #expect(requests.claim(identity))
        #expect(!requests.claim(identity))
    }

    @Test func reusedPIDWithNewBirthGetsOneNewRequest() {
        let requests = ChatGPTVoiceAccessibilityRequests()
        #expect(requests.claim(.init(pid: 7, launchedAt: Date(timeIntervalSince1970: 100))))
        #expect(requests.claim(.init(pid: 7, launchedAt: Date(timeIntervalSince1970: 101))))
        #expect(!requests.claim(.init(pid: 7, launchedAt: Date(timeIntervalSince1970: 101))))
    }

    @Test func staleProcessCannotDisplaceTheNewerClaim() {
        let requests = ChatGPTVoiceAccessibilityRequests()
        let latest = ChatGPTVoiceAccessibilityProcess(pid: 8, launchedAt: Date(timeIntervalSince1970: 101))
        #expect(requests.claim(latest))
        #expect(!requests.claim(.init(pid: 7, launchedAt: Date(timeIntervalSince1970: 100))))
        #expect(!requests.claim(latest))
    }

    @Test func simultaneousLaunchAndActivationClaimOnlyOnce() async {
        let requests = ChatGPTVoiceAccessibilityRequests()
        let identity = ChatGPTVoiceAccessibilityProcess(pid: 7, launchedAt: Date(timeIntervalSince1970: 100))
        let count = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { requests.claim(identity) } }
            var claims = 0
            for await claimed in group { if claimed { claims += 1 } }
            return claims
        }
        #expect(count == 1)
    }

    @Test func testHostsNeverPrepareTheRealCodexProcess() {
        #expect(ChatGPTVoiceAccessibilityPreparation.isTestHost(environment: ["XCTestConfigurationFilePath": "fixture"], xctestLoaded: false))
        #expect(ChatGPTVoiceAccessibilityPreparation.isTestHost(environment: [:], xctestLoaded: true))
        #expect(!ChatGPTVoiceAccessibilityPreparation.isTestHost(environment: [:], xctestLoaded: false))
    }

    @Test func exposureRemainsSeparateFromCaptureAndCannotChangeFocusOrAudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/ChatGPTVoiceAccessibilityPreparation.swift"), encoding: .utf8)
        let delegate = try String(contentsOf: root.appendingPathComponent("VoiceInk/AppDelegate.swift"), encoding: .utf8)
        #expect(delegate.contains("ChatGPTVoiceAccessibilityPreparation.shared.startForApplication()"))
        #expect(source.contains("SystemChatGPTVoiceMuteTransport.expectedApplication()"))
        #expect(source.contains("speakerShortcutCommand"))
        #expect(source.components(separatedBy: "AXUIElementSetAttributeValue(").count == 2)
        #expect(source.contains("AXManualAccessibility\" as CFString, kCFBooleanTrue"))
        for forbidden in ["AXEnhancedUserInterface\" as", "AXFocused", "AXUIElementPerformAction", "postToPid", ".activate(", "Task.sleep", "Thread.sleep"] {
            #expect(!source.contains(forbidden))
        }
    }
}
