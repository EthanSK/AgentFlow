// Chooses compact prompt files only for a Claude Code pane that visibly proves
// it runs on this Mac. Unknown, Chat, Cloud and SSH panes keep complete inline
// context. This read-only presentation check never focuses, pastes or sends.
import AppKit
import ApplicationServices

enum ClaudePromptEnvironment {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    @MainActor static func supportsLocalPrompt(
        recipient: AgentFlowPromptPreview.Recipient, target: RecordingPasteTarget
    ) async -> Bool {
        if target.destination.usesAppSpecificExactDelivery {
            // Next owns an exact input. Inspect only that pane, including when
            // backgrounded; the foreground app says nothing about its environment.
            return await target.focusedInput?.supportsLocalClaudePrompt() ?? false
        }
        guard recipient.bundleID == bundleIdentifier,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleIdentifier,
              app.bundleURL == recipient.bundleURL else { return false }
        let pid = app.processIdentifier
        let local = await read(processIdentifier: pid)
        // Primary owns no input. A focus change during the read invalidates the
        // classification, rather than saving/restoring the inspected composer.
        return local && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// The measured Code pane has Session tools, Session details and its own
    /// Environment card. Sidebar labels, another split pane and a local_ URL
    /// alone are insufficient: Desktop also gives SSH sessions local_ IDs.
    static func isLocalCode<Node>(
        from leaf: Node, parent: (Node) -> Node?, children: (Node) -> [Node]?,
        role: (Node) -> String?, named: (Node, String) -> Bool,
        transparent: (Node) -> Bool, same: (Node, Node) -> Bool,
        localMarker: (Node) -> Bool, codeDocument: (Node, Bool) -> Bool,
        expired: () -> Bool
    ) -> Bool {
        // Computer Use omits unnamed groups; native AX preserves them. Collapse
        // only single-child, unnamed group wrappers, never a named region or a
        // branching container. This keeps inspection on the focused pane's own
        // chrome instead of searching sibling sessions or message descendants.
        func unwrapped(_ source: Node) -> Node? {
            var node = source
            for _ in 0..<12 {
                guard !expired(), role(node) != nil else { return nil }
                guard transparent(node) else { return node }
                guard let inner = children(node) else { return nil }
                guard inner.count == 1 else { return node }
                node = inner[0]
            }
            return nil
        }
        func visibleChildren(_ source: Node) -> [Node]? {
            guard !expired(), let direct = children(source) else { return nil }
            var result: [Node] = []
            for child in direct {
                guard let node = unwrapped(child) else { return nil }
                result.append(node)
            }
            return result
        }
        var node = leaf
        var ancestry: [Node] = []
        var localPane = false
        var codeShell = false
        var inConversation = false
        for _ in 0..<48 {
            guard !expired(), let currentRole = role(node) else { return false }
            ancestry.append(node)
            inConversation = inConversation || (currentRole == "AXTextArea" && named(node, "Prompt"))
                || (currentRole == "AXGroup" && named(node, "Chat messages"))
            if currentRole == "AXWebArea" { return localPane && codeDocument(node, codeShell) }
            if currentRole == "AXWindow" { return false }
            if currentRole == "AXGroup" && !named(node, "Chat messages") {
                guard let siblings = visibleChildren(node) else { return false }
                codeShell = codeShell || siblings.contains(where: {
                    role($0) == "AXHeading" && named($0, "Claude Code")
                })
                if !localPane, siblings.contains(where: {
                    role($0) == "AXToolbar" && named($0, "Session tools")
                }) {
                    // The nearest measured session shell has toolbar + content.
                    // Content must be on the leaf's actual parent path. Never
                    // borrow a This computer card from another split/session.
                    let content = siblings.filter { role($0) == "AXGroup" }
                    guard inConversation, siblings.count == 2, content.count == 1,
                          ancestry.contains(where: { same($0, content[0]) }),
                          let sections = visibleChildren(content[0]) else { return false }
                    let details = sections.filter { role($0) == "AXGroup" && named($0, "Session details") }
                    guard details.count == 1, let detailCards = visibleChildren(details[0]) else { return false }
                    let cards = detailCards.filter { role($0) == "AXGroup" && named($0, "Environment") }
                    guard cards.count == 1 else { return false }
                    guard let rows = visibleChildren(cards[0]), rows.count == 2 else { return false }
                    var labels: [Node] = []
                    for row in rows {
                        guard let columns = visibleChildren(row) else { return false }
                        labels.append(contentsOf: columns.filter { role($0) == "AXStaticText" })
                    }
                    guard labels.count == 1, localMarker(labels[0]) else { return false }
                    localPane = true
                }
            }
            guard let next = parent(node) else { return false }
            node = next
        }
        return false
    }

    static func isCodeDocumentURL(_ url: URL, hasCodeHeading: Bool) -> Bool {
        // The separate native Code window really exposes about:blank, even after
        // a session starts. Its Code heading AND pane-local Environment card must
        // still pass above; about:blank alone never establishes local file access.
        if url.absoluteString == "about:blank" { return hasCodeHeading }
        return url.scheme == "https" && url.host == "claude.ai" && url.path.hasPrefix("/epitaxy/local_")
    }

    // CF references are immutable handles here and used on one serial worker.
    // A Next handle remains solely a read scope, never new delivery authority.
    private struct Element: @unchecked Sendable { let value: AXUIElement }

    static func read(processIdentifier: pid_t, element: AXUIElement? = nil) async -> Bool {
        let source = element.map { Element(value: $0) }
        return await Task.detached(priority: .userInitiated) {
            guard AXIsProcessTrusted() else { return false }
            let reader = Reader(processIdentifier: processIdentifier)
            guard let leaf = source?.value ?? reader.element(reader.app, kAXFocusedUIElementAttribute),
                  let window = reader.element(leaf, kAXWindowAttribute) else { return false }
            var localEnvironment: AXUIElement?
            let local = isLocalCode(from: leaf, parent: { reader.element($0, kAXParentAttribute) },
                children: reader.children, role: { reader.metadata($0)?.role },
                named: { reader.metadata($0)?.names.contains($1) == true },
                transparent: { reader.metadata($0).map { $0.role == "AXGroup" && $0.names.allSatisfy(\.isEmpty) } == true },
                same: { CFEqual($0, $1) },
                localMarker: {
                    localEnvironment = $0
                    return reader.copy($0, kAXValueAttribute) as? String == "This computer"
                },
                codeDocument: reader.isCodeDocument, expired: { reader.expired })
            guard local, !reader.expired,
                  let localEnvironment,
                  reader.copy(localEnvironment, kAXValueAttribute) as? String == "This computer",
                  let afterWindow = reader.element(leaf, kAXWindowAttribute), CFEqual(window, afterWindow) else { return false }
            if source == nil {
                guard let focused = reader.element(reader.app, kAXFocusedUIElementAttribute), CFEqual(leaf, focused) else { return false }
            }
            return !reader.expired
        }.value
    }

    private final class Reader {
        struct Metadata { let role: String; let names: [String] }
        let app: AXUIElement
        // This is a ceiling on actual IPC work, not a settling wait. A slow or
        // hidden Environment card immediately falls back to complete inline XML.
        private let deadline = ContinuousClock.now.advanced(by: .milliseconds(80))
        private var messages = 0
        private var metadataCache: [(AXUIElement, Metadata)] = []
        private var childrenCache: [(AXUIElement, [AXUIElement])] = []
        var expired: Bool { ContinuousClock.now >= deadline || messages >= 240 || Task.isCancelled }

        init(processIdentifier: pid_t) { app = AXUIElementCreateApplication(processIdentifier) }

        private func prepare(_ node: AXUIElement) -> Bool {
            guard !expired else { return false }
            messages += 1
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            AXUIElementSetMessagingTimeout(node, Float(min(0.02, max(0.001, seconds))))
            return true
        }

        func copy(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard prepare(node) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
            return result
        }

        func metadata(_ node: AXUIElement) -> Metadata? {
            if let cached = metadataCache.first(where: { CFEqual($0.0, node) }) { return cached.1 }
            guard prepare(node) else { return nil }
            var values: CFArray?
            let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, [], &values) == .success,
                  let values = values as? [Any], values.count == 3, let role = values[0] as? String else { return nil }
            let result = Metadata(role: role, names: values.dropFirst().compactMap { $0 as? String })
            metadataCache.append((node, result))
            return result
        }

        func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = copy(node, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }

        func children(_ node: AXUIElement) -> [AXUIElement]? {
            if let cached = childrenCache.first(where: { CFEqual($0.0, node) }) { return cached.1 }
            guard let result = copy(node, kAXChildrenAttribute) as? [AXUIElement], result.count <= 32 else { return nil }
            childrenCache.append((node, result))
            return result
        }

        func isCodeDocument(_ node: AXUIElement, _ hasCodeHeading: Bool) -> Bool {
            let value = copy(node, kAXURLAttribute)
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            return url.map { isCodeDocumentURL($0, hasCodeHeading: hasCodeHeading) } ?? false
        }
    }
}
