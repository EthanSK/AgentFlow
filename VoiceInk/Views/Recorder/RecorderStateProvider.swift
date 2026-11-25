import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var codexBanner: String? { get }
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
    var captureFinishRequested: Bool { get }
    var outlineProcessingStartedAt: Date? { get }
    var outlineActivity: RecorderOutlineActivity? { get }
    func liveContextEditorHeight(width: CGFloat, contextHeight: CGFloat) -> CGFloat
    func toggleMicrophone()
    func togglePause()
    func updateTypedInput(_ value: String)
    func endTypingRun()
    func submitTypedInput()
    func finishTypedInputWithoutPasting()
    // A realtime provider owns a live-text HUD from recording start, even before
    // its first partial arrives. This is presentation state only: the placeholder
    // never enters the transcript or either Primary/Next delivery route.
    var showsRealtimeTranscriptHUD: Bool { get }
    // Optional GPT Live silence sleep: the network stream is resting while capture
    // continues. Presentation only; never a Pause, microphone-off, or delivery state.
    var realtimeStreamSleeping: Bool { get }
    var pasteDestinationIndicatorTarget: FocusLockService.Target? { get } // While recording this previews the Next Track destination; after stop it follows the session's actual pending paste target until delivery finishes.
    var iconActionPulse: RecorderIconActionPulse? { get } // Primary normal stop flashes the left/current icon; either accepted Next-button route flashes the right/locked icon.
    // The latest accepted highlight/screenshot, which the Recording Outline answers
    // with one lap of its transcript colour. A requirement, not only an extension
    // value, so the generic cards reach RecordingSession's published pulse.
    // Presentation only; never a route or capture signal. — Claude Opus 5.5
    var contextAcceptancePulse: RecorderContextAcceptancePulse? { get }

}

extension RecorderStateProvider {
    func liveContextEditorHeight(width: CGFloat, contextHeight: CGFloat) -> CGFloat {
        guard canTypeInHUD else { return 0 }
        return MiniRecorderLayoutMetrics.typingHeight(text: typedInput, width: width,
            maxHeight: contextHeight - MiniRecorderLayoutMetrics.singleLineHeight)
    }
    var codexBanner: String? { nil }
    // The small Stop card hides context without closing the assistant conversation.
    // The visible card, its host window and warning placement share this gate so
    // a retained response cannot leave a large invisible panel above it.
    // Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    func showsAssistantContext(isVisible: Bool) -> Bool {
        isVisible && !captureFinishRequested
    }
    // The editor disappears at finish. Do not measure its now-hidden transcript
    // while showing the loading card; all mirrored layouts use this same gate.
    var showsLiveContext: Bool {
        !captureFinishRequested && (recordingState.isRecordingOrPaused || canTypeInHUD)
            && (showsRealtimeTranscriptHUD || canTypeInHUD || !liveSelectionReferences.isEmpty)
    }

    // Microphone-off typing can retain the recording state and the sleeping socket.
    // Its badge must not claim that microphone recording continues in that state.
    var showsRealtimeStreamSleepingBadge: Bool {
        realtimeStreamSleeping && !microphoneOff && recordingState == .recording
    }

    /// Capture-state eligibility also lets the first accepted context gesture create
    /// its pulse before empty typing has mounted any decorative view. Keep pulse
    /// production independent from the deferred display gate. — GPT-6.1 Sol
    var isEligibleForRecordingActivityOutline: Bool {
        recordingState == .recording || recordingState.isProcessing
            || (recordingState == .starting && microphoneOff && canTypeInHUD)
    }

    /// Ethan's rainbow now follows live microphone capture AND the small loading
    /// card until transcription/processing finishes. During the real stop tail the
    /// small card keeps the actual waveform; only capture end changes it to loading.
    /// Microphone-off typing shares the outline after its first actual edit or
    /// accepted context gesture, so decorative geometry stays out of empty typing
    /// startup without suppressing the blue/magenta acknowledgement. Voice startup,
    /// Pause and idle remain unlit. This replaces
    /// the old showsLiveCaptureOutline gate; it is never a hardware or route signal.
    /// Original design by Claude Opus 5.5. Found and fixed by GPT-6.1 Sol.
    var showsRecordingActivityOutline: Bool {
        if microphoneOff && canTypeInHUD && !captureFinishRequested,
           outlineActivity?.hasTextActivity == false && contextAcceptancePulse == nil { return false }
        return isEligibleForRecordingActivityOutline
    }

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
    var realtimeStreamSleeping: Bool { false }
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
    var captureFinishRequested: Bool { false }
    var outlineProcessingStartedAt: Date? { nil }
    var outlineActivity: RecorderOutlineActivity? { nil }
    var contextAcceptancePulse: RecorderContextAcceptancePulse? { nil }
    func toggleMicrophone() {}
    func togglePause() {}
    func updateTypedInput(_ value: String) {}
    func endTypingRun() {}
    func submitTypedInput() {}
    func finishTypedInputWithoutPasting() {}

    var currentFocusIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .currentFocus else { return nil }
        return pulse.id
    }

    var lockedDestinationIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .lockedDestination else { return nil }
        return pulse.id
    }
}
