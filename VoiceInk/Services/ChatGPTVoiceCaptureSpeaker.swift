// Owns only the local Voice speaker change made by a real Agent Flow microphone capture.
import Foundation
import SQLite3
import os

struct ChatGPTVoiceCall: Equatable, Sendable {
    let applicationPID: pid_t
    let sessionID: UUID
}

enum ChatGPTVoiceSpeakerPost: Equatable, Sendable {
    case skipped
    case posted(priorStateReadable: Bool)
}

protocol ChatGPTVoiceSpeakerTransport: Sendable {
    func activeSpeakerCall() async -> ChatGPTVoiceCall?
    // Check the current state at the action boundary. Another actor may
    // already have reached the requested state.
    func postSpeakerToggle(
        for call: ChatGPTVoiceCall, mute: Bool
    ) async -> ChatGPTVoiceSpeakerPost
}

actor ChatGPTVoiceCaptureSpeaker {
    private let transport: any ChatGPTVoiceSpeakerTransport
    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "ChatGPTVoiceCaptureSpeaker")
    private var ownedCall: ChatGPTVoiceCall?

    init(transport: any ChatGPTVoiceSpeakerTransport) {
        self.transport = transport
    }

    func silenceForCapture() async {
        guard let call = await transport.activeSpeakerCall() else {
            return
        }
        // Preserve manual unsilence and avoid another toggle after a rapid
        // successor takes over the same still-owned call.
        if ownedCall == call { return }
        ownedCall = nil
        // Ethan wants one attempt even if Voice hides its speaker control.
        // Own only our own dispatch to a proven call. Unknown state is never
        // evidence that the toggle applied in the intended direction.
        guard case .posted(let readable) = await transport.postSpeakerToggle(for: call, mute: true)
        else { return }

        ownedCall = call
        logger.notice("Posted one Codex Voice speaker silence attempt; prior state readable=\(readable, privacy: .public)")
    }

    func restoreAfterCapture() async {
        guard let call = ownedCall else { return }
        ownedCall = nil
        guard case .posted(let readable) = await transport.postSpeakerToggle(for: call, mute: false) else {
            logger.notice("Codex Voice speaker restore skipped; call changed, output already on, or shortcut unavailable")
            return
        }
        logger.notice("Posted one Codex Voice speaker restore attempt; prior state readable=\(readable, privacy: .public)")
    }
}

// Saved call boundaries supplement the live Voice controls. Read only IDs and
// lifecycle events, and fail closed if the private desktop schema is absent,
// incomplete or ambiguous. Never treat the process ID alone as a call.
enum ChatGPTVoiceSessionBoundaryReader {
    static func uniqueActiveSession(
        since launchDate: Date,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex.db")
    ) -> UUID? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        let query = """
            SELECT json_extract(payload_json, '$.sessionId'),
                   json_extract(payload_json, '$.type')
            FROM thread_timeline_ledger
            WHERE host_id = 'local' AND json_valid(payload_json)
              AND json_extract(payload_json, '$.type') IN ('session-started', 'session-ended')
              AND json_extract(payload_json, '$.occurredAtMs') >= ?1
            ORDER BY thread_id, sequence
            LIMIT 2000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, launchDate.timeIntervalSince1970 * 1000) == SQLITE_OK
        else { return nil }

        var active = Set<UUID>()
        var count = 0
        while count < 2000 {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return active.count == 1 ? active.first : nil
            case SQLITE_ROW:
                guard let rawID = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: rawID)),
                      let rawEvent = sqlite3_column_text(statement, 1)
                else { return nil }
                switch String(cString: rawEvent) {
                case "session-started": active.insert(id)
                case "session-ended": active.remove(id)
                default: return nil
                }
                count += 1
            default:
                return nil
            }
        }
        return nil
    }
}
