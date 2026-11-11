import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct ClaudeSelectionPromptFocusTests {
    @Test func resolvesStandalonePromptFromChatMessagesWithoutAPaneLabel() {
        let tree = Tree()
        #expect(tree.composer(at: 6) == 8)
    }

    @Test func rejectsOtherControlsAndTheTranscriptWithoutSessionTools() {
        var tree = Tree()
        #expect(tree.composer(at: 9) == nil)
        #expect(tree.composer(at: 8) == nil)
        tree.names[2] = "Different toolbar"
        #expect(tree.composer(at: 6) == nil)
    }

    @Test func excludesSessionDetailsAndRefusesAnAmbiguousPrompt() {
        var tree = Tree()
        tree.edges[1, default: []].append(10)
        tree.names[10] = "Session details"
        tree.edges[10] = [11]
        tree.roles[11] = "AXTextArea"
        tree.names[11] = "Prompt"
        #expect(tree.composer(at: 6) == 8)
        tree.names.removeValue(forKey: 10)
        #expect(tree.composer(at: 6) == nil)
    }

    @Test func abortedSearchReturnsNoPrompt() {
        #expect(Tree().composer(at: 6, expired: true) == nil)
    }

    @Test func liveCaptureCommitsBeforeFocusAndStopCancelsTheAttempt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let capture = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/LiveSelectionCapture.swift"),
                                 encoding: .utf8)
        let commit = try #require(capture.range(of: "self.onCapture(captured.timed"))
        let prepare = try #require(capture.range(of: "await ClaudeSelectionPromptFocus.prepare"))
        let returnToTyping = try #require(capture.range(of: "self.onReturnTypingFocus()",
                                                       range: prepare.upperBound..<capture.endIndex))
        #expect(commit.lowerBound < prepare.lowerBound && prepare.lowerBound < returnToTyping.lowerBound)
        let stop = try #require(capture.range(of: "func stop()"))
        let cancel = try #require(capture.range(of: "captureTask?.cancel()", range: stop.upperBound..<capture.endIndex))
        #expect(cancel.lowerBound < commit.lowerBound)
    }

    private struct Tree {
        var roles = [2: "AXToolbar", 6: "AXStaticText", 8: "AXTextArea", 9: "AXLink"]
        var names = [2: "Session tools", 4: "Chat messages", 8: "Prompt"]
        var edges = [1: [2, 3, 7], 3: [4], 4: [5], 5: [6, 9], 7: [8]]

        func composer(at hit: Int, expired: Bool = false) -> Int? {
            ClaudeSelectionPromptFocus.composer(
                at: hit,
                role: { roles[$0, default: "AXGroup"] },
                named: { names[$0] == $1 },
                parent: { node in edges.first(where: { $0.value.contains(node) })?.key },
                children: { edges[$0, default: []] },
                same: ==,
                expired: { expired }
            )
        }
    }
}
