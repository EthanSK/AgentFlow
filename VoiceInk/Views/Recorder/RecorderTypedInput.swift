import AppKit
import SwiftUI
import OSLog

/// An ordinary, explicitly focused editor inside the recorder, never a global
/// keyboard monitor. Clicking another app returns keyboard ownership to that app.
/// Only explicit typing opt-in permits a one-shot return after accepted context;
/// ordinary speech updates and arbitrary app switches must never chase focus.
/// Context return starts only after explicit typing opt-in, never voice-only start.
struct RecorderTypedInput: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onEndEditing: () -> Void
    var typingFocus: RecorderTypingFocus? = nil
    var onSubmit: (() -> Void)? = nil

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
        let editor = RecorderTypingTextView(frame: NSRect(
            x: 0, y: 0, width: 640, height: MiniRecorderLayoutMetrics.typedInputHeight
        ))
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.font = .systemFont(ofSize: MiniRecorderLayoutMetrics.liveTranscriptFontSize)
        editor.textContainerInset = NSSize(width: 12, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        // Must not exceed the one-line frame: a taller minimum document would
        // scroll inside the box and reintroduce the empty band under the text.
        editor.minSize = NSSize(width: 0, height: MiniRecorderLayoutMetrics.typedInputHeight)
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
        editor.onSubmit = onSubmit
        editor.typingFocus = typingFocus
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RecorderTypingTextView else { return }
        editor.onEndEditing = onEndEditing
        editor.onSubmit = onSubmit
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
    var onSubmit: (() -> Void)?
    weak var typingFocus: RecorderTypingFocus?
    private var windowResignedObserver: NSObjectProtocol?
    // True only while `releaseKeyboardBeforeFinish()` resigns this editor. Capture
    // end, not this blur, commits the run, so it can follow every final word.
    private var isReleasingForCaptureEnd = false

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
        guard !isReleasingForCaptureEnd else { return }
        unmarkText()
        didChangeText()
        // Clear locally before publishing the seal so repeated focus callbacks
        // cannot re-append the previous run while SwiftUI catches up.
        string = ""
        undoManager?.removeAllActions()
        onEndEditing?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func isSubmitGesture(_ event: NSEvent) -> Bool {
        event.type == .keyDown && [36, 76].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    private func submitIfOwned(_ event: NSEvent) -> Bool {
        guard Self.isSubmitGesture(event), let window, window.isKeyWindow,
              window.firstResponder === self, let onSubmit else { return false }
        // AppKit routes Command shortcuts through key equivalents before keyDown.
        // Consume the owned gesture once, not a global shortcut or a newline; an
        // auto-repeat must not submit a second session. Flush IME/binding first.
        if !event.isARepeat {
            unmarkText()
            didChangeText()
            onSubmit()
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        submitIfOwned(event) || super.performKeyEquivalent(with: event)
    }

    /// Bare Return/Enter commits the current prose run into the speech/context
    /// timeline at this moment while recording continues (Ethan, 2026-10-10).
    static func isRunCommitGesture(_ event: NSEvent) -> Bool {
        event.type == .keyDown && [36, 76].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Shift+Return keeps one run multiline instead of committing it.
    static func isLineBreakGesture(_ event: NSEvent) -> Bool {
        event.type == .keyDown && [36, 76].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        // An IME composition owns Return to confirm its candidate. Never commit
        // or insert a newline over marked text; AppKit confirms it first.
        guard !hasMarkedText() else { return false }
        if Self.isRunCommitGesture(event) {
            // Keep keyboard focus for the next run; only this run is sealed.
            // Not a finish: Command+Return alone submits, via submitIfOwned.
            sealEditingRun()
            return true
        }
        if Self.isLineBreakGesture(event) {
            insertNewline(nil)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if submitIfOwned(event) || handleReturn(event) { return }
        super.keyDown(with: event)
    }

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
        // Flush IME composition and the latest characters into the session, but
        // do not seal here: the caller's `endLiveSelectionCapture()` is this run's
        // commit boundary and places it after every captured word. Leave the
        // editor text intact; if no capture end followed, the run stays editable.
        editor.unmarkText()
        editor.didChangeText()
        editor.isReleasingForCaptureEnd = true
        defer { editor.isReleasingForCaptureEnd = false }
        window.makeFirstResponder(nil)
        window.resignKey()
    }
}

/// Per-recording keyboard ownership, separate from all paste destinations.
/// Mirrored panels share the opt-in, but only the explicitly chosen editor may
/// regain focus. Never activate another app, poll focus, or re-arm after finish.
@MainActor
final class RecorderTypingFocus: ObservableObject {
    nonisolated static let automaticReturnDefaultsKey = "VIPPAutomaticTypingFocusReturnEnabled"
    @Published private(set) var isEnabled = false
    private(set) var initialFocusPending = false
    private var generation = 0
    private weak var preferredEditor: RecorderTypingTextView?
    private let editors = NSHashTable<RecorderTypingTextView>.weakObjects()
    private let automaticReturnEnabled: () -> Bool
    private let canFocus: () -> Bool
    private let mouseButtonsPressed: () -> Bool
    private let retryDelay: UInt64
    private let maximumAttempts: Int
    private var returnTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "TypingFocus")

    nonisolated static func automaticReturnEnabled(in defaults: UserDefaults) -> Bool {
        // Ethan wants focus back after each captured highlight/screenshot once
        // typing is engaged. Keep an explicit false opt-out, but an absent old
        // experiment key must not silently disable the advertised behaviour.
        (defaults.object(forKey: automaticReturnDefaultsKey) as? Bool) ?? true
    }

    init(automaticReturnEnabled: @escaping () -> Bool = {
        RecorderTypingFocus.automaticReturnEnabled(in: .standard)
    }, canFocus: @escaping () -> Bool = { true },
         mouseButtonsPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 },
         retryDelay: UInt64 = 50_000_000, maximumAttempts: Int = 40) {
        self.automaticReturnEnabled = automaticReturnEnabled
        self.canFocus = canFocus
        self.mouseButtonsPressed = mouseButtonsPressed
        self.retryDelay = retryDelay
        self.maximumAttempts = max(1, maximumAttempts)
    }

    // Explicit shortcut/click focus opts this session in. Finish disarms it;
    // speech updates and arbitrary app switches cannot re-enable it. Ethan
    // removed the old Unfocus control: leaving to highlight is not an opt-out.

    func register(_ editor: RecorderTypingTextView) {
        editors.add(editor)
        if initialFocusPending, returnTask == nil { scheduleReturn(initial: true) }
    }

    func enable(_ editor: RecorderTypingTextView) {
        guard canFocus() else { return }
        generation &+= 1
        returnTask?.cancel()
        returnTask = nil
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
        guard isEnabled, automaticReturnEnabled() else { return }
        // An initial highlight can arrive before the editor mounts. It must not
        // replace the pending explicit startup with a return to a nil editor.
        scheduleReturn(initial: initialFocusPending)
    }

    func disable(releaseKeyboard: Bool = true) {
        generation &+= 1
        returnTask?.cancel()
        returnTask = nil
        isEnabled = false
        initialFocusPending = false
        if releaseKeyboard, let editor = preferredEditor,
           editor.window?.isKeyWindow == true {
            RecorderTypingTextView.releaseKeyboardBeforeFinish()
        }
    }

    private func scheduleReturn(initial: Bool) {
        generation &+= 1
        let expectedGeneration = generation
        returnTask?.cancel()
        let attempts = maximumAttempts
        let delay = retryDelay
        returnTask = Task { @MainActor [weak self] in
            defer {
                if self?.generation == expectedGeneration { self?.returnTask = nil }
            }
            // Event-driven, coalesced and bounded to two seconds, not an idle
            // focus watcher. Mouse-up, screenshot UI teardown and editor mounting
            // can lag the accepted-context callback. The old single async turn
            // silently discarded those requests. Never interrupt a held drag,
            // activate another app, or focus a session after finish/cancellation.
            for attempt in 0..<attempts {
                guard !Task.isCancelled, let self, self.isEnabled, self.canFocus(),
                      self.generation == expectedGeneration else { return }
                // Recheck the explicit opt-out at the actual focus boundary;
                // it cannot cancel an explicitly requested keyboard-mode start.
                guard initial || self.automaticReturnEnabled() else { return }
                if !self.mouseButtonsPressed() {
                    let editor: RecorderTypingTextView?
                    if initial {
                        guard self.initialFocusPending else { return }
                        let visible = self.editors.allObjects.filter { $0.window?.isVisible == true }
                        editor = self.preferredEditor.flatMap {
                            $0.window?.isVisible == true ? $0 : nil
                        } ?? visible.first {
                            $0.window?.screen?.frame.contains(NSEvent.mouseLocation) == true
                        } ?? visible.first
                    } else {
                        editor = self.preferredEditor
                    }
                    if let editor, let window = editor.window, window.isVisible {
                        window.makeKey()
                        let accepted = window.makeFirstResponder(editor)
                        if accepted, window.isKeyWindow, window.firstResponder === editor {
                            self.preferredEditor = editor
                            self.initialFocusPending = false
                            Self.log.info("typing focus: restored initial=\(initial) attempt=\(attempt + 1)")
                            return
                        }
                    }
                }
                if attempt + 1 < attempts {
                    do { try await Task.sleep(nanoseconds: delay) } catch { return }
                }
            }
            Self.log.notice("typing focus: return expired initial=\(initial) attempts=\(attempts)")
        }
    }
}
