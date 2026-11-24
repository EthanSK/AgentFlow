// Exercises local recording diagnostics and the removed automatic recap boundary.
// Tests never connect to a live Voice chat. — GPT-6.1 Sol
import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct CodexVoiceCaptureEventsTests {
    private func event() -> CodexVoiceCaptureEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000.123)
        let end = Date(timeIntervalSince1970: 1_700_000_001.456)
        return .init(id: UUID(), phase: "stopped",
            call: .init(applicationPID: 42, sessionID: UUID(), threadID: UUID()),
            startedAt: start, occurredAt: end, microphoneResult: "restoredVerified",
            microphoneAttemptedAt: nil, checkedAt: end, speakerPost: .skipped)
    }

    @Test func recordingMetadataPreservesOriginalTimesAndSeparatesAttemptsFromReadback() {
        let event = event()
        #expect(event.metadata.contains("recording_started_at=\"2023-11-14T22:13:20.123Z\""))
        #expect(event.metadata.contains("occurred_at=\"2023-11-14T22:13:21.456Z\""))
        #expect(event.metadata.contains("voice_chat_id=\"\(event.call.threadID!.uuidString.lowercased())\""))
        #expect(event.metadata.contains("microphone_attempted_at=\"unavailable\""))
        #expect(!event.metadata.contains("Check the CURRENT speaker state"))
    }

    @Test func directSpeakerPostReportsOnlyTheAttemptAndOnlyForItsCall() {
        let end = event()
        let replacement = ChatGPTVoiceCall(applicationPID: end.call.applicationPID, sessionID: UUID())
        for postedCall in [end.call, replacement] {
            let event = CodexVoiceCaptureEvent(id: end.id, phase: end.phase, call: end.call,
                startedAt: end.startedAt, occurredAt: end.occurredAt, microphoneResult: end.microphoneResult,
                microphoneAttemptedAt: nil, checkedAt: end.checkedAt,
                speakerPost: .postedDirectly(call: postedCall, attemptedAt: end.occurredAt))
            if postedCall == end.call {
                #expect(event.metadata.contains("speaker_result=\"togglePosted\""))
                #expect(event.metadata.contains("speaker_attempted_at=\"2023-11-14T22:13:21.456Z\""))
            } else {
                #expect(event.metadata.contains("speaker_result=\"noCommandPosted\""))
                #expect(event.metadata.contains("speaker_attempted_at=\"unavailable\""))
            }
            #expect(event.metadata.contains("speaker_control_readback_muted=\"unknown\""))
            #expect(event.metadata.contains("speaker_observed_at=\"unavailable\""))
        }
    }

    @Test func speakerObservationDoesNotClaimACommandOrAnAudioMuteBoundary() {
        let end = event()
        let observation = ChatGPTVoiceSpeakerObservation(call: end.call, isMuted: false, observedAt: end.occurredAt)
        let event = CodexVoiceCaptureEvent(id: end.id, phase: end.phase, call: end.call,
            startedAt: end.startedAt, occurredAt: end.occurredAt, microphoneResult: end.microphoneResult,
            microphoneAttemptedAt: nil, checkedAt: end.checkedAt, speakerPost: .observed(observation))
        #expect(event.metadata.contains("speaker_result=\"controlReadbackOnly\""))
        #expect(event.metadata.contains("speaker_attempted_at=\"unavailable\""))
        #expect(event.metadata.contains("speaker_control_readback_muted=\"false\""))
        #expect(event.metadata.contains("speaker_observed_at=\"2023-11-14T22:13:21.456Z\""))
    }

    // A local recording diagnostic must never become an automatic chat message.
    // Found and fixed by GPT-6.1 Sol.
    @Test func automaticVoiceRecapProducerRemainsRemoved() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let services = root.appendingPathComponent("VoiceInk/Services")
        let source = try String(contentsOf: services.appendingPathComponent("CodexVoiceCaptureEvents.swift"))
        for forbidden in ["CodexRecordingTarget", ".enqueue(", "CodexVoiceCaptureNotice", "NSPasteboard"] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains("event.metadata"))
        #expect(!FileManager.default.fileExists(atPath:
            services.appendingPathComponent("CodexVoiceCaptureQueueDelivery.swift").path))
    }
}
