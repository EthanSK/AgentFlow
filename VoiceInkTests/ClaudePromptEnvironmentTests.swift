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
        var mainDocument = false
        init(_ role: String, _ name: String = "") { self.role = role; self.name = name }
        @discardableResult func add(_ node: Node) -> Node {
            children.append(node); node.parent = self; return node
        }
    }

    private struct Fixture {
        let web = Node("AXWebArea")
        let shell = Node("AXGroup")
        let pane = Node("AXGroup")
        let content = Node("AXGroup")
        let conversation = Node("AXGroup", "Chat messages")
        let toolbar = Node("AXToolbar", "Session tools")
        let details = Node("AXGroup", "Session details")
        let environment = Node("AXGroup", "Environment")
        let marker = Node("AXStaticText", "This computer")
        let prompt = Node("AXTextArea", "Prompt")
        init(local: Bool = true) {
            web.code = true
            web.add(shell)
            shell.add(Node("AXHeading", "Claude Code"))
            shell.add(pane)
            // Native AX has single-child wrappers that Computer Use's printed
            // tree omits. These are the measured separate-window relationships.
            pane.add(Node("AXGroup")).add(toolbar)
            pane.add(content)
            content.add(Node("AXGroup")).add(Node("AXGroup")).add(conversation)
            content.add(Node("AXGroup")).add(details)
            details.add(Node("AXGroup")).add(environment)
            let heading = environment.add(Node("AXGroup"))
            heading.add(Node("AXGroup")).add(Node("AXButton", "Environment"))
            heading.add(Node("AXButton"))
            let values = environment.add(Node("AXGroup"))
            values.add(Node("AXGroup")).add(Node("AXGroup")).add(marker)
            values.add(Node("AXButton"))
            values.add(Node("AXGroup")).add(Node("AXPopUpButton"))
            values.add(Node("AXPopUpButton"))
            values.add(Node("AXGroup")).add(Node("AXCheckBox"))
            marker.local = local
            var ancestor = content.add(Node("AXGroup"))
            for _ in 0..<6 { ancestor = ancestor.add(Node("AXGroup")) }
            ancestor.add(prompt)
            ancestor.add(Node("AXGroup"))
        }
        func resolves(from node: Node? = nil, expired: Bool = false) -> Bool {
            ClaudePromptEnvironment.isLocalCode(from: node ?? prompt,
                parent: { $0.parent }, children: { $0.children }, role: { $0.role },
                named: { $0.name == $1 }, transparent: { $0.role == "AXGroup" && $0.name.isEmpty },
                same: { $0 === $1 }, localMarker: { $0.local },
                codeDocument: { $0.code && ($1 || $0.mainDocument) }, expired: { expired })
        }
    }

    @Test func measuredLocalCodePaneAcceptsPromptAndConversationFocus() {
        let f = Fixture()
        #expect(f.resolves())
        #expect(f.resolves(from: f.conversation))
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
        remote.shell.add(local.pane)
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
        let noCodeHeading = Fixture()
        noCodeHeading.shell.children.removeFirst()
        #expect(!noCodeHeading.resolves())
    }

    @Test func missingRemoteDetailsCannotBorrowAnotherLocalSessionOrSidebarCard() {
        let remote = Fixture()
        remote.content.children.remove(at: 1)
        let local = Fixture()
        remote.shell.add(local.pane)
        #expect(!remote.resolves())
        #expect(local.resolves())
    }

    @Test func ambiguousShellUnreadableChildrenAndExcessiveWrappersFailInline() {
        let ambiguous = Fixture()
        ambiguous.pane.add(Node("AXGroup"))
        #expect(!ambiguous.resolves())
        let wrappers = Fixture()
        var wrapper = Node("AXGroup")
        wrappers.pane.children[0] = wrapper
        for _ in 0..<13 { wrapper = wrapper.add(Node("AXGroup")) }
        wrapper.add(wrappers.toolbar)
        #expect(!wrappers.resolves())
        let unreadable = Fixture()
        let unreadableResult: Bool = ClaudePromptEnvironment.isLocalCode(from: unreadable.prompt,
            parent: { $0.parent }, children: { $0 === unreadable.details ? nil : $0.children },
            role: { $0.role }, named: { $0.name == $1 },
            transparent: { $0.role == "AXGroup" && $0.name.isEmpty }, same: { $0 === $1 },
            localMarker: { $0.local }, codeDocument: { $0.code && ($1 || $0.mainDocument) }, expired: { false })
        #expect(!unreadableResult)
    }

    @Test func classificationNeverVisitsMessageDescendantsOrReadsTheirValues() {
        let f = Fixture()
        f.conversation.add(Node("AXStaticText", "private message"))
        var visitedTranscript = false
        let result: Bool = ClaudePromptEnvironment.isLocalCode(from: f.prompt,
            parent: { $0.parent }, children: {
                if $0 === f.conversation { visitedTranscript = true }
                return $0.children
            }, role: { $0.role }, named: { $0.name == $1 },
            transparent: { $0.role == "AXGroup" && $0.name.isEmpty }, same: { $0 === $1 },
            localMarker: { node in
                #expect(node === f.marker)
                return node.local
            }, codeDocument: { $0.code && ($1 || $0.mainDocument) }, expired: { false })
        #expect(result)
        #expect(!visitedTranscript)
    }

    @Test func nativePopoutAndMainCodeDocumentsAreAllowedOnlyWithTheMeasuredLocalPane() throws {
        for source in ["about:blank", "https://claude.ai/epitaxy/local_123"] {
            #expect(ClaudePromptEnvironment.isCodeDocumentURL(try #require(URL(string: source)), hasCodeHeading: true))
        }
        for source in ["https://claude.ai/new", "https://claude.ai/epitaxy/session_remote",
                       "https://claude.ai.evil.test/epitaxy/local_123", "file:///tmp/claude.html"] {
            #expect(!ClaudePromptEnvironment.isCodeDocumentURL(try #require(URL(string: source)), hasCodeHeading: true))
        }
        #expect(!ClaudePromptEnvironment.isCodeDocumentURL(try #require(URL(string: "about:blank")), hasCodeHeading: false))
        #expect(ClaudePromptEnvironment.isCodeDocumentURL(try #require(URL(string: "https://claude.ai/epitaxy/local_123")), hasCodeHeading: false))
        let main = Fixture()
        main.web.mainDocument = true
        main.shell.children.removeFirst()
        #expect(main.resolves())
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
