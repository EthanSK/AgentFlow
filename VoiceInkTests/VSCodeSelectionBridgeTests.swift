import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct VSCodeSelectionBridgeTests {
    private let request = VSCodeSelectionBridge.Request(
        nonce: "12345678-1234-1234-1234-123456789012", sourcePID: 42,
        gestureStartedAt: 9000, requestedAt: 10_000
    )

    @Test func vscodeBridgeAcceptsOnlyFreshMatchingGestureAndProcess() {
        func response(nonce: String? = nil, pid: Int32 = 42, time: Double = 9500, text: String = "chosen code") -> VSCodeSelectionBridge.Response {
            .init(version: 1, nonce: nonce ?? request.nonce, sourcePID: pid, changedAt: time, text: text)
        }
        #expect(VSCodeSelectionBridge.validatedText(response(), for: request, now: 10_050) == "chosen code")
        #expect(VSCodeSelectionBridge.validatedText(response(nonce: "old"), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(pid: 43), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: 8000), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: .nan), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: 11_000), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(), for: request, now: 12_000) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(text: " \n"), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(text: String(repeating: "a", count: 8193)), for: request, now: 10_050) == nil)
    }

    @Test func vscodeBridgeDoesNotClaimOtherAppsOrChangeXMLBudget() throws {
        #expect(VSCodeSelectionBridge.supports("com.microsoft.VSCode"))
        #expect(VSCodeSelectionBridge.supports("com.microsoft.VSCodeInsiders"))
        #expect(!VSCodeSelectionBridge.supports("com.google.Chrome"))
        #expect(!VSCodeSelectionBridge.supports(nil))
        let reference = try #require(LiveSelectionReference("let selected = true"))
        #expect(reference.scopedToApplication(name: "Code", bundleID: "com.microsoft.VSCode").preview == reference.preview)
        #expect(LiveSelectionReference.maxSelectionCharacters == 500)
    }
}
