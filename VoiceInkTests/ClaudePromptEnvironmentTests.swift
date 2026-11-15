// Exercises the pane-scoped local-file decision without opening Claude, changing
// focus, reading a real chat or issuing paste/Return.
import Foundation
import Testing
@testable import VoiceInkPlusPlus

@Suite struct ClaudePromptEnvironmentTests {
    private final class Node {
        let role: String
        let name: String
        weak var parent: Node?
        var children: [Node] = []
        var local = false
        var code = false
        init(_ role: String, _ name: String = "") { self.role = role; self.name = name }
        @discardableResult func add(_ node: Node) -> Node {
            children.append(node); node.parent = self; return node
        }
    }

    private struct Fixture {
        let web = Node("AXWebArea")
        let pane = Node("AXGroup")
        let details = Node("AXGroup", "Session details")
        let environment = Node("AXGroup", "Environment")
        let marker = Node("AXStaticText", "This computer")
        let prompt = Node("AXTextArea", "Prompt")
        init(local: Bool = true) {
            web.code = true
            web.add(pane)
            pane.add(Node("AXToolbar", "Session tools"))
            pane.add(Node("AXGroup", "Chat messages"))
            pane.add(details)
            details.add(environment)
            environment.add(Node("AXGroup")).add(Node("AXButton", "Environment"))
            environment.add(Node("AXGroup")).add(marker)
            marker.local = local
            var ancestor = pane
            for _ in 0..<6 { ancestor = ancestor.add(Node("AXGroup")) }
            ancestor.add(prompt)
        }
        func resolves(from node: Node? = nil, expired: Bool = false) -> Bool {
            ClaudePromptEnvironment.isLocalCode(from: node ?? prompt,
                parent: { $0.parent }, children: { $0.children }, role: { $0.role },
                named: { $0.name == $1 }, localMarker: { $0.local },
                codeDocument: { $0.code }, expired: { expired })
        }
    }

    @Test func measuredLocalCodePaneAcceptsPromptAndConversationFocus() {
        let f = Fixture()
        #expect(f.resolves())
        #expect(f.resolves(from: f.pane.children[1]))
    }

    @Test func cloudAndSSHPanesRemainInlineEvenWithLocalLookingIDsOrSidebarLabels() {
        let f = Fixture(local: false)
        // Both SSH and local sessions have /epitaxy/local_ URLs. The Code URL
        // cannot grant access, and the sidebar's local label is outside the pane.
        f.web.add(Node("AXGroup", "Sidebar")).add(Node("AXStaticText", "This computer")).local = true
        #expect(!f.resolves())
    }

    @Test func anotherLocalSplitPaneCannotAuthorizeTheRemotePane() {
        let remote = Fixture(local: false)
        let local = Fixture()
        remote.web.add(local.pane)
        #expect(!remote.resolves())
        #expect(local.resolves())
    }

    @Test func missingCollapsedOrAmbiguousEnvironmentKeepsCompleteInlineContext() {
        let hidden = Fixture()
        hidden.details.children = []
        #expect(!hidden.resolves())
        let duplicate = Fixture()
        duplicate.details.add(Node("AXGroup", "Environment"))
        #expect(!duplicate.resolves())
        let multipleLabels = Fixture()
        multipleLabels.environment.children[1].add(Node("AXStaticText", "Another host"))
        #expect(!multipleLabels.resolves())
    }

    @Test func ordinaryChatAndCoworkDoNotBecomeLocalCodeBecauseTheySayThisComputer() {
        let chat = Fixture()
        chat.web.code = false
        #expect(!chat.resolves())
        let noCodeToolbar = Fixture()
        noCodeToolbar.pane.children.removeFirst()
        #expect(!noCodeToolbar.resolves())
    }

    @Test func staleOrUnboundedAncestryNeverGrantsLocalFileAccess() {
        let f = Fixture()
        #expect(!f.resolves(expired: true))
        f.prompt.parent = nil
        #expect(!f.resolves())
        let deep = Fixture()
        var last = deep.prompt.parent!
        for _ in 0..<49 { last = last.add(Node("AXGroup")) }
        let distant = last.add(Node("AXTextArea"))
        #expect(!deep.resolves(from: distant))
    }

    @Test func localConfirmationDoesNotPromoteAnyOtherAppToFilePrompts() {
        #expect(AgentFlowPromptPreview.supportsLocalFilePrompt(
            bundleID: ClaudePromptEnvironment.bundleIdentifier, bundleURL: nil, claudeLocalCodeConfirmed: true))
        #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(
            bundleID: ClaudePromptEnvironment.bundleIdentifier, bundleURL: nil))
        for bundle in ["org.telegram.desktop", "com.google.Chrome", "com.apple.Terminal", "unknown"] {
            #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(
                bundleID: bundle, bundleURL: nil, claudeLocalCodeConfirmed: true))
        }
    }
}
