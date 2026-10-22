import CryptoKit
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
    static func reserve(at state: URL, advancingBy positions: Int = 1) -> Int? {
        let lock = state.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }

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
            let advance = max(0, positions) % palette.count
            try Data("\((index + advance) % palette.count)\n".utf8).write(to: state, options: .atomic)
            return index
        } catch {
            return nil
        }
    }

    /// Viewer cursors are separate from the assistant quote counter: Ethan now
    /// wants the next message to continue AFTER its last authored word, not shift
    /// the starting colour by one. Context and visual wrapping consume nothing.
    /// Opaque proven chat IDs separate chats; ambiguous/no-chat scope continues an
    /// app-local fallback stream rather than guessing a chat or resetting to red.
    static func reserveViewerStartIndex(chatID: String?, wordCount: Int,
                                        directory: URL = viewerStateDirectory) -> Int {
        let scope = chatID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? "unscoped"
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        guard wordCount > 0 else { return 0 }
        // Private, bounded local state only; never touch the shared reply quote
        // counter or consume positions again when reopening a saved viewer.
        return viewerCursors.reserve(key: key, wordCount: wordCount, directory: directory)
    }

    private static let viewerCursors = ViewerCursors()

    private final class ViewerCursors: @unchecked Sendable {
        private let lock = NSLock()
        private var fallbackIndexes: [String: Int] = [:]

        func reserve(key: String, wordCount: Int, directory: URL) -> Int {
            // These reservations run in the archive's utility task, never the
            // startup/UI path. Serialize same-process writers; a busy foreign
            // lock or unavailable disk keeps the in-memory stream moving rather
            // than resetting every message or blocking delivery on presentation.
            lock.lock()
            defer { lock.unlock() }
            let state = directory.appendingPathComponent("viewer-\(key).txt")
            var persisted: Int?
            if (try? FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
               (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                persisted = AuthoredTextRainbow.reserve(at: state, advancingBy: wordCount)
            }
            let index = persisted ?? fallbackIndexes[state.path] ?? 0
            fallbackIndexes[state.path] = (index + wordCount % AuthoredTextRainbow.palette.count)
                % AuthoredTextRainbow.palette.count
            return index
        }
    }

    static var viewerStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentFlow/Presentation", isDirectory: true)
    }
}
