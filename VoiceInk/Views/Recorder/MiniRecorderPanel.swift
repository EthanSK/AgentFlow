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
    static let separatorHeight: CGFloat = 1
    static let assistantPanelHeight: CGFloat = 320
    static let stackedCardSpacing: CGFloat = 46

    static func transcriptHeight(
        parts: [LiveSelectionReference.PreviewPart],
        width: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        let plain = parts.map { part -> String in
            switch part {
            case .speech(let text): return text
            case .selection(let text): return "Selected Text: \(text)"
            case .screenshot(let text): return "Screenshot: \(text)"
            }
        }.joined(separator: "  ")
        let content = plain.isEmpty ? "…" : plain
        // After enough dictated context to fill any normal display, measuring
        // the whole transcript on every provider partial would add HUD latency.
        if content.count > 3_000 { return max(liveTranscriptHeight, maxHeight) }
        let bounds = (content as NSString).boundingRect(
            with: NSSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: liveTranscriptFontSize)]
        )
        return min(max(liveTranscriptHeight, maxHeight),
                   max(liveTranscriptHeight, ceil(bounds.height) + 16))
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
            frame.origin.y = edge == .bottom
                ? screen.visibleFrame.minY + MiniRecorderLayoutMetrics.bottomPadding
                : screen.frame.maxY - height
            panel.setFrame(frame, display: true)
        }
    }
}

class MiniRecorderPanel: NSPanel {
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
        level = .floating
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
