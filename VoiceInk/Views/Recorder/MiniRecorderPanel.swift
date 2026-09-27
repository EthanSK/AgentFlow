import SwiftUI
import AppKit

/// Shared geometry for the bottom-anchored mini recorder and notifications that
/// must clear it. Keep these values as the single source of truth: a hard-coded
/// notification offset previously assumed a 34pt bar and overlapped the 97pt
/// real-time transcript HUD.
enum MiniRecorderLayoutMetrics {
    // Keep the expanded width for mixed speech/context, but use the midpoint
    // between the original 12pt and enlarged 24pt type. The separate HUD
    // slider scales the entire panel without changing this layout measurement.
    static let liveTranscriptWidth: CGFloat = 688
    static let liveTranscriptFontSize: CGFloat = 18
    static let notchTranscriptSideExpansion: CGFloat = 360
    static let bottomPadding: CGFloat = 24
    static let controlBarHeight: CGFloat = 40
    static let liveTranscriptHeight: CGFloat = 56
    /// One line of recorder text plus the 16pt vertical padding every measured
    /// section adds (the editor's 6pt top/bottom insets plus rounding slack).
    /// Build 347 gave the empty "Click to type" editor a fixed 60pt box and kept
    /// the preview row above it at the 56pt two-line minimum, so both showed tall
    /// empty bands (Ethan, 2026-09-26). While typing is available, both sections
    /// now start at exactly one line and grow only with real content.
    static let singleLineHeight: CGFloat = {
        let bounds = ("\u{200B}" as NSString).boundingRect(
            with: NSSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: liveTranscriptFontSize)]
        )
        return ceil(bounds.height) + 16
    }()
    static var typedInputHeight: CGFloat { singleLineHeight }
    static let typedInputControlWidth: CGFloat = 90
    static let separatorHeight: CGFloat = 1
    static let assistantPanelHeight: CGFloat = 320
    static let stackedCardSpacing: CGFloat = 46

    /// Lay out only the lines that can fit in the current display's envelope.
    /// A character count cannot establish that the HUD is full: at the same
    /// font and width, 3,001 characters measured 919pt but the old shortcut
    /// jumped straight to a 1,450pt panel. TextKit's height-bounded container
    /// avoids that discontinuity without laying out an unbounded transcript
    /// on every live provider update.
    private static func measuredHeight(_ text: String, width: CGFloat, limit: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: liveTranscriptFontSize)
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width), height: max(1, limit - 16)
        ))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let visibleGlyphs = layout.glyphRange(for: container)
        let visibleCharacters = layout.characterRange(
            forGlyphRange: visibleGlyphs, actualGlyphRange: nil
        )
        if NSMaxRange(visibleCharacters) < storage.length { return limit }
        return min(limit, ceil(layout.usedRect(for: container).height) + 16)
    }

    static func typingHeight(text: String, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let limit = max(typedInputHeight, maxHeight)
        // Include the trailing insertion line: NSString otherwise omits it after Return.
        return max(typedInputHeight, measuredHeight(
            text + "\u{200B}", width: width - 34 - typedInputControlWidth, limit: limit
        ))
    }

    static func contextHeight(
        parts: [LiveSelectionReference.PreviewPart], typedText: String?,
        width: CGFloat, maxHeight: CGFloat
    ) -> CGFloat {
        // With the editor present, the preview row above it only needs one line
        // at minimum. Reserve exactly that line when capping a long editor, and
        // keep LiveTranscriptView's editor cap on the same reserve so the rendered
        // split matches this envelope. Without typing (after stop, transcribing),
        // the long-standing 56pt preview minimum is unchanged.
        let previewMinimum = typedText == nil ? liveTranscriptHeight : singleLineHeight
        let editor = typedText.map {
            typingHeight(text: $0, width: width, maxHeight: maxHeight - previewMinimum)
        } ?? 0
        return editor + transcriptHeight(
            parts: parts, width: width, maxHeight: maxHeight - editor, minimumHeight: previewMinimum
        )
    }

    static func transcriptHeight(
        parts: [LiveSelectionReference.PreviewPart],
        width: CGFloat,
        maxHeight: CGFloat,
        minimumHeight: CGFloat = liveTranscriptHeight
    ) -> CGFloat {
        let plain = parts.map { part -> String in
            switch part {
            case .speech(let text): return text
            case .selection(let text): return "Selected Text: \(text)"
            case .screenshot(let text): return "Screenshot: \(text)"
            }
        }.joined(separator: "  ")
        let content = plain.isEmpty ? "…" : plain
        let limit = max(minimumHeight, maxHeight)
        return max(minimumHeight, measuredHeight(content, width: width - 32, limit: limit))
    }

    static func notificationBottomReservedHeight(
        showsAssistant: Bool,
        showsRealtimeTranscript: Bool,
        sessionCount: Int,
        realtimeTranscriptHeight: CGFloat = liveTranscriptHeight,
        scale: CGFloat = 1
    ) -> CGFloat {
        let baseHeight: CGFloat
        if showsAssistant {
            baseHeight = assistantPanelHeight + separatorHeight + controlBarHeight
        } else if showsRealtimeTranscript {
            baseHeight = realtimeTranscriptHeight + separatorHeight + controlBarHeight
        } else {
            baseHeight = controlBarHeight
        }

        let stackedHeight = CGFloat(max(0, sessionCount - 1)) * stackedCardSpacing
        return bottomPadding + (baseHeight + stackedHeight) * scale
    }
}

/// Resize only the transparent host window needed for the visible live context.
/// A permanent full-screen nonactivating panel would intercept clicks in other
/// apps even where the recorder draws nothing.
struct RecorderPanelHeightSync: NSViewRepresentable {
    enum Edge: Equatable { case bottom, top }
    let desiredHeight: CGFloat
    let edge: Edge
    let scale: CGFloat

    final class Coordinator {
        var desiredHeight: CGFloat = 430
        var scale: CGFloat = 1
        var scheduled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.desiredHeight = desiredHeight
        context.coordinator.scale = scale
        guard !context.coordinator.scheduled else { return }
        context.coordinator.scheduled = true
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            coordinator.scheduled = false
            guard let panel = view?.window,
                  let screen = panel.screen else { return }
            let limit = edge == .bottom
                ? screen.visibleFrame.height - MiniRecorderLayoutMetrics.bottomPadding - 12
                : screen.frame.height - 12
            let minimum = 120 * coordinator.scale
            let height = min(max(minimum, coordinator.desiredHeight * coordinator.scale),
                             max(minimum, limit))
            guard abs(panel.frame.height - height) > 1 else { return }
            var frame = panel.frame
            frame.size.height = height
            if (panel as? MiniRecorderPanel)?.wasDraggedByUser != true {
                frame.origin.y = edge == .bottom
                    ? screen.visibleFrame.minY + MiniRecorderLayoutMetrics.bottomPadding
                    : screen.frame.maxY - height
            }
            panel.setFrame(frame, display: true)
        }
    }
}

class MiniRecorderPanel: NSPanel {
    var wasDraggedByUser = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }
    
    private func configurePanel() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Codex Model Bar is also floating and reorders itself. A distinct level
        // keeps this editor readable without activating it or fighting focus.
        level = .floating + 1
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
    
    static func calculateWindowMetrics(
        for screen: NSScreen? = NSScreen.main,
        scale: CGFloat = 1
    ) -> NSRect {
        let width: CGFloat = 720 * scale
        let height: CGFloat = 430 * scale

        guard let screen else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }

        // Host stays large enough for assistant output; SwiftUI controls the visible mini width.
        let visibleFrame = screen.visibleFrame
        let centerX = visibleFrame.midX
        let xPosition = centerX - (width / 2)
        let yPosition = visibleFrame.minY + MiniRecorderLayoutMetrics.bottomPadding

        return NSRect(
            x: xPosition,
            y: yPosition,
            width: width,
            height: height
        )
    }

    func show(on screen: NSScreen, scale: CGFloat = 1) {
        let metrics = MiniRecorderPanel.calculateWindowMetrics(for: screen, scale: scale)
        setFrame(metrics, display: true)
        orderFrontRegardless()
        // Flush the first hosted frame so a window that passed the manager's visibility
        // postcondition cannot remain blank. Do not make this nonactivating panel key or
        // steal focus from the app Ethan is dictating into.
        displayIfNeeded()
    }
    
} 
