import Foundation
import os
import Testing
@testable import VoiceInkPlusPlus

/// Ethan reported recordings that stopped without any Primary, Next or Cancel action.
/// These fixtures pin the bounded repair: optional realtime startup can never end
/// live capture, a superseded result can never touch the newer session that owns the
/// shared Recorder, and a cooperative quit waits for a start that has no card yet.
@Suite(.serialized)
struct RecordingStopSafetyTests {
    private enum ScriptedRealtimeError: Error {
        case providerRejected
    }

    private final class ChunkLog: @unchecked Sendable {
        private let storage = OSAllocatedUnfairLock<[UInt8]>(initialState: [])

        func append(_ data: Data) {
            storage.withLock { $0.append(contentsOf: data) }
        }

        func read() -> [UInt8] {
            storage.withLock { $0 }
        }
    }

    /// A provider attempt whose preparation result and timing are scripted. Holding
    /// reproduces a late result that arrives after the recording changed owner.
    @MainActor
    private final class ScriptedRealtimeSession: TranscriptionSession {
        enum Result {
            case failure
            case liveCallback
            case noCallback
        }

        let result: Result
        let holdsUntilReleased: Bool
        let chunks = ChunkLog()
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var isHeld = false
        private(set) var cancelCount = 0

        init(result: Result, holdsUntilReleased: Bool = false) {
            self.result = result
            self.holdsUntilReleased = holdsUntilReleased
        }

        func prepare(
            configuration: TranscriptionRuntimeConfiguration
        ) async throws -> ((Data) -> Void)? {
            if holdsUntilReleased {
                isHeld = true
                await withCheckedContinuation { gate = $0 }
                isHeld = false
            }
            switch result {
            case .failure:
                throw ScriptedRealtimeError.providerRejected
            case .liveCallback:
                let chunks = chunks
                return { chunks.append($0) }
            case .noCallback:
                return nil
            }
        }

        func release() {
            let pending = gate
            gate = nil
            pending?.resume()
        }

        func transcribe(audioURL: URL) async throws -> String { "" }

        func cancel() {
            cancelCount += 1
        }
    }

    /// Stands in for the engine's single shared-Recorder owner.
    @MainActor
    private final class CaptureOwner {
        var session: RecordingSession?
        var detachedRecorderAudio = 0

        init(_ session: RecordingSession?) {
            self.session = session
        }

        func owns(_ candidate: RecordingSession) -> Bool {
            session === candidate
                && candidate.liveRecordingState.isRecordingOrPaused
                && !candidate.shouldCancel
        }
    }

    @MainActor
    private func frozenRealtimeConfiguration() -> TranscriptionRuntimeConfiguration {
        let model = CloudModel(
            name: "realtime-stop-fixture", displayName: "Realtime stop fixture",
            description: "Offline test only", provider: .openAI,
            speed: 1, accuracy: 1, isMultilingual: true,
            supportsStreaming: true, supportedLanguages: ["en": "English"]
        )
        return TranscriptionRuntimeConfiguration(
            mode: nil, model: model, language: "en", isRealtimeEnabled: true,
            requestContext: TranscriptionRequestContext(
                language: "en", prompt: "frozen vocabulary"
            )
        )
    }

    @MainActor
    private func liveRealtimeSession(
        configuration: TranscriptionRuntimeConfiguration,
        provider: ScriptedRealtimeSession
    ) -> RecordingSession {
        let session = RecordingSession(phase: .recording)
        session.liveRecordingState = .recording
        session.audioURL = URL(
            fileURLWithPath: "/private/tmp/realtime-stop-\(UUID().uuidString).wav"
        )
        session.transcriptionConfiguration = configuration
        session.showsRealtimeTranscriptHUD = true
        // Production attaches the attempt before preparing, so a stop during
        // preparation freezes it into that recording's own pipeline job.
        session.transcriptionSession = provider
        return session
    }

    @MainActor
    private func waitUntilHeld(_ provider: ScriptedRealtimeSession) async throws {
        var turns = 0
        while !provider.isHeld && turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        try #require(provider.isHeld)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test @MainActor func activeRealtimePrepareFailureKeepsRecordingOnFrozenCompletedWAVFallback() async {
        let configuration = frozenRealtimeConfiguration()
        let provider = ScriptedRealtimeSession(result: .failure)
        let session = liveRealtimeSession(configuration: configuration, provider: provider)
        let audioURL = session.audioURL
        let router = RecordingStartupAudioRouter()
        router.receive(Data([1, 2, 3]))
        let owner = CaptureOwner(session)

        let outcome = await RealtimeTranscriptionStartup.prepare(
            streamingSession: provider,
            configuration: configuration,
            session: session,
            startupAudioRouter: router,
            ownsLiveCapture: { owner.owns(session) },
            detachRecorderAudio: { owner.detachedRecorderAudio += 1 }
        )

        #expect(outcome == .completedFileFallback(.providerPreparationFailed))
        // Capture continues: no stop, cancel, removal or change to its audio file.
        #expect(session.phase == .recording)
        #expect(session.liveRecordingState == .recording)
        #expect(!session.shouldCancel)
        #expect(session.audioURL == audioURL)
        #expect(owner.session === session)
        // Only realtime is abandoned. With no streaming session the pipeline sends the
        // complete WAV through the provider file service with this frozen request.
        #expect(session.transcriptionSession == nil)
        #expect(session.transcriptionConfiguration?.model.id == configuration.model.id)
        #expect(session.transcriptionConfiguration?.requestContext.openAITranscriptionPrompt == "frozen vocabulary")
        #expect(!session.showsRealtimeTranscriptHUD)
        #expect(provider.cancelCount == 1)
        #expect(owner.detachedRecorderAudio == 1)
        // The startup buffer is released and cannot later revive a partial stream.
        #expect(router.activate { _ in } == .closed)
    }

    @Test @MainActor func delayedPrepareFailureAfterAStoppedCannotTouchNewerSessionB() async throws {
        let configuration = frozenRealtimeConfiguration()
        let providerA = ScriptedRealtimeSession(result: .failure, holdsUntilReleased: true)
        let sessionA = liveRealtimeSession(configuration: configuration, provider: providerA)
        let routerA = RecordingStartupAudioRouter()
        let owner = CaptureOwner(sessionA)

        let preparation = Task { @MainActor in
            await RealtimeTranscriptionStartup.prepare(
                streamingSession: providerA,
                configuration: configuration,
                session: sessionA,
                startupAudioRouter: routerA,
                ownsLiveCapture: { owner.owns(sessionA) },
                detachRecorderAudio: { owner.detachedRecorderAudio += 1 }
            )
        }
        try await waitUntilHeld(providerA)

        // Primary stops A while its provider is still preparing, so A's immutable
        // pipeline job holds providerA. B then starts and owns the shared Recorder.
        sessionA.phase = .transcribing
        sessionA.liveRecordingState = .transcribing
        let providerB = ScriptedRealtimeSession(result: .liveCallback)
        let sessionB = liveRealtimeSession(configuration: configuration, provider: providerB)
        let routerB = RecordingStartupAudioRouter()
        routerB.receive(Data([7]))
        owner.session = sessionB

        providerA.release()
        let outcome = await preparation.value

        #expect(outcome == .supersededAttemptReleased)
        // B is untouched: still recording with its realtime HUD, its Recorder callback
        // never detached and its own startup audio still deliverable.
        #expect(owner.detachedRecorderAudio == 0)
        #expect(sessionB.phase == .recording)
        #expect(sessionB.liveRecordingState == .recording)
        #expect(!sessionB.shouldCancel)
        #expect(sessionB.showsRealtimeTranscriptHUD)
        #expect(sessionB.transcriptionSession === providerB)
        #expect(providerB.cancelCount == 0)
        #expect(routerB.activate { _ in } == .connected(replayedChunks: 1, replayedBytes: 1))
        // A's stopped pipeline keeps its attempt and chooses the complete-WAV fallback
        // itself; cancelling it here could turn A's transcript into a cancellation.
        #expect(sessionA.phase == .transcribing)
        #expect(sessionA.transcriptionSession === providerA)
        #expect(providerA.cancelCount == 0)
        #expect(routerA.activate { _ in } == .closed)
    }

    @Test @MainActor func delayedPrepareSuccessAfterAStoppedNeverRoutesAudioIntoA() async throws {
        let configuration = frozenRealtimeConfiguration()
        let providerA = ScriptedRealtimeSession(result: .liveCallback, holdsUntilReleased: true)
        let sessionA = liveRealtimeSession(configuration: configuration, provider: providerA)
        let routerA = RecordingStartupAudioRouter()
        routerA.receive(Data([1]))
        let owner = CaptureOwner(sessionA)

        let preparation = Task { @MainActor in
            await RealtimeTranscriptionStartup.prepare(
                streamingSession: providerA,
                configuration: configuration,
                session: sessionA,
                startupAudioRouter: routerA,
                ownsLiveCapture: { owner.owns(sessionA) },
                detachRecorderAudio: { owner.detachedRecorderAudio += 1 }
            )
        }
        try await waitUntilHeld(providerA)
        sessionA.phase = .transcribing
        sessionA.liveRecordingState = .transcribing
        owner.session = nil

        providerA.release()
        let outcome = await preparation.value

        #expect(outcome == .supersededAttemptReleased)
        routerA.receive(Data([2]))
        #expect(providerA.chunks.read().isEmpty)
        #expect(owner.detachedRecorderAudio == 0)
        #expect(providerA.cancelCount == 0)
    }

    @Test @MainActor func delayedPrepareFailureAfterCancelReleasesOnlyThatAttempt() async throws {
        let configuration = frozenRealtimeConfiguration()
        let providerA = ScriptedRealtimeSession(result: .failure, holdsUntilReleased: true)
        let sessionA = liveRealtimeSession(configuration: configuration, provider: providerA)
        let routerA = RecordingStartupAudioRouter()
        let owner = CaptureOwner(sessionA)

        let preparation = Task { @MainActor in
            await RealtimeTranscriptionStartup.prepare(
                streamingSession: providerA,
                configuration: configuration,
                session: sessionA,
                startupAudioRouter: routerA,
                ownsLiveCapture: { owner.owns(sessionA) },
                detachRecorderAudio: { owner.detachedRecorderAudio += 1 }
            )
        }
        try await waitUntilHeld(providerA)
        // Explicit cancel already owns teardown and History retention.
        sessionA.shouldCancel = true
        owner.session = nil

        providerA.release()
        let outcome = await preparation.value

        #expect(outcome == .supersededAttemptReleased)
        #expect(providerA.cancelCount == 1)
        #expect(owner.detachedRecorderAudio == 0)
        #expect(routerA.activate { _ in } == .closed)
    }

    @Test @MainActor func liveOwnerConnectsAndReplaysStartupAudioBeforeLiveChunks() async {
        let configuration = frozenRealtimeConfiguration()
        let provider = ScriptedRealtimeSession(result: .liveCallback)
        let session = liveRealtimeSession(configuration: configuration, provider: provider)
        let router = RecordingStartupAudioRouter()
        router.receive(Data([1]))
        router.receive(Data([2]))
        let owner = CaptureOwner(session)

        let outcome = await RealtimeTranscriptionStartup.prepare(
            streamingSession: provider,
            configuration: configuration,
            session: session,
            startupAudioRouter: router,
            ownsLiveCapture: { owner.owns(session) },
            detachRecorderAudio: { owner.detachedRecorderAudio += 1 }
        )
        router.receive(Data([3]))

        #expect(outcome == .connected(replayedChunks: 2, replayedBytes: 2))
        #expect(provider.chunks.read() == [1, 2, 3])
        #expect(session.showsRealtimeTranscriptHUD)
        #expect(session.transcriptionSession === provider)
        #expect(provider.cancelCount == 0)
        #expect(owner.detachedRecorderAudio == 0)
    }

    @Test @MainActor func startupOverflowAndMissingCallbackKeepCaptureOnCompletedWAV() async {
        let configuration = frozenRealtimeConfiguration()

        let overflowProvider = ScriptedRealtimeSession(result: .liveCallback)
        let overflowSession = liveRealtimeSession(configuration: configuration, provider: overflowProvider)
        let overflowRouter = RecordingStartupAudioRouter(maximumBufferedBytes: 2)
        overflowRouter.receive(Data([1, 2, 3]))
        let overflowOwner = CaptureOwner(overflowSession)
        let overflow = await RealtimeTranscriptionStartup.prepare(
            streamingSession: overflowProvider,
            configuration: configuration,
            session: overflowSession,
            startupAudioRouter: overflowRouter,
            ownsLiveCapture: { overflowOwner.owns(overflowSession) },
            detachRecorderAudio: { overflowOwner.detachedRecorderAudio += 1 }
        )
        #expect(overflow == .completedFileFallback(.startupAudioOverflow(droppedChunks: 1, droppedBytes: 3)))
        #expect(overflowProvider.chunks.read().isEmpty)
        #expect(overflowSession.phase == .recording)
        #expect(overflowSession.transcriptionSession == nil)
        #expect(!overflowSession.showsRealtimeTranscriptHUD)
        #expect(overflowProvider.cancelCount == 1)
        #expect(overflowOwner.detachedRecorderAudio == 1)

        // A paused owner is still the live capture: fallback must not turn Pause into Stop.
        let silentProvider = ScriptedRealtimeSession(result: .noCallback)
        let pausedSession = liveRealtimeSession(configuration: configuration, provider: silentProvider)
        pausedSession.liveRecordingState = .paused
        let silentRouter = RecordingStartupAudioRouter()
        let pausedOwner = CaptureOwner(pausedSession)
        let silent = await RealtimeTranscriptionStartup.prepare(
            streamingSession: silentProvider,
            configuration: configuration,
            session: pausedSession,
            startupAudioRouter: silentRouter,
            ownsLiveCapture: { pausedOwner.owns(pausedSession) },
            detachRecorderAudio: { pausedOwner.detachedRecorderAudio += 1 }
        )
        #expect(silent == .completedFileFallback(.noLiveAudioCallback))
        #expect(pausedSession.phase == .recording)
        #expect(pausedSession.liveRecordingState == .paused)
        #expect(pausedSession.transcriptionSession == nil)
        #expect(!pausedSession.showsRealtimeTranscriptHUD)
        #expect(silentProvider.cancelCount == 1)
        #expect(pausedOwner.detachedRecorderAudio == 1)
        #expect(silentRouter.activate { _ in } == .closed)
    }

    @Test func supersededStartFailureLeavesSharedCaptureToItsOwner() throws {
        for tokenIsCurrent in [false, true] {
            for registered in [false, true] {
                for ownsMic in [false, true] {
                    #expect(RecorderPanelLifecyclePolicy.startFailureOwnsCaptureTeardown(
                        startTokenIsCurrent: tokenIsCurrent,
                        sessionIsRegistered: registered,
                        sessionStillOwnsMic: ownsMic
                    ) == (tokenIsCurrent && registered && ownsMic))
                }
            }
        }

        // The hardware-start handler consults ownership before it stops the shared
        // Recorder or discards audio, and provider preparation can no longer reach it.
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let ownership = try #require(engine.range(
            of: "RecorderPanelLifecyclePolicy.startFailureOwnsCaptureTeardown("
        ))
        let failureLog = try #require(engine.range(
            of: "self.logger.error(\"Recording failed to start:",
            range: ownership.upperBound..<engine.endIndex
        ))
        let sharedStop = try #require(engine.range(
            of: "await self.recorder.stopRecording()",
            range: ownership.upperBound..<engine.endIndex
        ))
        let discard = try #require(engine.range(
            of: "discardUnusableRecordingAndJournal(for: session)",
            range: ownership.upperBound..<engine.endIndex
        ))
        #expect(failureLog.lowerBound < sharedStop.lowerBound)
        #expect(sharedStop.lowerBound < discard.lowerBound)
        #expect(!engine.contains("try await streamingSession.prepare("))
        #expect(!engine.contains("try await prepare?()"))
        #expect(engine.components(separatedBy: "await prepare?()").count - 1 == 3)
        let session = try source("VoiceInk/Transcription/Engine/RecordingSession.swift")
        #expect(session.contains("var prepareMicrophoneTranscription: (() async -> Void)?"))
        #expect(engine.contains("sessionStillOwnsMic: self.activeRecordingSession === session"))
    }

    @Test func recorderStartFailureHasNoSecondUnownedGlobalShutdown() throws {
        let recorder = try source("VoiceInk/Recorder.swift")
        let start = try #require(recorder.range(of: "func startRecording(toOutputFile"))
        let end = try #require(recorder.range(of: "func enableMicrophoneCapture()", range: start.upperBound..<recorder.endIndex))
        let body = recorder[start.lowerBound..<end.lowerBound]
        #expect(body.contains("throw error"))
        #expect(!body.contains("await stopRecording()"))
        // The serial hardware layer still closes unusable AUHAL/WAV capture;
        // only the engine may retire shared media/session state after revalidation.
        let core = try source("VoiceInk/CoreAudioRecorder.swift")
        let localStart = try #require(core.range(of: "func startRecording(toOutputFile"))
        let pause = try #require(core.range(of: "func pauseRecording()", range: localStart.upperBound..<core.endIndex))
        #expect(core[localStart.lowerBound..<pause.lowerBound].contains("teardownPreparedAudioUnit()"))
    }

    @Test @MainActor func cooperativeQuitWaitsForAStartThatHasNoSessionCardYet() throws {
        #expect(AppDelegate.shouldBlockTermination(
            hasInFlightSessions: false, hasPendingRecordingStart: true
        ))
        #expect(!AppDelegate.shouldBlockTermination(
            hasInFlightSessions: false, hasPendingRecordingStart: false
        ))
        #expect(AppDelegate.shouldBlockTermination(
            hasInFlightSessions: true, hasPendingRecordingStart: false
        ))
        let delegate = try source("VoiceInk/AppDelegate.swift")
        #expect(delegate.contains(
            "let hasPendingRecordingStart = voiceInkEngine?.hasPendingRecordingStart == true"
        ))
        #expect(delegate.contains("hasPendingRecordingStart: hasPendingRecordingStart"))
    }
}
