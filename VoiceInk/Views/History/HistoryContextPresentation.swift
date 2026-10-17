import AppKit
import SwiftUI

/// Lossless decoding for Agent Flow's retired presentation vocabulary. History
/// now uses the same neutral text appearance as the current Codex paste; recognizing
/// an old colour wrapper must not revive its rainbow or metadata colours.
/// Arbitrary commands stay inert and stored source remains unchanged.
enum HistoryContextPresentation {
    struct Run: Equatable {
        var text: String
        var colorHex: String?
        var italic: Bool = false
    }

    struct Document {
        var runs: [Run]
        var hasFormatting: Bool
        var plainText: String { runs.map(\.text).joined() }
    }

    private static let prefix = "\\(\\textsf{\\color{"
    private static let escapes: [(String, String)] = [
        ("\\textbackslash{}", "\\"), ("\\textasciicircum{}", "^"),
        ("\\textasciitilde{}", "~"), ("\\{", "{"), ("\\}", "}"),
        ("\\$", "$"), ("\\&", "&"), ("\\#", "#"), ("\\%", "%"),
        ("\\_", "_"), ("\\ ", " "), ("{[}", "["), ("{]}", "]"), ("{}", "")
    ]

    static func document(_ source: String) -> Document {
        // New recovery journals preserve canonical metadata rather than only
        // raw HUD words. Colour the known overlap fragment without interpreting
        // arbitrary markup or altering any stored source byte.
        if !source.contains(prefix), source.contains("<potential_tts "),
           let expression = try? NSRegularExpression(pattern: #"(?ms)^[\t ]*<potential_tts\b[^>]*>.*?</potential_tts>"#) {
            let ns = source as NSString
            let matches = expression.matches(in: source, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var spans: [Run] = [], end = 0
                for match in matches {
                    if match.range.location > end {
                        spans.append(Run(text: ns.substring(with: NSRange(location: end, length: match.range.location - end))))
                    }
                    spans.append(Run(text: ns.substring(with: match.range), colorHex: LiveSelectionStyledMath.potentialTTSColor))
                    end = NSMaxRange(match.range)
                }
                if end < ns.length { spans.append(Run(text: ns.substring(from: end))) }
                return Document(runs: spans, hasFormatting: true)
            }
        }
        var runs: [Run] = []
        var cursor = source.startIndex
        var search = cursor
        var hasFormatting = false
        while let opening = source.range(of: prefix, range: search..<source.endIndex) {
            guard let colorEnd = source[opening.upperBound...].firstIndex(of: "}"),
                  let closing = source.range(of: "\\)", range: colorEnd..<source.endIndex) else { break }
            let color = String(source[opening.upperBound..<colorEnd])
            let bodyStart = source.index(after: colorEnd)
            var body = String(source[bodyStart..<closing.lowerBound])
            guard color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
                  body.hasSuffix("}") else {
                search = closing.upperBound
                continue
            }
            body.removeLast()
            let italic = body.hasPrefix("\\textit{")
            if italic {
                guard body.hasSuffix("}") else { search = closing.upperBound; continue }
                body = String(body.dropFirst("\\textit{".count).dropLast())
            }
            guard let decoded = decodeText(body) else {
                search = closing.upperBound
                continue
            }
            var between = String(source[cursor..<opening.lowerBound])
            // Only the producer's adjacent-formula separator is presentation.
            // Do not strip invisible characters from arbitrary user payloads.
            if hasFormatting && between == "\u{200B}" { between = "" }
            if !between.isEmpty { runs.append(Run(text: between)) }
            runs.append(Run(text: decoded, colorHex: color, italic: italic))
            hasFormatting = true
            cursor = closing.upperBound
            search = cursor
        }
        if cursor < source.endIndex { runs.append(Run(text: String(source[cursor...]))) }
        return Document(runs: runs, hasFormatting: hasFormatting)
    }

    private static func decodeText(_ body: String) -> String? {
        var result = ""
        var cursor = body.startIndex
        while cursor < body.endIndex {
            if let (encoded, decoded) = escapes.first(where: { body[cursor...].hasPrefix($0.0) }) {
                result += decoded
                cursor = body.index(cursor, offsetBy: encoded.count)
            } else {
                let character = body[cursor]
                // Unknown commands or group nesting are literal fallback, never
                // silently erased or interpreted as executable TeX/Markdown.
                guard character != "\\", character != "{", character != "}" else { return nil }
                result.append(character)
                cursor = body.index(after: cursor)
            }
        }
        return result
    }

    static func listPreview(_ source: String) -> String {
        // A two-line row needs only the beginning. Bound work independently of
        // very large historical transcripts; expanded/copy content stays whole.
        let readable = document(String(source.prefix(8_192))).plainText
        if let envelope = readable.range(of: "<agent_flow_context") {
            let opening = readable[..<envelope.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !opening.isEmpty { return opening }
        }
        return readable.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CopyFormat { case plain, formatted }

    static func copyText(_ source: String, format: CopyFormat) -> String {
        let readable = document(source).plainText
        switch format {
        case .plain:
            // Normal Copy means the user's words, not captured source material
            // or our XML/timing scaffolding. Parse only known timeline events;
            // malformed/unrecognised source stays literal rather than vanishing.
            // Legacy producers sometimes joined two sections without a newline
            // and wrapped the timeline after an opening preview. Normalize only
            // these known structural boundaries for extraction, not stored/XML
            // copy bytes or escaped tags inside selected/typed payloads.
            let timeline = readable
                .replacingOccurrences(of: "<agent_flow_context preview=\"authored_text_above\">", with: "")
                .replacingOccurrences(of: "</agent_flow_context>", with: "")
                .replacingOccurrences(of: #"(</(?:speech|speech_segment|typed_text|potential_tts)>)(?=<(?:speech|speech_segment|typed_text|potential_tts)\b)"#,
                                      with: "$1\n", options: .regularExpression)
            let events = AgentFlowPromptViewer.events(timeline)
            let authoredTags: Set<String> = ["speech", "speech_segment", "typed_text", "potential_tts"]
            guard events.contains(where: { authoredTags.contains($0.tag)
                || ["app_selection", "codex_selection", "local_screenshot"].contains($0.tag) }) else { return readable }
            let authored = events.filter { authoredTags.contains($0.tag) }
                .map { unframed($0.text) }
            let normalizedAuthored = authored.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return events.compactMap { event -> String? in
                if authoredTags.contains(event.tag) { return unframed(event.text) }
                guard event.tag == "opening" || event.tag == "text" else { return nil }
                // Older records repeat the same words before their timeline.
                if event.tag == "opening", !normalizedAuthored.isEmpty,
                   event.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") == normalizedAuthored { return nil }
                return event.text.trimmingCharacters(in: .newlines)
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .formatted:
            // Match the complete readable History, including XML/context, not
            // the retired producer-LaTeX hidden by its renderer. Never truncate
            // this copy or rewrite the saved record. Recipient-specific colour
            // belongs only to the actual inline Codex paste, not the clipboard.
            return readable
        }
    }

    private static func unframed(_ text: String) -> String {
        var text = text
        if text.hasPrefix("\n\n") { text.removeFirst(2) }
        else if text.hasPrefix("\n") { text.removeFirst() }
        if text.hasSuffix("\n\n") { text.removeLast(2) }
        else if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    static func recoveredCodexText(for transcription: Transcription) -> String? {
        guard transcription.transcriptionStatus == TranscriptionStatus.recoveredAfterInterruption.rawValue,
              let draft = transcription.recoverableRealtimeDraftText else { return nil }
        // New journals retain a canonical timeline, including overlap and typed
        // words. Do not escape that complete source inside a second speech tag.
        // Old raw-only journals still need the unavailable-time wrapper; neither
        // path invents provider-final words, events or precise audio timestamps.
        let events = AgentFlowPromptViewer.events(draft)
        if events.contains(where: { ["speech", "potential_tts", "typed_text"].contains($0.tag)
            && ($0.attributes["start_at"] != nil || $0.attributes["timing"] == "unavailable") }) {
            return draft
        }
        return LiveSelectionReference.interleaving([], with: draft, includeTiming: true)
    }

    static func attributed(_ document: Document, fontSize: CGFloat, foreground: Color) -> AttributedString {
        // Old History retains its exact producer markup for recovery. Decode
        // those wrappers for reading, but never apply their retired colours or
        // italics to the native UI. A single neutral attributed run also avoids
        // rebuilding a separate native font/colour span for every rainbow word.
        AttributedString(NSAttributedString(string: document.plainText, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor(foreground),
        ]))
    }
}

/// Both choices stay outside disclosure/scrolling content. Formatting runs only
/// on click, not on every History render; neither choice rewrites the saved row.
struct HistoryCopyButtons: View {
    let text: String
    var identifier: String = "history-copy"
    var showsFormattingTitle: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            CopyIconButton(textToCopy: text, textTransform: {
                HistoryContextPresentation.copyText($0, format: .plain)
            })
            .accessibilityIdentifier(identifier)
            CopyIconButton(textToCopy: text, systemImage: "doc.on.doc",
                           title: showsFormattingTitle ? "Copy with formatting" : nil,
                           accessibilityTitle: "Copy with formatting", textTransform: {
                HistoryContextPresentation.copyText($0, format: .formatted)
            })
            .accessibilityIdentifier(identifier + "-formatted")
        }
        .fixedSize()
    }
}

/// Both History layouts use the same native renderer. It never loads a web view,
/// evaluates pasted markup, fetches links or reads screenshot files automatically.
struct HistoryMessageContentView: View {
    let text: String
    var fontSize: CGFloat = 14
    var foregroundColor: Color = AppTheme.Text.primary
    var alignment: Alignment = .leading

    var body: some View {
        let document = HistoryContextPresentation.document(text)
        if document.hasFormatting {
            Text(HistoryContextPresentation.attributed(document, fontSize: fontSize, foreground: foregroundColor))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            MarkdownContentView(text, fontSize: fontSize, foregroundColor: foregroundColor, alignment: alignment)
        }
    }
}

/// The recovered draft is already shown as speech in History. This separate
/// copy surface formats that same saved draft for Codex without changing it,
/// sending it, or claiming to restore context that the crash journal never held.
struct HistoryRecoveredCodexView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryDraftHeader(title: "Codex", text: text,
                               copyIdentifier: "history-recovered-codex-copy")
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Surface.subtle)
            )
        }
    }
}

/// The XML Copy action belongs beside the heading, never underneath a long
/// scrolling draft. Both exit drafts and the recovered Codex surface use it.
struct HistoryDraftHeader: View {
    let title: LocalizedStringKey
    let text: String
    let copyIdentifier: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            HistoryCopyButtons(text: text, identifier: copyIdentifier)
        }
    }
}
