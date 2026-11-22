// Exercises metadata routing and exact-turn guards without connecting to a live Voice chat.
import Foundation
import Testing
@testable import VoiceInkPlusPlus

private final class VoiceEventRPCFixture: CodexVoiceCaptureRPC {
    let threadID: UUID
    var status = "active"
    var directInput = true
    var turnStatus = "inProgress"
    var rejectDelivery = false
    let turnID = UUID().uuidString.lowercased()
    var requests: [(String, [String: Any])] = []
    var notifications: [String] = []

    init(threadID: UUID) { self.threadID = threadID }
    func notify(_ method: String) { notifications.append(method) }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "initialize": return [:]
        case "thread/read": return ["thread": ["id": threadID.uuidString.lowercased(),
            "canAcceptDirectInput": directInput, "status": ["type": status]]]
        case "thread/turns/list": return ["data": [["id": turnID, "status": turnStatus]]]
        default:
            if rejectDelivery { throw CodexVoiceCaptureDeliveryError.rejected }
            return method == "turn/steer" ? ["turnId": turnID] : ["turn": ["id": turnID]]
        }
    }
}

struct CodexVoiceCaptureEventsTests {
    private func event(phase: String = "started", id: UUID = UUID()) -> CodexVoiceCaptureEvent {
        .init(id: id, phase: phase, call: .init(applicationPID: 42, sessionID: UUID(), threadID: UUID()),
              startedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
              occurredAt: Date(timeIntervalSince1970: 1_700_000_001.456),
              microphoneResult: "mutedVerified", microphoneAttemptedAt: nil,
              checkedAt: Date(timeIntervalSince1970: 1_700_000_000), speakerPost: .skipped)
    }

    @Test func activeVoiceEventsUseExactTurnSteeringWithoutReadingItems() throws {
        let event = event()
        let rpc = VoiceEventRPCFixture(threadID: try #require(event.call.threadID))
        #expect(try CodexVoiceCaptureAppServer.send(event, through: rpc) == "steerAccepted")
        #expect(rpc.requests.map(\.0) == ["initialize", "thread/read", "thread/turns/list", "turn/steer"])
        #expect(rpc.notifications == ["initialized"])
        #expect(rpc.requests[1].1["includeTurns"] as? Bool == false)
        #expect(rpc.requests[2].1["itemsView"] as? String == "notLoaded")
        #expect(rpc.requests[3].1["expectedTurnId"] as? String == rpc.turnID)
        #expect(rpc.requests[3].1["threadId"] as? String == event.call.threadID?.uuidString.lowercased())
        #expect(rpc.requests[3].1["clientUserMessageId"] as? String == "agent-flow-\(event.id.uuidString.lowercased())-started")
    }

    @Test func idleVoiceEventPreservesChatSettingsAndSegmentPhasesHaveDistinctIDs() throws {
        let id = UUID()
        var clientIDs: [String] = []
        for phase in ["started", "stopped"] {
            let event = event(phase: phase, id: id)
            let rpc = VoiceEventRPCFixture(threadID: try #require(event.call.threadID))
            rpc.status = "idle"
            #expect(try CodexVoiceCaptureAppServer.send(event, through: rpc) == "startAccepted")
            #expect(rpc.requests.map(\.0) == ["initialize", "thread/read", "turn/start"])
            let params = rpc.requests[2].1
            #expect(Set(params.keys) == ["threadId", "clientUserMessageId", "input", "turnTrigger"])
            clientIDs.append(try #require(params["clientUserMessageId"] as? String))
        }
        #expect(Set(clientIDs).count == 2)
    }

    @Test func unloadedOrAmbiguousVoiceChatNeverResumesStartsOrRetargets() throws {
        for (status, direct, matching) in [("notLoaded", true, true), ("active", false, true), ("active", true, false)] {
            let event = event()
            let rpc = VoiceEventRPCFixture(threadID: matching ? try #require(event.call.threadID) : UUID())
            rpc.directInput = direct
            rpc.status = status
            #expect(throws: CodexVoiceCaptureDeliveryError.self) {
                try CodexVoiceCaptureAppServer.send(event, through: rpc)
            }
            #expect(rpc.requests.map(\.0) == ["initialize", "thread/read"])
        }
    }

    @Test func activeTurnRaceAndUncertainReceiptNeverFallBackToStartOrQueue() throws {
        for reject in [true, false] {
            let event = event()
            let rpc = VoiceEventRPCFixture(threadID: try #require(event.call.threadID))
            rpc.rejectDelivery = reject
            rpc.turnStatus = reject ? "inProgress" : "completed"
            #expect(throws: CodexVoiceCaptureDeliveryError.self) {
                try CodexVoiceCaptureAppServer.send(event, through: rpc)
            }
            #expect(!rpc.requests.contains { $0.0 == "turn/start" || $0.0 == "thread/resume" })
            #expect(rpc.requests.filter { $0.0 == "turn/steer" }.count == (reject ? 1 : 0))
        }
    }

    @Test func recordingMetadataPreservesOriginalTimesAndSeparatesAttemptsFromReadback() {
        let event = event()
        #expect(event.message.contains("recording_started_at=\"2023-11-14T22:13:20.123Z\""))
        #expect(event.message.contains("occurred_at=\"2023-11-14T22:13:21.456Z\""))
        #expect(event.message.contains("voice_chat_id=\"\(event.call.threadID!.uuidString.lowercased())\""))
        #expect(event.message.contains("microphone_attempted_at=\"unavailable\""))
        #expect(event.message.contains("Speaker requests are unverified"))
        #expect(event.message.contains("controls can lag the audio"))
    }

    @Test func unverifiedDesktopCannotLaunchTheDirectMessageProxy() async {
        let original = event()
        let event = CodexVoiceCaptureEvent(id: original.id, phase: original.phase,
            call: .init(applicationPID: Int32.max, sessionID: original.call.sessionID, threadID: original.call.threadID),
            startedAt: original.startedAt, occurredAt: original.occurredAt,
            microphoneResult: original.microphoneResult, microphoneAttemptedAt: nil,
            checkedAt: original.checkedAt, speakerPost: .skipped)
        let result = await CodexVoiceCaptureAppServer.deliver(event,
            executable: URL(fileURLWithPath: "/nonexistent-codex-event-test"))
        #expect(result == "sharedDesktopNotConfigured")
    }
}
