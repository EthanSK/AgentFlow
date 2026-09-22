import AppKit
import Foundation

/// A compact, per-recording reference to text selected in Codex. The complete
/// selection is discarded after making this value; the sent message includes only
/// its boundaries, so the recipient must already have the source to resolve them.
struct LiveSelectionReference: Equatable {
    let preview: String
    let characterCount: Int
    let omittedMiddle: Bool

    init?(_ selectedText: String) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        characterCount = trimmed.count
        if normalized.count <= 96 {
            preview = "“\(normalized)”"
            omittedMiddle = false
        } else {
            preview = "“\(normalized.prefix(46))” … “\(normalized.suffix(46))”"
            omittedMiddle = true
        }
    }

    static func appending(_ references: [Self], to transcript: String) -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !references.isEmpty else {
            return transcript
        }

        let entries = references.enumerated().map { index, reference in
            let omission = reference.omittedMiddle ? "; middle omitted" : ""
            let unit = reference.characterCount == 1 ? "character" : "characters"
            return "[\(index + 1)] \(reference.preview) (\(reference.characterCount) \(unit)\(omission))"
        }
        return transcript + "\n\nSelected text in Codex, in selection order (quoted context):\n"
            + entries.joined(separator: "\n")
    }
}

/// Watches genuine selection gestures only while a VoiceInk recording owns the
/// microphone. No copy command or pasteboard restoration is allowed here: an older
/// transcription may be writing the clipboard concurrently for Primary delivery.
@MainActor
final class LiveSelectionCapture {
    private let onCapture: (LiveSelectionReference) -> Void
    private var monitor: Any?
    private var mouseDownPoint: NSPoint?
    private var captureTask: Task<Void, Never>?

    init(onCapture: @escaping (LiveSelectionReference) -> Void) {
        self.onCapture = onCapture
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        captureTask?.cancel()
        captureTask = nil
        mouseDownPoint = nil
    }

    private func handle(_ event: NSEvent) {
        guard monitor != nil else { return }
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = NSEvent.mouseLocation
        case .leftMouseUp:
            let endPoint = NSEvent.mouseLocation
            let startPoint = mouseDownPoint
            mouseDownPoint = nil
            guard let startPoint,
                  Self.isSelectionGesture(
                      from: startPoint,
                      to: endPoint,
                      clickCount: event.clickCount
                  ),
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == "com.openai.codex" else {
                return
            }

            let sourcePID = app.processIdentifier
            captureTask?.cancel()
            captureTask = Task { @MainActor [weak self] in
                // The target app finishes its own mouse-up selection update before
                // this read. A newer gesture or stop cancels the pending read.
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled,
                      let text = await SelectedTextService.fetchSelectedText(),
                      !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
                      let reference = LiveSelectionReference(text) else {
                    return
                }
                self?.onCapture(reference)
            }
        default:
            break
        }
    }

    static func isSelectionGesture(
        from start: NSPoint,
        to end: NSPoint,
        clickCount: Int
    ) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return clickCount >= 2 || dx * dx + dy * dy >= 16
    }
}
