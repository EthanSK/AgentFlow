import Foundation

/// Resolves one recording's optional realtime-provider startup without ever owning
/// that recording's lifecycle.
///
/// By the time preparation runs, the microphone is capturing, the start sound has
/// played and the WAV plus its crash-recovery journal exist. Realtime only adds the
/// HUD-only partial preview and an earlier provider final. It never owns the shared
/// Recorder, the WAV, the journal, History, the recorder panel, or a Primary/Next
/// destination route.
///
/// A thrown preparation used to escape into the recorder-start failure handler, which
/// stops the shared Recorder, deletes the WAV and journal, removes the session and
/// dismisses the HUD. That is right for a microphone that never opened, but it would
/// end a recording that is already capturing speech, and a late failure could stop a
/// newer session that now owns the Recorder. Every outcome is therefore resolved here,
/// without throwing, into exactly one of:
///  - connected: replay buffered startup PCM in order, then stream live chunks;
///  - completedFileFallback: the session still owns live capture. Keep recording,
///    abandon only realtime, and let the stopped recording transcribe its complete WAV
///    through the pipeline's file path with the configuration frozen at start;
///  - supersededAttemptReleased: the session stopped, was canceled or lost capture
///    while preparation was suspended. Touch nothing shared and never act for a newer
///    session.
@MainActor
enum RealtimeTranscriptionStartup {
    enum FallbackReason: Equatable {
        case providerPreparationFailed
        case startupAudioOverflow(droppedChunks: Int, droppedBytes: Int)
        case startupRouterClosed
        case noLiveAudioCallback
    }

    enum Outcome: Equatable {
        case connected(replayedChunks: Int, replayedBytes: Int)
        case completedFileFallback(FallbackReason)
        case supersededAttemptReleased
    }

    /// - Parameters:
    ///   - streamingSession: This recording's provider attempt. The caller attaches it
    ///     as `session.transcriptionSession` first, so a stop during preparation freezes
    ///     it into that recording's own pipeline job.
    ///   - configuration: The per-recording configuration frozen before preparation.
    ///   - ownsLiveCapture: Re-evaluated after the suspension. True only while this
    ///     exact session and start token still own recording or paused capture.
    ///   - detachRecorderAudio: Clears the shared Recorder's chunk callback. It is
    ///     called only while `ownsLiveCapture()` is true, so it cannot detach a newer
    ///     session's callback.
    static func prepare(
        streamingSession: any TranscriptionSession,
        configuration: TranscriptionRuntimeConfiguration,
        session: RecordingSession,
        startupAudioRouter: RecordingStartupAudioRouter,
        ownsLiveCapture: @MainActor () -> Bool,
        detachRecorderAudio: @MainActor () -> Void
    ) async -> Outcome {
        let liveCallback: ((Data) -> Void)?
        do {
            liveCallback = try await streamingSession.prepare(configuration: configuration)
        } catch {
            guard ownsLiveCapture() else {
                return releaseSupersededAttempt(
                    streamingSession,
                    session: session,
                    startupAudioRouter: startupAudioRouter
                )
            }
            fallBackToCompletedFile(
                streamingSession,
                session: session,
                startupAudioRouter: startupAudioRouter,
                detachRecorderAudio: detachRecorderAudio
            )
            return .completedFileFallback(.providerPreparationFailed)
        }

        // `prepare` is async. Session A may have stopped and session B may now own the
        // shared Recorder while it was suspended. Never install A's callback into B's
        // recorder: that would route B's microphone chunks into A's provider.
        guard ownsLiveCapture() else {
            return releaseSupersededAttempt(
                streamingSession,
                session: session,
                startupAudioRouter: startupAudioRouter
            )
        }

        guard let liveCallback else {
            fallBackToCompletedFile(
                streamingSession,
                session: session,
                startupAudioRouter: startupAudioRouter,
                detachRecorderAudio: detachRecorderAudio
            )
            return .completedFileFallback(.noLiveAudioCallback)
        }

        switch startupAudioRouter.activate(liveCallback) {
        case .connected(let replayedChunks, let replayedBytes):
            return .connected(
                replayedChunks: replayedChunks,
                replayedBytes: replayedBytes
            )
        case .fallbackRequired(let droppedChunks, let droppedBytes):
            // The WAV has every frame. Keep the recording usable by disabling only its
            // incomplete realtime session; stop then uses the same frozen prompt and
            // Vocabulary with completed-file audio.
            fallBackToCompletedFile(
                streamingSession,
                session: session,
                startupAudioRouter: startupAudioRouter,
                detachRecorderAudio: detachRecorderAudio
            )
            return .completedFileFallback(
                .startupAudioOverflow(
                    droppedChunks: droppedChunks,
                    droppedBytes: droppedBytes
                )
            )
        case .closed:
            fallBackToCompletedFile(
                streamingSession,
                session: session,
                startupAudioRouter: startupAudioRouter,
                detachRecorderAudio: detachRecorderAudio
            )
            return .completedFileFallback(.startupRouterClosed)
        }
    }

    /// The session still owns live capture. Abandon only realtime: no stop, cancel,
    /// session removal, WAV/journal change, panel dismissal or destination change.
    private static func fallBackToCompletedFile(
        _ streamingSession: any TranscriptionSession,
        session: RecordingSession,
        startupAudioRouter: RecordingStartupAudioRouter,
        detachRecorderAudio: @MainActor () -> Void
    ) {
        streamingSession.cancel()
        if session.transcriptionSession === streamingSession {
            // With no streaming session the pipeline transcribes the complete WAV via
            // the provider's file service and this session's frozen configuration.
            session.transcriptionSession = nil
        }
        session.showsRealtimeTranscriptHUD = false
        startupAudioRouter.close()
        detachRecorderAudio()
    }

    /// The session no longer owns live capture. Only its own startup buffer is
    /// released. Never touch the shared Recorder, WAV, journal, panel or a newer session.
    private static func releaseSupersededAttempt(
        _ streamingSession: any TranscriptionSession,
        session: RecordingSession,
        startupAudioRouter: RecordingStartupAudioRouter
    ) -> Outcome {
        // This router belongs only to the superseded recording. A newer recording has
        // its own router installed on the shared Recorder.
        startupAudioRouter.close()
        if session.shouldCancel || session.phase == .done {
            // Cancel or reset already owns teardown and History retention; releasing
            // this provider attempt again is idempotent.
            streamingSession.cancel()
        }
        // A normally stopped recording's immutable pipeline job may already hold this
        // exact attempt. Leave it attached: its own finalization awaits the startup
        // result and falls back to the complete WAV. Cancelling it here could turn that
        // recording's transcript into a cancellation.
        return .supersededAttemptReleased
    }
}
