import Foundation

/// Matches response-preferences' fixed per-word palette. Formatting is local,
/// deterministic and side-effect-free; reserving an offset happens once at final
/// styled output, never for live partials, previews, plain destinations or retries.
enum AuthoredTextRainbow {
    static let palette = [
        "#fa7070", "#fa9370", "#fab570", "#fad870", "#fafa70", "#d8fa70",
        "#b5fa70", "#93fa70", "#70fa70", "#70fa93", "#70fab5", "#70fad8",
        "#70fafa", "#70d8fa", "#70b5fa", "#7093fa", "#7070fa", "#9370fa",
        "#b570fa", "#d870fa", "#fa70fa", "#fa70d8", "#fa70b5", "#fa7093"
    ]

    static func render(_ text: String, startIndex: Int, maxUTF16Count: Int = 64_000,
                       preserveWhitespace: Bool = false) -> String? {
        let start = ((startIndex % palette.count) + palette.count) % palette.count
        // One complete formula per word makes the exact original word colour
        // reusable in a reply. Long words retain one colour across short boxes;
        // reversible escaping is shared with XML, not lossy preview sanitization.
        var words: [String] = []
        var used = 0
        var cursor = text.startIndex
        for (offset, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            // A single huge identifier cannot fit; avoid expanding it merely to
            // discover that. Complete authored content remains in plain fallback.
            guard word.utf16.count <= maxUTF16Count - used else { return nil }
            let colored = LiveSelectionStyledMath.coloredXML(String(word), color: palette[(start + offset) % palette.count])
            let gap = preserveWhitespace ? String(text[cursor..<word.startIndex]) : (words.isEmpty ? "" : " ")
            used += colored.utf16.count + gap.utf16.count
            guard used <= maxUTF16Count else { return nil }
            words.append(gap + colored)
            cursor = word.endIndex
        }
        let tail = preserveWhitespace ? String(text[cursor...]) : ""
        guard used + tail.utf16.count <= maxUTF16Count else { return nil }
        return words.joined() + tail
    }

    // Ethan's "follows me around between chats" cursor (2026-11-02).
    // App outputs share one in-process offset. No chat/PID reads, disk state,
    // expiry map or coupling to the assistant response-preferences counter.
    static let cursor = Cursor()

    final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var nextIndex = 0

        func reserve(wordCount: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let start = nextIndex
            nextIndex = (start + max(0, wordCount) % AuthoredTextRainbow.palette.count)
                % AuthoredTextRainbow.palette.count
            return start
        }
    }
}
