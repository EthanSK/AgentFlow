// Runs the production Voice-control traversal against bounded fake AX graphs.
// No application, focus, microphone, speaker or keyboard event is changed.
import ApplicationServices
import Testing
@testable import VoiceInkPlusPlus

private final class VoiceControlGraph {
    struct Node {
        var role = kAXGroupRole
        var label: String?
        var children: [Int] = []
        var enabled = true
    }
    var nodes: [Int: Node] = [:]
    var searches: [Int: ChatGPTVoiceButtonSearch<Int>] = [:]
    var childrenReads: [Int] = []
    var searchReads: [Int] = []
    var running = true
    var expireAfterRole = false

    func read(_ channel: ChatGPTVoiceControlChannel = .speaker) -> ChatGPTVoiceControlRead {
        ChatGPTVoiceControlReader.read(
            roots: [0], channel: channel,
            role: { id in
                if self.expireAfterRole { self.running = false }
                return self.nodes[id]?.role
            },
            enabled: { self.nodes[$0]?.enabled },
            label: { self.nodes[$0]?.labelAttribute($1) },
            children: { self.childrenReads.append($0); return self.nodes[$0]?.children ?? [] },
            buttonSearch: { self.searchReads.append($0); return self.searches[$0] },
            canContinue: { self.running }
        )
    }
}

private extension VoiceControlGraph.Node {
    func labelAttribute(_ attribute: String) -> String? { attribute == kAXTitleAttribute ? label : nil }
}

struct ChatGPTVoiceControlReaderTests {
    @Test func nativeButtonSearchBypassesThousandsOfChatTextNodes() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea", children: Array(1...3000))
        for id in 1...3000 { graph.nodes[id] = .init(role: kAXStaticTextRole, label: "chat") }
        graph.nodes[4000] = .init(role: kAXButtonRole, label: "Mute speakers")
        graph.searches[0] = .init(buttons: [4000], complete: true)
        let result = graph.read()
        #expect(result.isMuted == false)
        #expect(result.voiceControlFound)
        #expect(result.visitedCount == 2)
        #expect(result.nativeSearchCount == 1)
        #expect(graph.childrenReads.isEmpty)
    }

    @Test func voiceControlsBeyondTheOldFourteenLevelLimitAreFound() {
        let graph = VoiceControlGraph()
        for id in 0..<46 { graph.nodes[id] = .init(children: [id + 1]) }
        graph.nodes[46] = .init(role: kAXButtonRole, label: "Unmute speakers")
        let result = graph.read()
        #expect(result.isMuted == true)
        #expect(result.voiceControlFound)
        #expect(result.visitedCount == 47)
    }

    @Test func microphoneAndEndControlsCanProveALiveCallWithoutInventingSpeakerState() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea")
        graph.nodes[1] = .init(role: kAXButtonRole, label: "Turn on microphone")
        graph.nodes[2] = .init(role: kAXButtonRole, label: "End voice")
        graph.searches[0] = .init(buttons: [1, 2], complete: true)
        let speaker = graph.read()
        #expect(speaker.isMuted == nil)
        #expect(speaker.voiceControlFound)
        #expect(graph.read(.microphone).isMuted == true)
    }

    @Test func unsupportedNativeSearchStillUsesBoundedTraversal() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea", children: [1])
        graph.nodes[1] = .init(role: kAXButtonRole, label: "Mute speakers")
        #expect(graph.read().isMuted == false)
        #expect(graph.searchReads == [0])
        #expect(graph.childrenReads == [0])
    }

    @Test func truncatedNativeSearchDoesNotDiscardTheRemainingSubtree() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea", children: [2])
        graph.nodes[1] = .init(role: kAXButtonRole, label: "Copy")
        graph.nodes[2] = .init(role: kAXButtonRole, label: "Unmute speakers")
        graph.searches[0] = .init(buttons: [1], complete: false)
        #expect(graph.read().isMuted == true)
        #expect(graph.childrenReads == [0])
    }

    @Test func disabledButtonsDoNotProvideMuteOrLiveCallEvidence() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea")
        graph.nodes[1] = .init(role: kAXButtonRole, label: "Mute speakers", enabled: false)
        graph.nodes[2] = .init(role: kAXButtonRole, label: "End voice", enabled: false)
        graph.searches[0] = .init(buttons: [1, 2], complete: true)
        let result = graph.read()
        #expect(result.isMuted == nil)
        #expect(!result.voiceControlFound)
    }

    @Test func anExpiredBudgetStartsNoNativeSearchOrChildReads() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(role: "AXWebArea", children: [1])
        graph.expireAfterRole = true
        let result = graph.read()
        #expect(result.truncated)
        #expect(result.isMuted == nil)
        #expect(graph.searchReads.isEmpty)
        #expect(graph.childrenReads.isEmpty)
    }

    @Test func repeatedElementsAndCyclesAreReadOnce() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(children: [1, 0, 1])
        graph.nodes[1] = .init(children: [0])
        let result = graph.read()
        #expect(result.visitedCount == 2)
        #expect(!result.truncated)
        #expect(graph.childrenReads == [0, 1])
    }

    @Test func messageTextThatNamesVoiceControlsIsNotControlEvidence() {
        let graph = VoiceControlGraph()
        graph.nodes[0] = .init(children: [1])
        graph.nodes[1] = .init(role: kAXStaticTextRole, label: "Mute speakers", children: [2])
        graph.nodes[2] = .init(role: kAXButtonRole, label: "End voice")
        let result = graph.read()
        #expect(result.isMuted == nil)
        #expect(!result.voiceControlFound)
        #expect(graph.childrenReads == [0])
    }
}
