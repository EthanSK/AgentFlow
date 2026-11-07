import AppKit
import Testing
@testable import VoiceInkPlusPlus

/// Codex drag images (approved 2026-11-07). Codex can omit KaTeX-rendered words
/// from every Accessibility range, so a consented fresh drag also keeps a
/// gesture-area picture beside its unchanged text. These tests pin the
/// eligibility policy, the one-owner file lease, honest Codex XML, capture order
/// beside the text, and viewer/History/HUD recognition. Telegram's own fallback
/// is pinned separately in TelegramSelectionImageTests and must stay unchanged.
@MainActor
struct CodexSelectionImageTests {
    private let window = CGRect(x: -900, y: 100, width: 800, height: 700)
    private var sourceWindow: LiveSelectionWindow {
        LiveSelectionWindow(ownerPID: 7, bounds: window, alpha: 1, windowID: 42)
    }
    private func drag(dx: CGFloat = 400, dy: CGFloat = 100, clicks: Int = 1) -> LiveSelectionGesture {
        var gesture = LiveSelectionGesture(mouseDown: CGPoint(x: -700, y: 300),
                                           mouseUp: CGPoint(x: -700 + dx, y: 300 + dy), displays: [window])
        gesture.clickCount = clicks
        gesture.callbackLagMilliseconds = 0
        return gesture
    }

    @Test func codexImageEligibilityRequiresConsentVerifiedCodexAttachedFreshDragAndNoSecureInput() {
        // Missing gesture/window cases are spelled out separately below.
        func allowed(enabled: Bool = true, verified: Bool = true, attached: Bool = true,
                     frontmost: Bool = true, precedes: Bool = false, extends: Bool = false,
                     secure: Bool = false, gesture: LiveSelectionGesture? = nil,
                     source: LiveSelectionWindow? = nil) -> Bool {
            CodexSelectionImageCapture.mayCapture(
                enabled: enabled, isVerifiedCodex: verified, isAttached: attached,
                sourceIsFrontmost: frontmost, precedesSpeech: precedes, extendsSelection: extends,
                gesture: gesture ?? drag(), sourceWindow: source ?? sourceWindow,
                secureInputActive: secure)
        }
        #expect(allowed())
        // Consent defaults off; identity must be the verified Codex app, still
        // frontmost when the drag finishes; the session must still be attached.
        #expect(!allowed(enabled: false))
        #expect(!allowed(verified: false))
        #expect(!allowed(frontmost: false))
        #expect(!allowed(attached: false))
        // Never a highlight made before Agent Flow started, a Shift-extended
        // selection, or while any app holds secure keyboard entry.
        #expect(!allowed(precedes: true))
        #expect(!allowed(extends: true))
        #expect(!allowed(secure: true))
        // Keyboard selections have no pointer gesture.
        #expect(!CodexSelectionImageCapture.mayCapture(
            enabled: true, isVerifiedCodex: true, isAttached: true, sourceIsFrontmost: true,
            precedesSpeech: false, extendsSelection: false, gesture: nil, sourceWindow: sourceWindow,
            secureInputActive: false))
        // One exact source window with a real window ID is required.
        #expect(!CodexSelectionImageCapture.mayCapture(
            enabled: true, isVerifiedCodex: true, isAttached: true, sourceIsFrontmost: true,
            precedesSpeech: false, extendsSelection: false, gesture: drag(), sourceWindow: nil,
            secureInputActive: false))
        #expect(!allowed(source: LiveSelectionWindow(ownerPID: 7, bounds: window, alpha: 1, windowID: nil)))
        // Fresh drag only: double/triple clicks select units the gesture area
        // does not describe. AppKit's 0-count drag remains a drag.
        #expect(!allowed(gesture: drag(clicks: 2)))
        #expect(!allowed(gesture: drag(clicks: 3)))
        #expect(allowed(gesture: drag(clicks: 0)))
        var stale = drag()
        stale.callbackLagMilliseconds = nil
        #expect(!allowed(gesture: stale))
        for lag in [-1, 51, 1_000] {
            stale.callbackLagMilliseconds = lag
            #expect(!allowed(gesture: stale))
        }
        stale.callbackLagMilliseconds = 50
        #expect(allowed(gesture: stale))
        // The same 4-point threshold as the live selection watcher.
        #expect(!allowed(gesture: drag(dx: 3, dy: 0)))
        #expect(allowed(gesture: drag(dx: 4, dy: 0)))
        // Both endpoints must lie inside the source window; no off-window crop.
        #expect(!allowed(gesture: drag(dx: 1_000, dy: 0)))
    }

    @Test func codexImageIsKeptOnlyAfterATrustedReadWithoutSecureRefusal() {
        #expect(!CodexSelectionImageCapture.mayAttach(resolution: nil))
        var resolution = LiveSelectionResolution()
        #expect(CodexSelectionImageCapture.mayAttach(resolution: resolution))
        // No omission heuristic: a normal text result keeps its image too, and
        // span/widening counters neither require nor veto it.
        resolution.candidate = LiveSelectionCandidate(text: "plain words", tier: .pointerElement,
                                                      source: .textMarkers, evidence: .atGesture)
        resolution.observedOverextended = 1
        resolution.preventedWidening = 1
        #expect(CodexSelectionImageCapture.mayAttach(resolution: resolution))
        var secure = resolution
        secure.refusedSecure = 1
        #expect(!CodexSelectionImageCapture.mayAttach(resolution: secure))
        var untrusted = resolution
        untrusted.accessibilityTrusted = false
        #expect(!CodexSelectionImageCapture.mayAttach(resolution: untrusted))
    }

    @Test func codexImageCropPreservesWrappedRowsWithoutChangingTelegramGeometry() throws {
        let gesture = LiveSelectionGesture(mouseDown: CGPoint(x: -700, y: 300),
                                           mouseUp: CGPoint(x: -300, y: 400), displays: [window])
        let crop = try #require(CodexSelectionImageCapture.cropRect(gesture: gesture, window: window))
        #expect(crop == CGRect(x: 0, y: 164, width: 800, height: 172))
        #expect(TelegramSelectionImageCapture.cropRect(gesture: gesture, window: window)
            == CGRect(x: 152, y: 164, width: 496, height: 172))
        #expect(CGRect(origin: .zero, size: window.size).contains(crop))

        // Both ends near the centre on different lines: selected text on the
        // right of line one and left of line two must both survive the crop.
        let wrapped = LiveSelectionGesture(mouseDown: CGPoint(x: -500, y: 300),
                                           mouseUp: CGPoint(x: -490, y: 350), displays: [window])
        let reverse = LiveSelectionGesture(mouseDown: wrapped.mouseUp, mouseUp: wrapped.mouseDown,
                                           displays: [window])
        let rows = try #require(CodexSelectionImageCapture.cropRect(gesture: wrapped, window: window))
        #expect(rows == CodexSelectionImageCapture.cropRect(gesture: reverse, window: window))
        #expect(rows.contains(CGPoint(x: 750, y: 200)))
        #expect(rows.contains(CGPoint(x: 50, y: 250)))
        let old = try #require(TelegramSelectionImageCapture.cropRect(gesture: wrapped, window: window))
        #expect(!old.contains(CGPoint(x: 750, y: 200)))
        #expect(!old.contains(CGPoint(x: 50, y: 250)))
        // Ordinary same-line drags keep a tight endpoint rectangle.
        let sameLine = drag(dx: 100, dy: 8)
        #expect(CodexSelectionImageCapture.cropRect(gesture: sameLine, window: window)
            == TelegramSelectionImageCapture.cropRect(gesture: sameLine, window: window))
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        context.setFillColor(NSColor.cyan.cgColor)
        context.fill(CGRect(x: 32, y: 16, width: 64, height: 32))
        return try #require(context.makeImage())
    }

    private func discardRecorder() -> (stream: AsyncStream<URL>, record: (URL) -> Void) {
        var continuation: AsyncStream<URL>.Continuation!
        let stream = AsyncStream<URL> { continuation = $0 }
        return (stream, { _ = continuation.yield($0) })
    }

    @Test func codexImageLeaseHandsTheFileToOneOwnerOrDeletesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SelectionWindowImageCapture.save(image(), directory: root,
                                                         filePrefix: CodexSelectionImageCapture.filePrefix)
        #expect(file.lastPathComponent.hasPrefix("codex-highlight-"))

        // Accepted: the caller owns the file, nothing is deleted, and the lease
        // settles once.
        var acceptedDiscards: [URL] = []
        let kept = CodexSelectionImageLease(capture: { file }, discard: { acceptedDiscards.append($0) })
        #expect(await kept.claim(stillEligible: { true }) == file)
        #expect(await kept.claim(stillEligible: { true }) == nil)
        kept.abandon()
        #expect(acceptedDiscards.isEmpty)

        // Consent revoked, source window replaced, detached or secure refusal
        // at hand-over: the file is deleted, not returned.
        let declined = discardRecorder()
        let refused = CodexSelectionImageLease(capture: { file }, discard: declined.record)
        #expect(await refused.claim(stillEligible: { false }) == nil)
        var declinedIterator = declined.stream.makeAsyncIterator()
        #expect(await declinedIterator.next() == file)

        // A newer gesture or stop abandons the lease: a capture finishing later
        // is still deleted, so no unreferenced file remains.
        let abandoned = discardRecorder()
        let dropped = CodexSelectionImageLease(capture: { file }, discard: abandoned.record)
        dropped.abandon()
        #expect(await dropped.claim(stillEligible: { true }) == nil)
        var abandonedIterator = abandoned.stream.makeAsyncIterator()
        #expect(await abandonedIterator.next() == file)

        // Cancelling the waiting read cancels the capture and deletes its file.
        let cancelled = discardRecorder()
        let waiting = CodexSelectionImageLease(capture: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return file
        }, discard: cancelled.record)
        let claimer = Task { @MainActor in await waiting.claim(stillEligible: { true }) }
        claimer.cancel()
        #expect(await claimer.value == nil)
        var cancelledIterator = cancelled.stream.makeAsyncIterator()
        #expect(await cancelledIterator.next() == file)

        // The default disposal really removes the private file.
        let real = CodexSelectionImageLease(capture: { file })
        #expect(await real.claim(stillEligible: { false }) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func codexImageFollowsItsUnchangedTextAtTheSameTimeAndAnchorWithHonestXML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SelectionWindowImageCapture.save(image(), directory: root,
                                                         filePrefix: CodexSelectionImageCapture.filePrefix)
        let selectedAt = Date(timeIntervalSince1970: 100)
        let textID = UUID()
        let session = RecordingSession()
        let text = try #require(LiveSelectionReference("x plus"))
            .scopedToVisibleCodexThreads([]).timed(at: selectedAt).identifiedForCapture(textID)
        session.recordLiveSelection(text, spokenAnchor: "before")
        // Another context event lands while the drag's image is still capturing.
        session.recordLiveSelection(try #require(LiveSelectionReference("later highlight"))
            .timed(at: selectedAt.addingTimeInterval(1)), spokenAnchor: "before and")
        let picture = try #require(LiveSelectionReference(codexSelectionImageURL: file)).timed(at: selectedAt)
        #expect(picture.isSelectionImage)
        // Only an image may be attached, and only beside its own committed text.
        #expect(!session.attachLiveSelectionImage(try #require(LiveSelectionReference("not an image")),
                                                  after: textID, spokenAnchor: "before"))
        #expect(!session.attachLiveSelectionImage(picture, after: UUID(), spokenAnchor: "before"))
        #expect(session.attachLiveSelectionImage(picture, after: textID, spokenAnchor: "before"))

        let references = session.liveSelectionReferences
        #expect(references.count == 3)
        #expect(references[0].captureID == textID && !references[0].isSelectionImage)
        #expect(references[1].isSelectionImage)
        #expect(!references[2].isSelectionImage)
        // Text is unchanged and keeps its own character count; the image adds
        // no text and claims no count.
        #expect(references[0].characterCount == 6)
        #expect(references[1].characterCount == 0)
        #expect(references[0].spokenWordCount == references[1].spokenWordCount)

        let timeline = LiveSelectionReference.interleaving(references, with: "before and after", includeTiming: true)
        let events = AgentFlowPromptViewer.events(timeline)
        #expect(events.map(\.tag) == ["speech", "codex_selection", "app_selection_image",
                                      "speech", "codex_selection", "speech"])
        #expect(events[1].text == "x plus")
        #expect(events[1].attributes["characters"] == "6")
        let tag = events[2].attributes
        #expect(tag["source"] == "Codex")
        #expect(tag["bundle_id"] == "com.openai.codex")
        #expect(tag["scope"] == "gesture_area")
        #expect(tag["exact_selection"] == "false")
        #expect(tag["path"] == file.path)
        #expect(tag["captured_at"] == "100.000")
        #expect(tag["captured_at"] == events[1].attributes["captured_at"])
        #expect(tag["characters"] == nil)
        #expect(!timeline.contains("source=\"Telegram\""))
        // Telegram's established tag is untouched by the shared image init.
        let telegram = try #require(LiveSelectionReference(telegramSelectionImageURL: file))
        let telegramEvents = AgentFlowPromptViewer.events(
            LiveSelectionReference.interleaving([telegram], with: "", includeTiming: true))
        #expect(telegramEvents.first?.attributes["source"] == "Telegram")
        #expect(telegramEvents.first?.attributes["bundle_id"] == "ru.keepcoder.Telegram")
    }

    @Test func codexImageViewerHistoryCopyAndHUDShowOneSelectionImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SelectionWindowImageCapture.save(image(), directory: root,
                                                         filePrefix: CodexSelectionImageCapture.filePrefix)
        let at = Date(timeIntervalSince1970: 100)
        let text = try #require(LiveSelectionReference("x plus")).anchored(after: "before").timed(at: at)
        let picture = try #require(LiveSelectionReference(codexSelectionImageURL: file))
            .anchored(after: "before").timed(at: at)
        let timeline = LiveSelectionReference.interleaving([text, picture], with: "before after", includeTiming: true)
        #expect(HistoryContextPresentation.hasFlowMarkers(timeline))
        #expect(HistoryContextPresentation.copyText(timeline, format: .plain) == "before\n\nafter")
        #expect(HistoryContextPresentation.copyText(timeline, format: .formatted) == timeline)
        let parts = LiveSelectionReference.previewParts([text, picture], with: "before after")
        #expect(parts.contains(.selection("“x plus”")))
        #expect(parts.contains(.selection("Selection image")))
        let html = AgentFlowPromptViewer.html(timeline)
        #expect(html.contains("<h2>Selection image</h2>"))
        #expect(html.contains("<span class=\"app\">Codex</span>"))
        #expect(html.contains("Highlighted area; nearby text may be included."))
        #expect(html.components(separatedBy: "<img ").count == 2)
        #expect(!html.contains("Preview unavailable"))
        let styled = LiveSelectionReference.interleaving([text, picture], with: "before after", presentation: .styledMath)
        let decoded = HistoryContextPresentation.document(styled).plainText
        #expect(AgentFlowPromptViewer.events(decoded).filter { $0.tag == "app_selection_image" }.count == 1)
        #expect(AgentFlowPromptViewer.events(decoded).filter { $0.tag == "codex_selection" }.count == 1)
    }

    @Test func codexImageStartsBesideTheReadAndCommitsAfterTextAndReceipt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let capture = try source("VoiceInk/Services/LiveSelectionCapture.swift")
        let start = try #require(capture.range(of: "codexImage = CodexSelectionImageLease"))
        let abandon = try #require(capture.range(of: "defer { codexImage?.abandon() }"))
        let read = try #require(capture.range(of: "let result = await Self.readSelectedText("))
        let telegram = try #require(capture.range(of: "} else if TelegramSelectionImageCapture.mayCapture("))
        let imageOnly = try #require(capture.range(of: "LiveSelectionReference(codexSelectionImageURL: imageURL) else"))
        let commit = try #require(capture.range(of: "self.onCapture(captured.timed"))
        let receipt = try #require(capture.range(of: "if isCodex, let receipt = Self.selectionReceipt"))
        let companion = try #require(capture.range(of: "self.onImage(captureID, image.timed(at: selectedAt), spokenAnchor)"))
        let labels = try #require(capture.range(of: "let threadsBefore = await beforeLabels"))
        // Pixels are requested before the possibly long text read; text, then
        // the unchanged receipt, then the image, then optional labels.
        #expect(start.lowerBound < abandon.lowerBound && abandon.lowerBound < read.lowerBound)
        // Telegram's narrower no-AX fallback is still evaluated first.
        #expect(telegram.lowerBound < imageOnly.lowerBound && imageOnly.lowerBound < commit.lowerBound)
        #expect(commit.lowerBound < receipt.lowerBound && receipt.lowerBound < companion.lowerBound)
        #expect(companion.lowerBound < labels.lowerBound)
        // Image capture code never prompts for permission, reads text from
        // pixels, polls, or touches the clipboard, focus or input events.
        for path in ["VoiceInk/Services/CodexSelectionImageCapture.swift",
                     "VoiceInk/Services/SelectionWindowImageCapture.swift"] {
            let code = try source(path)
            for forbidden in ["CGRequestScreenCaptureAccess", "VNRecognizeText", "NSPasteboard",
                              "CGEvent", "AXUIElementSetAttributeValue", "AXUIElementPerformAction",
                              ".activate(", "kAXFocusedAttribute", "Timer", "asyncAfter"] {
                #expect(!code.contains(forbidden), "\(path) must not use \(forbidden)")
            }
        }
        // The Codex consent is its own key, separate from Telegram's.
        #expect(CodexSelectionImageCapture.preferenceKey != TelegramSelectionImageCapture.preferenceKey)
        let settings = try source("VoiceInk/Views/Settings/SettingsView.swift")
        #expect(settings.contains("@AppStorage(CodexSelectionImageCapture.preferenceKey) private var codexHighlightImages = false"))
    }
}
