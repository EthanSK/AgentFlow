/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-25 · Agent Flow chat 01a1f045-8e29-75f3-b537-bf10be4fd21f
 RecorderComponents.swift / LiveTranscriptView.previewText supplied the ordered
 labels, separators and colours below. This is a behavioural refactor, not a pure
 move: AppKit TextKit 2 now draws the read-only preview instead of SwiftUI Text,
 avoiding its repeated full-draft redraw cost. Full context and the editable
 typing control remain unchanged. — GPT-6.1 Sol
 ============================================================================
 */
import AppKit
import SwiftUI

/// Refactor of LiveTranscriptView.previewText's existing chronological stream.
/// Preserve its wording and colours; only the drawing engine changes. Ethan's
/// "as the text grows" performance request does not authorize cutting its text.
struct RecorderTranscriptPreviewContent: Equatable {
    let parts: [LiveSelectionReference.PreviewPart]
    var potentialTTSActive = false
    var dimsContextUntilSpeechArrives = false

    func attributedText() -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MiniRecorderLayoutMetrics.liveTranscriptFontSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let amber = NSColor(srgbRed: 251.0/255, green: 191.0/255, blue: 36.0/255, alpha: 1)
        let waiting = NSColor.white.withAlphaComponent(0.45)
        let result = NSMutableAttributedString(string: "")
        func append(_ text: String, color: NSColor? = nil) {
            var attributes = base
            if let color { attributes[.foregroundColor] = color }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        guard !parts.isEmpty else {
            append(potentialTTSActive ? "Potential ignore" : "…", color: potentialTTSActive ? amber : nil)
            return result
        }
        let hasAnnotatedWords = parts.contains { if case .potentialTTS = $0 { return true }; return false }
        if potentialTTSActive && !hasAnnotatedWords { append("Potential ignore · ", color: amber) }
        for (index, part) in parts.enumerated() {
            if index > 0 { append("  ") }
            switch part {
            case .speech(let text): append(text)
            case .potentialTTS(let text): append("Potential ignore: " + text, color: amber)
            case .selection(let text):
                append("\(String(localized: "Selected Text")): \(text)", color: dimsContextUntilSpeechArrives
                    ? waiting : NSColor(RecorderContextColor.selection).withAlphaComponent(0.8))
            case .screenshot(let filename):
                append("\(String(localized: "Screenshot")): \(filename)", color: dimsContextUntilSpeechArrives
                    ? waiting : NSColor(RecorderContextColor.screenshot).withAlphaComponent(0.95))
            }
        }
        return result
    }
}

/// Native read-only preview, separate from RecorderTypedInput and its IME/Undo.
/// TextKit 2 owns the visible viewport. Never read `layoutManager`, which would
/// force the legacy engine and discard the measured benefit.
struct RecorderTranscriptPreview: NSViewRepresentable {
    let content: RecorderTranscriptPreviewContent
    let width: CGFloat
    var dragsWindow = false
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> RecorderTranscriptScrollView {
        RecorderTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
    }
    func updateNSView(_ view: RecorderTranscriptScrollView, context: Context) {
        view.update(content, dragsWindow: dragsWindow, onClick: onClick)
    }
}

final class RecorderTranscriptTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class RecorderTranscriptScrollView: NSScrollView {
    let preview = RecorderTranscriptTextView(usingTextLayoutManager: true)
    private let dragSurface = RecorderPanelDragView()
    private var content: RecorderTranscriptPreviewContent?
    private var bottomScrollScheduled = false
    private var lastViewportWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        preview.frame = bounds
        preview.drawsBackground = false
        preview.isEditable = false
        preview.isSelectable = false
        preview.allowsUndo = false
        preview.textContainerInset = NSSize(width: 16, height: 6)
        preview.textContainer?.lineFragmentPadding = 0
        preview.textContainer?.widthTracksTextView = true
        preview.textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        preview.isHorizontallyResizable = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.minSize = NSSize(width: 0, height: bounds.height)
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentView = preview
        // Keep the existing hit-tested drag/click receiver INSIDE this exact
        // scroll document, so wheel forwarding never moves a different panel.
        dragSurface.frame = preview.bounds
        dragSurface.autoresizingMask = [.width, .height]
        preview.addSubview(dragSurface)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func update(_ next: RecorderTranscriptPreviewContent, dragsWindow: Bool, onClick: (() -> Void)?) {
        // Even a non-dragging preview retains the existing click-to-type path.
        dragSurface.isHidden = !dragsWindow
        dragSurface.onClick = onClick
        guard content != next else { return }
        content = next
        preview.textStorage?.setAttributedString(next.attributedText())
        followNewestWords()
    }

    override func layout() {
        super.layout()
        let viewport = contentSize
        if preview.minSize.height != viewport.height {
            preview.minSize = NSSize(width: 0, height: viewport.height)
        }
        guard viewport.width > 0, viewport.width != lastViewportWidth else { return }
        lastViewportWidth = viewport.width
        // Width changes are real layout inputs; normal meter/outline redraws
        // must not repeatedly reflow or snap a manually scrolled preview.
        followNewestWords()
    }

    private func followNewestWords() {
        guard !bottomScrollScheduled else { return }
        bottomScrollScheduled = true
        // One run-loop handoff lets AppKit receive the current SwiftUI frame.
        // It is coalescing, not a timer or extra recording/processing delay.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bottomScrollScheduled = false
            self.preview.scrollRangeToVisible(NSRange(location: self.preview.string.utf16.count, length: 0))
        }
    }
}
