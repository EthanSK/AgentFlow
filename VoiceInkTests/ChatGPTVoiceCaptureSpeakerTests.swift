// Exercises recording-scoped speaker ownership without sending real shortcuts.
import Foundation
import CoreGraphics
import SQLite3
import Testing
@testable import VoiceInkPlusPlus

private actor FakeVoiceSpeakerTransport: ChatGPTVoiceSpeakerTransport {
    struct State: Sendable {
        let call: ChatGPTVoiceCall
        let isMuted: Bool?
        var hasLiveControl = true
    }

    private var current: State?
    private var posts: [Bool] = []
    private var postChangesState = true

    init(_ snapshot: State?) {
        current = snapshot
    }

    func activeSpeakerCall() -> ChatGPTVoiceCall? { current?.call }

    func postSpeakerToggle(for call: ChatGPTVoiceCall, mute: Bool) -> ChatGPTVoiceSpeakerPost {
        guard let current, current.call == call, current.hasLiveControl,
              current.isMuted != mute
        else { return .skipped }
        posts.append(mute)
        if postChangesState, current.isMuted != nil {
            self.current = .init(call: call, isMuted: mute)
        }
        return .posted(priorStateReadable: current.isMuted != nil)
    }

    func setCurrent(_ snapshot: State?) { current = snapshot }
    func ignorePostedShortcut() { postChangesState = false }
    func postedStates() -> [Bool] { posts }
}

struct ChatGPTVoiceCaptureSpeakerTests {
    private let call = ChatGPTVoiceCall(applicationPID: 42, sessionID: UUID())

    @Test func aSingleRecordingOwnsAndRestoresItsSpeakerChange() async {
        let transport = FakeVoiceSpeakerTransport(.init(call: call, isMuted: false))
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
        await speaker.silenceForCapture()
        await speaker.silenceForCapture()
        await speaker.restoreAfterCapture()
        await speaker.restoreAfterCapture()
        #expect(await transport.postedStates() == [true, false])
    }

    @Test func alreadyMutedOrUnverifiedCallsAreLeftAlone() async {
        for snapshot in [
            FakeVoiceSpeakerTransport.State(call: call, isMuted: true),
            FakeVoiceSpeakerTransport.State(call: call, isMuted: nil, hasLiveControl: false),
            nil
        ] {
            let transport = FakeVoiceSpeakerTransport(snapshot)
            let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
            await speaker.silenceForCapture()
            await speaker.restoreAfterCapture()
            #expect(await transport.postedStates().isEmpty)
        }
    }

    @Test func replacedCallOrManualUnsilenceDoesNotReceiveRestore() async {
        for snapshot in [
            FakeVoiceSpeakerTransport.State(call: .init(applicationPID: call.applicationPID, sessionID: UUID()), isMuted: true),
            FakeVoiceSpeakerTransport.State(call: call, isMuted: false),
            nil
        ] {
            let transport = FakeVoiceSpeakerTransport(.init(call: call, isMuted: false))
            let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
            await speaker.silenceForCapture()
            await transport.setCurrent(snapshot)
            await speaker.restoreAfterCapture()
            #expect(await transport.postedStates() == [true])
        }
    }

    @Test func ignoredSilenceDoesNotSendAnInverseToggle() async {
        let transport = FakeVoiceSpeakerTransport(.init(call: call, isMuted: false))
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
        await transport.ignorePostedShortcut()
        await speaker.silenceForCapture()
        await speaker.restoreAfterCapture()
        #expect(await transport.postedStates() == [true])
    }

    @Test func unreadableSpeakersOnTheSameLiveCallGetOnePairedAttempt() async {
        let transport = FakeVoiceSpeakerTransport(.init(call: call, isMuted: nil))
        let speaker = ChatGPTVoiceCaptureSpeaker(transport: transport)
        await speaker.silenceForCapture()
        await speaker.silenceForCapture()
        await speaker.restoreAfterCapture()
        await speaker.restoreAfterCapture()
        #expect(await transport.postedStates() == [true, false])
    }

    @Test func speakerControlLabelsDescribeTheCurrentState() {
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Mute speakers") == false)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: " Unmute speakers ") == true)
        #expect(SystemChatGPTVoiceMuteTransport.speakerMuteState(accessibilityLabel: "Mute microphone") == nil)
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
        try insert(newer, "session-started", 4000, 3)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == nil)
        try insert(call.sessionID, "session-ended", 5000, 4)
        #expect(ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launch, databaseURL: url) == newer)
    }
}
