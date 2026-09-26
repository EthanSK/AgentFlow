import AppKit
import SwiftUI

/// An ordinary, explicitly focused editor inside the recorder, never a global
/// keyboard monitor. Clicking another app returns keyboard ownership to that app.
/// Only explicit typing opt-in permits a one-shot return after accepted context;
/// ordinary speech updates and arbitrary app switches must never chase focus.
struct RecorderTypedInput: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onEndEditing: () -> Void
    var typingFocus: RecorderTypingFocus? = nil

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
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel(String(localized: "Type in dictation"))
        editor.delegate = context.coordinator
        editor.onEndEditing = onEndEditing
        editor.typingFocus = typingFocus
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RecorderTypingTextView else { return }
        editor.onEndEditing = onEndEditing
        editor.typingFocus = typingFocus
        typingFocus?.register(editor)
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
            editor.typingFocus?.enable(editor)
            window.makeKey()
            window.makeFirstResponder(editor)
        }
    }
}

final class RecorderTypingTextView: NSTextView {
    var onEndEditing: (() -> Void)?
    weak var typingFocus: RecorderTypingFocus?
    private var windowResignedObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignedObserver {
            NotificationCenter.default.removeObserver(windowResignedObserver)
        }
        windowResignedObserver = nil
        guard let window else { return }
        typingFocus?.register(self)
        // A window can lose key status while retaining its first responder.
        // Observe this window only; a highlight in another app must seal the run
        // without activating us or finishing the recording. Focus return, when
        // explicitly enabled, waits for an accepted context item instead of blur.
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
        typingFocus?.enable(self)
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { sealEditingRun() }
        return resigned
    }

    static var ownsKeyboard: Bool {
        NSApp?.keyWindow?.firstResponder is RecorderTypingTextView
    }

    static func sealFocusedRun() {
        guard let editor = NSApp?.keyWindow?.firstResponder as? RecorderTypingTextView else { return }
        editor.sealEditingRun()
    }

    /// End only this app-owned input before the existing finish path. Resigning
    /// our nonactivating panel is not activation/restoration of a saved app or
    /// exact input: Primary still follows whatever keyboard input macOS owns.
    static func releaseKeyboardBeforeFinish() {
        guard let window = NSApp?.keyWindow,
              let editor = window.firstResponder as? RecorderTypingTextView else { return }
        editor.typingFocus?.disable(releaseKeyboard: false)
        editor.unmarkText()
        editor.didChangeText()
        window.makeFirstResponder(nil)
        window.resignKey()
    }
}

/// Per-recording keyboard ownership, separate from all paste destinations.
/// Mirrored panels share the opt-in, but only the explicitly chosen editor may
/// regain focus. Never activate another app, poll focus, or re-arm after finish.
@MainActor
final class RecorderTypingFocus: ObservableObject {
    @Published private(set) var isEnabled = false
    private(set) var initialFocusPending = false
    private var generation = 0
    private weak var preferredEditor: RecorderTypingTextView?
    private let editors = NSHashTable<RecorderTypingTextView>.weakObjects()
    private let canFocus: () -> Bool

    init(canFocus: @escaping () -> Bool = { true }) { self.canFocus = canFocus }

    func register(_ editor: RecorderTypingTextView) {
        editors.add(editor)
        if initialFocusPending { scheduleReturn(initial: true) }
    }

    func enable(_ editor: RecorderTypingTextView) {
        guard canFocus() else { return }
        generation &+= 1
        preferredEditor = editor
        initialFocusPending = false
        isEnabled = true
    }

    func requestInitialFocus() {
        guard canFocus() else { return }
        isEnabled = true
        initialFocusPending = true
        scheduleReturn(initial: true)
    }

    func returnAfterContext() {
        guard isEnabled else { return }
        scheduleReturn(initial: false)
    }

    func disable(releaseKeyboard: Bool = true) {
        generation &+= 1
        isEnabled = false
        initialFocusPending = false
        if releaseKeyboard, let editor = preferredEditor,
           editor.window?.isKeyWindow == true {
            RecorderTypingTextView.releaseKeyboardBeforeFinish()
        }
    }

    private func scheduleReturn(initial: Bool) {
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.canFocus(),
                  self.generation == expectedGeneration,
                  NSEvent.pressedMouseButtons == 0 else { return }
            let editor: RecorderTypingTextView?
            if initial {
                guard self.initialFocusPending else { return }
                let visible = self.editors.allObjects.filter { $0.window?.isVisible == true }
                editor = visible.first {
                    $0.window?.screen?.frame.contains(NSEvent.mouseLocation) == true
                } ?? visible.first
            } else {
                editor = self.preferredEditor
            }
            guard let editor, let window = editor.window, window.isVisible else { return }
            self.preferredEditor = editor
            self.initialFocusPending = false
            window.makeKey()
            window.makeFirstResponder(editor)
        }
    }
}

struct RecorderTypingFocusControl: View {
    @ObservedObject var focus: RecorderTypingFocus
    var body: some View {
        if focus.isEnabled {
            Button("Unfocus", systemImage: "lock.open") { focus.disable() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .padding(6)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
