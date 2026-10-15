import Foundation
import Combine
import SwiftUI
import os

enum RecordingPasteDestination: Equatable {
    case recordingStart
    case primaryCurrentInput
    case focusedDuringTranscription

    /// Primary is intentionally base VoiceInk: it follows the system keyboard focus
    /// at delivery and never owns an exact input or app-specific delivery mechanism.
    var usesBaseCurrentInputDelivery: Bool {
        self == .primaryCurrentInput
    }

    /// Exact, app-specific resolution belongs only to a physical Next-button latch.
    /// Keeping this policy on the enum makes it impossible for a Primary target to
    /// enter Telegram/OpenAI/Terminal delivery merely because a caller supplied one.
    var usesAppSpecificExactDelivery: Bool {
        switch self {
        case .recordingStart, .focusedDuringTranscription:
            true
        case .primaryCurrentInput:
            false
        }
    }
}

/// One recording's post-transcription side-effect policy.
///
/// This is deliberately independent from `RecordingPasteDestination`: Primary and
/// the two Next routes still own where a normal delivery goes. A genuine Primary
/// double-click chooses no paste destination at all. It completes the same audio and
/// transcription pipeline, then leaves the usable result on the clipboard without
/// issuing Command-V, Return, a custom command, or a recorder response.
enum RecordingCompletionDisposition: Equatable {
    case normalDelivery
    case clipboardOnly
}

/// One recording's configured auto-send override.
///
/// This is a separate axis from `RecordingCompletionDisposition`: a Primary
/// quadruple-click still performs the ordinary base-current-input paste, but
/// deliberately suppresses the configured Return/Enter for this session only.
/// Keeping the value on `RecordingSession` makes it survive asynchronous provider
/// completion without becoming a global setting that can leak into the next capture.
enum RecordingAutoSendDisposition: Equatable {
    case configured
    case suppressOnce
    case commandEnterOnce

    func resolvedKey(destination: RecordingPasteDestination, configuredKey: AutoSendKey) -> AutoSendKey {
        switch self {
        case .suppressOnce: return .none
        case .commandEnterOnce where destination.usesBaseCurrentInputDelivery:
            // Explicit HUD submit is still Primary: it owns no app/input/Mode.
            // Replay the user's key intent once. A subsequent physical Next
            // retarget instead retains that exact destination's atomic Mode.
            return .commandEnter
        case .configured, .commandEnterOnce: return configuredKey
        }
    }
}

struct RecordingCompletionPolicy: Equatable {
    let completionDisposition: RecordingCompletionDisposition
    let autoSendDisposition: RecordingAutoSendDisposition

    static let normal = RecordingCompletionPolicy(
        completionDisposition: .normalDelivery,
        autoSendDisposition: .configured
    )
}

/// Updates made by the idle Primary classifier while it is bound to the newest
/// eligible pending transcription. An idle gesture with no such session keeps the
/// existing one-click-start/two-click-cancel contract and never invents a new route.
enum PendingPrimaryCompletionGestureAction: Equatable {
    case begin(decisionInterval: TimeInterval)
    case selectClipboardOnly(continuationInterval: TimeInterval)
    case continueTowardNoAutoSend(continuationInterval: TimeInterval)
    case deliverWithoutAutoSend
    case endUnchanged
}

/// One user-confirmation pulse in the recorder bar. The token belongs to the
/// recording session so every mirrored monitor panel sees the same action, and
/// the icon is derived from the destination route at the moment it is chosen.
struct RecorderIconActionPulse: Equatable {
    enum Icon: Equatable {
        case currentFocus
        case lockedDestination
    }

    let id: UUID
    let icon: Icon

    init(destination: RecordingPasteDestination, id: UUID = UUID()) {
        self.id = id
        switch destination {
        case .primaryCurrentInput:
            icon = .currentFocus
        case .recordingStart, .focusedDuringTranscription:
            icon = .lockedDestination
        }
    }
}

struct RecordingPasteTarget {
    let destination: RecordingPasteDestination
    let focusedInput: FocusLockService.Target?
    // An exact destination and its complete Mode are one atomic per-session choice,
    // but only for the two Next-button routes. Primary deliberately owns neither:
    // it follows the current system input and current Mode like base VoiceInk.
    // In particular, the transcription-time Next route is a second chance:
    // Ethan can stop normally, focus a different input, press Next Track while the
    // transcript is still loading, then leave that app. The later app switch must
    // not replace any part of this target app's formatting/output/Return behavior.
    let mode: ModeConfig?
    var autoSendKey: AutoSendKey { mode?.autoSendKey ?? .none }

    init(
        destination: RecordingPasteDestination,
        focusedInput: FocusLockService.Target?,
        mode: ModeConfig? = nil
    ) {
        self.destination = destination
        // Structural regression guard: even if a future caller accidentally passes a
        // Telegram/OpenAI wrapper or Mode for Primary, discard both here. App-specific
        // state is valid only after the physical Next button selected an exact route.
        self.focusedInput = destination.usesAppSpecificExactDelivery
            ? focusedInput
            : nil
        self.mode = destination.usesAppSpecificExactDelivery ? mode : nil
    }

    func resolvedAutoSendKey(currentInputKey: AutoSendKey) -> AutoSendKey {
        destination.usesBaseCurrentInputDelivery ? currentInputKey : autoSendKey
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RecordingSession — one in-flight "voice capture → transcription → paste" job.
// ═══════════════════════════════════════════════════════════════════════════════
//
// FORK FEATURE (record-while-transcribing, 2026-06-28):
// VoiceInkEngine used to be SINGLE-FLIGHT — exactly one recording lifecycle existed
// at a time, and the STOP press AWAITED the whole transcription pipeline INLINE on
// the MainActor before the mic could be used again. That inline await is what blocked
// the user from starting a new dictation while the previous one was still uploading /
// transcribing.
//
// We now model each capture as an independent RecordingSession object. The engine owns
// a COLLECTION of these (`@Published var sessions`). The mic (the single shared
// `Recorder`) is only ever owned by the ONE session that is currently `.recording`;
// every other session in the collection has already stopped capturing and is somewhere
// in the transcription pipeline. So the user can stop session A (mic frees instantly),
// start session B, and A keeps transcribing in the background on a serial queue.
//
// ── SESSION STATE MACHINE ──────────────────────────────────────────────────────
//
//        ┌───────────┐  stop press / key-up   ┌──────────────┐
//        │ .recording│ ─────────────────────► │ .transcribing│
//        └───────────┘  (mic released here)   └──────────────┘
//              ▲                                      │
//   start press│                                      │ transcription returns text,
//   (new sess) │                                      │ enhancement runs (if enabled)
//              │                                      ▼
//        (engine creates                       ┌──────────────┐
//         a fresh session)                     │  .delivering │  paste / respond / cmd
//                                              └──────────────┘
//                                                     │ delivery finished
//                                                     ▼
//                                              ┌──────────────┐
//                                              │    .done     │  → removed from `sessions`
//                                              └──────────────┘     (UI animates it out)
//
//   • .recording    — owns the open capture session. THE mic owner. Its fine-grained
//                     live state is normally `.recording`, or `.paused` while AUHAL
//                     is temporarily stopped but the same WAV/stream remains open.
//                     At most ONE session is ever in this phase.
//   • .transcribing — audio captured, pipeline running (network upload / whisper /
//                     fluidaudio transcription). Mic already released.
//   • .delivering   — transcription (and optional AI enhancement) done; the result is
//                     being pasted / responded / sent to a custom command. The pipeline
//                     drives the recorder UI state through .enhancing then delivery.
//   • .done         — terminal. The engine removes the session from `sessions`; SwiftUI
//                     animates the card out and the stack collapses.
//
// NOTE: the pipeline internally also surfaces the legacy RecordingState (.transcribing
// / .enhancing) for the per-session status display; Phase here is the coarse lifecycle
// the engine + stack UI key off. We keep both: Phase for collection/stack management,
// the per-session liveRecordingState for the card's spinner/waveform rendering.
//
// ── ONE-ACTIVE-RECORDING INVARIANT (HARD RULE) ─────────────────────────────────
// At most ONE session in `sessions` may have phase == .recording at any time. This is
// enforced at the only two mutation sites:
//   1. VoiceInkEngine.toggleRecord START branch refuses to create a new .recording
//      session if `activeRecordingSession != nil` (defensive assert; the toggle path
//      already guarantees it because a press while one is recording STOPS it instead).
//   2. The STOP branch transitions the active session OUT of .recording (→.transcribing)
//      BEFORE any new session can be created.
// Why it matters: the shared `Recorder` is a single mic owner. Two `.recording` sessions
// would both think they own the mic and fight over start/stop + media pause/resume.
//
// ── ObservableObject ───────────────────────────────────────────────────────────
// Each card in the stacked recorder UI observes ITS OWN session, so phase /
// liveRecordingState / partialTranscript changes redraw only that card. The engine's
// `sessions` array is @Published for add/remove (stack grows/shrinks); the per-session
// @Published members drive each individual card's content.
@MainActor
final class RecordingSession: ObservableObject, Identifiable, RecorderStateProvider {
    enum Phase: Equatable {
        case recording
        case transcribing
        case delivering
        case done
    }

    // Stable identity for SwiftUI ForEach + per-card cancel routing (engine.cancelSession(id:)).
    let id = UUID()

    // Coarse lifecycle phase (drives stack membership / which card is the base). @Published
    // so the owning engine's array observers and this session's card both react.
    @Published var phase: Phase

    // Fine-grained recorder UI state for THIS card (idle/recording/transcribing/enhancing).
    // The pipeline pushes .enhancing here via onStateChange; the card's RecorderStatusDisplay
    // reads it to show the right spinner/waveform. Conforms to RecorderStateProvider so the
    // existing MiniRecorderView / NotchRecorderView can render a single session unchanged.
    @Published var liveRecordingState: RecordingState {
        didSet { updateAnnotationCaptureState(at: Date()) }
    }
    // Keyboard mode remains an active composing session, not gesture-Pause:
    // one Primary press must finish, never unexpectedly turn the microphone on.
    @Published var microphoneOff = false {
        didSet { updateAnnotationCaptureState(at: Date()) }
    }
    @Published var microphoneTransitionPending = false
    // Frozen birth intent distinguishes real keyboard-only startup from a late
    // Command edge while a voice-start hardware await may already be in flight.
    var beganMicrophoneOff = false
    private var microphoneTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    func finishMicrophoneTransition() {
        microphoneTransitionPending = false
        let waiters = microphoneTransitionWaiters
        microphoneTransitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForMicrophoneTransition() async {
        guard microphoneTransitionPending else { return }
        await withCheckedContinuation { microphoneTransitionWaiters.append($0) }
    }
    var hasCapturedAudio = true
    var onMicrophoneToggle: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var startupAudioRouter: RecordingStartupAudioRouter?
    var prepareMicrophoneTranscription: (() async throws -> Void)?
    func toggleMicrophone() { onMicrophoneToggle?() }
    func togglePause() {
        // A retained/transcribing card must never pause a newer mic-owning session.
        guard phase == .recording, liveRecordingState.isRecordingOrPaused,
              !microphoneTransitionPending, !shouldCancel else { return }
        onPauseToggle?()
    }

    var onTypingSubmit: (() -> Void)?
    var onTypingFinishWithoutPasting: (() -> Void)?
    private(set) var typingSubmitRequested = false
    private(set) var typingFinishWithoutPastingRequested = false
    private var typingSubmitDispatched = false

    func submitTypedInput() {
        requestTypingFinish(withoutPasting: false)
    }

    func finishTypedInputWithoutPasting() {
        requestTypingFinish(withoutPasting: true)
    }

    private func requestTypingFinish(withoutPasting: Bool) {
        guard canTypeInHUD, !typingSubmitRequested else { return }
        typingSubmitRequested = true
        typingFinishWithoutPastingRequested = withoutPasting
        if withoutPasting { completionDisposition = .clipboardOnly }
        typingFocus.disable(releaseKeyboard: false)
        dispatchPendingTypingSubmit()
    }

    func dispatchPendingTypingSubmit() {
        // Keyboard input is available during .starting. Normal toggle would
        // cancel startup, so retain this one session's finish intent until the
        // audio writer is ready. No timer, global flag, or later-session replay.
        let finish = typingFinishWithoutPastingRequested ? onTypingFinishWithoutPasting : onTypingSubmit
        guard typingSubmitRequested, !typingSubmitDispatched,
              phase == .recording, liveRecordingState.isRecordingOrPaused,
              !shouldCancel, let finish else { return }
        typingSubmitDispatched = true
        finish()
    }

    // Live streaming partial (only meaningful while phase == .recording — only this
    // session streams partials). While liveRecordingState == .paused, the last partial
    // stays frozen in the HUD and no new audio reaches the provider.
    @Published var partialTranscript: String = "" {
        didSet { hudContextPreviewCache = nil }
    }

    // Only short selection boundaries and paths of screenshots saved during
    // this recording are retained. Pixels are not read; a new recording gets
    // an independent list, and cancellation never transfers these references
    // to a later transcription job.
    @Published private(set) var liveSelectionReferences: [LiveSelectionReference] = [] {
        didSet { hudContextPreviewCache = nil }
    }
    private var liveSelectionCapture: LiveSelectionCapture?
    // The editable prose run is NOT part of `liveSelectionReferences`. It has no
    // timeline position until it is committed (Enter, leaving the editor, an
    // accepted highlight/screenshot, or capture end); the commit boundary's
    // observed speech decides where it lands. Ethan corrected the old first-edit
    // anchor on 2026-10-10: prose typed while speaking appeared before speech he
    // had already said. Only first/latest edit times are tracked while editing.
    @Published private(set) var typedInput = ""
    private var typedRunStartedAt: Date?
    private var typedRunLatestEditAt: Date?
    private var undoneTypedRuns: [(index: Int, reference: LiveSelectionReference)] = []
    lazy var typingUndo = RecorderTypingUndoController(session: self)
    var typingUndoController: RecorderTypingUndoController? { typingUndo }
    // Set only while one commit boundary seals the focused HUD editor, whose end
    // callback synchronously re-enters `endTypingRun()` and must reuse that
    // boundary's placement instead of a later live partial.
    private var typedRunCommitPlacement: TypedRunPlacement?
    private var speechRunStartedAt: Date? { didSet { hudContextPreviewCache = nil } }
    private var lastSpeechActivityAt: Date? { didSet { hudContextPreviewCache = nil } }
    private var pendingSpeechAnchor = "" { didSet { hudContextPreviewCache = nil } }
    private var speechTimingTask: Task<Void, Never>?
    private var contextCaptureEndedAt: Date?
    private var hudContextPreviewCache: (references: [LiveSelectionReference], parts: [LiveSelectionReference.PreviewPart])?
    @Published private(set) var potentialTTSActive = false

    private func updateAnnotationCaptureState(at date: Date) {
        potentialTTSActive = false
    }

    // Old exported prompts remain readable, but new recordings never manufacture
    // Potential ignore sections: the shared speaker now waits for recording to end.
    func receiveReminderSnapshot(_ snapshot: SpokenReminderAnnotationState.Snapshot) {}

    private func annotatedReferences(_ references: [LiveSelectionReference], endedAt: Date?) -> [LiveSelectionReference] {
        references
    }

    /// A short utterance can reach its final result without a live callback.
    /// Preserve the real composing-session bounds in that case, explicitly
    /// labelled as broader than speech activity. This does not claim word/audio
    /// alignment, restart a clock at delivery, or modify the HUD's reference list.
    var liveSelectionReferencesForDelivery: [LiveSelectionReference] {
        // Capture end normally commits the run already. A snapshot taken while it
        // is still editable treats that snapshot as its commit boundary.
        let references = liveSelectionReferences + uncommittedTypedRunReferences
        guard hasCapturedAudio, useCase == .newSession,
              let ended = contextCaptureEndedAt, createdAt <= ended,
              !references.contains(where: \.hasSpeechTiming) else {
            return annotatedReferences(references, endedAt: contextCaptureEndedAt)
        }
        return annotatedReferences(references + [.speechTiming(after: partialTranscript,
            startedAt: createdAt, endedAt: ended, sessionWindow: true)], endedAt: ended)
    }
    lazy var typingFocus = RecorderTypingFocus(canFocus: { [weak self] in self?.canTypeInHUD == true })
    var typingFocusController: RecorderTypingFocus? { typingFocus }

    var canTypeInHUD: Bool {
        // Explicit microphone-off typing is ready before the audio writer's
        // asynchronous startup. Do not make keyboard input wait for Core Audio;
        // ordinary voice startup still leaves the destination's focus alone.
        phase == .recording && useCase == .newSession && !shouldCancel
            && (liveRecordingState.isRecordingOrPaused
                || (liveRecordingState == .starting && microphoneOff))
    }

    // The active run is shown in the editable field, not duplicated in the
    // read-only timeline. All mirrored panels share the same session value.
    var liveContextPreviewReferences: [LiveSelectionReference] {
        hudContextPreview().references
    }

    var liveContextPreviewParts: [LiveSelectionReference.PreviewPart] {
        hudContextPreview().parts
    }

    private func hudContextPreview() -> (references: [LiveSelectionReference], parts: [LiveSelectionReference.PreviewPart]) {
        // One presentation snapshot for every mirrored panel and height/warning
        // calculation. No full selection payload is rendered; its short preview
        // is cached separately from the unchanged recovery/delivery references.
        // Invalidate on authored/context/timing/annotation edits, never on meter
        // ticks. Recovery and final export must not reuse this display-only cache.
        if let hudContextPreviewCache { return hudContextPreviewCache }
        // The editable run is never in this committed list, so it cannot appear
        // twice (editor plus read-only timeline) or jump while it is edited.
        var references = liveSelectionReferences
        if let started = speechRunStartedAt, let ended = lastSpeechActivityAt {
            references.append(.speechTiming(after: pendingSpeechAnchor, startedAt: started, endedAt: ended))
        }
        references = annotatedReferences(references, endedAt: nil)
        let snapshot = (references: references,
                        parts: LiveSelectionReference.previewParts(references, with: partialTranscript))
        hudContextPreviewCache = snapshot
        return snapshot
    }

    /// Crash recovery must keep the current editable typing as well as the
    /// speech classification. The read-only HUD intentionally omits that typing
    /// to avoid showing it twice, so it is not a durable recovery source.
    var liveSelectionReferencesForRecovery: [LiveSelectionReference] {
        var references = liveSelectionReferences
        if let started = speechRunStartedAt, let ended = lastSpeechActivityAt {
            references.append(.speechTiming(after: pendingSpeechAnchor, startedAt: started, endedAt: ended))
        }
        // Still-editable words are recoverable as if committed at this snapshot,
        // i.e. after all speech the snapshot is interleaved with.
        references += uncommittedTypedRunReferences
        return annotatedReferences(references, endedAt: contextCaptureEndedAt)
    }

    /// Where a prose run lands when it is committed. Interleaving places it after
    /// the observed live words of its anchor; it never claims audio/word alignment.
    private enum TypedRunPlacement {
        /// Enter, blur, or a highlight/screenshot: the live speech observed at that boundary.
        case after(String)
        /// Capture end (or a snapshot of a still-editable run): after every captured
        /// word, including a final provider tail that never appeared as a partial.
        case afterAllSpeech
    }

    private func typedRunReference(_ placement: TypedRunPlacement) -> LiveSelectionReference? {
        guard let started = typedRunStartedAt, let latest = typedRunLatestEditAt,
              let run = LiveSelectionReference(typedText: typedInput) else { return nil }
        let placed: LiveSelectionReference
        switch placement {
        case .after(let speech): placed = run.anchored(after: speech)
        case .afterAllSpeech: placed = run.anchoredAfterAllSpeech(observed: partialTranscript)
        }
        // First and latest real edits, never the commit/seal time.
        return placed.timed(at: latest, startedAt: started)
    }

    private var uncommittedTypedRunReferences: [LiveSelectionReference] {
        typedRunReference(.afterAllSpeech).map { [$0] } ?? []
    }

    // Keep the exact RecorderStateProvider witness. Adding a defaulted timestamp
    // alone changes the signature and would select its compatibility no-op in HUDs.
    func updateTypedInput(_ value: String) {
        updateTypedInput(value, at: Date())
    }

    func updateTypedInput(_ value: String, at date: Date) {
        // A seal/flush republishes the editor's unchanged text. That is not an
        // edit, so it must not move the run's latest-edit time to the commit.
        guard canTypeInHUD, value != typedInput else { return }
        if !typingUndo.isReplaying { undoneTypedRuns.removeAll() }
        typedInput = value
        if typedRunStartedAt == nil { typedRunStartedAt = date }
        typedRunLatestEditAt = date
    }

    /// Enter, leaving the editor, and a mirrored panel's end callback commit the
    /// prose run here; none of them finishes the recording or delivers. Repeated
    /// callbacks find no active run and do nothing, so every word lands once.
    func endTypingRun() {
        commitTypingRun(typedRunCommitPlacement ?? .after(partialTranscript))
    }

    // Enter/context capture seals an editable run, not the user's ability to
    // undo unsent typing. Remove/restore only that exact typed reference at its
    // original timeline slot; selections, screenshots, speech and their timing
    // remain unchanged. Never undo a finished/pending delivery or restore words
    // into both the editor and transcript, which would duplicate final output.
    @discardableResult func undoCommittedTyping() -> Bool {
        guard canTypeInHUD,
              let index = liveSelectionReferences.lastIndex(where: \.isTypedText) else { return false }
        undoneTypedRuns.append((index, liveSelectionReferences.remove(at: index)))
        return true
    }

    @discardableResult func redoCommittedTyping() -> Bool {
        guard canTypeInHUD, let run = undoneTypedRuns.popLast() else { return false }
        liveSelectionReferences.insert(run.reference, at: min(run.index, liveSelectionReferences.count))
        return true
    }

    private func commitTypingRun(_ placement: TypedRunPlacement) {
        let run = typedRunReference(placement)
        // Clear before appending so a re-entrant/duplicate end callback cannot
        // commit the same words twice.
        if !typedInput.isEmpty { typedInput = "" }
        typedRunStartedAt = nil
        typedRunLatestEditAt = nil
        if let run { liveSelectionReferences.append(run) }
    }

    /// Commit at a boundary that the session, not the editor, observed. A focused
    /// HUD editor is sealed first so IME composition and its latest characters
    /// reach this session and it is cleared locally before the run is appended
    /// (otherwise its stale text could later republish as a duplicate run).
    private func sealFocusedEditorAndCommitTypingRun(_ placement: TypedRunPlacement) {
        typedRunCommitPlacement = placement
        defer { typedRunCommitPlacement = nil }
        RecorderTypingTextView.sealFocusedRun()
        commitTypingRun(placement)
    }

    func recordSpeechActivity(_ transcript: String, at date: Date = Date()) {
        guard canTypeInHUD, !microphoneOff, transcript != partialTranscript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if speechRunStartedAt == nil { speechRunStartedAt = date }
        lastSpeechActivityAt = date
        pendingSpeechAnchor = transcript
        speechTimingTask?.cancel()
        speechTimingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.flushSpeechTiming()
        }
    }

    func flushSpeechTiming() {
        speechTimingTask?.cancel()
        speechTimingTask = nil
        guard let started = speechRunStartedAt, let ended = lastSpeechActivityAt else { return }
        liveSelectionReferences.append(.speechTiming(
            after: pendingSpeechAnchor, startedAt: started, endedAt: ended
        ))
        speechRunStartedAt = nil
        lastSpeechActivityAt = nil
        pendingSpeechAnchor = ""
    }

    // Make the realtime HUD visible as soon as the frozen Mode selects a streaming
    // provider. A network/Wi-Fi handshake may delay the first Soniox partial, but the
    // recorder must still communicate that live transcription is active. The empty
    // state renders only an ellipsis; it is never treated as transcript content.
    @Published var showsRealtimeTranscriptHUD = false

    // ── VIPP (skip-mode-processing feature) — per-session ONE-SHOT bypass flag ──
    //
    // WHAT: when true, THIS recording's pipeline skips ALL of the active Mode's
    // post-transcription processing and pastes the RAW verbatim transcript instead. Two
    // things get bypassed (both at the engine's runPipeline closure resolution site):
    //   1. AI ENHANCEMENT — the `enhancementConfiguration` closure returns nil, so the
    //      pipeline's "enhance" branch is skipped entirely (no LLM round-trip, no rewrite).
    //   2. The mode's CUSTOM COMMAND / SCRIPT (and `.respond` mode) — the
    //      `outputConfiguration` closure is rewritten to a plain `.paste` config with
    //      customCommand stripped, so TranscriptionDelivery takes the raw-paste branch
    //      instead of deliverCustomCommand / deliverResponse.
    //
    // WHY ON RecordingSession (not a global setting): the bypass must be PER-SESSION and
    // ONE-SHOT. The user decides DURING a given recording that this one should be raw; it
    // must NOT alter their default Mode/settings, and the very next recording (a fresh
    // RecordingSession, which initializes this back to false) behaves normally again.
    // Putting it here means it travels with the exact capture it applies to — even with
    // record-while-transcribing, where session A (raw) and session B (normal) can be in
    // flight simultaneously, each carries its own flag and the pipeline reads the right one.
    //
    // WHEN IT'S READ: the engine's runPipeline resolves the enhancement/output closures at
    // pipeline-run time (after STOP), so toggling the button any time BEFORE the pipeline's
    // enhancement/delivery step is honored. @Published so the recorder card's toggle button
    // re-renders its on/off (subdued vs amber) state the instant it flips.
    @Published var skipPostProcessing: Bool = false

    // A genuine Primary double-click sets this one-shot value during capture or
    // pending transcription. It must travel with this exact session because another
    // recording may already exist while this one finishes in the FIFO pipeline.
    // Unlike the separate raw/skip toggle, clipboard-only completion still applies
    // the session's normal formatting/enhancement; it changes only the final side
    // effect so no destination app is touched.
    @Published var completionDisposition: RecordingCompletionDisposition = .normalDelivery

    @Published var autoSendDisposition: RecordingAutoSendDisposition = .configured

    private(set) var acceptsCompletionDispositionChanges = true
    private var pendingPrimaryCompletionDecisionGeneration = 0
    private var pendingPrimaryCompletionDecisionTask: Task<Void, Never>?

    // Four-key stop has a separate, exact-session late-Shift decision. The
    // Primary click policy must still freeze before processing, but a typing
    // stop must not lose its second chance merely because its provider is fast.
    // Keep this open through preparation/queue waiting, with one second from
    // stop for a human to release the chord and tap Shift on a typed-only result.
    // Only the irreversible-action boundary may seal it; never undo a paste.
    private var typingClipboardDeadline: ContinuousClock.Instant?
    private(set) var typingClipboardOnlySelected = false

    var acceptsTypingClipboardOnlyCompletion: Bool {
        typingClipboardDeadline != nil && !shouldCancel
            && (phase == .transcribing || phase == .delivering)
    }

    func armTypingClipboardOnlyCompletion(minimumInterval: TimeInterval = 1) {
        guard phase == .recording, !shouldCancel else { return }
        typingClipboardOnlySelected = false
        typingClipboardDeadline = ContinuousClock.now.advanced(by: .seconds(max(0, minimumInterval)))
    }

    @discardableResult
    func selectTypingClipboardOnlyCompletion() -> Bool {
        guard acceptsTypingClipboardOnlyCompletion else { return false }
        typingClipboardOnlySelected = true
        completionDisposition = .clipboardOnly
        autoSendDisposition = .configured
        return true
    }

    /// Read and seal atomically on MainActor immediately before any output
    /// effect (or assistant response request), after all asynchronous waits.
    /// A preselected result finishes immediately; only a fast result waits
    /// for the remainder of its bounded human reaction window.
    func commitTypingCompletion() async -> Bool {
        if let deadline = typingClipboardDeadline, !typingClipboardOnlySelected {
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
        typingClipboardDeadline = nil
        return typingClipboardOnlySelected
    }

    /// Changes a pending transcription to clipboard-only without canceling its provider.
    @discardableResult
    func selectPendingClipboardOnlyCompletion() -> Bool {
        guard acceptsCompletionDispositionChanges,
              phase == .transcribing || phase == .delivering,
              !shouldCancel else { return false }
        completionDisposition = .clipboardOnly
        autoSendDisposition = .configured
        return true
    }

    /// Applies one stage of a pending-transcription Primary gesture. The first click
    /// temporarily holds the completion-policy freeze; click two selects Won't paste,
    /// click three only extends the same bounded gesture, and click four atomically
    /// restores normal paste while suppressing auto-send once. Each stage replaces the
    /// prior timeout, so provider completion can never freeze the intermediate double
    /// before a still-valid fourth click arrives.
    @discardableResult
    func applyPendingPrimaryCompletionGesture(
        _ action: PendingPrimaryCompletionGestureAction
    ) -> Bool {
        guard acceptsCompletionDispositionChanges,
              phase == .transcribing || phase == .delivering,
              !shouldCancel else {
            endPendingPrimaryCompletionGesture()
            return false
        }

        switch action {
        case .begin(let decisionInterval):
            extendPendingPrimaryCompletionGesture(by: decisionInterval)
        case .selectClipboardOnly(let continuationInterval):
            completionDisposition = .clipboardOnly
            autoSendDisposition = .configured
            extendPendingPrimaryCompletionGesture(by: continuationInterval)
        case .continueTowardNoAutoSend(let continuationInterval):
            extendPendingPrimaryCompletionGesture(by: continuationInterval)
        case .deliverWithoutAutoSend:
            completionDisposition = .normalDelivery
            autoSendDisposition = .suppressOnce
            endPendingPrimaryCompletionGesture()
        case .endUnchanged:
            endPendingPrimaryCompletionGesture()
        }
        return true
    }

    private func extendPendingPrimaryCompletionGesture(by interval: TimeInterval) {
        pendingPrimaryCompletionDecisionGeneration += 1
        let generation = pendingPrimaryCompletionDecisionGeneration
        pendingPrimaryCompletionDecisionTask?.cancel()
        pendingPrimaryCompletionDecisionTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.pendingPrimaryCompletionDecisionGeneration == generation else {
                return
            }
            self.pendingPrimaryCompletionDecisionTask = nil
        }
    }

    func endPendingPrimaryCompletionGesture() {
        pendingPrimaryCompletionDecisionGeneration += 1
        pendingPrimaryCompletionDecisionTask?.cancel()
        pendingPrimaryCompletionDecisionTask = nil
    }

    /// Waits only for an explicitly active pending-transcription click sequence, then
    /// freezes both delivery axes together before formatting, enhancement, response,
    /// paste, or Return can begin.
    func freezeCompletionPolicy() async -> RecordingCompletionPolicy {
        while let task = pendingPrimaryCompletionDecisionTask {
            await task.value
        }
        acceptsCompletionDispositionChanges = false
        return RecordingCompletionPolicy(
            completionDisposition: completionDisposition,
            autoSendDisposition: autoSendDisposition
        )
    }

    /// Freezes no-paste intent after transcription, before Mode effects can begin.
    func freezeCompletionDisposition() -> RecordingCompletionDisposition {
        endPendingPrimaryCompletionGesture()
        acceptsCompletionDispositionChanges = false // A late click must not claim Won't paste after a Mode response or delivery has already begun. (Codex task: 01a039f7-873c-7c30-b3dc-af8a6724ace5)
        return completionDisposition
    }

    // Realtime partials normally exist only in the recorder HUD and are cleared when
    // capture stops. Keep one private per-session snapshot so an explicit cancel while
    // the provider is finalizing can retain words already shown to the user instead of
    // replacing them with the generic canceled marker. This value is never delivered
    // normally and never crosses into another recording's lineage.
    var recoverablePartialTranscript: String = ""

    // The recorded audio file for this session. Set at record-start, consumed by the pipeline.
    var audioURL: URL?

    // Created before AUHAL starts so a force-quit can recover successfully written PCM
    // even though ExtAudioFile has not finalized the WAV header. This is local recovery
    // state only; it never contributes destination, paste, or auto-send behavior.
    var recoveryJournalEntry: RecordingRecoveryJournalEntry?

    // The exact Core Audio device successfully handed to AUHAL at capture start. This belongs
    // to the recording lineage just like its WAV and frozen provider configuration; a later
    // system-default/device selection change must not alter what History reports for this row.
    var recordingInputDevice: RecordingInputDeviceSnapshot?

    // Final transcript text once the pipeline completes (kept for potential future use /
    // debugging; delivery already pastes it).
    var transcript: String?

    // The target is captured before recording starts and belongs to this exact session so
    // another recording can safely begin while this one is still transcribing.
    @Published var recordingStartFocusedInput: FocusLockService.Target? // Published because an initially invalid shortcut-time capture can be replaced once microphone recording begins, and the destination icon must then appear immediately.
    @Published var pasteTarget: RecordingPasteTarget // Published so the icon remains visible after stop and immediately follows a Next Track retarget while transcription is still loading.
    @Published private(set) var iconActionPulse: RecorderIconActionPulse?
    private(set) var acceptsPasteRetargeting = true
    private var pasteTargetEnrichment: (
        captured: FocusLockService.Target,
        task: Task<FocusLockService.Target, Never>
    )?
    private var triggerWordModeOverride: ModeConfig?

    /// Next-button destinations own post-processing atomically. Primary is deliberately
    /// different: like base VoiceInk, it follows whichever Mode is current while the
    /// result is processed and delivered. An explicit trigger-word Mode remains the
    /// intentional higher-priority override for either policy.
    var postProcessingMode: ModeConfig? {
        Self.resolvePostProcessingMode(
            triggerWordModeOverride: triggerWordModeOverride,
            destination: pasteTarget.destination,
            currentMode: ModeManager.shared.currentEffectiveConfiguration,
            destinationMode: pasteTarget.mode
        )
    }

    /// Pure policy seam for the History/processing Mode contract. Keeping the precedence
    /// explicit and testable prevents a future refactor from making the UI's recent-context
    /// explanation false: trigger words win; Primary follows the live Mode; either Next
    /// route keeps the Mode frozen with its exact destination.
    static func resolvePostProcessingMode(
        triggerWordModeOverride: ModeConfig?,
        destination: RecordingPasteDestination,
        currentMode: ModeConfig?,
        destinationMode: ModeConfig?
    ) -> ModeConfig? {
        if let triggerWordModeOverride {
            return triggerWordModeOverride
        }
        if destination.usesBaseCurrentInputDelivery {
            return currentMode
        }
        return destinationMode
    }

    // ── Per-session bits migrated OFF the old engine singletons ──
    // Previously these were single-flight members on VoiceInkEngine; now each session
    // carries its own so two sessions (one recording, one transcribing) never share state.

    // Streaming/file transcription session prepared at record-start, used by the pipeline.
    var transcriptionSession: TranscriptionSession?
    // Mode-resolved transcription engine settings captured at record-start (so the pipeline
    // uses the config that was active WHEN this recording started, not whatever is active now).
    var transcriptionConfiguration: TranscriptionRuntimeConfiguration?
    // App/window context snapshot store for AI enhancement context.
    var contextStore: RecordingContextSnapshotStore?
    // A failed-file retry reuses only the original value snapshot. Never restart
    // clipboard/selection/screen capture against the user's later workspace.
    var retryContextSnapshot: RecordingContextSnapshot?
    // Background tasks capturing the above context; cancelled when the session ends.
    var contextTasks: [Task<Void, Never>] = []

    func beginLiveSelectionCapture(activationTime: Date = Date()) {
        guard liveSelectionCapture == nil else { return }
        let capture = LiveSelectionCapture(
            speechSnapshot: { [weak self] in self?.partialTranscript ?? "" },
            onCapture: { [weak self] reference, precedesSpeech, spokenAnchor in
                self?.recordLiveSelection(reference, precedesSpeech: precedesSpeech, spokenAnchor: spokenAnchor)
            },
            onLabels: { [weak self] captureID, reference in
                self?.updateLiveSelectionLabels(captureID: captureID, reference: reference)
            }
        )
        liveSelectionCapture = capture
        capture.start(activationTime: activationTime)
    }

    /// `precedesSpeech` marks a highlight made before this recording's capture
    /// attached (while reading, then pressing start). Its read can finish after
    /// the first live words arrive, so it is anchored before all speech instead.
    func recordLiveSelection(_ reference: LiveSelectionReference, precedesSpeech: Bool = false,
                             spokenAnchor: String? = nil) {
        guard phase == .recording, !shouldCancel,
              liveRecordingState == .starting || liveRecordingState.isRecordingOrPaused else { return }
        // Freeze the live speech visible at selection mouse-up or screenshot
        // save. Final transcription may revise words, so this is an approximate
        // insertion anchor, not an AX range or a live destination write.
        let gestureSpeech = spokenAnchor ?? partialTranscript
        // The accepted context ends any prose still being typed. Commit that run
        // at this gesture's frozen speech, not the later read-completion partial:
        // interleaving keeps anchors monotonic, so a later prose anchor would push
        // this gesture-time highlight forward. A pre-attachment highlight is placed
        // before all speech separately, so its prose simply commits at live speech.
        sealFocusedEditorAndCommitTypingRun(.after(precedesSpeech ? partialTranscript : gestureSpeech))
        let anchored = reference.anchored(after: precedesSpeech ? "" : gestureSpeech)
        // Distinct highlights at the same speech anchor are still a reading
        // trail. Preserve every gesture in capture order, even across silence
        // or a screenshot; the receiving agent decides which cues matter.
        if precedesSpeech {
            // An asynchronous initial-selection read can finish after a timing
            // marker or typed run. Its chronology still precedes those words.
            liveSelectionReferences.insert(anchored, at: 0)
        } else {
            liveSelectionReferences.append(anchored)
        }
        typingFocus.returnAfterContext()
    }

    func updateLiveSelectionLabels(captureID: UUID, reference: LiveSelectionReference) {
        guard phase == .recording, !shouldCancel,
              let index = liveSelectionReferences.firstIndex(where: { $0.captureID == captureID }) else { return }
        liveSelectionReferences[index] = liveSelectionReferences[index].updatingSourceLabels(from: reference)
    }

    func endLiveSelectionCapture(at date: Date = Date()) {
        // Freeze once at capture finish, never at provider/network completion.
        if contextCaptureEndedAt == nil { contextCaptureEndedAt = date }
        updateAnnotationCaptureState(at: date)
        flushSpeechTiming()
        typingFocus.disable(releaseKeyboard: false)
        // Finishing is the commit boundary for prose still in the editor. Every
        // captured word, including a final tail the provider never streamed as a
        // partial, was spoken before this point, so the run follows all speech.
        // `releaseKeyboardBeforeFinish()` flushes the editor without sealing so
        // the run reaches this placement instead of the last observed partial.
        commitTypingRun(.afterAllSpeech)
        liveSelectionCapture?.stop()
        liveSelectionCapture = nil
    }

    func restoreLiveContextForRetry(_ references: [LiveSelectionReference]) {
        guard phase == .transcribing else { return }
        liveSelectionReferences = references
    }

    // Whether this capture is a brand-new dictation or an assistant follow-up turn. Mirrors
    // the engine's old RecordingUseCase; kept per-session because two sessions could in
    // principle have different use cases.
    enum UseCase: Equatable {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool { self == .assistantFollowUp }
    }
    var useCase: UseCase

    // The Transcription model id this session's pipeline runs against. Used as the cancel
    // "poison" key (canceledPipelineTranscriptionIDs) so cancelling THIS session can't
    // discard another session's finished 200.
    var pipelineTranscriptionID: UUID?

    // Identity token for the record-start handshake (the async start path checks this is
    // still the live start before transitioning to .recording — guards against a re-press
    // cancelling a not-yet-started session). Replaces the old engine activeRecordingStartID.
    var startID: UUID

    // Per-session cancel flag. Replaces the old GLOBAL engine `shouldCancelRecording`. The
    // pipeline's shouldCancel() gate reads this for ITS session only, so cancelling session
    // A never poisons session B.
    var shouldCancel: Bool = false

    // Stable creation timestamp for deterministic stack ordering (oldest at the bottom/base
    // in mini; newest nearest the pill in notch). The `sessions` array is also kept in
    // creation order, but createdAt makes the intent explicit + survives any reordering.
    let createdAt: Date

    init(
        phase: Phase = .recording,
        useCase: UseCase = .newSession,
        startID: UUID = UUID(),
        recordingStartFocusedInput: FocusLockService.Target? = nil
    ) {
        self.phase = phase
        // A session is born recording, so its live UI state starts at .recording too.
        self.liveRecordingState = (phase == .recording) ? .recording : .idle
        self.useCase = useCase
        self.startID = startID
        self.createdAt = Date()
        self.recordingStartFocusedInput = recordingStartFocusedInput
        self.pasteTarget = RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: recordingStartFocusedInput,
            mode: ModeRuntimeResolver.modeSnapshot(
                forPasteTargetBundleIdentifier: recordingStartFocusedInput?.bundleIdentifier
            )
        )
    }

    // RecorderStateProvider conformance: the card reads `recordingState` for its spinner/
    // waveform. We expose the fine-grained liveRecordingState under that protocol name.
    var recordingState: RecordingState {
        liveRecordingState
    }

    var pasteDestinationIndicatorTarget: FocusLockService.Target? {
        switch phase {
        case .recording:
            recordingStartFocusedInput // Before stop, the icon previews the original input that a Next Track stop will select.
        case .transcribing, .delivering:
            pasteTarget.focusedInput // After stop, keep showing the real per-session target until it is delivered, failed, or retargeted.
        case .done:
            nil
        }
    }

    func retargetPaste(to target: RecordingPasteTarget) -> Bool {
        guard acceptsPasteRetargeting else { return false }
        // A recording-start Terminal lookup belongs only to that older decision.
        // Cancel and detach it before second chance replaces the target so its late
        // window/TTY result can never overwrite the newly focused input.
        discardPasteTargetEnrichment()
        pasteTarget = target
        // This method is the successful second-chance latch boundary. Emit only
        // after the target was accepted; a failed/no-input Next press must keep
        // its warning behavior and never flash a misleading success pulse.
        if target.destination == .focusedDuringTranscription {
            signalDestinationAction(target.destination)
        }
        return true
    }

    func signalDestinationAction(_ destination: RecordingPasteDestination) {
        iconActionPulse = RecorderIconActionPulse(destination: destination)
    }

    func applyTriggerWordModeOverride(_ mode: ModeConfig) {
        triggerWordModeOverride = mode
    }

    func beginPasteTargetEnrichment(
        captured: FocusLockService.Target,
        task: Task<FocusLockService.Target, Never>
    ) {
        guard acceptsPasteRetargeting,
              pasteTarget.focusedInput.map({
                  FocusLockService.shared.representsSameCaptureDecision(
                      $0,
                      captured
                  )
              }) == true else {
            task.cancel()
            return
        }
        pasteTargetEnrichment = (captured, task)

        // Update the recording preview as soon as the bounded lookup settles. Delivery
        // also awaits this same task, closing the very-fast Next-stop race without
        // delaying microphone startup or starting a second identity lookup.
        Task { @MainActor [weak self] in
            let completed = await task.value
            self?.applyPasteTargetEnrichment(
                captured: captured,
                completed: completed
            )
        }
    }

    private func applyPasteTargetEnrichment(
        captured: FocusLockService.Target,
        completed: FocusLockService.Target
    ) {
        guard acceptsPasteRetargeting,
              pasteTarget.focusedInput.map({
                  FocusLockService.shared.representsSameCaptureDecision(
                      $0,
                      captured
                  )
              }) == true else {
            return
        }
        if phase == .recording,
           pasteTarget.destination == .recordingStart {
            recordingStartFocusedInput = completed
        }
        pasteTarget = RecordingPasteTarget(
            destination: pasteTarget.destination,
            focusedInput: completed,
            mode: pasteTarget.mode
        )
        if pasteTargetEnrichment.map({
            FocusLockService.shared.representsSameCaptureDecision(
                $0.captured,
                captured
            )
        }) == true {
            pasteTargetEnrichment = nil
        }
    }

    func discardPasteTargetEnrichment() {
        pasteTargetEnrichment?.task.cancel()
        pasteTargetEnrichment = nil
    }

    func resolvePasteTargetForDelivery() async -> RecordingPasteTarget {
        // The task began at the physical input decision and is hard-bounded by the
        // AppleScript runner. Await only that existing task before freezing delivery;
        // never recapture whichever Terminal tab or app is focused now.
        while let pending = pasteTargetEnrichment {
            let completed = await pending.task.value
            applyPasteTargetEnrichment(
                captured: pending.captured,
                completed: completed
            )
            if pasteTargetEnrichment.map({
                FocusLockService.shared.representsSameCaptureDecision(
                    $0.captured,
                    pending.captured
                )
            }) == true {
                pasteTargetEnrichment = nil
            }
        }
        acceptsPasteRetargeting = false // Delivery resolves exactly once; a later media-key press must pass through rather than falsely claiming it changed an already-issued paste.
        return pasteTarget
    }

    // Cancel + tear down this session's background context capture. Safe to call multiple times.
    func clearContext() {
        endPendingPrimaryCompletionGesture()
        discardPasteTargetEnrichment()
        contextTasks.forEach { $0.cancel() }
        contextTasks.removeAll()
        contextStore = nil
        retryContextSnapshot = nil
    }
}
