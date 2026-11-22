// Captures the local Codex conversation once for a recording and queues its final prompt.
import AppKit
import ApplicationServices
import Foundation
import SQLite3

struct CodexRecordingTarget: Equatable, Sendable {
    static let preferenceKey = "queueToRecordingStartCodexChat"
    let id: UUID
    let name: String
    let executable: URL

    /// Extraction of CodexRecordingCapture.atStart's existing CLI lookup, shared by
    /// dictation and event metadata without changing either route's authority. — GPT-6.1 Sol
    static func executable(in bundleURL: URL) -> URL? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        return ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex"]
            .map { resources.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A short-lived CLI producer writes to the owning chat's queue. Never resume a
    /// second writer. A failure or indeterminate receipt must never trigger a paste.
    func enqueue(_ message: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["queue", "--thread", id.uuidString.lowercased(), "--message=" + message]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
            process.waitUntilExit()
            deadline.cancel()
            return process.terminationReason == .exit && process.terminationStatus == 0
        }.value
    }
}

enum CodexRecordingRoute: Equatable {
    case detecting, unavailable
    case chat(CodexRecordingTarget)

    /// Codex mode keeps the same finished prompt on the clipboard for manual paste.
    /// Copy once, before waiting on the queue, including when detection was inconclusive.
    @MainActor func deliver(_ prompt: String, copy: (String) -> Bool,
                            enqueue: (CodexRecordingTarget, String) async -> Bool = { await $0.enqueue($1) })
        async -> (copied: Bool, queued: Bool) {
        let copied = copy(prompt)
        guard case .chat(let target) = self else { return (copied, false) }
        return (copied, await enqueue(target, prompt))
    }
}

struct CodexRecordingCapture {
    let mode: ModeConfig
    let lookup: Task<CodexRecordingTarget?, Never>

    @MainActor static func atStart(frontmost app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Self? {
        guard UserDefaults.standard.bool(forKey: CodexRecordingTarget.preferenceKey),
              let app,
              CodexConversationContextReader.isSupportedCodexApplication(app, fileManager: .default),
              let bundleURL = app.bundleURL,
              let mode = ModeRuntimeResolver.modeSnapshot(forPasteTargetBundleIdentifier: app.bundleIdentifier),
              mode.isEnabled, mode.outputMode == .paste, mode.autoSendKey != .none else { return nil }
        let pid = app.processIdentifier
        let launchedAt = app.launchDate
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let window = element(application, kAXFocusedWindowAttribute)
        let name = window.flatMap { value($0, kAXTitleAttribute) as? String }
        let focused = element(application, kAXFocusedUIElementAttribute)
        let instant = Date()
        return Self(mode: mode, lookup: Task.detached(priority: .userInitiated) {
            guard let window, let name, !name.isEmpty else { return nil }
            let id: UUID
            let chatName: String
            let pane = conversation(in: window, focused: focused)
            guard value(window, kAXTitleAttribute) as? String == name else { return nil }
            switch pane {
            case .main:
                let candidates = localIDs(named: name)
                func activeChat(at date: Date) -> UUID? {
                    singleActiveChat(candidates, activity: {
                        CodexConversationContextReader.localChatActivity($0, pid: pid, launchedAt: launchedAt, at: date)
                    })
                }
                if let match = activeChat(at: instant) {
                    id = match
                } else {
                    // Codex can report the newly opened chat several seconds after its
                    // composer is visible. Only confirm the single original candidate,
                    // while its original title and pane still agree. Never retarget.
                    guard candidates.count == 1 else { return nil }
                    var confirmed: UUID?
                    for delay in [1, 2, 3] {
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled,
                              value(window, kAXTitleAttribute) as? String == name else { return nil }
                        if let match = activeChat(at: Date()), conversation(in: window, focused: element(application, kAXFocusedUIElementAttribute)) == .main,
                           value(window, kAXTitleAttribute) as? String == name {
                            confirmed = match
                            break
                        }
                    }
                    guard let confirmed else { return nil }
                    id = confirmed
                }
                chatName = name
            case .side(let sideID):
                guard CodexConversationContextReader.localChatActivity(sideID, pid: pid, launchedAt: launchedAt, at: instant) == true,
                      let sideName = CodexSelectionThreadTitleReader.title(for: sideID.uuidString.lowercased()) else { return nil }
                id = sideID
                chatName = sideName
            case .unknown: return nil
            }
            guard let cli = CodexRecordingTarget.executable(in: bundleURL) else { return nil }
            return CodexRecordingTarget(id: id, name: chatName, executable: cli)
        })
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
        guard let result = value(source, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    /// Codex's window title names its main conversation. A nearer side tab wins
    /// over the main landmark. With no focused composer, require a single main
    /// Conversation region. Prune the transcript so cost does not grow with speech.
    enum Pane: Equatable { case main, side(UUID), unknown }

    static func sidePane(identifier: String?) -> Pane {
        let prefix = "app-shell-tab-panel-sidechat:"
        guard let identifier, identifier.hasPrefix(prefix),
              let id = UUID(uuidString: String(identifier.dropFirst(prefix.count))) else { return .unknown }
        return .side(id)
    }

    private static func isCodexConversation(_ node: AXUIElement) -> Bool {
        value(node, kAXDescriptionAttribute) as? String == "Conversation"
            && (value(node, "AXDOMClassList") as? [String])?.contains("thread-scroll-container") == true
    }

    private static func conversation(in window: AXUIElement, focused: AXUIElement?) -> Pane {
        var node = focused
        var inConversation = false
        var pane = Pane.unknown
        let editor = focused.flatMap { value($0, "AXDOMClassList") as? [String] }?.contains("ProseMirror") == true
        var inComposer = false
        for _ in 0..<60 {
            guard let current = node else { break }
            if CFEqual(current, window) { if (inConversation || inComposer) && pane != .unknown { return pane }; break }
            if editor && !inComposer {
                // The desktop composer is a sibling of the Conversation region.
                inComposer = (value(current, "AXDOMClassList") as? [String])?.contains {
                    $0.hasPrefix("ComposerLayoutBody-")
                } == true
            }
            let subrole = value(current, kAXSubroleAttribute) as? String
            if subrole == "AXTabPanel" || value(current, kAXRoleAttribute) as? String == "AXTabPanel" {
                guard inConversation || inComposer else { return .unknown }
                pane = sidePane(identifier: value(current, "AXDOMIdentifier") as? String)
                guard pane != .unknown else { return .unknown }
            }
            if subrole == "AXLandmarkMain" && pane == .unknown { pane = .main }
            if isCodexConversation(current) { inConversation = true }
            node = element(current, kAXParentAttribute)
        }
        var pending = [(window, false)]
        var seen = 0
        var found = false
        while let (item, insideMain) = pending.popLast() {
            seen += 1
            guard seen <= 1200, let role = value(item, kAXRoleAttribute) as? String else { return .unknown }
            guard ["AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXTabPanel"].contains(role) else { continue }
            let subrole = value(item, kAXSubroleAttribute) as? String
            let isMain = insideMain || subrole == "AXLandmarkMain"
            if role == "AXTabPanel" || subrole == "AXTabPanel" { return .unknown }
            if value(item, kAXDescriptionAttribute) as? String == "Conversation" {
                guard isMain, !found, isCodexConversation(item) else { return .unknown }
                found = true
                continue
            }
            if ["AXLandmarkNavigation", "AXLandmarkBanner"].contains(subrole ?? "") { continue }
            guard let children = value(item, kAXChildrenAttribute) as? [AXUIElement] else { return .unknown }
            pending.append(contentsOf: children.map { ($0, isMain) })
        }
        return found ? .main : .unknown
    }

    static func singleActiveChat(_ candidates: [UUID], activity: (UUID) -> Bool?) -> UUID? {
        var match: UUID?
        for id in candidates {
            guard let active = activity(id) else { return nil }
            if active {
                guard match == nil else { return nil }
                match = id
            }
        }
        return match
    }

    static func localIDs(named title: String, databaseURL: URL = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")) -> [UUID] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE archived = 0 AND COALESCE(NULLIF(name,''), title) = ?1 LIMIT 9"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        return title.withCString { pointer in
            guard sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK else { return [] }
            var ids: [UUID] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard ids.count < 8, let raw = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: raw)) else { return [] }
                ids.append(id)
                status = sqlite3_step(statement)
            }
            return status == SQLITE_DONE ? ids : []
        }
    }
}
