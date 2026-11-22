import Foundation
import Darwin
import Testing
@testable import VoiceInkPlusPlus

// These transports exercise real coordinator ownership without touching a Voice call.
private actor CaptureBoundarySpeakerTransport: ChatGPTVoiceSpeakerTransport {
    let call: ChatGPTVoiceCall
    private var muted = false
    private var posts: [Bool] = []
    init(call: ChatGPTVoiceCall) { self.call = call }
    func activeSpeakerCall() -> ChatGPTVoiceCall? { call }
    func postSpeakerToggle(for call: ChatGPTVoiceCall, mute: Bool) -> ChatGPTVoiceSpeakerPost {
        guard call == self.call, muted != mute else { return .skipped }
        muted = mute
        posts.append(mute)
        return .posted(priorStateReadable: true)
    }
    func postedStates() -> [Bool] { posts }
}

private actor FakeChatGPTVoiceMuteTransport: ChatGPTVoiceMuteTransport {
    var currentSnapshot: ChatGPTVoiceInputSnapshot?
    var allowsPost = true
    var changesStateOnPost = true
    var postPIDs: [pid_t] = []

    init(snapshot: ChatGPTVoiceInputSnapshot?) {
        currentSnapshot = snapshot
    }

    func snapshot() async -> ChatGPTVoiceInputSnapshot? {
        currentSnapshot
    }

    func postMicrophoneToggle(
        from before: ChatGPTVoiceInputSnapshot,
        toward target: ChatGPTVoiceMicrophoneState,
        using authority: ChatGPTVoiceShortcutAuthority
    ) async -> Date? {
        guard let call = before.call else { return nil }
        postPIDs.append(call.applicationPID)
        guard allowsPost, currentSnapshot?.call == call else { return nil }
        if changesStateOnPost,
           let currentSnapshot {
            self.currentSnapshot = ChatGPTVoiceInputSnapshot(
                applicationPID: call.applicationPID,
                isInputRunning: currentSnapshot.isInputRunning,
                microphoneState: currentSnapshot.microphoneState.map {
                    $0 == .listening ? .muted : .listening
                },
                call: call
            )
        }
        return Date()
    }

    func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) async -> ChatGPTVoiceMicrophoneState? {
        currentSnapshot?.call == call ? currentSnapshot?.microphoneState : nil
    }

    func setSnapshot(_ snapshot: ChatGPTVoiceInputSnapshot?) {
        currentSnapshot = snapshot
    }

    func setAllowsPost(_ allowsPost: Bool) {
        self.allowsPost = allowsPost
    }

    func setChangesStateOnPost(_ changesStateOnPost: Bool) {
        self.changesStateOnPost = changesStateOnPost
    }

    func postedPIDs() -> [pid_t] {
        postPIDs
    }
}

// Models the real failure: a successful toggle can temporarily hide both AX
// controls. Read both channels before the microphone action, without a timer,
// retry, live call or a second source of mute state in the coordinator.
private actor RepaintingVoiceTransport: ChatGPTVoiceMuteTransport, ChatGPTVoiceSpeakerTransport {
    let call = ChatGPTVoiceCall(applicationPID: 42, sessionID: UUID())
    private var microphoneMuted: Bool
    private var speakerMuted: Bool
    private var controlsReadable = true
    private var commands: [String] = []

    init(microphoneMuted: Bool = false, speakerMuted: Bool = false) {
        self.microphoneMuted = microphoneMuted
        self.speakerMuted = speakerMuted
    }

    func snapshot() -> ChatGPTVoiceInputSnapshot? {
        .init(applicationPID: call.applicationPID, isInputRunning: true,
              microphoneState: controlsReadable ? (microphoneMuted ? .muted : .listening) : nil,
              call: call)
    }

    func postMicrophoneToggle(
        from before: ChatGPTVoiceInputSnapshot, toward target: ChatGPTVoiceMicrophoneState,
        using authority: ChatGPTVoiceShortcutAuthority
    ) -> Date? {
        guard before.call == call else { return nil }
        commands.append(target == .muted ? "mic mute" : "mic restore")
        microphoneMuted.toggle()
        controlsReadable = false
        return Date()
    }

    func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) -> ChatGPTVoiceMicrophoneState? {
        guard self.call == call, controlsReadable else { return nil }
        return microphoneMuted ? .muted : .listening
    }

    func activeSpeakerCall() -> ChatGPTVoiceCall? { call }

    func postSpeakerToggle(for call: ChatGPTVoiceCall, mute: Bool) -> ChatGPTVoiceSpeakerPost {
        guard self.call == call, controlsReadable, speakerMuted != mute else { return .skipped }
        commands.append(mute ? "speaker mute" : "speaker restore")
        speakerMuted.toggle()
        controlsReadable = false
        return .posted(priorStateReadable: true)
    }

    func revealControls(manualMicrophoneMuted: Bool? = nil) {
        if let manualMicrophoneMuted { microphoneMuted = manualMicrophoneMuted }
        controlsReadable = true
    }

    func postedCommands() -> [String] { commands }
}

private actor CapturingVoiceEventSender: CodexVoiceCaptureEventSending {
    private var events: [CodexVoiceCaptureEvent] = []
    func record(_ event: CodexVoiceCaptureEvent) { events.append(event) }
    func recorded() -> [CodexVoiceCaptureEvent] { events }
}

struct ChatGPTVoiceCaptureMuteCoordinatorTests {
    private let pid: pid_t = 4_242
    private let sessionID = UUID()

    private func voice(
        _ state: ChatGPTVoiceMicrophoneState?,
        isInputRunning: Bool = true
    ) -> ChatGPTVoiceInputSnapshot {
        .init(applicationPID: pid, isInputRunning: isInputRunning, microphoneState: state,
              call: isInputRunning ? .init(applicationPID: pid, sessionID: sessionID) : nil)
    }

    @Test func failedHardwareStartupDoesNotInventARecordingEvent() async {
        let events = CapturingVoiceEventSender()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening)), events: events)
        let lease = await coordinator.prepareForCapture()
        #expect(await events.recorded().isEmpty)
        await coordinator.captureAborted(lease)
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await events.recorded().isEmpty)
    }

    @Test func hardwareStopBeforeStartContinuationStillReportsOneOrderedSegment() async throws {
        let events = CapturingVoiceEventSender()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening)), events: events)
        let lease = await coordinator.prepareForCapture()
        await coordinator.captureStopped(lease, at: Date(timeIntervalSince1970: 2), reason: "stopped")
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await events.recorded().isEmpty)
        await coordinator.captureStarted(lease, at: Date(timeIntervalSince1970: 1))
        let result = await events.recorded()
        #expect(result.map(\.phase) == ["started", "stopped"])
        #expect(result.map(\.occurredAt) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
    }

    @Test func actualCaptureEventsKeepExactTimesAndFrozenOwningVoiceChat() async throws {
        let call = ChatGPTVoiceCall(applicationPID: pid, sessionID: sessionID, threadID: UUID())
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid, isInputRunning: true, microphoneState: .listening, call: call))
        let events = CapturingVoiceEventSender()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport, events: events)
        let lease = await coordinator.prepareForCapture()
        let start = Date(timeIntervalSince1970: 123.456)
        let stop = Date(timeIntervalSince1970: 125.678)
        await coordinator.captureStarted(lease, at: start)
        await coordinator.captureStopped(lease, at: stop, reason: "stopped")
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        let result = await events.recorded()
        #expect(result.count == 2)
        let began = try #require(result.first)
        let ended = try #require(result.last)
        #expect(began.id == ended.id)
        #expect(began.call == call && ended.call == call)
        #expect(began.occurredAt == start && ended.occurredAt == stop)
        #expect(ended.startedAt == start)
        #expect(began.microphoneResult == "mutedVerified")
        #expect(ended.microphoneResult == "restoredVerified")
        #expect(began.microphoneAttemptedAt != nil && ended.microphoneAttemptedAt != nil)
    }

    @Test func staleCaptureEventCannotRetargetOrRestoreTheReplacementVoiceCall() async throws {
        let old = ChatGPTVoiceCall(applicationPID: pid, sessionID: sessionID, threadID: UUID())
        let new = ChatGPTVoiceCall(applicationPID: pid, sessionID: UUID(), threadID: UUID())
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid, isInputRunning: true, microphoneState: .listening, call: old))
        let events = CapturingVoiceEventSender()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport, events: events)
        let a = await coordinator.prepareForCapture()
        await coordinator.captureStarted(a, at: Date(timeIntervalSince1970: 1))
        await transport.setSnapshot(.init(applicationPID: pid, isInputRunning: true,
                                          microphoneState: .listening, call: new))
        let b = await coordinator.prepareForCapture()
        await coordinator.captureStarted(b, at: Date(timeIntervalSince1970: 2))
        await coordinator.captureStopped(a, at: Date(timeIntervalSince1970: 3), reason: "stopped")
        await coordinator.releaseCapture(a)
        #expect(await transport.postedPIDs().count == 2)
        await coordinator.captureStopped(b, at: Date(timeIntervalSince1970: 4), reason: "stopped")
        await coordinator.releaseCapture(b)
        await coordinator.waitForPendingTransitionsForTesting()
        let result = await events.recorded()
        #expect(result.map(\.call) == [old, new, old, new])
        #expect(result[2].microphoneResult == "heldByOtherCapture")
        #expect(result[2].microphoneAttemptedAt == nil)
        #expect(result[3].microphoneResult == "restoredVerified")
    }

    @Test func pausedAndResumedCaptureEventsAreDistinctHardwareSegments() async throws {
        let events = CapturingVoiceEventSender()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening)), events: events)
        for reason in ["paused", "stopped"] {
            let lease = await coordinator.prepareForCapture()
            await coordinator.captureStarted(lease, at: Date(timeIntervalSince1970: 10))
            await coordinator.captureStopped(lease, at: Date(timeIntervalSince1970: 11), reason: reason)
            await coordinator.releaseCapture(lease)
            await coordinator.waitForPendingTransitionsForTesting()
        }
        let result = await events.recorded()
        #expect(result.map(\.phase) == ["started", "paused", "started", "stopped"])
        #expect(result[0].id == result[1].id && result[2].id == result[3].id)
        #expect(result[0].id != result[2].id)
    }

    @Test func alreadyMutedCaptureEventsDoNotClaimAnOwnedMuteOrUnmute() async throws {
        let events = CapturingVoiceEventSender()
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.muted))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport, events: events)
        let lease = await coordinator.prepareForCapture()
        await coordinator.captureStarted(lease, at: Date())
        await coordinator.captureStopped(lease, at: Date(), reason: "stopped")
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        let result = await events.recorded()
        #expect(result.map(\.microphoneResult) == ["alreadyMuted", "notOwned"])
        #expect(result.allSatisfy { $0.microphoneAttemptedAt == nil })
        #expect(await transport.postedPIDs().isEmpty)
    }

    @Test func disabledSpeakersKeepMicrophoneMuteAndManualStateProtection() async {
        for manuallyMuted in [false, true] {
            let transport = RepaintingVoiceTransport(microphoneMuted: manuallyMuted)
            let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport,
                speaker: ChatGPTVoiceCaptureSpeaker(transport: transport, automaticControlEnabled: false))
            let lease = await coordinator.prepareForCapture()
            #expect(await transport.postedCommands() == (manuallyMuted ? [] : ["mic mute"]))
            await transport.revealControls()
            await coordinator.releaseCapture(lease)
            await coordinator.waitForPendingTransitionsForTesting()
            #expect(await transport.postedCommands() == (manuallyMuted ? [] : ["mic mute", "mic restore"]))
        }
    }

    @Test func speakerChecksAndRestorationPrecedeTheMicrophoneRepaint() async {
        let transport = RepaintingVoiceTransport()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: transport))
        let lease = await coordinator.prepareForCapture()
        #expect(await transport.postedCommands() == ["speaker mute", "mic mute"])
        await transport.revealControls()
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedCommands() == ["speaker mute", "mic mute", "speaker restore", "mic restore"])
    }

    @Test func speakerRepaintDoesNotUnmuteAnInitiallyManuallyMutedMicrophone() async {
        let transport = RepaintingVoiceTransport(microphoneMuted: true)
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: transport))
        let lease = await coordinator.prepareForCapture()
        await transport.revealControls()
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedCommands() == ["speaker mute", "speaker restore"])
    }

    @Test func speakerRestorationRepaintPreservesAManualMicrophoneUnmute() async {
        let transport = RepaintingVoiceTransport()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: transport))
        let lease = await coordinator.prepareForCapture()
        await transport.revealControls(manualMicrophoneMuted: false)
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedCommands() == ["speaker mute", "mic mute", "speaker restore"])
    }

    @Test func manualSpeakerMuteRemainsUnownedAcrossTheOrderedTransition() async {
        let transport = RepaintingVoiceTransport(speakerMuted: true)
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: transport))
        let lease = await coordinator.prepareForCapture()
        await transport.revealControls()
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedCommands() == ["mic mute", "mic restore"])
    }

    @Test func speakerRestoresAcrossCaptureOffResumeAndFinalCompletion() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let speakers = CaptureBoundarySpeakerTransport(call: .init(applicationPID: pid, sessionID: sessionID))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: speakers))
        // Recorder's HUD mic-off and Pause both release the same capture lease;
        // mic-on and Resume reacquire it. Final completion releases the last one.
        for _ in 0..<3 {
            let lease = await coordinator.prepareForCapture()
            await coordinator.releaseCapture(lease)
            await coordinator.waitForPendingTransitionsForTesting()
        }
        #expect(await speakers.postedStates() == [true, false, true, false, true, false])
    }

    @Test func staleCaptureOffCannotRestoreSpeakersDuringANewerCapture() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let speakers = CaptureBoundarySpeakerTransport(call: .init(applicationPID: pid, sessionID: sessionID))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, speaker: ChatGPTVoiceCaptureSpeaker(transport: speakers))
        let older = await coordinator.prepareForCapture()
        let current = await coordinator.prepareForCapture()
        await coordinator.releaseCapture(older)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await speakers.postedStates() == [true])
        await coordinator.releaseCapture(current)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await speakers.postedStates() == [true, false])
    }

    @Test func activeVoiceIsMutedAndOwnedThenRestored() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        var state = await coordinator.stateForTesting()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        var postPIDs = await transport.postedPIDs()
        #expect(postPIDs == [pid])

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        state = await coordinator.stateForTesting()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        postPIDs = await transport.postedPIDs()
        let restoredSnapshot = await transport.snapshot()
        #expect(postPIDs == [pid, pid])
        #expect(restoredSnapshot?.isInputRunning == true)
        #expect(restoredSnapshot?.microphoneState == .listening)
    }

    @Test func capturePreparationReturnsOnlyAfterTheMuteTransitionCompletes() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        _ = await coordinator.prepareForCapture()

        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        let snapshot = await transport.snapshot()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        #expect(postPIDs == [pid])
        #expect(snapshot?.microphoneState == .muted)
    }

    @Test func absentOrAlreadyInactiveVoiceIsNeverToggledOrOwned() async {
        let absent = FakeChatGPTVoiceMuteTransport(snapshot: nil)
        let absentCoordinator = makeCoordinator(absent)
        _ = await absentCoordinator.prepareForCapture()
        let absentPostPIDs = await absent.postedPIDs()
        let absentState = await absentCoordinator.stateForTesting()
        #expect(absentPostPIDs.isEmpty)
        #expect(absentState.ownedMutedApplicationPID == nil)

        let inactive = FakeChatGPTVoiceMuteTransport(snapshot: voice(nil, isInputRunning: false))
        let inactiveCoordinator = makeCoordinator(inactive)
        _ = await inactiveCoordinator.prepareForCapture()
        let inactivePostPIDs = await inactive.postedPIDs()
        let inactiveState = await inactiveCoordinator.stateForTesting()
        #expect(inactivePostPIDs.isEmpty)
        #expect(inactiveState.ownedMutedApplicationPID == nil)

        let alreadyMuted = FakeChatGPTVoiceMuteTransport(snapshot: voice(.muted))
        let alreadyMutedCoordinator = makeCoordinator(alreadyMuted)
        _ = await alreadyMutedCoordinator.prepareForCapture()
        let alreadyMutedPostPIDs = await alreadyMuted.postedPIDs()
        let alreadyMutedState = await alreadyMutedCoordinator.stateForTesting()
        #expect(alreadyMutedPostPIDs.isEmpty)
        #expect(alreadyMutedState.ownedMutedApplicationPID == nil)
    }

    @Test func aReadableFailedToggleIsNotInvertedAtStop() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        await transport.setChangesStateOnPost(false)
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        var postPIDs = await transport.postedPIDs()
        var state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(state.ownedMutedApplicationPID == nil)
        await transport.setSnapshot(voice(nil))

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        postPIDs = await transport.postedPIDs()
        state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
    }

    @Test func shortcutPostFailureLeavesCaptureUsableAndUnowned() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        await transport.setAllowsPost(false)
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        var state = await coordinator.stateForTesting()
        var postPIDs = await transport.postedPIDs()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid])

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        state = await coordinator.stateForTesting()
        postPIDs = await transport.postedPIDs()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid])
    }

    @Test func unreadableBackgroundControlUsesOnePairedLease() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(nil))
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        var state = await coordinator.stateForTesting()
        var postPIDs = await transport.postedPIDs()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        #expect(postPIDs == [pid])

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        state = await coordinator.stateForTesting()
        postPIDs = await transport.postedPIDs()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid, pid])
    }

    @Test func endedUnreadableVoiceSessionIsNotInvertedAtStop() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(nil))
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        await transport.setSnapshot(voice(nil, isInputRunning: false))

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid])
    }

    @Test func userReenabledInputRelinquishesOwnershipWithoutInverseToggle() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        await transport.setSnapshot(voice(.listening))

        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid])
    }

    @Test func pauseResumeAndRapidCyclesEndInTheNewestCaptureState() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        let firstLease = await coordinator.prepareForCapture()
        await coordinator.releaseCapture(firstLease)
        _ = await coordinator.prepareForCapture()

        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        let snapshot = await transport.snapshot()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        #expect(postPIDs == [pid, pid, pid])
        #expect(snapshot?.isInputRunning == true)
        #expect(snapshot?.microphoneState == .muted)
    }

    @Test func staleReleaseCannotUnmuteANewerCaptureLease() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        let olderLease = await coordinator.prepareForCapture()
        let newerLease = await coordinator.prepareForCapture()
        await coordinator.releaseCapture(olderLease)
        await coordinator.waitForPendingTransitionsForTesting()

        var state = await coordinator.stateForTesting()
        var postPIDs = await transport.postedPIDs()
        var snapshot = await transport.snapshot()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        #expect(postPIDs == [pid])
        #expect(snapshot?.microphoneState == .muted)

        await coordinator.releaseCapture(newerLease)
        await coordinator.waitForPendingTransitionsForTesting()
        state = await coordinator.stateForTesting()
        postPIDs = await transport.postedPIDs()
        snapshot = await transport.snapshot()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid, pid])
        #expect(snapshot?.microphoneState == .listening)
    }

    @Test func aChangedChatGPTProcessIsNeverRestored() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)

        let lease = await coordinator.prepareForCapture()
        await transport.setSnapshot(.init(
            applicationPID: pid + 1,
            isInputRunning: true,
            microphoneState: .muted,
            call: .init(applicationPID: pid + 1, sessionID: UUID())
        ))
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()

        let postPIDs = await transport.postedPIDs()
        let state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(state.ownedMutedApplicationPID == nil)
    }

    @Test func aReplacementOrUnidentifiedCallInTheSameProcessIsNeverRestored() async {
        for replacement in [ChatGPTVoiceCall(applicationPID: pid, sessionID: UUID()), nil] {
            let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
            let coordinator = makeCoordinator(transport)
            let lease = await coordinator.prepareForCapture()
            await transport.setSnapshot(.init(applicationPID: pid, isInputRunning: true,
                                              microphoneState: .muted, call: replacement))

            await coordinator.releaseCapture(lease)
            await coordinator.waitForPendingTransitionsForTesting()
            #expect(await transport.postedPIDs() == [pid])
            #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == nil)
        }
    }

    @Test func aRefusedRestoreCannotKeepMuteOwnershipForTheNextRecording() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: voice(.listening))
        let coordinator = makeCoordinator(transport)
        let first = await coordinator.prepareForCapture()
        await transport.setAllowsPost(false)
        await coordinator.releaseCapture(first)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == nil)

        // A later manual unmute is a fresh listening state, even in the same call.
        await transport.setSnapshot(voice(.listening))
        await transport.setAllowsPost(true)
        let next = await coordinator.prepareForCapture()
        #expect(await transport.snapshot()?.microphoneState == .muted)
        await coordinator.releaseCapture(next)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.snapshot()?.microphoneState == .listening)
    }

    @Test func inputActivityWithoutAnIdentifiedCallDoesNotSendAShortcut() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid, isInputRunning: true, microphoneState: nil, call: nil
        ))
        let coordinator = makeCoordinator(transport)
        let lease = await coordinator.prepareForCapture()
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedPIDs().isEmpty)
    }

    @Test func executableBoundaryRejectsCodexAndAcceptsOnlyChatGPTBundle() {
        #expect(SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        ))
        #expect(SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex (Service).app/Contents/MacOS/Codex (Service)"
        ))
        #expect(!SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/Codex.app/Contents/MacOS/Codex"
        ))
        #expect(!SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/private/tmp/ChatGPT.app/Contents/MacOS/ChatGPT"
        ))
    }

    @Test func shortcutTimestampsUseNanosecondsFromTheUptimeClock() {
        let lower = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let stamp = SystemChatGPTVoiceMuteTransport.shortcutEventTimestamp()
        let upper = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(stamp >= lower)
        #expect(stamp <= upper)
    }

    @Test func shortcutBindingMustMatchTheExactSupportedCommandAndAccelerator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")

        try Data(#"[{"command":"realtimeVoice.toggleMicrophoneMute","key":"Command+Control+Option+Shift+F20"}]"#.utf8)
            .write(to: file)
        #expect(SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))

        try Data(#"[{"command":"realtimeVoice.toggleOutputMute","key":"Command+Control+Option+Shift+F20"}]"#.utf8)
            .write(to: file)
        #expect(!SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))

        try Data(#"[{"command":"realtimeVoice.toggleMicrophoneMute","key":"Alt+M"}]"#.utf8)
            .write(to: file)
        #expect(!SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))
    }

    @Test func accessibilityLabelsDistinguishListeningFromMutedWithoutInferringAudioState() {
        #expect(SystemChatGPTVoiceMuteTransport.microphoneState(
            accessibilityLabel: "Mute microphone"
        ) == .listening)
        #expect(SystemChatGPTVoiceMuteTransport.microphoneState(
            accessibilityLabel: " Unmute microphone \n"
        ) == .muted)
        #expect(SystemChatGPTVoiceMuteTransport.microphoneState(
            accessibilityLabel: "Turn off microphone"
        ) == .listening)
        #expect(SystemChatGPTVoiceMuteTransport.microphoneState(
            accessibilityLabel: "Turn on microphone"
        ) == .muted)
        #expect(SystemChatGPTVoiceMuteTransport.microphoneState(
            accessibilityLabel: "Mute speaker"
        ) == nil)
    }

    @Test func recorderHardwareCaptureOwnsTheLeaseAndNoTranscriptionOrNotifierPathDoes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recorder = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/Recorder.swift"),
            encoding: .utf8
        )
        let recorderUIManager = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/RecorderUIManager.swift"
            ),
            encoding: .utf8
        )
        let notifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Notifications/RecordingActivityNotifier.swift"
            ),
            encoding: .utf8
        )
        let transcriptionDirectory = repositoryRoot.appendingPathComponent("VoiceInk/Transcription")
        let transcriptionSources = try FileManager.default
            .subpathsOfDirectory(atPath: transcriptionDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .map {
                try String(
                    contentsOf: transcriptionDirectory.appendingPathComponent($0),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        #expect(recorder.components(separatedBy:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.prepareForCapture()"
        ).count - 1 == 2)
        #expect(recorder.components(separatedBy:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.releaseCapture("
        ).count - 1 == 3)

        let startPreparation = try #require(recorder.range(of:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.prepareForCapture()"
        ))
        let hardwareStart = try #require(recorder.range(of:
            "coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)"
        ))
        let startSound = try #require(recorder.range(of:
            "SoundManager.shared.playStartSound()"
        ))
        #expect(startPreparation.lowerBound < hardwareStart.lowerBound)
        #expect(startPreparation.lowerBound < startSound.lowerBound)
        #expect(startSound.lowerBound < hardwareStart.lowerBound)
        #expect(!recorderUIManager.contains("SoundManager.shared.playStartSound()"))

        let resumeFunction = try #require(recorder.range(of:
            "    func resumeRecording() async throws {"
        ))
        let stopFunction = try #require(recorder.range(of:
            "    func stopRecording("
        ))
        let resumeBody = recorder[resumeFunction.lowerBound..<stopFunction.lowerBound]
        let resumePreparation = try #require(resumeBody.range(of:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.prepareForCapture()"
        ))
        let hardwareResume = try #require(resumeBody.range(of:
            "currentRecorder.resumeRecording()"
        ))
        #expect(resumePreparation.lowerBound < hardwareResume.lowerBound)
        #expect(resumeBody.contains(
            "ChatGPTVoiceCaptureMuteCoordinator.shared.releaseCapture(muteLease)"
        ))
        #expect(!notifier.contains("ChatGPTVoiceCaptureMuteCoordinator.shared"))
        #expect(!transcriptionSources.contains("ChatGPTVoiceCaptureMuteCoordinator"))
    }

    @Test func targetedShortcutAndReadOnlyStateCannotMutateAccessibilityOrPointer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("keyDown.postToPid(applicationPID)"))
        #expect(source.contains("keyUp.postToPid(applicationPID)"))
        #expect(source.contains("AXUIElementCopyAttributeValue"))
        #expect(source.contains("try await Task.sleep(nanoseconds: 150_000_000)"))
        #expect(!source.contains("for _ in 0..<"))
        #expect(!source.contains(".activate(options:"))
        #expect(!source.contains("CGEvent(mouseEventSource:"))
        #expect(!source.contains("AXUIElementPerformAction"))
        #expect(!source.contains("AXUIElementSetAttributeValue"))
        #expect(!source.contains("RecordingActivityNotifier.post"))
    }

    private func makeCoordinator(
        _ transport: FakeChatGPTVoiceMuteTransport
    ) -> ChatGPTVoiceCaptureMuteCoordinator {
        ChatGPTVoiceCaptureMuteCoordinator(transport: transport)
    }
}
