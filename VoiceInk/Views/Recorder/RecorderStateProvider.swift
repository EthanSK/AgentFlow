import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var completionDisposition: RecordingCompletionDisposition { get }
    var liveSelectionReferences: [LiveSelectionReference] { get }
    var liveContextPreviewReferences: [LiveSelectionReference] { get }
    var liveContextPreviewParts: [LiveSelectionReference.PreviewPart] { get }
    var canTypeInHUD: Bool { get }
    var typedInput: String { get }
    var typingFocusController: RecorderTypingFocus? { get }
    var typingUndoController: RecorderTypingUndoController? { get }
    var microphoneOff: Bool { get }
    var potentialTTSActive: Bool { get }
    var microphoneTransitionPending: Bool { get }
    func toggleMicrophone()
    func togglePause()
    func updateTypedInput(_ value: String)
    func endTypingRun()
    func submitTypedInput()
    // A realtime provider owns a live-text HUD from recording start, even before
    // its first partial arrives. This is presentation state only: the placeholder
    // never enters the transcript or either Primary/Next delivery route.
    var showsRealtimeTranscriptHUD: Bool { get }
    var pasteDestinationIndicatorTarget: FocusLockService.Target? { get } // While recording this previews the Next Track destination; after stop it follows the session's actual pending paste target until delivery finishes.
    var iconActionPulse: RecorderIconActionPulse? { get } // Primary normal stop flashes the left/current icon; either accepted Next-button route flashes the right/locked icon.

    // VIPP (skip-mode-processing feature): the per-session, one-shot "skip post-processing
    // for THIS recording" flag. SETTABLE here so the recorder's toggle button (which is
    // bound to whatever RecorderStateProvider its card observes — normally the live
    // RecordingSession) can flip it DURING recording. Reading/writing it through the
    // protocol keeps the generic Mini/NotchRecorderView<S: RecorderStateProvider> able to
    // drive the button's on/off state directly off the observed object, mirroring how the
    // existing per-session-observation pattern works (no stateless closure threading needed).
    //
    // Semantics (see RecordingSession.skipPostProcessing for the authoritative doc):
    //   • true  → this single dictation pastes the RAW transcript: NO AI enhancement and
    //             NO mode custom-command/script. It does NOT change the user's default mode.
    //   • false → normal behaviour (the active Mode's full post-processing runs).
    // It is per-session + one-shot: the next recording starts a fresh RecordingSession with
    // the flag back at false.
    var skipPostProcessing: Bool { get set }
}

extension RecorderStateProvider {
    // Context colors acknowledge provider words, not microphone intent, a moving
    // meter, typing, or captured selections. This is only HUD presentation: batch
    // capture/realtime fallback stays unconfirmed until stop, and saved context
    // plus the single Primary/Next delivery remain unchanged. Typing-only and
    // retained/transcribing cards are not waiting for live microphone recognition.
    var dimsContextUntilSpeechArrives: Bool {
        guard !microphoneOff,
              recordingState == .starting || recordingState == .recording else { return false }
        return !showsRealtimeTranscriptHUD
            || !partialTranscript.contains(where: { !$0.isWhitespace })
    }

    var showsRealtimeTranscriptHUD: Bool { false }
    var completionDisposition: RecordingCompletionDisposition { .normalDelivery }
    var liveSelectionReferences: [LiveSelectionReference] { [] }
    var liveContextPreviewReferences: [LiveSelectionReference] { liveSelectionReferences }
    var liveContextPreviewParts: [LiveSelectionReference.PreviewPart] {
        LiveSelectionReference.previewParts(liveContextPreviewReferences, with: partialTranscript)
    }
    var canTypeInHUD: Bool { false }
    var typedInput: String { "" }
    var typingFocusController: RecorderTypingFocus? { nil }
    var typingUndoController: RecorderTypingUndoController? { nil }
    var microphoneOff: Bool { recordingState == .paused }
    var potentialTTSActive: Bool { false }
    var microphoneTransitionPending: Bool { false }
    func toggleMicrophone() {}
    func togglePause() {}
    func updateTypedInput(_ value: String) {}
    func endTypingRun() {}
    func submitTypedInput() {}

    var currentFocusIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .currentFocus else { return nil }
        return pulse.id
    }

    var lockedDestinationIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .lockedDestination else { return nil }
        return pulse.id
    }
}
