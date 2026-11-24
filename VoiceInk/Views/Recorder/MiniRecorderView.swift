// Bottom-anchored recorder card; every monitor observes the same live session.
import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    let liveTranscriptHeight: CGFloat
    var liveTranscriptWidth: CGFloat = MiniRecorderLayoutMetrics.liveTranscriptWidth
    var maximumContextHeight: CGFloat = MiniRecorderLayoutMetrics.assistantPanelHeight
    let recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    // Exit ("X"): stop without paste, save captured audio/HUD draft in History, and
    // resume paused media. Permanent deletion is a separate History action.
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void

    // Settings -> Interface -> Recording Outline. A missing value means on, and an
    // explicit false stays off; see RecorderCaptureOutlinePreference. — Claude Opus 5.5
    @AppStorage(RecorderCaptureOutlinePreference.preferenceKey)
    private var captureOutlineEnabled = RecorderCaptureOutlinePreference.defaultValue

    // MARK: - Layout Constants

    private let compactWidth: CGFloat = 228
    private var expandedWidth: CGFloat { liveTranscriptWidth }
    private var assistantWidth: CGFloat { min(liveTranscriptWidth, MiniRecorderLayoutMetrics.assistantPanelWidth) }
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    // One silhouette for the clip and the Recording Outline, so the neon tube
    // follows every compact/expanded corner and width change exactly. — Claude Opus 5.5
    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
            style: .continuous
        )
    }

    private var chatBanner: RecorderChatBannerLayout? {
        stateProvider.codexBanner.map { RecorderChatBannerLayout($0, availableWidth: hasAssistantResponse ? assistantWidth : liveTranscriptWidth) }
    }

    private var capsuleWidth: CGFloat {
        if hasAssistantResponse { return assistantWidth }
        if hasLiveTranscript { return expandedWidth }
        if let chatBanner { return chatBanner.cardWidth }
        // Leave room for Pause/Play and the current app. Ethan removed the secondary
        // app icon because its unused destination warning was mostly visual noise.
        if stateProvider.captureFinishRequested && stateProvider.recordingState == .recording { return 324 }
        if stateProvider.recordingState.isRecordingOrPaused { return 324 }
        return stateProvider.recordingState == .starting || stateProvider.recordingState.isProcessing
            ? 254 : compactWidth
    }

    // Realtime mode owns this panel immediately. LiveTranscriptView renders the
    // empty-state ellipsis, which never becomes speech or final delivery text.
    private var hasLiveTranscript: Bool {
        stateProvider.showsLiveContext
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible && !stateProvider.captureFinishRequested
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse &&
            stateProvider.recordingState == .idle &&
            !assistantSession.isBusy
    }

    // The cancel ("X") button is reachable whenever there is something to abort:
    // while RECORDING (save a local draft) AND while a transcription is IN-FLIGHT
    // (.transcribing/.enhancing — stop delivery before it pastes) and during the
    // brief .starting handshake. Hidden at .idle/.busy where there's nothing to
    // cancel (the assistant close-button affordance covers idle dismissal instead).
    private var shouldShowCancelButton: Bool {
        switch stateProvider.recordingState {
        case .starting, .recording, .paused, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }

    private var liveAssistantFollowUpText: String {
        guard stateProvider.recordingState.isRecordingOrPaused else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                // Every shipped build increments CFBundleVersion. Keeping this
                // immediately left of Stop makes the running release obvious.
                RecorderVersionLabel()

                Group {
                    if shouldShowCloseButton {
                        RecorderCloseButton(action: onCloseTapped)
                    } else {
                        RecorderRecordButton(
                            recordingState: stateProvider.recordingState,
                            action: onRecordButtonTapped
                        )
                        .disabled(stateProvider.captureFinishRequested)
                        .saturation(stateProvider.captureFinishRequested ? 0 : 1)
                    }
                }

                // Cancel ("X") sits immediately to the RIGHT of the Stop/record control
                // so an abort is one glance + one tap away from Stop. Only shown while a
                // recording or in-flight transcription is cancellable (see
                // shouldShowCancelButton); collapses out otherwise so idle bars are unchanged.
                if shouldShowCancelButton {
                    RecorderCancelButton(action: onCancelTapped)
                        .transition(.opacity)

                    if stateProvider.recordingState.isRecordingOrPaused && !stateProvider.captureFinishRequested {
                        RecorderPauseButton(stateProvider: stateProvider)
                    }
                    if stateProvider.canTypeInHUD && !stateProvider.captureFinishRequested {
                        RecorderMicrophoneButton(stateProvider: stateProvider)
                    }
                }
            }
            .padding(.leading, 10)
            .animation(.easeInOut(duration: 0.2), value: shouldShowCancelButton)

            Spacer(minLength: 0)
                .frame(maxHeight: .infinity)
                .background(RecorderPanelDragSurface())

            HStack(spacing: 6) {
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    completionDisposition: stateProvider.completionDisposition,
                    recorder: recorder,
                    realtimeStreamSleeping: stateProvider.showsRealtimeStreamSleepingBadge
                )
                .background(RecorderPanelDragSurface())
                if let chatBanner, !chatBanner.separateRow {
                    RecorderChatBanner(layout: chatBanner)
                }
            }

            Spacer(minLength: 0)
                .frame(maxHeight: .infinity)
                .background(RecorderPanelDragSurface())

            // Ethan's "cloud icon" is the current Mode chooser. It moved from
            // beside the waveform to the right controls; the middle stays status-only.
            HStack(spacing: 6) {
                RecorderModeButton(buttonSize: 22, padding: EdgeInsets())
                // Current focus is not a saved Next target.
                CurrentFocusApplicationIndicator(
                    actionPulseID: stateProvider.currentFocusIconActionPulseID
                )
            }
            .padding(.trailing, 12)
        }
        .frame(height: chatBanner.flatMap { $0.separateRow ? nil : $0.height } ?? MiniRecorderLayoutMetrics.controlBarHeight)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(
                    text: stateProvider.partialTranscript,
                    potentialTTSActive: stateProvider.potentialTTSActive,
                    dimsContextUntilSpeechArrives: stateProvider.dimsContextUntilSpeechArrives,
                    selectionReferences: stateProvider.liveContextPreviewReferences,
                    cachedPreviewParts: stateProvider.liveContextPreviewParts,
                    height: liveTranscriptHeight,
                    typedInput: stateProvider.canTypeInHUD ? Binding(
                        get: { stateProvider.typedInput },
                        set: { stateProvider.updateTypedInput($0) }
                    ) : nil,
                    onEndTyping: { stateProvider.endTypingRun() },
                    onSubmitTyping: { stateProvider.submitTypedInput() },
                    onFinishTypingWithoutPasting: { stateProvider.finishTypedInputWithoutPasting() },
                    typingFocus: stateProvider.typingFocusController,
                    typingUndo: stateProvider.typingUndoController,
                    width: liveTranscriptWidth,
                    dragsWindow: true
                )
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp,
                    height: min(MiniRecorderLayoutMetrics.assistantPanelHeight, maximumContextHeight)
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            if let chatBanner, chatBanner.separateRow {
                RecorderChatBanner(layout: chatBanner)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            controlBar
        }
        .frame(width: capsuleWidth)
        // Recording/processing activity. Chained before the fill, it sits above the card
        // colour but beneath every control, transcript line and drag surface, and the
        // clip below bounds it. It never marks a saved or Next destination. Removal is
        // instant for Pause; Stop retains it through the tail and transcription.
        .background {
            if captureOutlineEnabled && stateProvider.showsRecordingActivityOutline {
                RecorderCaptureOutline(shape: cardShape)
                    .transition(.identity)
            }
        }
        .background {
            if stateProvider.recordingState == .paused {
                RecorderPanelAppearance.pausedBackground
            } else if hasLiveTranscript && liveTranscriptHeight > 100 {
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.82), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.black
            }
        }
        .clipShape(cardShape)
        // Finish must visibly acknowledge the first press, not first shrink the
        // editor and cross-fade its loading indicator over another 300 ms.
        .animation(stateProvider.captureFinishRequested || stateProvider.recordingState.isProcessing ? nil : .easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
