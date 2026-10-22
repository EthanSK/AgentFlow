import AppKit
import Foundation

/// App-lifetime, text-free watcher for selection *gestures* in other apps.
///
/// Why it always runs: a recording's `LiveSelectionCapture` historically started
/// only after the microphone handshake. It now attaches at committed start. Before build 349 it
/// also owned its own mouse monitor, so a drag that began before that moment had no
/// recorded mouse-down and was rejected, and a highlight made just before pressing
/// start was never considered (Ethan, 2026-09-26). This watcher remembers the
/// in-progress mouse-down and the latest completed selection gesture at all times,
/// so a starting recording can adopt both.
///
/// Privacy and cost boundary: while idle it records only pointer coordinates,
/// timestamps, click counts, Shift intent and the frontmost app's process identity. It never
/// reads selected text, the pasteboard or Accessibility, and holds one gesture at
/// most. Text is read only by an attached recording's `LiveSelectionCapture`, with
/// the same read-only fallback chain and stable-source checks as before. One
/// global monitor is installed once and never duplicated. Keyboard intent is
/// retained only while a recording capture is attached, and only its released
/// selection gesture is forwarded; there is no text feed, timer or polling.
@MainActor
final class SelectionGestureWatcher {
    static let shared = SelectionGestureWatcher()

    /// A drag already in progress when recording starts is adopted only if its
    /// mouse-down is this recent; an older unmatched down (for example one whose
    /// mouse-up landed in Agent Flow's own window) must not seed a false gesture.
    nonisolated static let pendingMouseDownMaxAge: TimeInterval = 10

    /// A highlight made before starting is attached only if it finished this
    /// recently. It covers "highlight while reading, then start talking" without
    /// dragging an old, still-highlighted passage into an unrelated dictation.
    nonisolated static let priorSelectionMaxAge: TimeInterval = 120

    /// Sample the pointer synchronously in the global callback, before any actor
    /// hop. NSEvent.cgEvent may reconstruct an event for this monitoring process:
    /// its target PID and converted location are not reliable source evidence.
    struct MouseEdge {
        let type: NSEvent.EventType
        let clickCount: Int
        let location: NSPoint
        let occurredAt: Date
        var callbackLagMilliseconds: Int? = nil
        var extendsSelection = false
    }

    struct MouseDown: Equatable {
        let location: NSPoint
        let occurredAt: Date
        var callbackLagMilliseconds: Int? = nil
        var extendsSelection = false
    }

    /// A finished selection-shaped gesture. `processIdentifier` is the app that was
    /// frontmost at mouse-up, matching the live capture's source binding.
    struct CompletedGesture: Equatable {
        let start: NSPoint
        let end: NSPoint
        let startedAt: Date
        let endedAt: Date
        let processIdentifier: pid_t
        var clickCount = 1
        var callbackLagMilliseconds: Int? = nil
        var extendsSelection = false
    }

    enum KeyboardInputKind: String, Equatable { case keyboard, selectAll }

    struct KeyboardGesture: Equatable {
        let startedAt: Date
        let endedAt: Date
        let processIdentifier: pid_t
        let inputKind: KeyboardInputKind
        var inputDirection: String? = nil
    }

    /// Text-free reducer. Read only after the initiating key is released in the
    /// same app; ordinary typing cancels pending intent instead of borrowing its
    /// newer range. Repeats keep one gesture, and no characters are inspected.
    struct KeyboardSequence {
        private var pending: (key: UInt16, start: Date, pid: pid_t, kind: KeyboardInputKind, released: Bool)?

        mutating func handle(type: NSEvent.EventType, keyCode: UInt16,
                             modifiers: NSEvent.ModifierFlags, at time: Date,
                             sourcePID: pid_t?) -> KeyboardGesture? {
            guard let sourcePID, sourcePID > 0 else { pending = nil; return nil }
            if type == .keyDown {
                guard let kind = Self.selectionKind(keyCode: keyCode, modifiers: modifiers) else {
                    pending = nil
                    return nil
                }
                let start = pending.flatMap { $0.pid == sourcePID && $0.kind == kind ? $0.start : nil } ?? time
                pending = (keyCode, start, sourcePID, kind, false)
            } else if type == .keyUp, let previous = pending, previous.key == keyCode {
                pending?.released = true
                // Holding Shift defines one extension gesture. Do not return
                // typing focus to the HUD between its successive arrow presses.
                if previous.kind == .keyboard && modifiers.contains(.shift) { return nil }
                return finish(at: time, sourcePID: sourcePID)
            } else if type == .flagsChanged, !modifiers.contains(.shift),
                      pending?.kind == .keyboard, pending?.released == true {
                return finish(at: time, sourcePID: sourcePID)
            }
            return nil
        }

        private mutating func finish(at time: Date, sourcePID: pid_t) -> KeyboardGesture? {
            if let previous = pending {
                pending = nil
                guard previous.pid == sourcePID, time >= previous.start,
                      time.timeIntervalSince(previous.start) <= 10 else { return nil }
                return KeyboardGesture(startedAt: previous.start, endedAt: time,
                                       processIdentifier: sourcePID, inputKind: previous.kind,
                                       inputDirection: Self.direction(keyCode: previous.key))
            }
            return nil
        }

        static func selectionKind(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyboardInputKind? {
            guard !modifiers.contains(.control) else { return nil }
            guard !(modifiers.contains(.command) && modifiers.contains(.option)) else { return nil }
            if keyCode == 0, modifiers.contains(.command),
               !modifiers.contains(.shift), !modifiers.contains(.option) { return .selectAll }
            // Arrows, Home/End and Page Up/Down, including word/line extension.
            if modifiers.contains(.shift), [115, 116, 119, 121, 123, 124, 125, 126].contains(keyCode) {
                return .keyboard
            }
            return nil
        }

        static func direction(keyCode: UInt16) -> String? {
            switch keyCode {
            case 115, 123: return "left"
            case 119, 124: return "right"
            case 116, 126: return "up"
            case 121, 125: return "down"
            default: return nil
            }
        }
    }

    private var monitor: Any?
    private var keyboardSequence = KeyboardSequence()
    private(set) var pendingMouseDown: MouseDown?
    private(set) var lastSelectionGesture: CompletedGesture?

    /// The recording that currently owns live capture, if any. Weak so a finished
    /// session's capture can never be kept alive or receive later gestures.
    weak var listener: LiveSelectionCapture?

    /// Idempotent. Called at app launch and defensively when a capture attaches.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .flagsChanged]
        ) { event in
            // AppKit guarantees event-monitor callbacks on the main thread.
            // Avoid a queued hop that can reorder an edge with capture attachment
            // or sample another frontmost app after the user's first highlight.
            MainActor.assumeIsolated {
                let watcher = SelectionGestureWatcher.shared
                if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
                    // Keyboard intent exists only during an attached session.
                    // Idle monitoring retains neither typed keys nor selected text.
                    guard let listener = watcher.listener else { watcher.resetKeyboardGesture(); return }
                    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if event.type == .keyDown { listener.selectionWillChange() }
                    let sourcePID = Self.sourcePID(frontmostPID: frontmostPID,
                        ownPID: ProcessInfo.processInfo.processIdentifier)
                    if let gesture = watcher.keyboardSequence.handle(type: event.type, keyCode: event.keyCode,
                        modifiers: event.modifierFlags, at: Self.occurredAt(event), sourcePID: sourcePID) {
                        listener.handle(gesture)
                    }
                } else {
                    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let edge = Self.edge(from: event, mouseLocation: NSEvent.mouseLocation)
                    watcher.handle(edge, frontmostPID: frontmostPID)
                }
            }
        }
    }

    static func edge(from event: NSEvent, mouseLocation: NSPoint) -> MouseEdge {
        // Restore the pre-358 global-monitor geometry. Keep the event timestamp
        // for chronology, but never derive routing from a reconstructed CGEvent.
        let now = Date()
        let occurredAt = Self.occurredAt(event)
        return MouseEdge(type: event.type, clickCount: event.clickCount, location: mouseLocation,
            occurredAt: occurredAt,
            callbackLagMilliseconds: callbackLagMilliseconds(occurredAt: occurredAt, now: now),
            extendsSelection: event.modifierFlags.contains(.shift))
    }

    private static func occurredAt(_ event: NSEvent) -> Date {
        Date().addingTimeInterval(event.timestamp - ProcessInfo.processInfo.systemUptime)
    }

    func resetKeyboardGesture() { keyboardSequence = KeyboardSequence() }

    nonisolated static func callbackLagMilliseconds(occurredAt: Date, now: Date) -> Int {
        let elapsed = now.timeIntervalSince(occurredAt)
        guard elapsed.isFinite else { return 0 }
        return Int(min(60_000, max(0, elapsed * 1_000)).rounded())
    }

    nonisolated static func combinedCallbackLag(_ down: Int?, _ up: Int?) -> Int? {
        guard let down, let up else { return nil }
        return max(down, up)
    }

    /// Updates the remembered gesture state, then forwards the same edge to the
    /// attached recording, which keeps its own mouse-down copy (seeded from
    /// `pendingMouseDown` when it attached).
    func handle(_ edge: MouseEdge, frontmostPID: pid_t?) {
        let sourcePID = Self.sourcePID(frontmostPID: frontmostPID,
                                       ownPID: ProcessInfo.processInfo.processIdentifier)
        switch edge.type {
        case .leftMouseDown:
            resetKeyboardGesture()
            pendingMouseDown = MouseDown(location: edge.location, occurredAt: edge.occurredAt,
                                        callbackLagMilliseconds: edge.callbackLagMilliseconds,
                                        extendsSelection: edge.extendsSelection)
        case .leftMouseUp:
            if let down = pendingMouseDown,
               let sourcePID,
               LiveSelectionCapture.isSelectionGesture(
                   from: down.location, to: edge.location, clickCount: edge.clickCount,
                   extendsSelection: down.extendsSelection
               ) {
                lastSelectionGesture = CompletedGesture(
                    start: down.location, end: edge.location,
                    startedAt: down.occurredAt, endedAt: edge.occurredAt,
                    processIdentifier: sourcePID, clickCount: edge.clickCount,
                    callbackLagMilliseconds: Self.combinedCallbackLag(
                        down.callbackLagMilliseconds, edge.callbackLagMilliseconds),
                    extendsSelection: down.extendsSelection
                )
            }
            pendingMouseDown = nil
        default:
            break
        }
        listener?.handle(edge, sourcePID: sourcePID)
    }

    nonisolated static func sourcePID(frontmostPID: pid_t?, ownPID: pid_t) -> pid_t? {
        // A global monitor observes other apps. Never read our own HUD as source
        // context, even if a focus transition races the callback.
        frontmostPID.flatMap { $0 > 0 && $0 != ownPID ? $0 : nil }
    }

    /// Whether a gesture completed before this recording's capture began may be
    /// read once as the recording's first reference. It must belong to the app
    /// that is frontmost at startup, have
    /// finished before capture attached (later gestures are read live, so this
    /// never duplicates one), and be recent enough to still be the user's intent.
    nonisolated static func isEligiblePriorGesture(
        _ gesture: CompletedGesture,
        now: Date,
        captureStartedAt: Date,
        frontmostPID: pid_t?
    ) -> Bool {
        guard let frontmostPID, gesture.processIdentifier == frontmostPID else { return false }
        return gesture.endedAt <= captureStartedAt && gesture.endedAt <= now
            && now.timeIntervalSince(gesture.endedAt) <= priorSelectionMaxAge
    }

    /// Whether an unmatched mouse-down seen before recording should be adopted as
    /// the start of a drag that finishes during recording.
    nonisolated static func adoptablePendingDown(_ down: MouseDown?, now: Date) -> MouseDown? {
        guard let down, down.occurredAt <= now,
              now.timeIntervalSince(down.occurredAt) <= pendingMouseDownMaxAge else {
            return nil
        }
        return down
    }
}
