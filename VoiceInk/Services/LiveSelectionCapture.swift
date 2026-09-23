import AppKit
import Foundation

/// A compact, per-recording reference to text selected in Codex. The complete
/// selection is discarded after making this value; the sent message includes only
/// its boundaries, so the recipient must already have the source to resolve them.
struct LiveSelectionReference: Equatable {
    let preview: String
    let characterCount: Int
    let omittedMiddle: Bool
    private let start: String
    private let end: String?
    private var spokenPrefix = ""

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
            start = normalized
            end = nil
        } else {
            start = String(normalized.prefix(46))
            let last = String(normalized.suffix(46))
            end = last
            preview = "“\(start)” … “\(last)”"
            omittedMiddle = true
        }
    }

    func anchored(after spokenText: String) -> Self {
        var copy = self
        copy.spokenPrefix = spokenText
        return copy
    }

    static func interleaving(_ references: [Self], with transcript: String) -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !references.isEmpty else {
            return transcript
        }

        // Live provider text is a cumulative preview, not word-timestamped audio.
        // Its word count places each selection near the speech already shown when
        // the mouse came up. Never send a fake native Codex message/range anchor.
        let wordEnds = wordEndIndices(in: transcript)
        var lastWordCount = 0
        var previousEnd = transcript.startIndex
        var parts: [String] = []
        for (index, reference) in references.enumerated() {
            let spokenWordCount = reference.spokenPrefix.split(whereSeparator: \.isWhitespace).count
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? transcript.startIndex : wordEnds[wordCount - 1]
            let speech = String(transcript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty {
                parts.append(speech)
            }
            parts.append(reference.xml(index: index + 1))
            previousEnd = insertion
            lastWordCount = wordCount
        }
        let remainingSpeech = String(transcript[previousEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingSpeech.isEmpty {
            parts.append(remainingSpeech)
        }
        return parts.joined(separator: "\n\n")
    }

    private func xml(index: Int) -> String {
        let attributes = "index=\"\(index)\" source=\"Codex\" characters=\"\(characterCount)\" middle_omitted=\"\(omittedMiddle)\""
        if let end {
            return "<codex_selection \(attributes)>\n"
                + "  <start>\(Self.xmlEscaped(start))</start>\n"
                + "  <end>\(Self.xmlEscaped(end))</end>\n"
                + "</codex_selection>"
        }
        return "<codex_selection \(attributes)>\n"
            + "  <text>\(Self.xmlEscaped(start))</text>\n"
            + "</codex_selection>"
    }

    private static func wordEndIndices(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var insideWord = false
        for index in text.indices {
            if text[index].isWhitespace {
                if insideWord {
                    ends.append(index)
                    insideWord = false
                }
            } else {
                insideWord = true
            }
        }
        if insideWord { ends.append(text.endIndex) }
        return ends
    }

    private static func xmlEscaped(_ text: String) -> String {
        // A selection is untrusted page text. It must remain text even if it
        // contains tags, entities, or characters forbidden by XML 1.0.
        let xmlSafe = String(text.filter { character in
            character.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return value == 0x9 || value == 0xA || value == 0xD
                    || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value)
                    || (0x10000...0x10FFFF).contains(value)
            }
        })
        return xmlSafe.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
