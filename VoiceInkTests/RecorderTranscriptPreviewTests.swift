import AppKit
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized) struct RecorderTranscriptPreviewTests {
    @Test @MainActor func chronologicalContextAndSpeechKeepTheirTextAndColors() throws {
        let parts: [LiveSelectionReference.PreviewPart] = [
            .speech("First 👩🏽‍💻"), .selection("a < b\nsecond"), .potentialTTS("spoken reminder"),
            .screenshot("Screenshot.png"), .speech("last e\u{301}")
        ]
        let normal = RecorderTranscriptPreviewContent(parts: parts, potentialTTSActive: true).attributedText()
        #expect(normal.string == "First 👩🏽‍💻  Selected Text: a < b\nsecond  Potential ignore: spoken reminder  Screenshot: Screenshot.png  last e\u{301}")
        let ranges = ["Selected Text", "Screenshot", "Potential ignore"]
        let expected = [NSColor(RecorderContextColor.selection).withAlphaComponent(0.8),
                        NSColor(RecorderContextColor.screenshot).withAlphaComponent(0.95),
                        NSColor(srgbRed: 251.0/255, green: 191.0/255, blue: 36.0/255, alpha: 1)]
        for (label, color) in zip(ranges, expected) {
            let location = (normal.string as NSString).range(of: label).location
            #expect(normal.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == color)
        }
        let dim = RecorderTranscriptPreviewContent(parts: parts, dimsContextUntilSpeechArrives: true).attributedText()
        #expect(dim.string == normal.string)
        for label in ranges.prefix(2) {
            let location = (dim.string as NSString).range(of: label).location
            #expect(dim.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == NSColor.white.withAlphaComponent(0.45))
        }
        #expect(normal.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: 18))
    }

    @Test @MainActor func playbackPrefixAppearsOnlyBeforeUnannotatedWords() {
        #expect(RecorderTranscriptPreviewContent(parts: []).attributedText().string == "…")
        #expect(RecorderTranscriptPreviewContent(parts: [], potentialTTSActive: true).attributedText().string == "Potential ignore")
        #expect(RecorderTranscriptPreviewContent(parts: [.speech("words")], potentialTTSActive: true).attributedText().string == "Potential ignore · words")
        #expect(RecorderTranscriptPreviewContent(parts: [.potentialTTS("words")], potentialTTSActive: true).attributedText().string == "Potential ignore: words")
        #expect(RecorderTranscriptPreviewContent(parts: [.speech("words")]).attributedText().string == "words")
    }

    @Test @MainActor func fullLongPreviewFollowsTailAndPreservesManualScrollUntilTextChanges() async throws {
        let keyWindow = NSApp.keyWindow
        let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 160))
        let scroll = RecorderTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        panel.contentView = scroll
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        let text = String(repeating: "A full paragraph with 👩🏽‍💻 and e\u{301} stays available. ", count: 1_500) + " FINAL_TAIL_27"
        let content = RecorderTranscriptPreviewContent(parts: [.speech(text)])
        scroll.update(content, dragsWindow: true, onClick: nil)
        scroll.layoutSubtreeIfNeeded()
        // Release the main actor for the production coalesced scroll. A nested
        // RunLoop.run keeps this Swift Testing task on the dispatch main queue.
        try await waitForCompletion { scroll.preview.bounds.height > scroll.contentSize.height
            && scroll.preview.visibleRect.maxY >= scroll.preview.bounds.maxY - 2 }
        #expect(scroll.preview.string == text && scroll.preview.textLayoutManager != nil)
        #expect(scroll.preview.bounds.height > scroll.contentSize.height)
        #expect(scroll.preview.visibleRect.maxY >= scroll.preview.bounds.maxY - 2)
        #expect(!scroll.preview.isEditable && !scroll.preview.isSelectable && !scroll.preview.allowsUndo)
        #expect(!scroll.preview.acceptsFirstResponder && NSApp.keyWindow === keyWindow)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.origin.y
        scroll.update(content, dragsWindow: true, onClick: nil)
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(scroll.contentView.bounds.origin.y == before)
        scroll.update(.init(parts: [.speech(text + " newest")]), dragsWindow: true, onClick: nil)
        try await waitForCompletion { scroll.preview.visibleRect.maxY >= scroll.preview.bounds.maxY - 2 }
        #expect(scroll.preview.string.hasSuffix("FINAL_TAIL_27 newest"))
        #expect(scroll.preview.visibleRect.maxY >= scroll.preview.bounds.maxY - 2)
        scroll.update(.init(parts: [.speech("replacement")]), dragsWindow: true, onClick: nil)
        try await waitForCompletion { scroll.preview.visibleRect.origin.y == 0 }
        #expect(scroll.preview.string == "replacement")
        #expect(scroll.preview.textLayoutManager != nil && NSApp.keyWindow === keyWindow)
    }

    @Test @MainActor func resizingAndMirrorsKeepCompleteIndependentPreviewDocuments() async throws {
        let content = RecorderTranscriptPreviewContent(parts: [.speech(String(repeating: "Long context wraps naturally. ", count: 150))])
        let a = RecorderTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        let b = RecorderTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 140))
        let pa = MiniRecorderPanel(contentRect: a.frame), pb = MiniRecorderPanel(contentRect: b.frame)
        pa.contentView = a; pb.contentView = b
        pa.orderFrontRegardless(); pb.orderFrontRegardless()
        defer { pa.close(); pb.close() }
        a.update(content, dragsWindow: true, onClick: nil)
        b.update(content, dragsWindow: true, onClick: nil)
        try await waitForCompletion { a.preview.bounds.height > b.preview.bounds.height
            && a.preview.visibleRect.maxY >= a.preview.bounds.maxY - 2
            && b.preview.visibleRect.maxY >= b.preview.bounds.maxY - 2 }
        #expect(a.preview.string == b.preview.string)
        #expect(a.preview.bounds.height > b.preview.bounds.height)
        #expect(a.preview.textStorage !== b.preview.textStorage)
        let narrowHeight = a.preview.bounds.height
        pa.setContentSize(NSSize(width: 1_100, height: 140))
        a.layoutSubtreeIfNeeded()
        try await waitForCompletion { a.preview.bounds.height < narrowHeight
            && a.preview.visibleRect.maxY >= a.preview.bounds.maxY - 2 }
        #expect(a.preview.bounds.height < narrowHeight)
        #expect(a.preview.visibleRect.maxY >= a.preview.bounds.maxY - 2)
        #expect(a.preview.string == content.attributedText().string)
        b.update(.init(parts: [.speech("Other capture")]), dragsWindow: true, onClick: nil)
        #expect(a.preview.string != b.preview.string)
    }
}
