import AppKit
import SwiftUI

/// An ordinary, explicitly focused editor inside the recorder, never a global
/// keyboard monitor. Clicking another app returns keyboard ownership to that app;
/// incoming context must not make this view key again.
struct RecorderTypedInput: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onEndEditing: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RecorderTypedInput
        var focusRequest: UUID
        init(_ parent: RecorderTypedInput) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? RecorderTypingTextView else { return }
            parent.text = editor.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = RecorderTypingTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 60))
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.font = .systemFont(ofSize: MiniRecorderLayoutMetrics.liveTranscriptFontSize)
        editor.textContainerInset = NSSize(width: 12, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 60)
        editor.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 640, height: .greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel(String(localized: "Type in dictation"))
        editor.delegate = context.coordinator
        editor.onEndEditing = onEndEditing
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RecorderTypingTextView else { return }
        editor.onEndEditing = onEndEditing
        if editor.string != text {
            // Model changes seal a run or mirror another screen. Never let Undo
            // resurrect a sealed run and duplicate it in the final message.
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window else { return }
            window.makeKey()
            window.makeFirstResponder(editor)
        }
    }
}

final class RecorderTypingTextView: NSTextView {
    var onEndEditing: (() -> Void)?
    private var windowResignedObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignedObserver {
            NotificationCenter.default.removeObserver(windowResignedObserver)
        }
        windowResignedObserver = nil
        guard let window else { return }
        // A window can lose key status while retaining its first responder.
        // Observe this window only; a highlight in another app must seal the run
        // without activating us or finishing the recording.
        windowResignedObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                self.sealEditingRun()
            }
        }
    }

    deinit {
        if let windowResignedObserver {
            NotificationCenter.default.removeObserver(windowResignedObserver)
        }
    }

    private func sealEditingRun() {
        unmarkText()
        didChangeText()
        // Clear locally before publishing the seal so repeated focus callbacks
        // cannot re-append the previous run while SwiftUI catches up.
        string = ""
        undoManager?.removeAllActions()
        onEndEditing?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { sealEditingRun() }
        return resigned
    }

    static var ownsKeyboard: Bool {
        NSApp.keyWindow?.firstResponder is RecorderTypingTextView
    }

    static func commitFocusedDraft() {
        guard let editor = NSApp.keyWindow?.firstResponder as? RecorderTypingTextView else { return }
        editor.unmarkText()
        editor.didChangeText()
    }

    /// End only this app-owned input before the existing finish path. Resigning
    /// our nonactivating panel is not activation/restoration of a saved app or
    /// exact input: Primary still follows whatever keyboard input macOS owns.
    static func releaseKeyboardBeforeFinish() {
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? RecorderTypingTextView else { return }
        editor.unmarkText()
        editor.didChangeText()
        window.makeFirstResponder(nil)
        window.resignKey()
    }
}
