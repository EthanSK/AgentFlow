import AppKit

/// Explicitly approved, Telegram-only context fallback. This is a picture of
/// the gesture area (which can contain nearby messages), never selected text,
/// OCR, a clipboard read, a delivery target, or a full-screen screenshot.
/// The window capture and private storage now live in
/// `SelectionWindowImageCapture`, shared with the separately consented Codex
/// drag image. This type keeps Telegram's own consent key, its narrower
/// no-Accessibility-elements policy and its existing entry points.
enum TelegramSelectionImageCapture {
    static let preferenceKey = "VIPPTelegramHighlightImageFallbackEnabled"
    static let bundleID = "ru.keepcoder.Telegram"
    static let filePrefix = "telegram-highlight"

    static func mayCapture(enabled: Bool, sourceBundleID: String?, precedesSpeech: Bool,
                           gesture: LiveSelectionGesture?, resolution: LiveSelectionResolution?) -> Bool {
        guard enabled, sourceBundleID == bundleID, !precedesSpeech,
              let gesture, let resolution, resolution.accessibilityTrusted,
              resolution.candidate == nil, resolution.examinedElements == 0,
              resolution.emptyHitTests == gesture.hitTestPoints.count,
              resolution.refusedSecure == 0, resolution.rejectedElsewhere == 0,
              resolution.rejectedOutsideSourceWindow == 0, !resolution.budgetExhausted else { return false }
        return true
    }

    static func cropRect(gesture: LiveSelectionGesture, window: CGRect) -> CGRect? {
        SelectionWindowImageCapture.cropRect(gesture: gesture, window: window)
    }

    @MainActor
    static func capture(identity: LiveSelectionReadIdentity, gesture: LiveSelectionGesture) async -> URL? {
        await SelectionWindowImageCapture.capture(identity: identity, gesture: gesture,
                                                  filePrefix: filePrefix, isCurrent: { isCurrent($0) })
    }

    @MainActor
    private static func isCurrent(_ identity: LiveSelectionReadIdentity) -> Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processIdentifier
            && identity.isValid(frontmostPID: identity.processIdentifier, windows: LiveSelectionWindow.onScreen())
    }

    static func save(_ image: CGImage, directory: URL) throws -> URL {
        try SelectionWindowImageCapture.save(image, directory: directory, filePrefix: filePrefix)
    }

    static func discard(_ url: URL) { SelectionWindowImageCapture.discard(url) }

    static func hasVisibleContent(_ image: CGImage) -> Bool {
        SelectionWindowImageCapture.hasVisibleContent(image)
    }
}
