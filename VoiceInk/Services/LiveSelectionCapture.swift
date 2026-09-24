import AppKit
import CoreServices
import Darwin
import Foundation
import SQLite3

/// A compact, per-recording reference to text selected in Codex. The complete
/// selection is discarded after making this value; the sent message includes only
/// its boundaries, so the recipient must already have the source to resolve them.
struct LiveSelectionReference: Equatable {
    enum PreviewPart: Equatable {
        case speech(String)
        case selection(String)
        case screenshot(String)
    }

    let preview: String
    let characterCount: Int
    let omittedMiddle: Bool
    private let start: String
    private let end: String?
    private let screenshotPath: String?
    private var spokenPrefix = ""
    private var codexThreadID: String?
    private var codexThreadTitle: String?

    init?(_ selectedText: String) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        characterCount = trimmed.count
        screenshotPath = nil
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

    /// Only a saved macOS screenshot's path is carried into the final message;
    /// image pixels and clipboard contents are never read by this recorder path.
    init?(screenshotURL: URL) {
        guard screenshotURL.isFileURL,
              screenshotURL.path.hasPrefix("/") else { return nil }
        let path = screenshotURL.standardizedFileURL.path
        guard !path.contains("\n"), !path.contains("\r") else { return nil }
        screenshotPath = path
        preview = screenshotURL.lastPathComponent
        characterCount = 0
        omittedMiddle = false
        start = ""
        end = nil
    }

    func anchored(after spokenText: String) -> Self {
        var copy = self
        copy.spokenPrefix = spokenText
        return copy
    }

    func scopedToCodexThread(id: String, title: String?) -> Self {
        guard UUID(uuidString: id) != nil else { return self }
        var copy = self
        copy.codexThreadID = id.lowercased()
        copy.codexThreadTitle = title
        return copy
    }

    static func previewParts(_ references: [Self], with partialTranscript: String) -> [PreviewPart] {
        // The HUD uses the same approximate cumulative-word anchor as final
        // delivery, but never writes provisional text into another app. Keep
        // every selection in sequence with speech, including equal anchors when
        // the provider has not emitted another partial between two selections.
        let wordEnds = wordEndIndices(in: partialTranscript)
        var lastWordCount = 0
        var previousEnd = partialTranscript.startIndex
        var parts: [PreviewPart] = []
        for reference in references {
            let spokenWordCount = reference.spokenPrefix.split(whereSeparator: \.isWhitespace).count
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? partialTranscript.startIndex : wordEnds[wordCount - 1]
            let speech = String(partialTranscript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty { parts.append(.speech(speech)) }
            if reference.screenshotPath != nil {
                parts.append(.screenshot(reference.preview))
            } else {
                parts.append(.selection(reference.preview))
            }
            previousEnd = insertion
            lastWordCount = wordCount
        }
        let remainingSpeech = String(partialTranscript[previousEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingSpeech.isEmpty { parts.append(.speech(remainingSpeech)) }
        return parts
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
        var selectionIndex = 0
        var previousEnd = transcript.startIndex
        var parts: [String] = []
        for reference in references {
            let spokenWordCount = reference.spokenPrefix.split(whereSeparator: \.isWhitespace).count
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? transcript.startIndex : wordEnds[wordCount - 1]
            let speech = String(transcript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty {
                parts.append(speech)
            }
            if reference.screenshotPath == nil { selectionIndex += 1 }
            parts.append(reference.xml(index: selectionIndex))
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
        if let screenshotPath {
            return "<local_screenshot path=\"\(Self.xmlEscaped(screenshotPath))\"/>"
        }
        var attributes = "index=\"\(index)\" source=\"Codex\" characters=\"\(characterCount)\" middle_omitted=\"\(omittedMiddle)\""
        if let codexThreadID {
            attributes += " task_id=\"\(Self.xmlEscaped(codexThreadID))\""
            if let codexThreadTitle {
                attributes += " task_title=\"\(Self.xmlEscaped(codexThreadTitle))\""
            }
        }
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

/// The selected-view event proves identity; this read-only lookup only adds a
/// human-readable label. Titles are mutable and non-unique, so a missing or
/// malformed row never becomes a substitute for the proven task ID.
enum CodexSelectionThreadTitleReader {
    static func title(
        for threadID: String,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    ) -> String? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let query = "SELECT COALESCE(NULLIF(name, ''), title) FROM threads WHERE id = ?1 LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        return threadID.withCString { identifier in
            guard sqlite3_bind_text(statement, 1, identifier, -1, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let rawTitle = sqlite3_column_text(statement, 0) else { return nil }
            let title = String(cString: rawTitle)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            // An unusually long or control-bearing title adds noise to dictation;
            // the stable task ID still disambiguates the selection without it.
            guard !title.isEmpty, title.count <= 120,
                  title.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
            return title
        }
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
    private var screenshotSource: DispatchSourceFileSystemObject?
    private var screenshotDirectory: URL?
    private var screenshotBaseline: Set<String> = []
    private var screenshotStart = Date.distantFuture
    private var screenshotScanTask: Task<Void, Never>?

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
        startScreenshotWatch()
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        captureTask?.cancel()
        captureTask = nil
        mouseDownPoint = nil
        screenshotScanTask?.cancel()
        screenshotScanTask = nil
        screenshotSource?.cancel()
        screenshotSource = nil
        screenshotDirectory = nil
        screenshotBaseline.removeAll()
        screenshotStart = .distantFuture
    }

    private func startScreenshotWatch() {
        let directory = Self.screenshotDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        screenshotDirectory = directory
        screenshotBaseline = Set((try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? [])
        screenshotStart = Date()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleScreenshotScan() }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        screenshotSource = source
        source.resume()
    }

    private static func screenshotDirectoryURL() -> URL {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func scheduleScreenshotScan() {
        screenshotScanTask?.cancel()
        screenshotScanTask = Task { @MainActor [weak self] in
            // The file and its screenshot metadata can appear in separate writes.
            // Bounded retries catch a normal save without monitoring the folder at idle.
            for delay in [250_000_000, 750_000_000, 1_500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.scanNewScreenshots()
            }
        }
    }

    private func scanNewScreenshots() {
        guard let directory = screenshotDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let candidates = names.filter { !screenshotBaseline.contains($0) }
            .sorted { first, second in
                let firstURL = directory.appendingPathComponent(first)
                let secondURL = directory.appendingPathComponent(second)
                let firstDate = (try? firstURL.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantFuture
                let secondDate = (try? secondURL.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantFuture
                return firstDate == secondDate ? first < second : firstDate < secondDate
            }
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            guard Self.isNativeScreenshot(url, since: screenshotStart),
                  let reference = LiveSelectionReference(screenshotURL: url) else { continue }
            screenshotBaseline.insert(name)
            onCapture(reference)
        }
    }

    static func isNativeScreenshot(_ url: URL, since start: Date) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey])
        guard values?.isRegularFile == true,
              let created = values?.creationDate,
              created >= start.addingTimeInterval(-1),
              ["png", "jpg", "jpeg", "heic", "pdf"].contains(url.pathExtension.lowercased()),
              !url.hasDirectoryPath else {
            return false
        }
        if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
           let marker = MDItemCopyAttribute(
               item, "kMDItemIsScreenCapture" as CFString
           ) as? NSNumber,
           marker.boolValue {
            return true
        }
        // Spotlight may not have indexed a screenshot during its first seconds.
        // Apple's own screen-capture xattr is written with the saved file and
        // avoids accepting a merely screenshot-named, unrelated image.
        let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = url.path.withCString { path in
            attribute.withCString { name in getxattr(path, name, nil, 0, 0, 0) }
        }
        guard size > 0, size < 1024 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBytes { buffer in
            url.path.withCString { path in
                attribute.withCString { name in
                    getxattr(path, name, buffer.baseAddress, size, 0, 0)
                }
            }
        }
        guard read == size else { return false }
        return isScreenshotMarker(Data(bytes))
    }

    static func isScreenshotMarker(_ data: Data) -> Bool {
        let value = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return (value as? NSNumber)?.boolValue == true
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
                  CodexConversationContextReader.isSupportedCodexApplication(
                    app, fileManager: .default
                  ) else {
                return
            }

            let sourcePID = app.processIdentifier
            captureTask?.cancel()
            captureTask = Task { @MainActor [weak self] in
                // The target app finishes its own mouse-up selection update before
                // this read. A newer gesture or stop cancels the pending read.
                try? await Task.sleep(nanoseconds: 40_000_000)
                let threadBefore = CodexConversationContextReader.activeThreadIDIfFrontmost(
                    frontmostApplication: app
                )
                guard !Task.isCancelled,
                      let text = await SelectedTextService.fetchSelectedText(),
                      !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
                      let reference = LiveSelectionReference(text) else {
                    return
                }
                // Switching Codex tasks during selection must not attach the
                // prior or next task's name. Unproven scope keeps plain XML.
                let threadAfter = CodexConversationContextReader.activeThreadIDIfFrontmost(
                    frontmostApplication: app
                )
                let labeled = threadBefore.flatMap { threadID -> LiveSelectionReference? in
                    guard threadID == threadAfter else { return nil }
                    return reference.scopedToCodexThread(
                        id: threadID,
                        title: CodexSelectionThreadTitleReader.title(for: threadID)
                    )
                } ?? reference
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
                    return
                }
                self?.onCapture(labeled)
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
