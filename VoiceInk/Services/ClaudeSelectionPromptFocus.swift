import AppKit
import ApplicationServices
import os

/// Prepares the Prompt of the Claude Code pane the user just highlighted.
/// This is a live context interaction, separate from selection reads and all
/// paste routes. It never runs on a stop, activates a window, or sends a key.
enum ClaudeSelectionPromptFocus {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus", category: "ClaudeSelectionPromptFocus"
    )

    static func composer<Node>(
        at hit: Node,
        role: (Node) -> String?,
        named: (Node, String) -> Bool,
        parent: (Node) -> Node?,
        children: (Node) -> [Node],
        same: (Node, Node) -> Bool,
        expired: () -> Bool
    ) -> Node? {
        var element = hit
        let controls = ["AXTextArea", "AXTextField", "AXButton", "AXLink",
                        "AXMenu", "AXMenuItem", "AXPopUpButton", "AXCheckBox"]
        for _ in 0..<40 {
            guard !expired(), let currentRole = role(element),
                  currentRole != "AXWebArea", !controls.contains(currentRole) else { return nil }
            if currentRole == "AXGroup", named(element, "Chat messages") {
                break
            }
            guard let next = parent(element) else { return nil }
            element = next
        }
        guard !expired(), role(element) == "AXGroup", named(element, "Chat messages"),
              let transcript = parent(element),
              let session = parent(transcript) else { return nil }
        let siblings = children(session).filter { !same($0, transcript) }
        // Both the main split view and standalone window expose this toolbar.
        // The standalone window has no AX group with a " pane" description.
        guard siblings.contains(where: { role($0) == "AXToolbar" && named($0, "Session tools") }) else {
            return nil
        }
        var stack = siblings.filter { role($0) == "AXGroup" && !named($0, "Session details") }
        var remaining = 120
        var prompt: Node?
        while let node = stack.popLast() {
            guard remaining > 0, !expired() else { return nil }
            remaining -= 1
            switch role(node) {
            case "AXTextArea" where named(node, "Prompt"):
                guard prompt == nil else { return nil }
                prompt = node
            case "AXGroup":
                guard !named(node, "Chat messages"), !named(node, "Session details") else { continue }
                stack.append(contentsOf: children(node))
            default:
                continue
            }
        }
        return prompt
    }

    static func prepare(
        processIdentifier: pid_t,
        gesture: LiveSelectionGesture,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async {
        let work = Task.detached(priority: .userInitiated) {
            guard await isCurrent(), !Task.isCancelled else { return }
            let probe = LiveAccessibilitySelectionProbe(
                processIdentifier: processIdentifier, budget: LiveSelectionReadPolicy.accessibilityBudget
            )
            guard let window = probe.focusedWindow(),
                  let hit = probe.element(at: gesture.mouseUp),
                  let hitWindow = probe.window(of: hit), probe.isSame(hitWindow, window),
                  let prompt = composer(at: hit, role: probe.role(of:), named: probe.isNamed(_:_:),
                                        parent: probe.parent(of:), children: probe.children(of:),
                                        same: probe.isSame(_:_:),
                                        expired: { probe.isExpired }),
                  let promptWindow = probe.window(of: prompt), probe.isSame(promptWindow, window) else { return }
            // Preserve any editable the user moved to, including another pane's
            // composer. A late result from a highlight cannot override it.
            let focused = probe.focusedElement()
            if let focused, probe.isEditable(focused) { return }
            var canSetFocus: DarwinBoolean = false
            guard !probe.isExpired,
                  AXUIElementIsAttributeSettable(prompt, kAXFocusedAttribute as CFString, &canSetFocus) == .success,
                  canSetFocus.boolValue,
                  let currentWindow = probe.focusedWindow(), probe.isSame(currentWindow, window),
                  probe.hasSameFocus(as: focused), probe.incompleteMessages == 0, !probe.isExpired,
                  await isCurrent(), !Task.isCancelled, !probe.isExpired else { return }
            let status = AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let verified = status == .success && probe.hasSameFocus(as: prompt)
            logger.info("Claude highlight Prompt focus result=\(status.rawValue, privacy: .public) verified=\(verified, privacy: .public)")
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
