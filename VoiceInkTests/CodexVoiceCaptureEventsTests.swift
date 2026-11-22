// Exercises local recording receipts without connecting to a live Voice chat.
import Foundation
import Testing
@testable import VoiceInkPlusPlus

private actor CapturedVoiceSummaryQueue {
    private var messages: [(UUID, String)] = []
    let accepts: Bool
    init(accepts: Bool = true) { self.accepts = accepts }
    func enqueue(_ target: CodexRecordingTarget, _ message: String) -> Bool {
        messages.append((target.id, message))
        return accepts
    }
    func captured() -> [(UUID, String)] { messages }
}

struct CodexVoiceCaptureEventsTests {
    private func notice() -> CodexVoiceCaptureNotice {
        let id = UUID()
        let call = ChatGPTVoiceCall(applicationPID: 42, sessionID: UUID(), threadID: UUID())
        let start = Date(timeIntervalSince1970: 1_700_000_000.123)
        let end = Date(timeIntervalSince1970: 1_700_000_001.456)
        return .init(
            started: .init(id: id, phase: "started", call: call, startedAt: start,
                occurredAt: start, microphoneResult: "mutedUnverified", microphoneAttemptedAt: nil,
                checkedAt: start, speakerPost: .skipped),
            ended: .init(id: id, phase: "stopped", call: call, startedAt: start,
                occurredAt: end, microphoneResult: "restoredVerified", microphoneAttemptedAt: nil,
                checkedAt: end, speakerPost: .skipped))
    }

    @Test func recordingMetadataPreservesOriginalTimesAndSeparatesAttemptsFromReadback() {
        let event = notice().ended
        #expect(event.message.contains("recording_started_at=\"2023-11-14T22:13:20.123Z\""))
        #expect(event.message.contains("occurred_at=\"2023-11-14T22:13:21.456Z\""))
        #expect(event.message.contains("voice_chat_id=\"\(event.call.threadID!.uuidString.lowercased())\""))
        #expect(event.message.contains("microphone_attempted_at=\"unavailable\""))
        #expect(event.message.contains("Shortcut requests are attempts, not confirmation"))
        #expect(event.message.contains("controls can lag the audio"))
    }

    @Test func noticeBeginsWithActionAndOriginalTimeAndContainsTheWholeInterval() {
        let notice = notice()
        #expect(notice.message.hasPrefix("Recording stopped at 22:13:21.456 UTC.\n"))
        #expect(notice.message.contains("Started at 22:13:20.123 UTC."))
        #expect(notice.message.contains("mute requested, not confirmed; then listening in controls"))
        #expect(notice.message.components(separatedBy: "<agent_flow_capture_event ").count == 3)
        #expect(!notice.message.contains("Agent Flow recording update"))
    }

    @Test func speakerObservationDoesNotClaimACommandOrAnAudioMuteBoundary() {
        let end = notice().ended
        let observation = ChatGPTVoiceSpeakerObservation(call: end.call, isMuted: false, observedAt: end.occurredAt)
        let event = CodexVoiceCaptureEvent(id: end.id, phase: end.phase, call: end.call,
            startedAt: end.startedAt, occurredAt: end.occurredAt, microphoneResult: end.microphoneResult,
            microphoneAttemptedAt: nil, checkedAt: end.checkedAt, speakerPost: .observed(observation))
        #expect(event.metadata.contains("speaker_result=\"controlReadbackOnly\""))
        #expect(event.metadata.contains("speaker_attempted_at=\"unavailable\""))
        #expect(event.metadata.contains("speaker_control_readback_muted=\"false\""))
        #expect(event.metadata.contains("speaker_observed_at=\"2023-11-14T22:13:21.456Z\""))
    }

    @Test func oneCompletedIntervalReplacesPerEdgeMessagesAndDeduplicatesBothPhases() {
        let notice = notice()
        var batcher = CodexVoiceCaptureNoticeBatcher()
        #expect(batcher.record(notice.started, enabled: true) == nil)
        #expect(batcher.record(notice.started, enabled: true) == nil)
        #expect(batcher.record(notice.ended, enabled: true)?.message == notice.message)
        #expect(batcher.record(notice.ended, enabled: true) == nil)
    }

    @Test func disabledOrUnmatchedIntervalsNeverReplayOnEnable() {
        let notice = notice()
        var batcher = CodexVoiceCaptureNoticeBatcher()
        #expect(batcher.record(notice.started, enabled: false) == nil)
        #expect(batcher.record(notice.ended, enabled: true) == nil)
        #expect(batcher.record(notice.started, enabled: true) == nil)
        #expect(batcher.record(notice.ended, enabled: true) == nil)
    }

    @Test func replacementCallCannotCompleteAnotherCallsInterval() {
        let notice = notice()
        let end = notice.ended
        let replacement = CodexVoiceCaptureEvent(id: end.id, phase: end.phase,
            call: .init(applicationPID: 42, sessionID: UUID(), threadID: UUID()),
            startedAt: end.startedAt, occurredAt: end.occurredAt,
            microphoneResult: end.microphoneResult, microphoneAttemptedAt: nil,
            checkedAt: end.checkedAt, speakerPost: .skipped)
        var batcher = CodexVoiceCaptureNoticeBatcher()
        #expect(batcher.record(notice.started, enabled: true) == nil)
        #expect(batcher.record(replacement, enabled: true) == nil)
    }

    @Test func eventQueueHasNoNewTurnResumeOrClipboardFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["CodexVoiceCaptureEvents.swift", "CodexVoiceCaptureQueueDelivery.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/\(file)"))
            for forbidden in ["\"turn/start\"", "\"thread/resume\"", "\"--resume\"", "NSPasteboard"] {
                #expect(!source.contains(forbidden))
            }
        }
    }

    @Test func completedNoticeQueuesOnceWithSeparateEnqueueReceiptAndFrozenChat() async throws {
        let notice = notice()
        let queue = CapturedVoiceSummaryQueue()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observe: @Sendable (ChatGPTVoiceCall) async -> ChatGPTVoiceSpeakerObservation? = {
            .init(call: $0, isMuted: false, observedAt: Date())
        }
        let result = await CodexVoiceCaptureQueueDelivery.enqueue(notice, directory: directory,
            executable: URL(fileURLWithPath: "/test-codex"), observe: observe,
            queue: { await queue.enqueue($0, $1) })
        #expect(result == "queued")
        let duplicate = await CodexVoiceCaptureQueueDelivery.enqueue(notice, directory: directory,
            executable: URL(fileURLWithPath: "/test-codex"), observe: observe,
            queue: { await queue.enqueue($0, $1) })
        #expect(duplicate == "alreadyAttempted")
        let messages = await queue.captured()
        #expect(messages.count == 1)
        #expect(messages[0].0 == notice.ended.call.threadID)
        #expect(messages[0].1.hasPrefix("Recording stopped at 22:13:21.456 UTC. — Agent Flow"))
        #expect(messages[0].1.contains("Enqueue requested at"))
        #expect(messages[0].1.contains("Check the CURRENT speaker state"))
        #expect(messages[0].1.contains("written recap"))
        let file = directory.appendingPathComponent("\(notice.ended.id.uuidString.lowercased()).json")
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(receipt["queueAccepted"] as? Bool == true)
        #expect(receipt["enqueueRequestedAt"] as? String != nil)
        #expect(receipt["queueAcceptanceObservedAt"] as? String != nil)
        #expect((receipt["speakerObservedAtEnqueue"] as? [String: Any])?["isMuted"] as? Bool == false)
    }

    @Test func failedOrUncertainQueueResultIsNeverAutomaticallyResubmitted() async {
        let notice = notice()
        let queue = CapturedVoiceSummaryQueue(accepts: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for expected in ["notConfirmed", "alreadyAttempted"] {
            let result = await CodexVoiceCaptureQueueDelivery.enqueue(notice, directory: directory,
                executable: URL(fileURLWithPath: "/test-codex"), observe: { _ in nil },
                queue: { await queue.enqueue($0, $1) })
            #expect(result == expected)
        }
        #expect(await queue.captured().count == 1)
    }
}
