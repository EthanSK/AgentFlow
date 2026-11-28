// Exercises recording-scoped speaker ownership without sending real shortcuts.
import Foundation
import CoreGraphics
import SQLite3
import Testing
@testable import VoiceInkPlusPlus

private actor FakeVoiceSpeakerTransport: ChatGPTVoiceSpeakerTransport {
    private var currentCall: ChatGPTVoiceCall?
    private var posts: [ChatGPTVoiceCall] = []
    private var callReads = 0
    private var shortcutConfigured: Bool
    private var muted: Bool? = false
    let attemptedAt = Date(timeIntervalSince1970: 42)

    init(_ call: ChatGPTVoiceCall?, shortcutConfigured: Bool = true) {
        currentCall = call
        self.shortcutConfigured = shortcutConfigured
    }

    func activeSpeakerCall() -> ChatGPTVoiceCall? {
        callReads += 1
        return currentCall
    }

    func postSpeakerToggle(for call: ChatGPTVoiceCall, fromMuted: Bool) -> Date? {
        guard currentCall == call, shortcutConfigured, muted == fromMuted else { return nil }
        posts.append(call)
        muted = !fromMuted
        return attemptedAt
    }

    func setMuted(_ value: Bool?) { muted = value }
    func setCurrentCall(_ call: ChatGPTVoiceCall?) { currentCall = call }
    func configureShortcut() { shortcutConfigured = true }
    func postedCalls() -> [ChatGPTVoiceCall] { posts }
    func callReadCount() -> Int { callReads }
}

struct ChatGPTVoiceCaptureSpeakerTests {
    private let call = ChatGPTVoiceCall(applicationPID: 42, sessionID: UUID())

    @Test func disabledAutomaticSpeakerControlNeverReadsOrPosts() async {
        let transport = FakeVoiceSpeakerTransport(call)
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport, automaticControlEnabled: false)
        for _ in 0..<3 {
            await speaker.silenceForCapture()
            await speaker.restoreAfterCapture()
        }
        #expect(await transport.callReadCount() == 0)
        #expect(await transport.postedCalls().isEmpty)
    }

    @Test func productionEnablesRecordingOwnedAutomaticSpeakerControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "static let shared:"))
        let end = try #require(source.range(of: "    }()", range: start.upperBound..<source.endIndex))
        let composition = source[start.lowerBound..<end.upperBound]
        #expect(composition.contains("ChatGPTVoiceCaptureSpeaker(transport: transport, automaticControlEnabled: true)"))
        #expect(composition.contains("transport: transport"))
    }

    @Test func productionSpeakerToggleOnlyUsesTheConfiguredShortcutAndSameCall() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    func activeSpeakerCall()"))
        let end = try #require(source.range(of: "    /// Reuses the existing bounded reader",
                                            range: start.upperBound..<source.endIndex))
        let dispatch = source[start.lowerBound..<end.lowerBound]
        #expect(dispatch.contains("Self.configuredSpeakerShortcut()"))
        #expect(dispatch.contains("Self.voiceCall(for: application) == call"))
        #expect(dispatch.components(separatedBy: "Self.postTargetedShortcut(").count == 2)
        #expect(dispatch.contains("Self.readVoiceControls(applicationPID: call.applicationPID, channel: .speaker).isMuted == fromMuted"))
        for forbidden in ["snapshot(", "activate(", "AXPress"] {
            #expect(!dispatch.contains(forbidden))
        }
    }

    @Test func readableSameCallGetsOneOwnedTogglePerCaptureBoundary() async {
        let transport = FakeVoiceSpeakerTransport(call)
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
        let posted = ChatGPTVoiceSpeakerPost.postedDirectly(call: call, attemptedAt: transport.attemptedAt)
        #expect(await speaker.silenceForCapture() == posted)
        #expect(await speaker.silenceForCapture() == .skipped)
        #expect(await speaker.restoreAfterCapture() == posted)
        #expect(await speaker.restoreAfterCapture() == .skipped)
        #expect(await transport.postedCalls() == [call, call])
    }

    @Test func preMutedOrUnreadableSpeakersAreNeverToggledOrOwned() async {
        for state in [true, nil] as [Bool?] {
            let transport = FakeVoiceSpeakerTransport(call)
            await transport.setMuted(state)
            let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
            #expect(await speaker.silenceForCapture() == .skipped)
            await transport.setMuted(false)
            #expect(await speaker.restoreAfterCapture() == .skipped)
            #expect(await transport.postedCalls().isEmpty)
        }
    }

    @Test func newerUnmuteOrUnreadableStateCannotReceiveAnOwnedInverse() async {
        for state in [false, nil] as [Bool?] {
            let transport = FakeVoiceSpeakerTransport(call)
            let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
            await speaker.silenceForCapture()
            await transport.setMuted(state)
            #expect(await speaker.restoreAfterCapture() == .skipped)
            await transport.setMuted(true)
            #expect(await speaker.restoreAfterCapture() == .skipped)
            #expect(await transport.postedCalls() == [call])
        }
    }

    @Test func replacedOrEndedCallDoesNotReceiveRestore() async {
        for nextCall in [ChatGPTVoiceCall(applicationPID: call.applicationPID, sessionID: UUID()), nil] {
            let transport = FakeVoiceSpeakerTransport(call)
            let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
            await speaker.silenceForCapture()
            await transport.setCurrentCall(nextCall)
            #expect(await speaker.restoreAfterCapture() == .skipped)
            await transport.setCurrentCall(call)
            #expect(await speaker.restoreAfterCapture() == .skipped)
            #expect(await transport.postedCalls() == [call])
        }
    }

    @Test func aMissingBindingDoesNotPostOrAcquireRestoreOwnership() async {
        let transport = FakeVoiceSpeakerTransport(call, shortcutConfigured: false)
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
        #expect(await speaker.silenceForCapture() == .skipped)
        await transport.configureShortcut()
        #expect(await speaker.restoreAfterCapture() == .skipped)
        #expect(await transport.postedCalls().isEmpty)
    }

    @Test func speakerControlLabelsDescribeTheCurrentState() {
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Mute speakers") == false)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: " Unmute speakers ") == true)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Mute voice chat") == false)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: " Unmute voice chat ") == true)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Mute microphone") == nil)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Stop voice chat") == nil)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Start voice chat") == nil)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Toggle voice chat") == nil)
    }

    @Test func speakerLetterResolvesThroughTheLayoutBeforeItsSavedModifiers() throws {
        let configured = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Control+Shift+O"))
        let dvorak: [CGKeyCode: String] = [1: "o", 31: "r"]
        #expect(!configured.matchesLayout(producedCharacters: dvorak[configured.virtualKey]))
        let resolved = configured.resolvingCharacterKey(using: dvorak)
        #expect(resolved.virtualKey == 1)
        #expect(resolved.flags == configured.flags)
        #expect(resolved.layoutCharacter == "o")
        #expect(resolved.matchesLayout(producedCharacters: dvorak[resolved.virtualKey]))
        #expect(configured.resolvingCharacterKey(using: [31: "o"]) == configured)
    }

    @Test func speakerLayoutLookupPreservesFunctionKeysAndDoesNotInventAMapping() throws {
        let function = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Shift+F13"))
        #expect(function.resolvingCharacterKey(using: [1: "o"]) == function)
        let letter = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Control+Shift+O"))
        #expect(letter.resolvingCharacterKey(using: [:]) == letter)
        #expect(letter.resolvingCharacterKey(using: [31: "r"]) == letter)
        #expect(!letter.matchesLayout(producedCharacters: "r"))
        #expect(ChatGPTVoiceShortcut.acceptedLocal.resolvingCharacterKey(using: [1: "o"]) == .acceptedLocal)
    }

    @Test func persistedBoundariesRejectStaleEndedAndAmbiguousCalls() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let database = try #require(handle)
        defer { sqlite3_close(database) }
        let launch = Date(timeIntervalSince1970: 2)
        let older = UUID()
        let newer = UUID()
        func exec(_ sql: String) throws {
            try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        func insert(_ id: UUID, _ event: String, _ time: Int, _ sequence: Int) throws {
            try exec("""
                INSERT INTO thread_timeline_ledger VALUES
                ('local', 'thread', \(sequence), '{"sessionId":"\(id)","type":"\(event)","occurredAtMs":\(time)}')
                """)
        }
        try exec("CREATE TABLE thread_timeline_ledger(host_id, thread_id, sequence, payload_json)")
        try insert(older, "session-started", 1000, 1)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == nil)
        try insert(call.sessionID, "session-started", 3000, 2)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == call.sessionID)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveCall(since: launch, databaseURL: url)?.threadID == "thread")
        try insert(newer, "session-started", 4000, 3)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == nil)
        try insert(call.sessionID, "session-ended", 5000, 4)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == newer)
    }
}
