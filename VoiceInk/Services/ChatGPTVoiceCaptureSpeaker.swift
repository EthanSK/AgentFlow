// Owns only the local Voice speaker change made by a real Agent Flow microphone capture.
import Foundation
import SQLite3
import os

struct ChatGPTVoiceCall: Equatable, Sendable, Codable {
    let applicationPID: pid_t
    let sessionID: UUID
    var threadID: UUID? = nil
}

struct ChatGPTVoiceSpeakerObservation: Equatable, Sendable, Codable {
    let call: ChatGPTVoiceCall
    let isMuted: Bool
    let observedAt: Date
}

enum ChatGPTVoiceSpeakerPost: Equatable, Sendable, Codable {
    case skipped
    case postedDirectly(call: ChatGPTVoiceCall, attemptedAt: Date)
    case observed(ChatGPTVoiceSpeakerObservation)
    case posted(priorStateReadable: Bool, attemptedAt: Date = .now,
                observation: ChatGPTVoiceSpeakerObservation? = nil)
}

protocol ChatGPTVoiceSpeakerTransport: Sendable {
    func activeSpeakerCall() async -> ChatGPTVoiceCall?
    // Must freshly observe fromMuted on this call before posting; nil state skips.
    // The result confirms dispatch only, never native acceptance. — GPT-6.1 Sol
    func postSpeakerToggle(for call: ChatGPTVoiceCall, fromMuted: Bool) async -> Date?
}

actor ChatGPTVoiceCaptureSpeaker {
    private let transport: any ChatGPTVoiceSpeakerTransport
    private let automaticControlEnabled: Bool
    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "ChatGPTVoiceCaptureSpeaker")
    private var ownedCall: ChatGPTVoiceCall?

    init(transport: any ChatGPTVoiceSpeakerTransport, automaticControlEnabled: Bool = true) {
        self.transport = transport
        self.automaticControlEnabled = automaticControlEnabled
    }

    @discardableResult
    func silenceForCapture() async -> ChatGPTVoiceSpeakerPost {
        // The explicit off composition remains available independently of
        // microphone muting. Do not even inspect Voice speakers while off.
        guard automaticControlEnabled else { return .skipped }
        guard let call = await transport.activeSpeakerCall() else {
            return .skipped
        }
        // A rapid successor inherits the outstanding toggle on the same call.
        if ownedCall == call { return .skipped }
        ownedCall = nil
        // Ethan's 28 November state-preserving hold supersedes blind pairing:
        // an existing H Chat/manual mute and unreadable state both stay untouched.
        // The transport reads state once at dispatch, without a duplicate scan. — GPT-6.1 Sol
        guard let attemptedAt = await transport.postSpeakerToggle(for: call, fromMuted: false)
        else { return .skipped }

        ownedCall = call
        logger.notice("Posted one Codex Voice speaker toggle for capture start")
        return .postedDirectly(call: call, attemptedAt: attemptedAt)
    }

    @discardableResult
    func restoreAfterCapture() async -> ChatGPTVoiceSpeakerPost {
        guard automaticControlEnabled else { return .skipped }
        guard let call = ownedCall else { return .skipped }
        ownedCall = nil
        // A later visible unmute takes precedence. Unknown state cannot justify
        // an inverse; a posted shortcut alone never proves the audible result. — GPT-6.1 Sol
        guard let attemptedAt = await transport.postSpeakerToggle(for: call, fromMuted: true)
        else { return .skipped }

        logger.notice("Posted one Codex Voice speaker toggle for capture end")
        return .postedDirectly(call: call, attemptedAt: attemptedAt)
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
        uniqueActiveCall(since: launchDate, databaseURL: databaseURL)?.sessionID
    }

    struct Identity {
        let sessionID: UUID
        let threadID: String
    }

    static func uniqueActiveCall(
        since launchDate: Date,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex.db")
    ) -> Identity? {
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
                   json_extract(payload_json, '$.type'), thread_id
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

        var active: [UUID: String] = [:]
        var count = 0
        while count < 2000 {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return active.count == 1 ? active.first.map { Identity(sessionID: $0.key, threadID: $0.value) } : nil
            case SQLITE_ROW:
                guard let rawID = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: rawID)),
                      let rawEvent = sqlite3_column_text(statement, 1),
                      let rawThreadID = sqlite3_column_text(statement, 2)
                else { return nil }
                switch String(cString: rawEvent) {
                case "session-started":
                    let threadID = String(cString: rawThreadID)
                    guard active[id] == nil || active[id] == threadID else { return nil }
                    active[id] = threadID
                case "session-ended":
                    guard active[id] == nil || active[id] == String(cString: rawThreadID) else { return nil }
                    active.removeValue(forKey: id)
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
