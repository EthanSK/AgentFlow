// Sends recording metadata to the exact Voice chat, independently of dictation auto-send.
// Delivery runs outside the capture transition. Dictation text and clipboard state never enter it.
import Foundation
import os

struct CodexVoiceCaptureEvent: Sendable {
    let id: UUID
    let phase: String
    let call: ChatGPTVoiceCall
    let startedAt: Date
    let occurredAt: Date
    let microphoneResult: String
    let microphoneAttemptedAt: Date?
    let checkedAt: Date
    let speakerPost: ChatGPTVoiceSpeakerPost?

    var message: String {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "unavailable" }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
        let speakerResult: String
        let speakerAt: Date?
        switch speakerPost {
        case .posted(let readable, let attemptedAt):
            speakerResult = readable ? "requestedWithReadablePriorState" : "requestedWithUnreadablePriorState"
            speakerAt = attemptedAt
        case .skipped:
            speakerResult = "noCommandPosted"
            speakerAt = nil
        case nil:
            speakerResult = "noCommandPostedOrHeldByNewerCapture"
            speakerAt = nil
        }
        return """
        Agent Flow recording update.
        <agent_flow_capture_event id="\(id.uuidString.lowercased())" phase="\(phase)" voice_session_id="\(call.sessionID.uuidString.lowercased())" voice_chat_id="\(call.threadID?.uuidString.lowercased() ?? "unavailable")" recording_started_at="\(stamp(startedAt))" occurred_at="\(stamp(occurredAt))" microphone_result="\(microphoneResult)" microphone_attempted_at="\(stamp(microphoneAttemptedAt))" state_checked_at="\(stamp(checkedAt))" speaker_result="\(speakerResult)" speaker_attempted_at="\(stamp(speakerAt))" />
        Microphone results describe control readbacks. Voice controls can lag the audio. Speaker requests are unverified until a later state observation. Use the recording interval to identify speech Ethan may have missed and repeat the unheard part after sound is restored.
        """
    }
}

protocol CodexVoiceCaptureEventSending: Sendable {
    func record(_ event: CodexVoiceCaptureEvent) async
}

/// Keeps event messages ordered without holding the microphone or restoration queue. — GPT-6.1 Sol
actor CodexVoiceCaptureEventSender: CodexVoiceCaptureEventSending {
    static let shared = CodexVoiceCaptureEventSender()
    private let activity: PairedVoiceMuteActivity
    private var tail: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "CodexVoiceCaptureEvents")

    init(activity: PairedVoiceMuteActivity = .shared) {
        self.activity = activity
    }

    func record(_ event: CodexVoiceCaptureEvent) {
        guard let threadID = event.call.threadID,
              let operation = activity.beginOperation() else { return }
        let previous = tail
        tail = Task { [activity, logger] in
            defer { activity.finishOperation(operation) }
            await previous?.value
            let bundle = URL(fileURLWithPath: SystemChatGPTVoiceMuteTransport.applicationPath)
            guard let executable = CodexRecordingTarget.executable(in: bundle) else {
                logger.error("Voice recording event has no installed Codex CLI")
                return
            }
            let result: String
            if CodexVoiceCaptureAppServer.isConfigured(for: event.call) {
                result = await CodexVoiceCaptureAppServer.deliver(event, executable: executable)
            } else {
                // The installed desktop has verified this ordinary route only at idle boundaries.
                // This is event-only delivery, separately authorized from the rejected dictation queue.
                // Select it before any direct attempt; never resend an uncertain direct request.
                let target = CodexRecordingTarget(id: threadID, name: "Voice", executable: executable)
                result = await target.enqueue(event.message) ? "queuedForIdle" : "queueNotConfirmed"
            }
            // Acceptance is not receipt. A delayed event keeps its original timestamps and ID.
            // Never retry, paste, or resume a second writer after an uncertain producer result.
            logger.notice("Voice recording event result=\(result, privacy: .public) phase=\(event.phase, privacy: .public) event=\(event.id.uuidString, privacy: .public) thread=\(threadID.uuidString, privacy: .public)")
        }
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
