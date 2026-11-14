// ============================================================================
// **MOVED FROM — MOVE HISTORY**
// 2026-11-14: label interpretation and traversal were extracted from
// SystemChatGPTVoiceMuteTransport.readVoiceControls in
// ChatGPTVoiceCaptureMuteCoordinator.swift so the production reader can be tested
// without inspecting or sending input to a live Voice call.
// New behavior: native button search, leaf skipping and hashed visit tracking
// prevent long/deep chat content from hiding the speaker control.
// ============================================================================
import ApplicationServices
import Foundation

enum ChatGPTVoiceControlChannel { case microphone, speaker }

struct ChatGPTVoiceControlRead {
    var isMuted: Bool?
    var voiceControlFound = false
    var visitedCount = 0
    var nativeSearchCount = 0
    var truncated = false
}

struct ChatGPTVoiceButtonSearch<Node> {
    let buttons: [Node]
    let complete: Bool
}

/// One native observation of a button. Reading these fields separately for every
/// chat toolbar button exhausted the restore deadline before reaching Voice.
struct ChatGPTVoiceButtonAttributes {
    static let names = [kAXRoleAttribute, kAXEnabledAttribute, kAXTitleAttribute,
                        kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
    let role: String?
    let enabled: Bool?
    let labels: [String]

    static func decode(_ values: [Any]?, fallback: () -> Self?) -> Self? {
        // Match FocusLockService's established multiple-attribute read: only a
        // failed/malformed batch uses the original accessors. Individual AX errors
        // stay unreadable, never guessed state or another pass over that button.
        guard let values, values.count == names.count else { return fallback() }
        return .init(role: values[0] as? String, enabled: values[1] as? Bool,
                     labels: values.dropFirst(2).compactMap { $0 as? String })
    }
}

/// Extraction of the existing Voice-control walk, with a native button-search
/// path matching H Chat. Reads remain bounded; missing controls never mean unmuted.
enum ChatGPTVoiceControlReader {
    static func read<Node: Hashable>(
        roots: [Node], channel: ChatGPTVoiceControlChannel,
        role: (Node) -> String?, buttonAttributes: (Node) -> ChatGPTVoiceButtonAttributes?,
        children: (Node) -> [Node],
        buttonSearch: (Node) -> ChatGPTVoiceButtonSearch<Node>?,
        canContinue: () -> Bool
    ) -> ChatGPTVoiceControlRead {
        var result = ChatGPTVoiceControlRead()
        var queue = roots.map { ($0, 0) }
        var index = 0
        var visited = Set<Node>()

        func inspectButton(_ node: Node) -> Bool {
            guard canContinue() else { result.truncated = true; return false }
            let attributes = buttonAttributes(node)
            guard canContinue() else { result.truncated = true; return false }
            guard let attributes, attributes.role == kAXButtonRole,
                  attributes.enabled != false else { return false }
            for value in attributes.labels {
                switch channel {
                case .microphone:
                    if let state = SystemChatGPTVoiceMuteTransport.microphoneState(accessibilityLabel: value) {
                        result.isMuted = state == .muted
                        result.voiceControlFound = true
                        return true
                    }
                case .speaker:
                    if let muted = SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: value) {
                        result.isMuted = muted
                        result.voiceControlFound = true
                        return true
                    }
                    if SystemChatGPTVoiceMuteTransport.microphoneState(accessibilityLabel: value) != nil
                        || ["end voice", "end voice chat", "stop voice chat"].contains(
                            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        result.voiceControlFound = true
                    }
                }
            }
            return false
        }

        while index < queue.count, visited.count < 12_000, canContinue() {
            let (node, depth) = queue[index]
            index += 1
            guard visited.insert(node).inserted else { continue }
            result.visitedCount = visited.count
            let currentRole = role(node)
            if currentRole == kAXButtonRole, inspectButton(node) { return result }
            if currentRole == "AXWebArea", canContinue(), let found = buttonSearch(node) {
                result.nativeSearchCount += 1
                for button in found.buttons {
                    guard canContinue(), visited.count < 12_000 else {
                        result.truncated = true
                        return result
                    }
                    guard visited.insert(button).inserted else { continue }
                    result.visitedCount = visited.count
                    // The native search returns button candidates. Validate role
                    // with the same batched observation rather than another IPC.
                    if inspectButton(button) { return result }
                }
                // Chromium's search already covered this web subtree. Do not walk
                // thousands of message/text nodes after a complete button search.
                if found.complete { continue }
            }
            if [kAXStaticTextRole, kAXImageRole, kAXButtonRole].contains(currentRole ?? "") { continue }
            guard canContinue() else { result.truncated = true; return result }
            guard depth < 96 else { result.truncated = true; continue }
            queue.append(contentsOf: children(node).map { ($0, depth + 1) })
        }
        if index < queue.count { result.truncated = true }
        return result
    }
}

/// Identity wrapper for the existing CFEqual comparison. Hashing avoids the old
/// repeated linear scan of every previously read accessibility element.
struct ChatGPTVoiceAXNode: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
