import AppKit
import Carbon.HIToolbox

/// Codex drag image, approved by Ethan on 2026-11-07 ("Allow Codex highlight
/// images"). Codex renders math with KaTeX and hides the visible formula from
/// Accessibility (`aria-hidden`), so the host's selected range can leave those
/// words out of a mixed highlight, or be empty for a formula-only drag. No safe
/// exact-text repair has been verified: see FAILED_APPROACHES.md, 2026-11-07. With its own
/// consent, every fresh Codex drag therefore also saves a picture of the
/// gesture area.
///
/// The picture accompanies the unchanged text. It never replaces, trims, widens
/// or vouches for that text. There is deliberately no omission heuristic: Codex
/// gives no signal that formatted words were dropped, so an image is taken for
/// every eligible drag, not only after an empty or suspicious read. The crop is
/// the gesture area and may include nearby text, so it is never labelled as the
/// exact selection. Double/triple clicks, Shift-extended drags, keyboard
/// selections and highlights made before Agent Flow started never produce one.
/// Telegram's separate fallback keeps its own key and narrower policy.
enum CodexSelectionImageCapture {
    /// Separate from Telegram's key and off by default for every user.
    static let preferenceKey = "VIPPCodexHighlightImagesEnabled"
    static let filePrefix = "codex-highlight"

    /// Gesture-time eligibility, before any pixels are read. `isVerifiedCodex`
    /// must come from `CodexConversationContextReader.isSupportedCodexApplication`
    /// (bundle plus the on-disk Codex executable), never a bundle ID alone,
    /// because ChatGPT can share Codex's bundle identifier. That same process
    /// must be frontmost when the drag finishes; background drags get no image.
    static func mayCapture(enabled: Bool, isVerifiedCodex: Bool, isAttached: Bool,
                           sourceIsFrontmost: Bool, precedesSpeech: Bool, extendsSelection: Bool,
                           gesture: LiveSelectionGesture?, sourceWindow: LiveSelectionWindow?,
                           secureInputActive: Bool) -> Bool {
        guard enabled, isVerifiedCodex, isAttached, sourceIsFrontmost, !precedesSpeech, !extendsSelection,
              !secureInputActive, let gesture, let sourceWindow, sourceWindow.windowID != nil,
              // AppKit reports 0 or 1 for a real drag. 2+ selects whole words or
              // paragraphs, whose extent the gesture area does not describe.
              (0...1).contains(gesture.clickCount),
              // Coordinates are sampled at event delivery. Follow the text
              // reader's established fresh-pointer limit, without waiting.
              gesture.hasFreshPointerSample else { return false }
        let dx = gesture.mouseUp.x - gesture.mouseDown.x
        let dy = gesture.mouseUp.y - gesture.mouseDown.y
        // The same 4-point drag threshold as `LiveSelectionCapture.isSelectionGesture`.
        guard dx * dx + dy * dy >= 16 else { return false }
        return cropRect(gesture: gesture, window: sourceWindow.bounds) != nil
    }

    static func cropRect(gesture: LiveSelectionGesture, window: CGRect) -> CGRect? {
        SelectionWindowImageCapture.cropRect(gesture: gesture, window: window,
                                             policy: .fullRowsForMultiline)
    }

    /// After the same gesture's Accessibility read. The image is kept only when
    /// that read was trusted and refused no secure text field. `nil` means the
    /// read stopped on cancellation or a source change, so it fails closed.
    static func mayAttach(resolution: LiveSelectionResolution?) -> Bool {
        guard let resolution, resolution.accessibilityTrusted, resolution.refusedSecure == 0 else { return false }
        return true
    }

    /// Any app holding secure keyboard entry (a focused password field) blocks
    /// the capture, before and after the pixels are taken.
    static func isSecureInputActive() -> Bool { IsSecureEventInputEnabled() }

    @MainActor
    static func capture(identity: LiveSelectionReadIdentity, gesture: LiveSelectionGesture) async -> URL? {
        await SelectionWindowImageCapture.capture(identity: identity, gesture: gesture,
                                                  filePrefix: filePrefix,
                                                  cropPolicy: .fullRowsForMultiline,
                                                  isCurrent: { isCurrent($0) })
    }

    /// Consent still on, no secure input, and the drag's exact source window
    /// (same ID, owner process and bounds) still on screen. Codex had to be
    /// frontmost when the drag finished (`mayCapture`); after that the window
    /// identity is the binding, so Agent Flow's own HUD typing focus taking
    /// key status mid-capture cannot silently drop the image.
    @MainActor
    static func isCurrent(_ identity: LiveSelectionReadIdentity) -> Bool {
        guard identity.window != nil else { return false }
        return UserDefaults.standard.bool(forKey: preferenceKey) && !isSecureInputActive()
            && identity.isValid(frontmostPID: identity.processIdentifier, windows: LiveSelectionWindow.onScreen())
    }

    static func discard(_ url: URL) { SelectionWindowImageCapture.discard(url) }
}

/// Owns one Codex drag's image until exactly one outcome: handed to the caller
/// after its final checks, or deleted. The capture starts as soon as the drag is
/// eligible, beside the text read rather than after it: Codex reads can retry
/// for over a second, and the separate pane-focus helper can clear the
/// highlight about 0.3 s after a drag. Running as its own task, it never delays
/// the text read or the text commit.
@MainActor
final class CodexSelectionImageLease {
    private var task: Task<URL?, Never>?
    private let discard: (URL) -> Void

    init(capture: @escaping @MainActor () async -> URL?,
         discard: @escaping (URL) -> Void = CodexSelectionImageCapture.discard) {
        self.discard = discard
        task = Task { @MainActor in await capture() }
    }

    /// Waits for the capture, then returns its file only if `stillEligible`
    /// passes at that moment; otherwise the file is deleted here. Cancelling the
    /// waiting task also cancels the capture. The caller owns a returned URL and
    /// must commit or discard it. A lease settles once: later calls return nil.
    func claim(stillEligible: () -> Bool) async -> URL? {
        guard let task else { return nil }
        self.task = nil
        let url = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard let url else { return nil }
        guard !Task.isCancelled, stillEligible() else {
            discard(url)
            return nil
        }
        return url
    }

    /// Cancellation, detach, a source change or an unused lease: cancel the
    /// capture and delete any file it still produces. No orphan files.
    func abandon() {
        guard let task else { return }
        self.task = nil
        task.cancel()
        let dispose = self.discard
        Task { @MainActor in
            if let url = await task.value { dispose(url) }
        }
    }
}
