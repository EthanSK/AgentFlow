import AppKit
import Foundation

/// App-lifetime watcher for left-mouse selection *gestures* in other apps.
///
/// Why it always runs: a recording's `LiveSelectionCapture` only starts once the
/// microphone has started, which can take a noticeable moment. Before build 349 it
/// also owned its own mouse monitor, so a drag that began before that moment had no
/// recorded mouse-down and was rejected, and a highlight made just before pressing
/// start was never considered (Ethan, 2026-09-26). This watcher remembers the
/// in-progress mouse-down and the latest completed selection gesture at all times,
/// so a starting recording can adopt both.
///
/// Privacy and cost boundary: while idle it records only pointer coordinates,
/// timestamps, click counts and the frontmost app's process identity. It never
/// reads selected text, the pasteboard or Accessibility, and holds one gesture at
/// most. Text is read only by an attached recording's `LiveSelectionCapture`, with
/// the same read-only fallback chain and stable-source checks as before. One
/// global monitor for mouse-button edges is installed once for the app's lifetime
/// and never duplicated; there is no timer, polling or per-event allocation beyond
/// a small value hop to the main actor.
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

    /// The pointer is sampled synchronously in the monitor callback. Bounds
    /// evidence compares it with the selection's on-screen rect, so a later
    /// MainActor hop must not substitute wherever the pointer moved next.
    struct MouseEdge {
        let type: NSEvent.EventType
        let clickCount: Int
        let location: NSPoint
        let occurredAt: Date
    }

    struct MouseDown: Equatable {
        let location: NSPoint
        let occurredAt: Date
    }

    /// A finished selection-shaped gesture. `processIdentifier` is the app that was
    /// frontmost at mouse-up, matching the live capture's source binding.
    struct CompletedGesture: Equatable {
        let start: NSPoint
        let end: NSPoint
        let startedAt: Date
        let endedAt: Date
        let processIdentifier: pid_t
    }

    private var monitor: Any?
    private(set) var pendingMouseDown: MouseDown?
    private(set) var lastSelectionGesture: CompletedGesture?

    /// The recording that currently owns live capture, if any. Weak so a finished
    /// session's capture can never be kept alive or receive later gestures.
    weak var listener: LiveSelectionCapture?

    /// Idempotent. Called at app launch and defensively when a capture attaches.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { event in
            let edge = MouseEdge(
                type: event.type,
                clickCount: event.clickCount,
                location: NSEvent.mouseLocation,
                occurredAt: Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
            )
            // Sample the frontmost app at the edge, as the live capture always did.
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Task { @MainActor in
                SelectionGestureWatcher.shared.handle(edge, frontmostPID: frontmostPID)
            }
        }
    }

    /// Updates the remembered gesture state, then forwards the same edge to the
    /// attached recording, which keeps its own mouse-down copy (seeded from
    /// `pendingMouseDown` when it attached).
    func handle(_ edge: MouseEdge, frontmostPID: pid_t?) {
        switch edge.type {
        case .leftMouseDown:
            pendingMouseDown = MouseDown(location: edge.location, occurredAt: edge.occurredAt)
        case .leftMouseUp:
            if let down = pendingMouseDown,
               let frontmostPID,
               LiveSelectionCapture.isSelectionGesture(
                   from: down.location, to: edge.location, clickCount: edge.clickCount
               ) {
                lastSelectionGesture = CompletedGesture(
                    start: down.location, end: edge.location,
                    startedAt: down.occurredAt, endedAt: edge.occurredAt,
                    processIdentifier: frontmostPID
                )
            }
            pendingMouseDown = nil
        default:
            break
        }
        listener?.handle(edge)
    }

    /// Whether a gesture completed before this recording's capture began may be
    /// read once as the recording's first reference. It must belong to the app
    /// that is frontmost now (the reader requires a stable frontmost source), have
    /// finished before capture attached (later gestures are read live, so this
    /// never duplicates one), and be recent enough to still be the user's intent.
    nonisolated static func isEligiblePriorGesture(
        _ gesture: CompletedGesture,
        now: Date,
        captureStartedAt: Date,
        frontmostPID: pid_t?
    ) -> Bool {
        guard let frontmostPID, gesture.processIdentifier == frontmostPID else { return false }
        return gesture.endedAt <= captureStartedAt
            && now.timeIntervalSince(gesture.endedAt) <= priorSelectionMaxAge
    }

    /// Whether an unmatched mouse-down seen before recording should be adopted as
    /// the start of a drag that finishes during recording.
    nonisolated static func adoptablePendingDown(_ down: MouseDown?, now: Date) -> MouseDown? {
        guard let down, now.timeIntervalSince(down.occurredAt) <= pendingMouseDownMaxAge else {
            return nil
        }
        return down
    }
}
