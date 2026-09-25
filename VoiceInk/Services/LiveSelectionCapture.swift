import AppKit
import CoreServices
import Darwin
import Foundation
import SQLite3

/// A per-recording reference to text selected in the frontmost app. The HUD
/// shows only a compact preview; a bounded excerpt is added to the final
/// destination message after transcription, never to live provider context.
struct LiveSelectionReference: Equatable {
    // Five hard lines or roughly five wrapped prose lines, whichever is shorter.
    // Bound at capture so a whole document is neither retained for the recording
    // nor slipped into the final agent message. `characterCount` still describes
    // the original selection, and XML explicitly marks a truncated excerpt.
    static let maxSelectionLines = 5
    static let maxSelectionCharacters = 500

    private enum Source: Equatable {
        case codex
        case application(name: String, bundleID: String?)
    }

    enum PreviewPart: Equatable {
        case speech(String)
        case selection(String)
        case screenshot(String)
    }

    let preview: String
    let characterCount: Int
    let omittedMiddle: Bool
    let truncated: Bool
    private let selectedText: String
    private let screenshotPath: String?
    private var spokenPrefix = ""
    private var codexThreadID: String?
    private var codexThreadTitle: String?
    private var chromeContext: ChromeSelectionContextReader.Context?
    private var source: Source = .codex

    private var hudPreview: String {
        if case let .application(name, _) = source {
            return "\(name) — \(preview)"
        }
        return preview
    }

    init?(_ selectedText: String) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.split(whereSeparator: \.isWhitespace).isEmpty else { return nil }
        let lineLimited = trimmed
            .split(separator: "\n", maxSplits: Self.maxSelectionLines,
                   omittingEmptySubsequences: false)
            .prefix(Self.maxSelectionLines)
            .joined(separator: "\n")
        let excerpt = String(lineLimited.prefix(Self.maxSelectionCharacters))
        let normalized = excerpt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        characterCount = trimmed.count
        screenshotPath = nil
        self.selectedText = excerpt
        omittedMiddle = false
        truncated = excerpt != trimmed
        if normalized.count <= 96 {
            preview = "“\(normalized)”"
        } else {
            let start = String(normalized.prefix(46))
            let last = String(normalized.suffix(46))
            preview = "“\(start)” … “\(last)”"
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
        truncated = false
        self.selectedText = ""
    }

    func anchored(after spokenText: String) -> Self {
        var copy = self
        copy.spokenPrefix = spokenText
        return copy
    }

    var isSelection: Bool { screenshotPath == nil }

    var spokenWordCount: Int {
        spokenPrefix.split(whereSeparator: \.isWhitespace).count
    }

    func scopedToCodexThread(id: String, title: String?) -> Self {
        guard UUID(uuidString: id) != nil else { return self }
        var copy = self
        copy.codexThreadID = id.lowercased()
        copy.codexThreadTitle = title
        return copy
    }

    func scopedToApplication(name: String?, bundleID: String?) -> Self {
        var copy = self
        let normalizedName = (name ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safeName = String(normalizedName.filter { character in
            character.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        }.prefix(80))
        let allowedBundleScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
        )
        let validBundleID = bundleID.flatMap { identifier -> String? in
            guard !identifier.isEmpty, identifier.count <= 128,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      allowedBundleScalars.contains(scalar)
                  }) else { return nil }
            return identifier
        }
        copy.source = .application(
            name: safeName.isEmpty ? validBundleID ?? "Application" : safeName,
            bundleID: validBundleID
        )
        // Generic applications do not have a proven Codex task identity.
        copy.codexThreadID = nil
        copy.codexThreadTitle = nil
        return copy
    }

    func scopedToChrome(_ context: ChromeSelectionContextReader.Context?) -> Self {
        guard case .application(_, let bundleID) = source,
              bundleID == "com.google.Chrome" else { return self }
        var copy = self
        copy.chromeContext = context
        return copy
    }

    static func previewParts(_ references: [Self], with partialTranscript: String) -> [PreviewPart] {
        // The HUD uses the same approximate cumulative-word anchor as final
        // delivery, but never writes provisional text into another app. Keep
        // selections in sequence with speech. Equal anchors retain their
        // capture order: they can be a silent trail of what was being read.
        let wordEnds = wordEndIndices(in: partialTranscript)
        var lastWordCount = 0
        var previousEnd = partialTranscript.startIndex
        var parts: [PreviewPart] = []
        for reference in references {
            let spokenWordCount = reference.spokenWordCount
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? partialTranscript.startIndex : wordEnds[wordCount - 1]
            let speech = String(partialTranscript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty { parts.append(.speech(speech)) }
            if reference.screenshotPath != nil {
                parts.append(.screenshot(reference.preview))
            } else {
                parts.append(.selection(reference.hudPreview))
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
        guard !references.isEmpty else {
            return transcript
        }

        // Live provider text is a cumulative preview, not word-timestamped audio.
        // Its word count places each selection near the speech already shown when
        // the mouse came up. Preserve a reference-only reading trail when no
        // words were recognized. Never send a fake native Codex message/range anchor.
        let wordEnds = wordEndIndices(in: transcript)
        var lastWordCount = 0
        var selectionIndex = 0
        var previousEnd = transcript.startIndex
        var parts: [String] = []
        for reference in references {
            let spokenWordCount = reference.spokenWordCount
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
        let tag: String
        var attributes: String
        switch source {
        case .codex:
            tag = "codex_selection"
            attributes = "index=\"\(index)\" source=\"Codex\" characters=\"\(characterCount)\" middle_omitted=\"\(omittedMiddle)\" truncated=\"\(truncated)\""
        case let .application(name, bundleID):
            tag = "app_selection"
            attributes = "index=\"\(index)\" source=\"\(Self.xmlEscaped(name))\" characters=\"\(characterCount)\" middle_omitted=\"\(omittedMiddle)\" truncated=\"\(truncated)\""
            if let bundleID {
                attributes += " bundle_id=\"\(Self.xmlEscaped(bundleID))\""
            }
            if let chromeContext {
                attributes += " page_url=\"\(Self.xmlEscaped(chromeContext.pageURL))\""
                if let pageTitle = chromeContext.pageTitle {
                    attributes += " page_title=\"\(Self.xmlEscaped(pageTitle))\""
                }
                if let elementTag = chromeContext.elementTag {
                    attributes += " element_tag=\"\(Self.xmlEscaped(elementTag))\""
                }
                if let elementRole = chromeContext.elementRole {
                    attributes += " element_role=\"\(Self.xmlEscaped(elementRole))\""
                }
                if let elementLabel = chromeContext.elementLabel {
                    attributes += " element_label=\"\(Self.xmlEscaped(elementLabel))\""
                }
            }
        }
        if case .codex = source, let codexThreadID {
            attributes += " task_id=\"\(Self.xmlEscaped(codexThreadID))\""
            if let codexThreadTitle {
                attributes += " task_title=\"\(Self.xmlEscaped(codexThreadTitle))\""
            }
        }
        return "<\(tag) \(attributes)>\n"
            + "  <text>\(Self.xmlEscaped(selectedText))</text>\n"
            + "</\(tag)>"
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

/// Optional Chrome-only enrichment from the same selected DOM range. A failed or
/// blocked Apple Event is not permission to use the clipboard or guess a page.
enum ChromeSelectionContextReader {
    struct Context: Equatable {
        let selectedText: String
        let pageURL: String
        let pageTitle: String?
        let elementTag: String?
        let elementRole: String?
        let elementLabel: String?
    }

    static func parse(_ output: String) -> Context? {
        guard let data = output.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let selected = fields["selectedText"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty,
              let rawURL = fields["url"],
              var url = URLComponents(string: rawURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        // Most query strings can hold tokens. Preserve only YouTube's validated
        // public video ID; other page context uses origin and path, never hashes.
        let videoID = url.queryItems?.first(where: { $0.name == "v" })?.value
        url.queryItems = nil
        if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host.lowercased()),
           url.path == "/watch", let videoID,
           !videoID.isEmpty, videoID.count <= 32,
           videoID.unicodeScalars.allSatisfy({
               CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
                   .contains($0)
           }) {
            url.queryItems = [URLQueryItem(name: "v", value: videoID)]
        }
        url.fragment = nil
        url.user = nil
        url.password = nil
        guard let pageURL = url.string, pageURL.count <= 512 else { return nil }
        func clean(_ value: String?, limit: Int) -> String? {
            guard let value else { return nil }
            let cleaned = value.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }
            return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
        }
        let allowedTag = CharacterSet.lowercaseLetters
        let tag = clean(fields["elementTag"], limit: 24)?.lowercased()
        let safeTag: String?
        if let tag,
           tag.unicodeScalars.allSatisfy({ allowedTag.contains($0) }),
           !["html", "body"].contains(tag) {
            safeTag = tag
        } else {
            safeTag = nil
        }
        let role = clean(fields["elementRole"], limit: 40)?.lowercased()
        let allowedRole = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz-")
        let safeRole = role?.unicodeScalars.allSatisfy { allowedRole.contains($0) } == true
            ? role : nil
        return Context(
            selectedText: selected,
            pageURL: pageURL,
            pageTitle: clean(fields["title"], limit: 160),
            elementTag: safeTag,
            elementRole: safeTag == nil ? nil : safeRole,
            elementLabel: safeTag == nil ? nil : clean(fields["elementLabel"], limit: 100)
        )
    }

    static func capture() async -> Context? {
        // This reads only the current selection, its common DOM ancestor and
        // active page identity. It does not install all-sites extension access,
        // inspect surrounding text, mutate DOM, or send page content to GPT Live.
        let javascript = #"(()=>{const s=window.getSelection();let t=s?.toString()??'';let e=s?.rangeCount?s.getRangeAt(0).commonAncestorContainer:null;e=e?.nodeType===1?e:e?.parentElement;if(!t){const a=document.activeElement;if(a&&typeof a.selectionStart==='number'&&typeof a.selectionEnd==='number'&&typeof a.value==='string'){t=a.value.slice(a.selectionStart,a.selectionEnd);e=a}}const o={selectedText:t,url:location.href,title:document.title};if(e&&e!==document.body&&e!==document.documentElement){o.elementTag=e.tagName?.toLowerCase()??'';o.elementRole=e.getAttribute('role')??'';o.elementLabel=e.getAttribute('aria-label')??e.getAttribute('title')??''}return JSON.stringify(o)})()"#
        let quoted = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application id \"com.google.Chrome\"\n"
            + "tell active tab of front window\n"
            + "execute javascript \"\(quoted)\"\n"
            + "end tell\nend tell"
        guard let result = try? await BoundedAppleScriptRunner.run(source: script, timeout: 1.0) else {
            return nil
        }
        return parse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
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
                  let app = NSWorkspace.shared.frontmostApplication else {
                return
            }

            // A drag can activate an app that was backgrounded at mouse-down.
            // Bind to the app at mouse-up, then require it to stay frontmost
            // throughout the asynchronous selected-text read.
            let sourcePID = app.processIdentifier
            let isCodex = CodexConversationContextReader.isSupportedCodexApplication(
                app, fileManager: .default
            )
            captureTask?.cancel()
            captureTask = Task { @MainActor [weak self] in
                // The target app finishes its own mouse-up selection update before
                // this read. A newer gesture or stop cancels the pending read.
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled,
                      Self.hasStableSource(expectedPID: sourcePID,
                                           currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
                    return
                }
                let threadBefore = isCodex
                    ? CodexConversationContextReader.activeThreadIDIfFrontmost(
                        frontmostApplication: app
                    ) : nil
                let chromeContext = app.bundleIdentifier == "com.google.Chrome"
                    ? await ChromeSelectionContextReader.capture() : nil
                let selectedText: String?
                if let chromeContext {
                    selectedText = chromeContext.selectedText
                } else {
                    selectedText = await SelectedTextService.fetchSelectedText()
                }
                guard !Task.isCancelled,
                      let text = selectedText,
                      !Task.isCancelled,
                      Self.hasStableSource(expectedPID: sourcePID,
                                           currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
                      let reference = LiveSelectionReference(text) else {
                    return
                }
                let labeled: LiveSelectionReference
                if isCodex {
                    // Only the verified Codex app may add a task label. A task
                    // switch during selection leaves the existing plain tag.
                    let threadAfter = CodexConversationContextReader.activeThreadIDIfFrontmost(
                        frontmostApplication: app
                    )
                    labeled = threadBefore.flatMap { threadID -> LiveSelectionReference? in
                        guard threadID == threadAfter else { return nil }
                        return reference.scopedToCodexThread(
                            id: threadID,
                            title: CodexSelectionThreadTitleReader.title(for: threadID)
                        )
                    } ?? reference
                } else {
                    // Generic apps expose an app identity, not a proven document,
                    // tab, or chat. Never infer more from selected text alone.
                    labeled = reference.scopedToApplication(
                        name: app.localizedName,
                        bundleID: app.bundleIdentifier
                    ).scopedToChrome(chromeContext)
                }
                guard !Task.isCancelled,
                      Self.hasStableSource(expectedPID: sourcePID,
                                           currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
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

    static func hasStableSource(expectedPID: pid_t?, currentPID: pid_t?) -> Bool {
        guard let expectedPID, let currentPID else { return false }
        return expectedPID > 0 && expectedPID == currentPID
    }
}
