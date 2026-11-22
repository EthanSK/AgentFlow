// Sends one completed recording/mute interval to its owning Voice chat, with durable
// enqueue receipts. Dictation text and clipboard state never enter these notices.
import Foundation
import os

struct CodexVoiceCaptureEvent: Sendable, Codable {
    let id: UUID
    let phase: String
    let call: ChatGPTVoiceCall
    let startedAt: Date
    let occurredAt: Date
    let microphoneResult: String
    let microphoneAttemptedAt: Date?
    let checkedAt: Date
    let speakerPost: ChatGPTVoiceSpeakerPost?

    var headline: String {
        let action: String
        switch phase {
        case "started": action = "Recording started"
        case "paused": action = "Recording paused"
        default: action = "Recording stopped"
        }
        return "\(action) at \(Self.clock(occurredAt))."
    }

    var message: String { "\(headline)\n\(metadata)\n\(Self.interpretation)" }

    static let interpretation = """
    Agent Flow event for the user's requested Voice recap feature; this contains no dictated text.
    Shortcut requests are attempts, not confirmation. Voice controls can lag the audio.
    Read the linked receipt for original recording, mute attempts, control observations and queue acceptance times. Compare those times with this message's observed receipt/processing time and the assistant's speech timeline; mark unavailable times unknown. Prefer verified audio mute/unmute boundaries; otherwise use recording start/stop as an approximation and state the uncertainty. A transcript frame's observed time is not per-word or audible-playback timing.
    Check the CURRENT speaker state of this same Voice call using available read-only evidence. Historical events and stale controls do not prove it is unmuted now. Tell the user they can hear the response only with current supporting evidence. Then repeat only assistant speech likely missed during the original interval. Do not invent missed speech or say nothing was said without timing evidence. If output is still muted or cannot be verified, give a written recap or defer the spoken recap until restoration is verified. If this call has ended or changed, keep the recap written and never change another call's controls.
    """

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss.SSS 'UTC'"
        return formatter.string(from: date)
    }

    /// Extraction of the existing receipt date format, shared by notices and JSON. — GPT-6.1 Sol
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Extraction of existing message fields so one notice composes both observations. — GPT-6.1 Sol
    var metadata: String {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "unavailable" }
            return Self.timestamp(date)
        }
        let speakerResult: String
        let speakerAt: Date?
        let observation: ChatGPTVoiceSpeakerObservation?
        switch speakerPost {
        case .posted(let readable, let attemptedAt, let read):
            speakerResult = readable ? "requestedWithReadablePriorState" : "requestedWithUnreadablePriorState"
            speakerAt = attemptedAt
            observation = read
        case .observed(let read):
            speakerResult = "controlReadbackOnly"
            speakerAt = nil
            observation = read
        case .skipped:
            speakerResult = "noCommandPosted"
            speakerAt = nil
            observation = nil
        case nil:
            speakerResult = "noCommandPostedOrHeldByNewerCapture"
            speakerAt = nil
            observation = nil
        }
        return """
        <agent_flow_capture_event recording_id="\(id.uuidString.lowercased())" phase="\(phase)" voice_session_id="\(call.sessionID.uuidString.lowercased())" voice_chat_id="\(call.threadID?.uuidString.lowercased() ?? "unavailable")" recording_started_at="\(stamp(startedAt))" occurred_at="\(stamp(occurredAt))" microphone_result="\(microphoneResult)" microphone_attempted_at="\(stamp(microphoneAttemptedAt))" state_checked_at="\(stamp(checkedAt))" speaker_result="\(speakerResult)" speaker_attempted_at="\(stamp(speakerAt))" speaker_control_readback_muted="\(observation.map { String($0.isMuted) } ?? "unknown")" speaker_observed_at="\(stamp(observation?.observedAt))" />
        """
    }

    var microphoneSummary: String {
        switch microphoneResult {
        case "mutedVerified": return "muted in controls"
        case "restoredVerified": return "listening in controls"
        case "mutedUnverified": return "mute requested, not confirmed"
        case "restoredUnverified": return "restore requested, not confirmed"
        case "alreadyMuted": return "already muted"
        case "alreadyOwned", "heldByOtherCapture": return "held by another recording"
        case "stillListening": return "controls still showed listening"
        case "userUnmuted": return "already listening"
        default: return "unchanged or not confirmed"
        }
    }
}

struct CodexVoiceCaptureNotice: Sendable, Codable {
    let started: CodexVoiceCaptureEvent
    let ended: CodexVoiceCaptureEvent

    var message: String {
        """
        \(ended.headline)
        Started at \(CodexVoiceCaptureEvent.clock(started.occurredAt)). Mic: \(started.microphoneSummary); then \(ended.microphoneSummary).
        \(started.metadata)
        \(ended.metadata)
        \(CodexVoiceCaptureEvent.interpretation)
        """
    }

    func queuedMessage(requestedAt: Date, receiptURL: URL) -> String {
        """
        \(ended.headline) — Agent Flow
        Started at \(CodexVoiceCaptureEvent.clock(started.occurredAt)). Enqueue requested at \(CodexVoiceCaptureEvent.clock(requestedAt)).
        [Recording receipt](<\(receiptURL.path)>) contains queue acceptance time and observed speaker state at enqueue. Acceptance time records the CLI producer's confirmation, separately from the original events.
        \(started.metadata)
        \(ended.metadata)
        \(CodexVoiceCaptureEvent.interpretation)
        """
    }
}

/// Emits one completed interval per capture; duplicate edges never create another notice. — GPT-6.1 Sol
struct CodexVoiceCaptureNoticeBatcher {
    private var starts: [UUID: CodexVoiceCaptureEvent] = [:]
    private var recent: [UUID] = []
    private var seen: [UUID: Set<String>] = [:]

    mutating func record(_ event: CodexVoiceCaptureEvent, enabled: Bool) -> CodexVoiceCaptureNotice? {
        guard enabled else { starts.removeValue(forKey: event.id); return nil }
        if seen[event.id] == nil {
            recent.append(event.id)
            if recent.count > 128 {
                let expired = recent.removeFirst()
                seen.removeValue(forKey: expired)
                starts.removeValue(forKey: expired)
            }
        }
        guard seen[event.id, default: []].insert(event.phase).inserted else { return nil }
        if event.phase == "started" {
            guard !seen[event.id, default: []].contains("stopped"),
                  !seen[event.id, default: []].contains("paused") else { return nil }
            starts[event.id] = event
            return nil
        }
        guard let start = starts.removeValue(forKey: event.id), start.call == event.call,
              start.occurredAt == event.startedAt, event.occurredAt >= start.occurredAt else { return nil }
        return CodexVoiceCaptureNotice(started: start, ended: event)
    }
}

protocol CodexVoiceCaptureEventSending: Sendable {
    func record(_ event: CodexVoiceCaptureEvent) async
}

/// Enqueues one completed notice, never per-edge cards or a retry of an uncertain send. — GPT-6.1 Sol
actor CodexVoiceCaptureEventSender: CodexVoiceCaptureEventSending {
    static let shared = CodexVoiceCaptureEventSender()
    private var batcher = CodexVoiceCaptureNoticeBatcher()
    private let activity: PairedVoiceMuteActivity
    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "CodexVoiceCaptureEvents")

    init(activity: PairedVoiceMuteActivity = .shared) { self.activity = activity }

    func record(_ event: CodexVoiceCaptureEvent) {
        let notice = batcher.record(event, enabled: true)
        guard let operation = activity.beginOperation() else { return }
        // Formatting/logging never holds the hardware or waveform startup path.
        // The existing cooperative-quit activity keeps a last receipt from being dropped.
        Task.detached(priority: .utility) { [activity, logger] in
            defer { activity.finishOperation(operation) }
            logger.notice("Local Voice capture receipt: \(event.message, privacy: .public)")
            if let notice {
                logger.notice("Local Voice interval receipt: \(notice.message, privacy: .public)")
                let result = await CodexVoiceCaptureQueueDelivery.enqueue(notice)
                logger.notice("Voice interval enqueue result=\(result, privacy: .public) recording=\(event.id.uuidString, privacy: .public)")
            }
        }
        // Ethan explicitly accepted normal queue delivery for ONE completed Voice recap
        // notice on 2026-11-22, superseding his earlier "It should never queue" instruction.
        // This never enables the separate dictated-text queue, resumes another writer,
        // requires shared-server setup, or replays a failed/uncertain enqueue.
    }
}

struct CodexVoiceCaptureContext {
    let id = UUID()
    let call: ChatGPTVoiceCall
    let microphoneResult: ChatGPTVoiceSuppressionOutcome
    let microphoneAttemptedAt: Date?
    let checkedAt: Date
    let speakerPost: ChatGPTVoiceSpeakerPost?
    var startedAt: Date?
    var stoppedAt: Date?
    var stopReason = "stopped"
    var restoration: (microphone: ChatGPTVoiceRestorationOutcome, attemptedAt: Date?,
                      checkedAt: Date, speakerPost: ChatGPTVoiceSpeakerPost?)?
}
