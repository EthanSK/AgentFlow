// Uses only a previously verified shared desktop server. Never starts/resumes a competing writer.
import Foundation
import Darwin
import AppKit

protocol CodexVoiceCaptureRPC {
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any]
    func notify(_ method: String) throws
}

enum CodexVoiceCaptureDeliveryError: Error {
    case unavailable, invalidResponse, threadNotLoaded, activeTurnChanged, rejected
}

enum CodexVoiceCaptureAppServer {
    // Set only after the desktop itself has been verified using the shared daemon.
    // A socket created by an unrelated CLI does not prove that it owns the Voice chat.
    static let verifiedDesktopPreference = "codexVoiceCaptureSharedDesktopIdentity"

    static func isConfigured(for call: ChatGPTVoiceCall) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: call.applicationPID),
              let launchedAt = application.launchDate,
              UserDefaults.standard.string(forKey: verifiedDesktopPreference)
                == "\(call.applicationPID):\(launchedAt.timeIntervalSince1970)" else { return false }
        return true
    }

    /// Delivers metadata off the capture queue, without a queue or paste fallback. — GPT-6.1 Sol
    static func deliver(_ event: CodexVoiceCaptureEvent, executable: URL) async -> String {
        guard isConfigured(for: event.call) else { return "sharedDesktopNotConfigured" }
        return await Task.detached(priority: .utility) {
            let socket = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/app-server-control/app-server-control.sock")
            guard FileManager.default.fileExists(atPath: socket.path) else { return "sharedServerUnavailable" }
            do {
                let connection = try CodexVoiceCaptureProxy(executable: executable, socket: socket)
                defer { connection.close() }
                return try send(event, through: connection)
            } catch {
                // An uncertain acknowledgement is not permission to resend or use the clipboard.
                return "notConfirmed"
            }
        }.value
    }

    /// Reads only loaded-chat and turn metadata, then uses the exact active-turn guard. — GPT-6.1 Sol
    static func send(_ event: CodexVoiceCaptureEvent, through connection: any CodexVoiceCaptureRPC) throws -> String {
        guard let threadID = event.call.threadID?.uuidString.lowercased() else {
            throw CodexVoiceCaptureDeliveryError.unavailable
        }
        _ = try connection.request("initialize", [
            "clientInfo": ["name": "agent_flow_capture_events", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ])
        try connection.notify("initialized")
        let response = try connection.request("thread/read", ["threadId": threadID, "includeTurns": false])
        guard let thread = response["thread"] as? [String: Any],
              (thread["id"] as? String)?.lowercased() == threadID,
              thread["canAcceptDirectInput"] as? Bool == true,
              let status = (thread["status"] as? [String: Any])?["type"] as? String,
              status == "active" || status == "idle" else {
            throw CodexVoiceCaptureDeliveryError.threadNotLoaded
        }
        // The phase is part of the ID: one segment has a start AND an end message.
        var params: [String: Any] = [
            "threadId": threadID, "clientUserMessageId": "agent-flow-\(event.id.uuidString.lowercased())-\(event.phase)",
            "input": [["type": "text", "text": event.message, "text_elements": []]]
        ]
        let method: String
        if status == "active" {
            let page = try connection.request("thread/turns/list", [
                "threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"
            ])
            guard let turns = page["data"] as? [[String: Any]], turns.count == 1,
                  turns[0]["status"] as? String == "inProgress", let turnID = turns[0]["id"] as? String else {
                throw CodexVoiceCaptureDeliveryError.activeTurnChanged
            }
            params["expectedTurnId"] = turnID
            method = "turn/steer"
        } else {
            // Omission preserves the owning chat's model, speed, permissions and environment.
            params["turnTrigger"] = "agent_flow_capture_event"
            method = "turn/start"
        }
        let receipt = try connection.request(method, params)
        guard method == "turn/steer"
            ? receipt["turnId"] as? String != nil
            : (receipt["turn"] as? [String: Any])?["id"] as? String != nil else {
            throw CodexVoiceCaptureDeliveryError.invalidResponse
        }
        return method == "turn/steer" ? "steerAccepted" : "startAccepted"
    }
}

/// A bounded connection to the installed CLI's existing proxy, never `app-server` startup. — GPT-6.1 Sol
private final class CodexVoiceCaptureProxy: CodexVoiceCaptureRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var sequence = 0
    private var buffer = Data()
    private var deadline: DispatchWorkItem?

    init(executable: URL, socket: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "proxy", "--sock", socket.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let process = process
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        deadline = timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        let id = sequence
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                guard let object else { throw CodexVoiceCaptureDeliveryError.invalidResponse }
                // Ordinary server notifications are not delivery receipts. Do not store their contents.
                guard object["id"] as? Int == id else { continue }
                guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                    throw CodexVoiceCaptureDeliveryError.rejected
                }
                return result
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty, buffer.count + chunk.count <= 1_048_576 else {
                throw CodexVoiceCaptureDeliveryError.invalidResponse
            }
            buffer.append(chunk)
        }
    }

    func notify(_ method: String) throws {
        var data = try JSONSerialization.data(withJSONObject: ["method": method])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        deadline?.cancel()
        try? output.fileHandleForReading.close()
    }
}
