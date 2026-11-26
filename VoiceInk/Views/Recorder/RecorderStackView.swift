import SwiftUI
import Combine
import AppKit

/// Cheap first pixels, not a recording card: no Mode, destination, live waveform,
/// editor, timers or controls until a real session owns them. Existing background
/// cards and assistant content remain intact instead of being replaced by a shell.
struct RecorderStartupPlaceholder: NSViewRepresentable {
    let requestID: UUID
    let onFirstDraw: (UUID, TimeInterval) -> Void

    func makeNSView(context: Context) -> RecorderStartupPlaceholderView {
        let view = RecorderStartupPlaceholderView(frame: .zero)
        view.configure(requestID: requestID, onFirstDraw: onFirstDraw)
        return view
    }

    func updateNSView(_ view: RecorderStartupPlaceholderView, context: Context) {
        view.configure(requestID: requestID, onFirstDraw: onFirstDraw)
    }
}

final class RecorderStartupPlaceholderView: NSView {
    private var requestID: UUID?
    private var reportedRequestID: UUID?
    private var onFirstDraw: ((UUID, TimeInterval) -> Void)?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(requestID: UUID, onFirstDraw: @escaping (UUID, TimeInterval) -> Void) {
        if self.requestID != requestID { reportedRequestID = nil }
        self.requestID = requestID
        self.onFirstDraw = onFirstDraw
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        // Neutral, static dots acknowledge the command without simulating audio
        // energy, recognized speech, Pause, or a live microphone.
        NSColor(white: 0.45, alpha: 1).setFill()
        for offset in [-8.0, 0.0, 8.0] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(
                x: bounds.midX + offset - 2, y: bounds.midY - 2, width: 4, height: 4
            )).fill()
        }
        guard let requestID, reportedRequestID != requestID,
              window?.isVisible == true,
              NSGraphicsContext.current?.isDrawingToScreen == true,
              let onFirstDraw else { return }
        reportedRequestID = requestID
        let drawnAt = ProcessInfo.processInfo.systemUptime
        // Do not publish SwiftUI state from inside AppKit drawing. Capture the
        // draw clock now; a late callback still cannot acknowledge a newer start.
        DispatchQueue.main.async { onFirstDraw(requestID, drawnAt) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RecorderStackView(s) — stacked recorder cards for record-while-transcribing.
// ═══════════════════════════════════════════════════════════════════════════════
//
// FORK FEATURE (2026-06-28): the engine now holds a COLLECTION of RecordingSession
// objects (`engine.sessions`), at most one of which is actively .recording (the mic
// owner). The recorder window used to host ONE card bound to the engine; it now hosts a
// STACK container that renders ONE card per session.
//
// LAYOUT MODEL (Mini):
//   • The ACTIVE recording session (or, if none is recording, the newest session) sits at
//     the BASE (bottom) — that's the "live" card with full record/stop/cancel/mode controls.
//   • Older in-flight transcribing sessions stack UPWARD above it: each is offset by
//     -cardHeight * indexFromBottom so they appear as a vertical pile growing up off-screen-
//     wards (the panel is bottom-anchored). Each upward card shows just a compact
//     "transcribing…" status + a per-card cancel "X".
//   • As each transcription completes its card animates out (opacity + move) and the stack
//     collapses — driven by SwiftUI's implicit animation on the `sessions` array plus the
//     per-index `.offset(y:)`.
//
// STACK OFFSET MATH (Mini):
//   sessions are ordered oldest→newest. We render so the BASE card is the active/newest one.
//   For a card at array index i (0 = oldest), let N = sessions.count. We want the
//   active/newest card (highest createdAt) at offset 0 and older ones stacked upward.
//   We compute `indexFromBottom` = (N-1 - i) when the newest is the base. Each card is
//   shifted up by `cardSpacing * indexFromBottom`. cardSpacing ≈ control-bar height + gap.
//
// The active/base card uses the FULL MiniRecorderView (with live waveform, controls,
// assistant panel, destination indicator). Background transcribing cards use a slim
// TranscribingChip to keep the pile compact.
//
// NOTE on which card is "base": the spec says the active .recording card is the base and
// transcribing cards stack upward. When NOTHING is recording (all sessions transcribing)
// we keep the NEWEST as the visual base for a stable anchor; controls on it are inert
// (it's not recording) but its TranscribingChip still shows + can be cancelled.

// MARK: - Mini Stack

struct MiniRecorderStackView: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var hudScale: RecorderHUDScaleStore
    @State private var layoutTick = 0
    let screenHeight: CGFloat
    let screenWidth: CGFloat
    let recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    // Per-card cancel: cancels THAT specific session (engine.cancelSession(id:)).
    let onCancelSession: (UUID) -> Void

    // Sessions oldest→newest as stored by the engine.
    private var ordered: [RecordingSession] { engine.sessions }

    // The base (live) session: the active recording one if present, else the newest.
    private var baseSession: RecordingSession? {
        engine.activeRecordingSession ?? ordered.last
    }

    // Show an assistant-only base card when there are NO sessions left but the assistant is
    // still presenting a response/follow-up. The session that produced the response has
    // already been removed from `sessions` (its pipeline finished), but the AssistantPanelView
    // lives INSIDE MiniRecorderView and must keep rendering. We bind that card to the engine
    // (RecorderStateProvider → reports .idle) which is exactly the old single-card behaviour.
    private var showAssistantOnlyCard: Bool {
        ordered.isEmpty && assistantSession.isVisible
    }

    private var showsAssistantContext: Bool {
        baseSession?.showsAssistantContext(isVisible: assistantSession.isVisible)
            ?? assistantSession.isVisible
    }

    private var liveTranscriptWidth: CGFloat {
        MiniRecorderLayoutMetrics.contextWidth(screenWidth: screenWidth, scale: CGFloat(hudScale.scale))
    }

    private var maximumContextHeight: CGFloat {
        MiniRecorderLayoutMetrics.contextHeightLimit(screenHeight: screenHeight, scale: CGFloat(hudScale.scale),
                                                     controlsHeight: controlsHeight)
    }

    private var liveTranscriptHeight: CGFloat {
        guard let baseSession, baseSession.showsLiveContext else {
            return MiniRecorderLayoutMetrics.liveTranscriptHeight
        }
        return baseSession.liveContextHeight(width: liveTranscriptWidth, maxHeight: maximumContextHeight)
    }

    private var controlsHeight: CGFloat {
        let width = showsAssistantContext ? min(liveTranscriptWidth, MiniRecorderLayoutMetrics.assistantPanelWidth) : liveTranscriptWidth
        return baseSession?.codexBanner.map { RecorderChatBannerLayout($0, availableWidth: width).height }
            ?? MiniRecorderLayoutMetrics.controlBarHeight
    }

    private func extraChipHeight(_ session: RecordingSession) -> CGFloat {
        RecorderChatBannerLayout.chipExtraHeight(session.codexBanner, availableWidth: liveTranscriptWidth)
    }

    private var baseCardHeight: CGFloat {
        if showsAssistantContext {
            return min(MiniRecorderLayoutMetrics.assistantPanelHeight, maximumContextHeight) + controlsHeight + MiniRecorderLayoutMetrics.separatorHeight
        }
        if let baseSession, baseSession.showsLiveContext {
            return liveTranscriptHeight + controlsHeight + MiniRecorderLayoutMetrics.separatorHeight
        }
        return controlsHeight
    }

    private var stackedChipCount: Int {
        max(0, ordered.count - (baseSession == nil ? 0 : 1))
    }

    var body: some View {
        let _ = layoutTick // Register the session-change dependency for host geometry.
        ZStack(alignment: .bottom) {
            if engine.startupPresentation.shouldShow(
                sessionCount: ordered.count, assistantVisible: assistantSession.isVisible
            ), let requestID = engine.startupPresentation.requestID {
                RecorderStartupPlaceholder(requestID: requestID) { [weak engine] id, uptime in
                    engine?.recordStartupPlaceholderDraw(requestID: id, uptime: uptime)
                }
                .frame(width: min(280, liveTranscriptWidth), height: MiniRecorderLayoutMetrics.controlBarHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.identity)
            }
            if showAssistantOnlyCard {
                MiniRecorderView(
                    stateProvider: engine,
                    liveTranscriptHeight: liveTranscriptHeight,
                    liveTranscriptWidth: liveTranscriptWidth,
                    maximumContextHeight: maximumContextHeight,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            }

            ForEach(ordered) { session in
                cardView(for: session)
                    // Each card is shifted UP by its distance from the base. The base card
                    // (indexFromBottom == 0) stays at offset 0; older transcribing cards
                    // climb upward in the bottom-anchored panel.
                    .offset(y: cardOffset(for: session))
                    .zIndex(zIndex(for: session))
                    .transition(engine.startupPresentation.isHandingOff(to: session.startID)
                        ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
            if let feedback = engine.noPasteOutlineFeedback {
                RecorderNoPasteFeedbackView(feedback: feedback, style: .mini)
                    .offset(y: ordered.isEmpty && !showAssistantOnlyCard ? 0 :
                        -(baseCardHeight + 6
                          + CGFloat(stackedChipCount) * MiniRecorderLayoutMetrics.stackedCardSpacing
                          + ordered.filter { $0.id != baseSession?.id }.reduce(0) { $0 + extraChipHeight($1) }))
                    .id(feedback.pulse.id)
                    .transition(.opacity)
            }
        }
        // Implicit animation keyed on the session id list so add/remove (and the resulting
        // offset shuffles) animate the pile growing/collapsing.
        .animation(engine.startupPresentation.isHandingOff(to: baseSession?.startID)
            ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: engine.sessions.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onReceive((baseSession?.objectWillChange ?? ObservableObjectPublisher()).receive(on: RunLoop.main)) { _ in
            // The engine's session array does not publish changes to a session's
            // screenshot/selection list. Refresh host height on those changes too.
            layoutTick &+= 1
        }
        .background(RecorderPanelHeightSync(
            desiredHeight: max(120, baseCardHeight + CGFloat(stackedChipCount) * MiniRecorderLayoutMetrics.stackedCardSpacing
                + ordered.filter { $0.id != baseSession?.id }.reduce(0) { $0 + extraChipHeight($1) }
                + (engine.noPasteOutlineFeedback != nil && (!ordered.isEmpty || showAssistantOnlyCard)
                    ? MiniRecorderLayoutMetrics.stackedCardSpacing : 0) + 12),
            edge: .bottom,
            scale: CGFloat(hudScale.scale)
        ))
    }

    private func cardOffset(for session: RecordingSession) -> CGFloat {
        let distance = indexFromBottom(of: session)
        guard distance > 0 else { return 0 }
        let between = ordered.filter { other in
            let position = indexFromBottom(of: other)
            return position > 0 && position < distance
        }
        return -(baseCardHeight + 6 + CGFloat(distance - 1) * MiniRecorderLayoutMetrics.stackedCardSpacing
                 + between.reduce(0) { $0 + extraChipHeight($1) })
    }

    // Distance of a session from the base, in card units. Base = 0, next-older = 1, etc.
    // We pile by reverse-chronological position relative to the base. Sessions newer than
    // the base (shouldn't normally exist, but be safe) also pile upward.
    private func indexFromBottom(of session: RecordingSession) -> Int {
        guard let baseSession,
              let baseIdx = ordered.firstIndex(where: { $0.id == baseSession.id }),
              let myIdx = ordered.firstIndex(where: { $0.id == session.id }) else {
            return 0
        }
        // Older sessions have a SMALLER array index (oldest first). The base is usually the
        // newest (largest index). Distance upward = baseIdx - myIdx for older cards.
        return max(0, baseIdx - myIdx)
    }

    // Base card on top of the z-order so its controls are tappable; older cards behind.
    private func zIndex(for session: RecordingSession) -> Double {
        Double(ordered.count - indexFromBottom(of: session))
    }

    @ViewBuilder
    private func cardView(for session: RecordingSession) -> some View {
        if session.id == baseSession?.id {
            // BASE/live card — full mini recorder with controls. Bound to the session as
            // its state provider so it shows that session's live state (recording waveform,
            // partial transcript, etc.). Controls route to the engine-level closures.
            MiniRecorderView(
                stateProvider: session,
                liveTranscriptHeight: liveTranscriptHeight,
                liveTranscriptWidth: liveTranscriptWidth,
                maximumContextHeight: maximumContextHeight,
                recorder: recorder,
                assistantSession: assistantSession,
                onRecordButtonTapped: onRecordButtonTapped,
                onCloseTapped: onCloseTapped,
                onCancelTapped: onCancelTapped,
                onAssistantFollowUp: onAssistantFollowUp
            )
        } else {
            // Background transcribing card — slim chip with per-card cancel.
            TranscribingChip(
                session: session,
                style: .mini,
                availableWidth: liveTranscriptWidth,
                onHeightChange: { layoutTick &+= 1 },
                onCancel: { onCancelSession(session.id) }
            )
        }
    }
}

// MARK: - Notch Stack

// LAYOUT MODEL (Notch):
//   The notch pill is anchored at the TOP center of the screen. "Upward" stacking makes no
//   sense there, so for the notch the ACTIVE session is the notch pill (full NotchRecorderView)
//   and in-flight transcribing sessions render as small "transcribing…" chips stacked BELOW
//   the pill (newest nearest the pill), animating in/out as they complete. The NotchRecorderPanel
//   window height was extended to fit up to a few stacked chips beneath the pill.
struct NotchRecorderStackView: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var hudScale: RecorderHUDScaleStore
    @State private var layoutTick = 0
    let recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let screenHeight: CGFloat
    let screenWidth: CGFloat
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    let onCancelSession: (UUID) -> Void

    private var ordered: [RecordingSession] { engine.sessions }

    // The pill session: active recording one if present, else newest.
    private var pillSession: RecordingSession? {
        engine.activeRecordingSession ?? ordered.last
    }

    // Background (non-pill) in-flight sessions, newest first so the newest chip sits nearest
    // the pill directly beneath it.
    private var backgroundSessions: [RecordingSession] {
        ordered
            .filter { $0.id != pillSession?.id && ($0.phase == .transcribing || $0.phase == .delivering) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // Assistant-only fallback (see the mini stack's equivalent): when the producing session
    // is gone but the assistant is still visible, render the pill bound to the engine so the
    // AssistantPanelView inside NotchRecorderView keeps showing.
    private var showAssistantOnlyPill: Bool {
        pillSession == nil && assistantSession.isVisible
    }

    private var showsAssistantContext: Bool {
        pillSession?.showsAssistantContext(isVisible: assistantSession.isVisible)
            ?? assistantSession.isVisible
    }

    private var liveTranscriptWidth: CGFloat {
        MiniRecorderLayoutMetrics.contextWidth(screenWidth: screenWidth, scale: CGFloat(hudScale.scale))
    }

    private var maximumContextHeight: CGFloat {
        MiniRecorderLayoutMetrics.contextHeightLimit(screenHeight: screenHeight,
            scale: CGFloat(hudScale.scale), controlsHeight: notchHeight + 6)
    }

    private var liveTranscriptHeight: CGFloat {
        guard let pillSession, pillSession.showsLiveContext else {
            return MiniRecorderLayoutMetrics.liveTranscriptHeight
        }
        return pillSession.liveContextHeight(width: liveTranscriptWidth - 16, maxHeight: maximumContextHeight)
    }

    private var desiredPanelHeight: CGFloat {
        let pill: CGFloat
        if showsAssistantContext {
            pill = notchHeight + 6 + min(320, maximumContextHeight)
        } else if let session = pillSession, session.showsLiveContext {
            pill = notchHeight + 6 + liveTranscriptHeight + 1
        } else {
            pill = notchHeight + 6
        }
        return max(120, pill + backgroundSessions.reduce(CGFloat.zero) { height, session in
            height + MiniRecorderLayoutMetrics.stackedCardSpacing
                + RecorderChatBannerLayout.chipExtraHeight(session.codexBanner, availableWidth: liveTranscriptWidth)
        } + (engine.noPasteOutlineFeedback != nil && (pillSession != nil || showAssistantOnlyPill)
            ? MiniRecorderLayoutMetrics.stackedCardSpacing : 0) + 12)
    }

    var body: some View {
        let _ = layoutTick
        VStack(spacing: 6) {
            if engine.startupPresentation.shouldShow(
                sessionCount: ordered.count, assistantVisible: assistantSession.isVisible
            ), let requestID = engine.startupPresentation.requestID {
                RecorderStartupPlaceholder(requestID: requestID) { [weak engine] id, uptime in
                    engine?.recordStartupPlaceholderDraw(requestID: id, uptime: uptime)
                }
                .frame(width: min(280, liveTranscriptWidth), height: notchHeight + 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.identity)
            }
            // The pill at the top (the notch itself).
            if let pillSession {
                NotchRecorderView(
                    stateProvider: pillSession,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    notchWidth: notchWidth,
                    notchHeight: notchHeight,
                    liveTranscriptHeight: liveTranscriptHeight,
                    liveTranscriptWidth: liveTranscriptWidth,
                    maximumContextHeight: maximumContextHeight,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            } else if showAssistantOnlyPill {
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    notchWidth: notchWidth,
                    notchHeight: notchHeight,
                    liveTranscriptHeight: liveTranscriptHeight,
                    liveTranscriptWidth: liveTranscriptWidth,
                    maximumContextHeight: maximumContextHeight,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            }

            // Stacked transcribing chips beneath the pill, newest nearest the pill.
            ForEach(backgroundSessions) { session in
                TranscribingChip(
                    session: session,
                    style: .notch,
                    availableWidth: liveTranscriptWidth,
                    onHeightChange: { layoutTick &+= 1 },
                    onCancel: { onCancelSession(session.id) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let feedback = engine.noPasteOutlineFeedback {
                RecorderNoPasteFeedbackView(feedback: feedback, style: .notch,
                    notchSize: pillSession == nil && !showAssistantOnlyPill
                        ? CGSize(width: notchWidth, height: notchHeight) : nil)
                    .id(feedback.pulse.id)
                    .transition(.opacity)
            }
        }
        .animation(engine.startupPresentation.isHandingOff(to: pillSession?.startID)
            ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: engine.sessions.map(\.id))
        .frame(maxWidth: .infinity, alignment: .top)
        .onReceive((pillSession?.objectWillChange ?? ObservableObjectPublisher()).receive(on: RunLoop.main)) { _ in
            layoutTick &+= 1
        }
        .background(RecorderPanelHeightSync(
            desiredHeight: desiredPanelHeight,
            edge: .top,
            scale: CGFloat(hudScale.scale)
        ))
    }
}

// MARK: - Transcribing Chip

// Compact card for a background (non-base/non-pill) session that is transcribing. Shows a
// spinner + label + a per-card cancel "X" that stops delivery for THAT session while
// retaining any completed/HUD result in History. Observes the
// session so its label/spinner reflect its live state (transcribing → enhancing).
struct TranscribingChip: View {
    enum Style { case mini, notch }

    @ObservedObject var session: RecordingSession
    let style: Style
    var availableWidth = MiniRecorderLayoutMetrics.liveTranscriptWidth
    var onHeightChange: () -> Void = {}
    let onCancel: () -> Void
    @AppStorage(RecorderCaptureOutlinePreference.preferenceKey)
    private var outlineEnabled = RecorderCaptureOutlinePreference.defaultValue

    private var label: String {
        if let noPasteReason { return noPasteReason.title }
        switch session.liveRecordingState {
        case .enhancing: return String(localized: "Enhancing…")
        default:         return String(localized: "Transcribing…")
        }
    }

    private var noPasteReason: RecorderNoPasteFeedback.Reason? {
        if session.shouldCancel { return .cancelled }
        return session.completionDisposition == .clipboardOnly ? .clipboardOnly : nil
    }

    var body: some View {
        let banner = session.codexBanner.map { RecorderChatBannerLayout($0, availableWidth: availableWidth, placement: .chip) }
        HStack(spacing: 8) {
            // Reuse the existing spinning processing indicator for visual consistency.
            if let noPasteReason {
                Image(systemName: noPasteReason.symbol)
                    .foregroundStyle(RecorderContextColor.noPaste)
                    .frame(width: 14, height: 14)
            } else {
                ProcessingIndicator(color: .white.opacity(0.86))
                    .frame(width: 14, height: 14)
            }

            if let banner, noPasteReason == nil {
                RecorderChatBanner(layout: banner)
            } else {
                Text(label)
                    .font(.system(size: MiniRecorderLayoutMetrics.processingFontSize, weight: .medium))
                    .foregroundColor(noPasteReason == nil ? .white.opacity(0.82) : RecorderContextColor.noPaste)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Pending cards omit the same secondary app/warning icon as the main bar.
            // Per-card cancel — stops THIS session's delivery only; recovery stays local.
            RecorderCancelButton(action: onCancel)
                .scaleEffect(0.82)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: max(banner?.cardWidth ?? 0,
            MiniRecorderLayoutMetrics.processingChipWidth + (style == .mini ? 0 : 16)), height: banner?.height)
        .onChange(of: banner?.height) { _, _ in onHeightChange() }
        .background(Color.black.opacity(style == .mini ? 1.0 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .overlay {
            if outlineEnabled, let pulse = session.contextAcceptancePulse, pulse.kind == .noPaste {
                RecorderCaptureOutline(
                    shape: RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous),
                    acceptancePulse: pulse,
                    isProcessing: session.noPasteOutlineMotion?.isProcessing ?? session.recordingState.isProcessing,
                    processingStartedAt: session.noPasteOutlineMotion?.processingStartedAt
                        ?? session.outlineProcessingStartedAt,
                    activity: session.noPasteOutlineMotion?.activity ?? session.outlineActivity,
                    continuesExistingOutline: true)
            }
        }
    }

}

/// A read-only end receipt, never a recorder session or a set of live controls.
/// The original pulse continues on the existing 30Hz leaf, so instant cancellation
/// stays visible without holding capture/paste work open. — GPT-6.1 Sol
struct RecorderNoPasteFeedbackView: View {
    let feedback: RecorderNoPasteFeedback
    let style: TranscribingChip.Style
    var notchSize: CGSize? = nil
    @AppStorage(RecorderCaptureOutlinePreference.preferenceKey)
    private var outlineEnabled = RecorderCaptureOutlinePreference.defaultValue

    var body: some View {
        Group {
            if let notchSize {
                // Keep the status in a wing, outside the physical camera notch.
                // Mirrored notch panels receive their own measured cutout size.
                // — GPT-6.1 Sol
                HStack(spacing: 0) {
                    label.frame(width: 120)
                    Color.clear.frame(width: notchSize.width)
                    Color.clear.frame(width: 120)
                }
                .frame(height: notchSize.height + 6)
                .background(Color.black)
                .clipShape(NotchShape(topCornerRadius: 8, bottomCornerRadius: 16))
                .overlay {
                    if outlineEnabled {
                        outline(shape: NotchShape(topCornerRadius: 8, bottomCornerRadius: 16), openTop: true)
                    }
                }
            } else {
                label
                    .frame(width: MiniRecorderLayoutMetrics.processingChipWidth,
                           height: MiniRecorderLayoutMetrics.controlBarHeight)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous))
                    .overlay {
                        if outlineEnabled {
                            outline(shape: RoundedRectangle(cornerRadius: style == .mini ? 16 : 12,
                                                             style: .continuous))
                        }
                    }
            }
        }
        // A finished card must never route a click to a newer live capture.
        // No editor, focus request, waveform, spinner or audio meter is retained.
        // — GPT-6.1 Sol
        .allowsHitTesting(false)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: feedback.reason.symbol)
            Text(feedback.reason.title)
        }
        .font(.system(size: MiniRecorderLayoutMetrics.processingFontSize, weight: .medium))
        .foregroundStyle(RecorderContextColor.noPaste)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func outline<S: Shape>(shape: S, openTop: Bool = false) -> some View {
        RecorderCaptureOutline(shape: shape, omitsTopEdge: openTop,
            acceptancePulse: feedback.pulse, isProcessing: feedback.isProcessing,
            processingStartedAt: feedback.processingStartedAt, activity: feedback.activity,
            continuesExistingOutline: true)
    }
}
