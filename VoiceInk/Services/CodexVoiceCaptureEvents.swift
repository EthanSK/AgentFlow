// Keeps recording/mute metadata in local diagnostics. It never sends a Voice recap
// or touches ordinary dictation delivery. — GPT-6.1 Sol
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

    /// Uses the existing timestamp format in local recording diagnostics. — GPT-6.1 Sol
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Preserves attempted versus observed audio state without generating a recap. — GPT-6.1 Sol
    var metadata: String {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "unavailable" }
            return Self.timestamp(date)
        }
        let speakerResult: String
        let speakerAt: Date?
        let observation: ChatGPTVoiceSpeakerObservation?
        switch speakerPost {
        case .postedDirectly(let postedCall, let attemptedAt):
            speakerResult = postedCall == call ? "togglePosted" : "noCommandPosted"
            speakerAt = postedCall == call ? attemptedAt : nil
            observation = nil
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
}

protocol CodexVoiceCaptureEventSending: Sendable {
    func record(_ event: CodexVoiceCaptureEvent) async
}

/// Records local diagnostics without generating or enqueueing chat messages. — GPT-6.1 Sol
actor CodexVoiceCaptureEventSender: CodexVoiceCaptureEventSending {
    static let shared = CodexVoiceCaptureEventSender()
    private let activity: PairedVoiceMuteActivity
    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "CodexVoiceCaptureEvents")

    init(activity: PairedVoiceMuteActivity = .shared) { self.activity = activity }

    func record(_ event: CodexVoiceCaptureEvent) {
        guard let operation = activity.beginOperation() else { return }
        // Formatting/logging never holds the hardware or waveform startup path.
        // The existing cooperative-quit activity keeps a last receipt from being dropped.
        Task.detached(priority: .utility) { [activity, logger] in
            defer { activity.finishOperation(operation) }
            logger.notice("Local Voice capture diagnostic: \(event.metadata, privacy: .public)")
        }
        // Ethan asked to turn off the automatic "Recording stopped" recaps on
        // 2026-11-24. Local metadata still explains shortcut attempts, without
        // generating a message, reading Codex again, or starting a queue producer.
        // Found and fixed by GPT-6.1 Sol.
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
