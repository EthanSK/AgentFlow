import Darwin
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

    static func render(_ text: String, startIndex: Int, maxUTF16Count: Int = 64_000) -> String? {
        let start = ((startIndex % palette.count) + palette.count) % palette.count
        // One complete formula per word makes the exact original word colour
        // reusable in a reply. Long words retain one colour across short boxes;
        // reversible escaping is shared with XML, not lossy preview sanitization.
        var words: [String] = []
        var used = 0
        for (offset, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            // A single huge identifier cannot fit; avoid expanding it merely to
            // discover that. Complete authored content remains in plain fallback.
            guard word.utf16.count <= maxUTF16Count - used else { return nil }
            let colored = LiveSelectionStyledMath.coloredXML(String(word), color: palette[(start + offset) % palette.count])
            used += colored.utf16.count + (words.isEmpty ? 0 : 1)
            guard used <= maxUTF16Count else { return nil }
            words.append(colored)
        }
        return words.joined(separator: " ")
    }

    static func reserveStartIndex() -> Int {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        let shared = codexHome.appendingPathComponent("state/response-preferences", isDirectory: true)
        // Interoperate only with an existing response-preferences installation.
        // Public users need neither Codex nor a personal skill to use the app.
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let index = reserve(at: shared.appendingPathComponent("rainbow-next-index.txt")) {
            return index
        }
        let local = home.appendingPathComponent("Library/Application Support/AgentFlow/Presentation", isDirectory: true)
        guard (try? files.createDirectory(at: local, withIntermediateDirectories: true)) != nil else { return 0 }
        return reserve(at: local.appendingPathComponent("rainbow-next-index.txt")) ?? 0
    }

    /// Same separate .lock file and atomic replace protocol as rainbow-quote.py.
    /// Never wait for another process or repair a malformed shared counter during
    /// paste. A local offset (or zero) is harmless; delaying/dropping words is not.
    static func reserve(at state: URL) -> Int? {
        let lock = state.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { Darwin.flock(descriptor, LOCK_UN) }

        var index = 0
        let input = Darwin.open(state.path, O_RDONLY | O_NOFOLLOW)
        if input >= 0 {
            defer { Darwin.close(input) }
            var metadata = stat()
            guard fstat(input, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 64,
                  (metadata.st_mode & S_IFMT) == S_IFREG else { return nil }
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(input, &bytes, bytes.count)
            guard count > 0,
                  let value = Int(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            index = ((value % palette.count) + palette.count) % palette.count
        } else if errno != ENOENT {
            return nil
        }
        do {
            try Data("\((index + 1) % palette.count)\n".utf8).write(to: state, options: .atomic)
            return index
        } catch {
            return nil
        }
    }
}
