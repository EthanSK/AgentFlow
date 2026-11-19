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
            switch conversation(in: window, focused: focused) {
            case .main:
                guard let mainID = uniqueLocalID(named: name) else { return nil }
                id = mainID
                chatName = name
            case .side(let sideID):
                guard let sideName = CodexSelectionThreadTitleReader.title(for: sideID.uuidString.lowercased()) else { return nil }
                id = sideID
                chatName = sideName
            case .unknown: return nil
            }
            guard CodexConversationContextReader.wasActiveLocalChat(id, pid: pid, at: instant),
                  value(window, kAXTitleAttribute) as? String == name else { return nil }
            let resources = bundleURL.appendingPathComponent("Contents/Resources")
            guard let cli = ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex"]
                .map({ resources.appendingPathComponent($0) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
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
        for _ in 0..<60 {
            guard let current = node else { break }
            if CFEqual(current, window) { if inConversation && pane != .unknown { return pane }; break }
            let subrole = value(current, kAXSubroleAttribute) as? String
            if subrole == "AXTabPanel" || value(current, kAXRoleAttribute) as? String == "AXTabPanel" {
                guard inConversation else { return .unknown }
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

    static func uniqueLocalID(named title: String, databaseURL: URL = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")) -> UUID? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE archived = 0 AND COALESCE(NULLIF(name,''), title) = ?1 LIMIT 2"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return title.withCString { pointer in
            guard sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
            let id = UUID(uuidString: String(cString: raw))
            return sqlite3_step(statement) == SQLITE_DONE ? id : nil
        }
    }
}
