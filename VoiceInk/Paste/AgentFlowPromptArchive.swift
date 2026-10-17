import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Full prompts are durable user documents, not temporary pasteboard payloads.
/// Write and sync before handing out a path; never overwrite or auto-expire them.
enum AgentFlowPromptArchive {
    // The canonical file is the agent's prompt, while its viewer shows only
    // user events. Keep this one-line skill reminder out of the event stream
    // so it cannot be mistaken for another authored request or rendered card.
    static let interpretationReminder = "<!-- Agent Flow: Read the $interpret-agent-flow-context skill before interpreting this timeline. -->\n\n"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentFlow/Prompts", isDirectory: true)
    }

    static func save(_ text: String, recordID: UUID, chatID: String? = nil) async throws -> URL {
        let destination = directory
        return try await Task.detached(priority: .utility) {
            let file = try write(text, recordID: recordID, directory: destination)
            // Reserve once after the canonical prompt is durable. The archived
            // viewer retains this start; reopen/copy never advances the cursor.
            let start = AuthoredTextRainbow.reserveViewerStartIndex(chatID: chatID,
                wordCount: AgentFlowPromptViewer.authoredWordCount(text))
            // A human-readable companion is optional. Its failure must never
            // invalidate the complete durable prompt or stop a normal paste.
            try? writeViewer(text, for: file, rainbowStartIndex: start)
            return file
        }.value
    }

    static func write(_ text: String, recordID: UUID, directory: URL) throws -> URL {
        let name = "prompt-\(recordID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).md"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try writeFile(interpretationReminder + text, name: name, directory: directory)
    }

    static func writeViewer(_ text: String, for file: URL, rainbowStartIndex: Int = 0) throws {
        _ = try writeFile(AgentFlowPromptViewer.html(text, sourceURL: file, rainbowStartIndex: rainbowStartIndex),
            name: file.deletingPathExtension().appendingPathExtension("html").lastPathComponent,
            directory: file.deletingLastPathComponent())
    }

    static func viewerURL(for file: URL) -> URL? {
        let viewer = file.deletingPathExtension().appendingPathExtension("html")
        guard let values = try? viewer.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else { return nil }
        return viewer
    }

    private static func writeFile(_ text: String, name: String, directory: URL) throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // Refuse a redirected final directory and exclusive-create each file.
        // Permissions are fixed on descriptors, never through a symlink path.
        let dir = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(dir) }
        guard fchmod(dir, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var completed = false
        defer {
            Darwin.close(fd)
            // Only this exclusive-created, incomplete file may be removed.
            // A completed prompt is never deleted by recorder/history cleanup.
            if !completed { unlinkat(dir, name, 0) }
        }
        let bytes = Data(text.utf8)
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // Sync the directory entry too. This is persistence, not a promise that
        // local storage survives drive loss; the user's backups remain essential.
        guard fsync(dir) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        completed = true
        return directory.appendingPathComponent(name)
    }
}

/// Offline timeline, parsed from the canonical XML. Payloads are always escaped
/// as text; metadata remains available in disclosures. The complete canonical
/// source lives once in the adjacent .md, linked here, not copied into HTML.
/// No prompt-supplied scripts, external entities, fonts or network fetches. Only genuine screenshot
/// events can embed a bounded, decoded raster preview. The .md is authoritative.
enum AgentFlowPromptViewer {
    // Only this fixed handler may execute. Prompt content remains escaped data;
    // do not broaden the CSP to unsafe-inline scripts or interpolate payloads.
    // window.close requests only this tab. Some hosts refuse page-initiated
    // closing; retain the prompt and show the native-tab fallback in that case.
    static let closeScript = """
    document.getElementById('close-prompt').addEventListener('click', () => {
      window.close();
      setTimeout(() => {
        if (!window.closed) document.getElementById('close-help').hidden = false;
      }, 300);
    });
    """
    static var closeScriptHash: String {
        Data(SHA256.hash(data: Data(closeScript.utf8))).base64EncodedString()
    }

    struct Event: Equatable {
        let tag: String
        let attributes: [String: String]
        let text: String
    }

    static let fragmentPattern = #"(?ms)^[\t ]*<(speech|speech_segment|typed_text|potential_tts|app_selection|codex_selection)\b[^>]*>.*?</\1>|^[\t ]*<local_screenshot\b[^>]*?/>"#

    /// Parse only known, line-delimited top-level fragments, never tags that
    /// merely occur inside a quoted selection. A malformed fragment is shown
    /// verbatim rather than silently dropping text or guessing a repaired XML.
    static func events(_ source: String) -> [Event] {
        let expression = try! NSRegularExpression(pattern: fragmentPattern)
        let ns = source as NSString
        var result: [Event] = []
        var end = 0
        var screenshotReference: String?
        func appendPlain(_ text: String) {
            // The serializer emits an image reference immediately after the
            // screenshot tag. Its path is already represented by that card.
            // Remove only that exact generated duplicate, never arbitrary prose.
            var plain = text
            if let reference = screenshotReference,
               plain.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(reference),
               let range = plain.range(of: reference) {
                plain.removeSubrange(range)
            }
            screenshotReference = nil
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Event(tag: result.isEmpty ? "opening" : "text", attributes: [:], text: plain))
            }
        }
        for match in expression.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            appendPlain(ns.substring(with: NSRange(location: end, length: match.range.location - end)))
            let xml = ns.substring(with: match.range)
            if let event = Fragment.parse(xml) {
                result.append(event)
                if event.tag == "local_screenshot", let path = event.attributes["path"] {
                    screenshotReference = LiveSelectionStyledMath.localImageReference(path: path)
                }
            } else {
                result.append(Event(tag: "text", attributes: [:], text: xml))
            }
            end = NSMaxRange(match.range)
        }
        appendPlain(ns.substring(from: end))
        return result
    }

    private final class Fragment: NSObject, XMLParserDelegate {
        var tag = ""
        var attributes: [String: String] = [:]
        var text = ""
        var depth = 0
        var valid = true

        static func parse(_ xml: String) -> Event? {
            // External entities and internal DTD expansion have no purpose in
            // our generated grammar. Do not even pass declarations to libxml.
            guard !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !xml.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
            let delegate = Fragment()
            let parser = XMLParser(data: Data(xml.utf8))
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            guard parser.parse(), delegate.valid, delegate.depth == 0 else { return nil }
            return Event(tag: delegate.tag, attributes: delegate.attributes, text: delegate.text)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 { tag = name; self.attributes = attributes }
            else if depth != 2 || name != "text" || !["app_selection", "codex_selection"].contains(tag) {
                valid = false
                parser.abortParsing()
            }
        }
        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Whitespace framing around <text> is XML layout; every byte inside
            // the selected payload, including indentation, remains visible.
            if depth == 2 || !["app_selection", "codex_selection"].contains(tag) { text += string }
            else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { valid = false }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if let string = String(data: block, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
            else { valid = false }
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Decode only regular local raster files, never SVG/HTML, symlinks, devices
    /// or pipes. Embedding a resized copy makes a captured image visible offline
    /// without granting the HTML viewer access to the filesystem or network.
    static func screenshotPreview(path: String) -> Data? {
        guard path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 32 * 1024 * 1024 else { return nil }
        var data = Data(count: Int(info.st_size))
        let complete = data.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard complete,
              let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(imageSource) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.heif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 200_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    static func authoredWordCount(_ source: String) -> Int {
        events(source).filter { ["speech", "speech_segment", "typed_text", "potential_tts"].contains($0.tag) }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Colour positions belong to words, never screen coordinates. Keep every
    /// original whitespace run outside its span so explicit/newly wrapped lines
    /// continue the same stream and selected/copied text remains byte-faithful.
    static func authoredHTML(_ text: String, nextIndex: inout Int) -> String {
        var result = ""
        var start = text.startIndex
        func append(_ run: Substring) {
            guard let first = run.first else { return }
            if first.isWhitespace { result += escape(String(run)); return }
            let index = ((nextIndex % AuthoredTextRainbow.palette.count) + AuthoredTextRainbow.palette.count)
                % AuthoredTextRainbow.palette.count
            result += "<span class=\"rainbow-word\" style=\"color:\(AuthoredTextRainbow.palette[index])\">\(escape(String(run)))</span>"
            nextIndex = (index + 1) % AuthoredTextRainbow.palette.count
        }
        for index in text.indices where text[index].isWhitespace != text[start].isWhitespace {
            append(text[start..<index])
            start = index
        }
        append(text[start...])
        return result
    }

    static func html(_ source: String, sourceURL: URL? = nil, imageBudget: Int = 32 * 1024 * 1024,
                     rainbowStartIndex: Int = 0) -> String {
        var body = ""
        var rainbowIndex = rainbowStartIndex
        var eventIndex = 0
        var remainingImageBytes = max(0, imageBudget)
        // The bubble opens this viewer. Put the canonical plain-source path
        // before image bytes so agents can find the .md without consuming a
        // rendered timeline or a duplicate source copy in this HTML.
        let sourcePath = sourceURL.flatMap { url -> String? in
            guard url.isFileURL, url.path.hasPrefix("/"),
                  !url.path.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
            return url.path
        }
        let sourceMeta = sourcePath.map { "<meta name=\"agent-flow-source\" content=\"\(escape($0))\">" } ?? ""
        let sourceLink = sourcePath.map {
            "<a class=\"source-link\" href=\"\(escape(URL(fileURLWithPath: $0).absoluteString))\">Source</a>"
        } ?? ""
        let parsed = events(source)
        // Older archives can begin with a queue-readable copy of the authored
        // timeline. Suppress it only when it exactly matches the speech/typing
        // below; unmatched opening prose is still part of the user's request.
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let authored = parsed.filter { ["speech", "speech_segment", "typed_text", "potential_tts"].contains($0.tag) }
            .map { normalized($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
        for event in parsed {
            if event.tag == "opening", !authored.isEmpty,
               normalized(event.text) == authored {
                continue
            }
            eventIndex += 1
            let label: String
            let color: String
            switch event.tag {
            case "speech", "speech_segment": label = "Speech"; color = LiveSelectionStyledMath.speechColor
            case "typed_text": label = "Typed text"; color = LiveSelectionStyledMath.typedColor
            case "potential_tts": label = "Potential ignore"; color = LiveSelectionStyledMath.potentialTTSColor
            case "app_selection", "codex_selection": label = "Selection"; color = LiveSelectionStyledMath.selectionColor
            case "local_screenshot": label = "Screenshot"; color = LiveSelectionStyledMath.screenshotColor
            default: label = "Text"; color = LiveSelectionStyledMath.speechColor
            }
            let app = event.attributes["source"].map { "<span class=\"app\">\(escape($0))</span>" } ?? ""
            // Remove only the serializer's two framing newlines from authored
            // sections. Never trim selected code or whitespace the user typed.
            var displayText = event.text
            if ["speech", "speech_segment", "typed_text", "potential_tts"].contains(event.tag),
               displayText.hasPrefix("\n\n"), displayText.hasSuffix("\n\n"), displayText.count >= 4 {
                displayText = String(displayText.dropFirst(2).dropLast(2))
            }
            var content = "<div class=\"payload\">\(escape(displayText))</div>"
            if ["speech", "speech_segment", "typed_text"].contains(event.tag) {
                content = "<div class=\"payload\">\(authoredHTML(displayText, nextIndex: &rainbowIndex))</div>"
            }
            if event.tag == "potential_tts" {
                // Override the rainbow visually but still advance its authored-word cursor.
                rainbowIndex = (rainbowIndex + displayText.split(whereSeparator: \.isWhitespace).count)
                    % AuthoredTextRainbow.palette.count
                content = "<div class=\"payload\" style=\"color:\(color)\">\(escape(displayText))</div>"
            }
            if event.tag == "local_screenshot", let path = event.attributes["path"] {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                if path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }) {
                    content = "<a class=\"screenshot\" href=\"\(escape(URL(fileURLWithPath: path).absoluteString))\">\(escape(filename)) ↗</a>"
                    if remainingImageBytes > 0, let data = screenshotPreview(path: path), data.count <= remainingImageBytes {
                        remainingImageBytes -= data.count
                        content += "<img class=\"screenshot-image\" src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" alt=\"\(escape(filename))\" loading=\"lazy\" decoding=\"async\">"
                    } else {
                        // The original path and all XML remain intact even if
                        // pixels are missing, unsupported or over the viewer's
                        // resource budget. Never imply a blank card is an image.
                        content += "<p class=\"image-unavailable\">Preview unavailable — open the screenshot above.</p>"
                    }
                } else { content = "<div class=\"payload\">\(escape(path))</div>" }
            }
            let rows = event.attributes.sorted { $0.key < $1.key }.map { key, value in
                "<dt>\(escape(key))</dt><dd>\(escape(value))</dd>"
            }.joined()
            let details = rows.isEmpty ? "" : "<details class=\"metadata\"><summary>Details</summary><dl>\(rows)</dl></details>"
            let authoredClass = ["speech", "speech_segment", "typed_text", "potential_tts"].contains(event.tag) ? " authored" : ""
            body += "<section class=\"event\(authoredClass)\" style=\"--event-color:\(color)\"><header><span class=\"index\">\(eventIndex)</span><h2>\(label)</h2>\(app)</header>\(content)\(details)</section>"
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        \(sourceMeta)
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="agent-flow-rainbow-start" content="\(rainbowStartIndex)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'sha256-\(closeScriptHash)'; base-uri 'none'; form-action 'none'">
        <title>Agent Flow prompt</title>
        <style>
        :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#141416;color:#f1f5f9;font:17px/1.55 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:920px;margin:auto;padding:32px 28px 64px}.title{display:flex;align-items:baseline;gap:12px;margin-bottom:32px}h1{font-size:22px;letter-spacing:-.5px;margin:0}.subtitle{color:#94a3b8;font-size:14px}
        .close-actions{margin-left:auto;text-align:right}.close-button{font:inherit;font-size:13px;color:#cbd5e1;background:#242428;border:1px solid #414147;border-radius:7px;padding:5px 12px;cursor:pointer}.close-button:hover{color:#fff;background:#303036}.close-button:focus-visible{outline:2px solid #67e8f9;outline-offset:3px}.close-help{font-size:12px;color:#94a3b8;margin:6px 0 0;max-width:160px}
        .event{border-left:2px solid var(--event-color);padding:0 0 0 22px;margin:0 0 30px 8px}.event header{display:flex;align-items:baseline;gap:10px;color:var(--event-color);margin-bottom:8px}h2{font-size:13px;font-weight:600;margin:0}.index{font:12px ui-monospace,Menlo,monospace;opacity:.7}.app{font-size:13px;opacity:.8;overflow-wrap:anywhere}
        .payload{white-space:pre-wrap;overflow-wrap:anywhere;color:var(--event-color,inherit)}.event .payload{margin:0}.metadata{margin-top:10px}summary{cursor:pointer;color:#94a3b8;font-size:13px;width:fit-content}summary:hover,a:hover{color:#f1f5f9}summary:focus-visible,a:focus-visible{outline:2px solid #67e8f9;outline-offset:5px}dl{display:grid;grid-template-columns:minmax(90px,auto) minmax(0,1fr);gap:6px 18px;font:12px/1.6 ui-monospace,Menlo,monospace;margin:12px 0 0;color:#94a3b8}dt{font-style:italic}dd{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
        .rainbow-word{color:inherit}
        .screenshot{color:#e879f9;text-decoration:none;overflow-wrap:anywhere}::selection{background:#554476}@media(max-width:520px){main{padding:24px 18px}.event{padding-left:14px;margin-left:2px}dl{grid-template-columns:1fr;gap:2px}dd{margin-bottom:8px}}
        .screenshot-image{display:block;max-width:100%;height:auto;margin-top:12px;border:1px solid #303036;border-radius:8px}.image-unavailable,.source-link{color:#94a3b8;font-size:13px}.source-link{display:inline-block;margin-bottom:20px}
        </style></head><body><main><div class="title"><h1>Agent Flow</h1><span class="subtitle">Prompt</span><div class="close-actions"><button id="close-prompt" class="close-button" type="button">Close</button><p id="close-help" class="close-help" role="status" hidden>Use the tab’s close button.</p></div></div>
        \(sourceLink)
        \(body)
        </main><script>\(closeScript)</script></body></html>
        """
    }
}

/// Presentation only: a single paste, with no AX receipts, attachment
/// choreography, saved input, retries, or extra Return. The full file is the
/// source of truth for metadata/context; every authored word also stays inline.
enum AgentFlowPromptPreview {
    /// Remove only producer-added framing inside valid blocks. Real payload
    /// paragraphs/indentation and all bytes outside those blocks stay intact.
    static func compactTimeline(_ source: String) -> String {
        mapTimeline(source) { fragment, event in compactFragment(fragment, tag: event.tag) }
    }

    /// The editable opening and file preview remain plain. Only inline authored
    /// payloads use the shared rainbow; metadata and source context keep their
    /// fixed type colours. Copy/archives never store this presentation.
    static func coloredInlineTimeline(_ source: String, rainbowStartIndex: Int = 0) -> String {
        var nextColor = rainbowStartIndex
        return mapTimeline(source) { fragment, event in
            let compact = compactFragment(fragment, tag: event.tag)
            let color: String
            switch event.tag {
            case "speech", "speech_segment": color = LiveSelectionStyledMath.speechColor
            case "typed_text": color = LiveSelectionStyledMath.typedColor
            case "potential_tts": color = LiveSelectionStyledMath.potentialTTSColor
            case "app_selection", "codex_selection": color = LiveSelectionStyledMath.selectionColor
            case "local_screenshot": color = LiveSelectionStyledMath.screenshotColor
            default: return fragment
            }
            if ["speech", "speech_segment", "typed_text"].contains(event.tag),
               let openingEnd = compact.firstIndex(of: ">"),
               let closing = compact.range(of: "</\(event.tag)>", options: .backwards) {
                let contentStart = compact.index(after: openingEnd)
                let content = String(compact[contentStart..<closing.lowerBound])
                let count = content.split(whereSeparator: \.isWhitespace).count
                let body = AuthoredTextRainbow.render(content, startIndex: nextColor,
                    preserveWhitespace: true)
                nextColor = (nextColor + count) % AuthoredTextRainbow.palette.count
                if let body {
                    return joinStyled([
                        LiveSelectionStyledMath.coloredXML(String(compact[...openingEnd]), color: color),
                        body,
                        LiveSelectionStyledMath.coloredXML(String(compact[closing.lowerBound...]), color: color)
                    ])
                }
            }
            return LiveSelectionStyledMath.coloredXML(compact, color: color)
        }
    }

    private static func joinStyled(_ parts: [String]) -> String {
        parts.reduce("") { result, part in
            result + (result.hasSuffix("\\)") && part.hasPrefix("\\(")
                ? LiveSelectionStyledMath.zeroWidthSpace : "") + part
        }
    }

    private static func compactFragment(_ fragment: String, tag: String) -> String {
        if ["app_selection", "codex_selection"].contains(tag) {
            let pattern = #"(?s)^(\s*<(?:app_selection|codex_selection)\b[^>]*>)\s*(<text\b[^>]*>)(.*)(</text>)\s*(</(?:app_selection|codex_selection)>)$"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)) else { return fragment }
            let ns = fragment as NSString
            return (1...5).map { ns.substring(with: match.range(at: $0)) }.joined()
        }
        guard ["speech", "speech_segment", "typed_text", "potential_tts"].contains(tag),
              let openingEnd = fragment.firstIndex(of: ">"),
              let closing = fragment.range(of: "</\(tag)>", options: .backwards) else { return fragment }
        var body = String(fragment[fragment.index(after: openingEnd)..<closing.lowerBound])
        // The serializer adds exactly two LFs. Removing those, not trimming,
        // retains genuine leading/trailing blank lines inside the payload.
        if body.hasPrefix("\n\n") { body.removeFirst(2) }
        if body.hasSuffix("\n\n") { body.removeLast(2) }
        return String(fragment[...openingEnd]) + body + String(fragment[closing.lowerBound...])
    }

    private static func mapTimeline(_ source: String, transform: (String, AgentFlowPromptViewer.Event) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: AgentFlowPromptViewer.fragmentPattern) else { return source }
        let ns = source as NSString
        var output = "", end = 0
        for match in expression.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: end, length: match.range.location - end))
            let fragment = ns.substring(with: match.range)
            let parsed = AgentFlowPromptViewer.events(fragment)
            guard parsed.count == 1, let event = parsed.first else {
                output += fragment; end = NSMaxRange(match.range); continue
            }
            output += transform(fragment, event)
            end = NSMaxRange(match.range)
        }
        output += ns.substring(from: end)
        return output
    }

    struct Recipient {
        var bundleID: String?
        var bundleURL: URL?
        var version: String?
        var build: String?

        @MainActor static func current() -> Self {
            let app = NSWorkspace.shared.frontmostApplication
            let info = app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
            return Self(bundleID: app?.bundleIdentifier, bundleURL: app?.bundleURL,
                        version: info?["CFBundleShortVersionString"] as? String,
                        build: info?["CFBundleVersion"] as? String)
        }
        var supportsLocalFilePrompt: Bool {
            AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: bundleID,
                bundleURL: bundleURL, version: version, build: build)
        }
    }

    struct Section: Equatable {
        let tag: String
        let text: String
        let color: String
    }

    static func supportsLocalFilePrompt(bundleID: String?, bundleURL: URL?,
                                        version _: String? = nil, build _: String? = nil) -> Bool {
        // Compact local files are for the known native Codex hosts, independent
        // of their release version. Ordinary apps must not receive agent prompts;
        // Telegram and Claude instead retain their inline context format. This
        // classifier changes presentation only, never exact-input authority.
        guard bundleID == "com.openai.codex" else { return false }
        guard let bundleURL else { return true }
        return ["Codex.app", "ChatGPT.app"].contains(bundleURL.lastPathComponent)
    }

    static let inlineContextRecipientBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram", "org.telegram.desktop",
        // Explicit recipient opt-in: Claude needs the full XML in the paste.
        // Its Chat/remote Code modes cannot be assumed to read this Mac's files.
        // This never allows Claude-specific focus, insertion or Send behavior.
        "com.anthropic.claudefordesktop"
    ]

    static func excerpt(_ text: String, limit: Int) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        let half = max(1, (limit - 3) / 2)
        return String(compact.prefix(half)) + " … " + String(compact.suffix(half))
    }

    // Keep the link label literal: Codex's user-message bubble displayed raw
    // LaTeX even when the isolated tokenizer accepted inline math in this link.
    // Parser tokens are not UI-renderer acceptance. Do not revive a styled label
    // without actual recipient bubble evidence; keep both file targets intact.
    static let fullPromptLinkLabel = "full prompt"

    // The native Codex handlePaste compares JS UTF-16 length against 5,000 per
    // paste event (ChatGPT 26.1002.52244/13536, rechecked 2026-10-08). At the
    // threshold it creates a pasted-text attachment. Count the entire plain-text
    // payload, including the encoded link, editable opening and full timeline.
    static let pastedTextAttachmentThreshold = 5_000

    static func make(authoredText: String, sections: [Section], fileURL: URL,
                     viewerURL: URL? = nil, completePromptText: String? = nil,
                     rainbowStartIndex: Int = 0) -> String? {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/"),
              !fileURL.path.contains(where: { "\n\r<>".contains($0) }) else { return nil }
        // Codex's native file-reference scanner reparses the raw Markdown target,
        // not the Markdown lexer's href. Angle delimiters therefore become literal
        // filename characters and open a nonexistent, blank IDE buffer. Encode the
        // path instead, including parentheses and percent signs, without adding a
        // URL scheme. The host's file resolver decodes this absolute path once.
        let linkCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "%()[]?#<>`\\\""))
        guard let linkPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: linkCharacters) else { return nil }
        // Keep the tiny opening link even though the footer points to the same
        // viewer. Ethan reversed its removal because a queued Codex message only
        // exposes its first line: the footer is not clickable until the turn runs.
        // The opening link must share the first line with the words, not add a row.
        let viewerPath = viewerURL.flatMap { url -> String? in
            guard url.isFileURL, url.path.hasPrefix("/"),
                  !url.path.contains(where: { "\n\r<>".contains($0) }) else { return nil }
            return url.path.addingPercentEncoding(withAllowedCharacters: linkCharacters)
        }
        let pointer = "Read the [\(fullPromptLinkLabel)](\(viewerPath ?? linkPath)) before answering."
        let openingLink = "[↗](\(viewerPath ?? linkPath))"
        var parts: [String] = []
        let ordered = sections.isEmpty ? [Section(tag: "speech", text: authoredText, color: LiveSelectionStyledMath.speechColor)] : sections
        // Ethan explicitly wants all authored words, not an attachment-avoidance
        // excerpt. Only context payload/attributes move to the archive; markers
        // keep their positions. A host may package a huge paste as an attachment,
        // but we must not silently discard a word or a long token.
        // Pure speech/typing is already complete in the editable message. Only
        // hidden references or interpretation metadata require opening the full
        // prompt; use structural tags, never words that merely mention a capture.
        let needsFullPrompt = ordered.contains { $0.tag != "speech" && $0.tag != "typed_text" }
        for section in ordered {
            if section.tag == "speech" || section.tag == "typed_text" || section.tag == "potential_tts" {
                if section.tag == "potential_tts" { parts.append("`<potential_tts>`") }
                for word in section.text.split(whereSeparator: \.isWhitespace) {
                    parts.append(String(word))
                }
                if section.tag == "potential_tts" { parts.append("`</potential_tts>`") }
            } else {
                // Ethan wants angular markers inline with editable words, not
                // square brackets or forced marker rows. Inline-code delimiters
                // keep Markdown from treating <selection> as invisible raw HTML;
                // they do not introduce TeX or change the saved XML timeline.
                parts.append("`<\(section.tag)>`")
            }
        }
        // The editable opening remains one paragraph. Captures keep their event
        // positions; only the appended timeline or footer gets a paragraph break.
        let body = parts.joined(separator: " ")
        guard !body.isEmpty else { return pointer }
        let result = openingLink + " " + body
        // Keep Ethan's existing editable opening and interleaved markers first.
        // A fitting timeline is additional context underneath, not a replacement
        // opening. Reuse the pipeline's exact payload without the archive's skill
        // reminder; normal skill discovery/reuse already handles interpretation.
        // Leave an extra blank line between the editable opening and raw XML:
        // compact question/queue surfaces can visually collapse the usual gap.
        // Count the actual fixed-colour expansion, both copies of authored
        // words and the separator. If it cannot fit, keep the plain compact
        // preview plus file instruction; never leak colours into that branch.
        if needsFullPrompt, let completePromptText,
           completePromptText.contains(where: { !$0.isWhitespace }) {
            // Reject an already-oversized plain candidate before allocating its
            // larger styled representation. Colouring is bounded to short copies.
            if (result + "\n\n\n" + completePromptText).utf16.count < pastedTextAttachmentThreshold {
                let inline = result + "\n\n\n" + coloredInlineTimeline(completePromptText, rainbowStartIndex: rainbowStartIndex)
                if inline.utf16.count < pastedTextAttachmentThreshold { return inline }
            }
        }
        return needsFullPrompt ? result + "\n\n" + pointer : result
    }
}
