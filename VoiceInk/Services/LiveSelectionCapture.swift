import AppKit
import CoreServices
import Darwin
import Foundation
import SQLite3

/// A per-recording reference to text selected in the frontmost app. The HUD
/// shows only a compact preview; a bounded excerpt is added to the final
/// destination message after transcription, never to live provider context.
struct LiveSelectionReference: Equatable {
    // Ethan wants substantial selected passages, not a five-line summary. Keep
    // all source whitespace and hard lines until this per-highlight safety cap;
    // the independently compact HUD must not determine final context length.
    // `characterCount` describes the input and XML explicitly marks truncation.
    static let maxSelectionCharacters = 8_000

    private enum Source: Equatable {
        case codex
        case application(name: String, bundleID: String?)
    }

    enum PreviewPart: Equatable {
        case speech(String)
        case selection(String)
        case screenshot(String)
    }

    /// How source references are written into the one final destination message.
    /// `.plain` is the canonical XML grammar that every recipient and the
    /// interpretation skill already understand, and remains the default.
    /// Historically `.styledMath` kept exact XML with a display-only KaTeX preview
    /// immediately above each highlight/screenshot tag, for Markdown renderers with
    /// `\(...\)` inline math such as the Codex desktop user bubble. The tag then says
    /// `display_copy="above"`, so neither Ethan's agent nor a reader without the skill
    /// could mistake the preview for a second selection, instruction, or context event.
    /// Build 351 instead colours the XML itself, once, with reversible TeX escaping.
    /// Screenshot references also receive a normal local Markdown image link outside
    /// math. That is still text in this one paste, not an attached pixel payload.
    /// The choice comes from the Mode that the existing route already resolved, never
    /// from an app classifier, and it adds no paste, attachment, or delivery route.
    enum Presentation: Equatable {
        case plain
        case styledMath
    }

    private enum InterleavedPart {
        case text(String)
        case reference(LiveSelectionReference, index: Int)

        var canonical: String {
            switch self {
            case .text(let text):
                return text
            case let .reference(reference, index):
                return reference.xml(index: index, hasDisplayCopy: false)
            }
        }
    }

    let preview: String
    let characterCount: Int
    let omittedMiddle: Bool
    let truncated: Bool
    private let selectedText: String
    private let screenshotPath: String?
    private var typedText: String?
    private var spokenPrefix = ""
    private var codexThreadID: String?
    private var codexThreadTitle: String?
    private var visibleCodexThreadIDs: [String] = []
    private var chromeContext: ChromeSelectionContextReader.Context?
    private var source: Source = .codex

    private var hudPreview: String {
        if case let .application(name, _) = source {
            return "\(name) — \(preview)"
        }
        return preview
    }

    init?(_ selectedText: String) {
        guard selectedText.contains(where: { !$0.isWhitespace }) else { return nil }
        let excerpt = String(selectedText.prefix(Self.maxSelectionCharacters))
        let normalized = excerpt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        characterCount = selectedText.count
        screenshotPath = nil
        self.selectedText = excerpt
        omittedMiddle = false
        truncated = excerpt != selectedText
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

    /// Keyboard input is authored prose, not selected source material. Keep it
    /// outside recognition so a later partial/final can never rewrite it.
    init?(typedText: String) {
        guard !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.preview = typedText
        self.characterCount = typedText.count
        self.omittedMiddle = false
        self.truncated = false
        self.selectedText = ""
        self.screenshotPath = nil
        self.typedText = typedText
    }

    var isTypedText: Bool { typedText != nil }
    var isSelection: Bool { screenshotPath == nil && !isTypedText }

    var spokenWordCount: Int {
        spokenPrefix.split(whereSeparator: \.isWhitespace).count
    }

    func scopedToCodexThread(id: String, title: String?) -> Self {
        guard UUID(uuidString: id) != nil else { return self }
        var copy = self
        copy.codexThreadID = id.lowercased()
        copy.codexThreadTitle = title
        copy.visibleCodexThreadIDs = []
        return copy
    }

    /// Multiple visible chats are context, not proof of the selected pane.
    /// In particular, a side chat's later activity event must not relabel text
    /// selected in its main chat. Consumers receive candidate IDs explicitly.
    func scopedToVisibleCodexThreads(_ ids: [String]) -> Self {
        var copy = self
        copy.codexThreadID = nil
        copy.codexThreadTitle = nil
        copy.visibleCodexThreadIDs = Array(Set(ids.filter {
            UUID(uuidString: $0) != nil
        }.map { $0.lowercased() })).sorted()
        if copy.visibleCodexThreadIDs.count > 4 { copy.visibleCodexThreadIDs = [] }
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
        copy.visibleCodexThreadIDs = []
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
            if let typedText = reference.typedText {
                parts.append(.speech(typedText))
            } else if reference.screenshotPath != nil {
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

    static func interleaving(
        _ references: [Self],
        with transcript: String,
        presentation: Presentation = .plain
    ) -> String {
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
        var parts: [InterleavedPart] = []
        for reference in references {
            let spokenWordCount = reference.spokenWordCount
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? transcript.startIndex : wordEnds[wordCount - 1]
            let speech = String(transcript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty {
                parts.append(.text(speech))
            }
            if reference.isSelection { selectionIndex += 1 }
            parts.append(.reference(reference, index: selectionIndex))
            previousEnd = insertion
            lastWordCount = wordCount
        }
        let remainingSpeech = String(transcript[previousEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingSpeech.isEmpty {
            parts.append(.text(remainingSpeech))
        }
        // Plain output must stay byte-identical to the accepted grammar: older
        // messages, the interpretation skill, and History all depend on it.
        let canonical = parts.map(\.canonical)
        guard presentation == .styledMath else {
            return canonical.joined(separator: "\n\n")
        }
        return styled(parts, canonical: canonical)
    }

    /// The previous implementation added previews in capture order only while the message stayed inside
    /// the renderer's paste budget. A preview that does not fit is omitted and its
    /// tag stays exactly canonical, so `display_copy="above"` never appears without
    /// the preview it described. The canonical message itself was never shortened.
    /// Now style that same XML in place: a second white copy was confusing in the
    /// actual user bubble. Optional colour still yields to complete source context
    /// at the paste budget; local screenshot links are part of the base output.
    private static func styled(_ parts: [InterleavedPart], canonical: [String]) -> String {
        let base = parts.enumerated().map { offset, part -> String in
            guard case let .reference(reference, _) = part,
                  let path = reference.screenshotPath else { return canonical[offset] }
            return canonical[offset] + "\n\n" + LiveSelectionStyledMath.localImageReference(path: path)
        }
        var remaining = LiveSelectionStyledMath.messageUTF16Budget
            - base.joined(separator: "\n\n").utf16.count
        var output: [String] = []
        for (offset, part) in parts.enumerated() {
            guard case let .reference(reference, _) = part, !reference.isTypedText else {
                output.append(base[offset])
                continue
            }
            let color = reference.screenshotPath == nil
                ? LiveSelectionStyledMath.selectionColor : LiveSelectionStyledMath.screenshotColor
            var colored = LiveSelectionStyledMath.coloredXML(canonical[offset], color: color)
            if let path = reference.screenshotPath {
                colored += "\n\n" + LiveSelectionStyledMath.localImageReference(path: path)
            }
            let cost = colored.utf16.count - base[offset].utf16.count
            guard cost <= remaining else {
                output.append(base[offset])
                continue
            }
            remaining -= cost
            // Previously a separate preview preceded the tag because raw XML
            // renders literally. Wrapping the tag itself removes that duplicate.
            output.append(colored)
        }
        return output.joined(separator: "\n\n")
    }

    /// Display-only preview for `.styledMath`. Typed prose is authored text that is
    /// already plain in the message, so it never gets a preview.
    private func styledDisplayCopy(index: Int) -> String? {
        guard typedText == nil else { return nil }
        if screenshotPath != nil {
            return LiveSelectionStyledMath.screenshotPreview(fileName: preview)
        }
        // The caption names where the text was highlighted. It is never the app
        // that will receive this message; Primary does not even know that app.
        let sourceName: String
        switch source {
        case .codex:
            sourceName = "Codex"
        case let .application(name, _):
            sourceName = name
        }
        return LiveSelectionStyledMath.selectionPreview(
            text: selectedText,
            index: index,
            sourceName: sourceName,
            truncated: truncated
        )
    }

    private func xml(index: Int, hasDisplayCopy: Bool) -> String {
        if let typedText { return typedText }
        // Emitted only when the preview paragraph directly above was included.
        let displayCopy = hasDisplayCopy ? " display_copy=\"above\"" : ""
        if let screenshotPath {
            return "<local_screenshot path=\"\(Self.xmlEscaped(screenshotPath))\"\(displayCopy)/>"
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
        if case .codex = source, visibleCodexThreadIDs.count > 1 {
            attributes += " task_scope=\"multiple_visible_chats\""
            attributes += " visible_task_ids=\"\(visibleCodexThreadIDs.joined(separator: ","))\""
        }
        attributes += displayCopy
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

/// KaTeX context presentation for `LiveSelectionReference.Presentation.styledMath`.
///
/// Offline, read-only inspection of the running Codex host, ChatGPT.app
/// 26.924.22138 (build 11645, Contents/Resources/app.asar), established these limits:
/// - User bubbles render Markdown. The supported `\(...\)` form ends at the first
///   `\)`; keep each generated formula on one line. Raw XML is literal text, and
///   the user-message image extension turns Markdown images into ordinary links.
/// - KaTeX 0.16.45 runs with `strict: "ignore"`, `throwOnError: false` and no
///   `trust`. A parse error shows the raw source in red, and trust-gated commands
///   such as `\includegraphics`/`\href` cannot load anything, so no images here.
/// - KaTeX formula bases do not wrap internally. Split source text into short
///   formulas, leaving ordinary spaces or zero-width breaks between them.
/// - The composer turns a paste of 5,000+ UTF-16 units into a pasted-text
///   attachment when that feature is enabled. Rich-text paste processing also
///   exists, so preview text must not create Markdown emphasis or link syntax.
/// Ethan verified that short `\(\textsf{\color{#rrggbb}…}\)` spans render in a
/// sent Codex bubble. The original preview helpers below remain legacy fixtures;
/// production now uses reversible `coloredXML`, never their lossy sanitization.
/// XML entities protect unsupported/invisible scalars without deleting source data.
enum LiveSelectionStyledMath {
    /// Ethan's verified bubble cyan; selections stay cyan as in the recorder HUD.
    static let selectionColor = "#67e8f9"
    /// Screenshot XML is magenta, distinct from cyan selected-text context.
    static let screenshotColor = "#e879f9"
    /// Quiet captions let the coloured source text carry the emphasis.
    static let captionColor = "#94a3b8"
    /// Conservative width (wide CJK/emoji, M/W and wide punctuation count twice) per formula,
    /// sized to fit even a narrow Codex pane.
    static let maxChunkWidth = 24
    static let maxIndentColumns = 8
    static let maxSourceNameCharacters = 40
    /// Colour is useful for longer highlights too. This bounds presentation
    /// expansion, not source content: fall back to canonical XML if needed,
    /// never shorten authored text to dodge a recipient's attachment threshold.
    /// Codex may turn a 5,000+-unit paste into a text attachment; that is a host
    /// behaviour, not permission to silently clip the selected passage.
    static let messageUTF16Budget = 64_000
    /// Joins pieces of one over-long token: no visible space, but still a
    /// line-break opportunity between formulas.
    static let zeroWidthSpace = "\u{200B}"

    /// Colour the complete XML, not a second caption or text copy. The receiving
    /// skill unwraps the limited TeX vocabulary, joins zero-width chunk breaks,
    /// then decodes XML entities. Never feed this through lossy preview cleanup.
    static func coloredXML(_ xml: String, color: String) -> String {
        var renderable = ""
        for scalar in xml.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.value == 0x09 || scalar.value == 0x0D || scalar.value == 0x2A
                || (0x7F...0x9F).contains(scalar.value)
                || category == .nonspacingMark || category == .spacingMark
                || category == .enclosingMark || category == .format
                || category == .lineSeparator || category == .paragraphSeparator {
                renderable += "&#x\(String(scalar.value, radix: 16));"
            } else {
                renderable.unicodeScalars.append(scalar)
            }
        }
        return renderable.components(separatedBy: "\n").map { line in
            pieces(of: line).map { piece in
                let escaped = escapedTeX(piece).replacingOccurrences(of: " ", with: "\\ ")
                return "\\(\\textsf{\\color{\(color)}\(escaped)}\\)"
            }.joined(separator: zeroWidthSpace)
        }.joined(separator: "\n")
    }

    /// An ordinary local Markdown image reference, never a KaTeX command or a
    /// second paste. Codex may render user-message images as links; it cannot be
    /// forced to attach pixels by surrounding the path with colour commands.
    /// Percent-encode delimiter/URL characters so a filename cannot escape the
    /// destination or inject another link. The XML retains the unencoded path.
    static func localImageReference(path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: " #%?<>\\()[]\"'`\t\r\n")
        )
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "![Screenshot](<\(encoded)>)"
    }

    static func selectionPreview(
        text: String,
        index: Int,
        sourceName: String,
        truncated: Bool
    ) -> String? {
        // One preview line per non-blank source line. Every line starts with a
        // formula, so no source indentation, `#`, `>`, list marker or fence can
        // reach Markdown block parsing outside math.
        var lines = text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { formulas(for: String($0), color: selectionColor) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if truncated {
            lines[lines.count - 1] += " " + formulas(for: "…", color: captionColor)
        }
        let name = String(
            sanitizedVisibleText(sourceName)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .prefix(maxSourceNameCharacters)
        )
        let caption = name.isEmpty ? "Selection \(index)" : "Selection \(index) from \(name)"
        return ([formulas(for: caption, color: captionColor)] + lines)
            .joined(separator: "\n")
    }

    static func screenshotPreview(fileName: String) -> String? {
        let name = formulas(for: fileName, color: screenshotColor)
        guard !name.isEmpty else { return nil }
        return formulas(for: "Screenshot", color: captionColor) + " " + name
    }

    /// One visual line as short `\(\textsf{\color{…}…}\)` formulas. Words are
    /// grouped up to `maxChunkWidth`; a longer token is split into pieces joined by
    /// a zero-width space so it never becomes a single clipped box.
    static func formulas(for line: String, color: String) -> String {
        let visible = sanitizedVisibleText(line)
        let indent = min(visible.prefix(while: { $0 == " " }).count, maxIndentColumns)
        let words = visible.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "" }

        var output = ""
        var separator = ""
        // Leading indentation lives inside the first formula as control spaces.
        // Outside math it could turn the line into a Markdown code block.
        var body = String(repeating: "\\ ", count: indent)
        var width = indent
        var hasText = false

        func close(then next: String) {
            guard hasText else { return }
            output += separator + "\\(\\textsf{\\color{\(color)}" + body + "}\\)"
            separator = next
            body = ""
            width = 0
            hasText = false
        }

        for word in words {
            // Indentation counts against the first box too. Otherwise a long
            // indented code token could exceed the limit by eight columns.
            let firstLimit = hasText ? maxChunkWidth : maxChunkWidth - width
            for (offset, piece) in pieces(of: word, firstChunkWidth: firstLimit).enumerated() {
                let pieceWidth = displayWidth(of: piece)
                if offset > 0 {
                    close(then: zeroWidthSpace)
                } else if hasText {
                    if width + 1 + pieceWidth <= maxChunkWidth {
                        body += " "
                        width += 1
                    } else {
                        close(then: " ")
                    }
                }
                body += escapedTeX(piece)
                width += pieceWidth
                hasText = true
            }
        }
        close(then: "")
        return output
    }

    static func pieces(of word: String, firstChunkWidth: Int = maxChunkWidth) -> [String] {
        var pieces: [String] = []
        var current = ""
        var width = 0
        var limit = max(2, min(firstChunkWidth, maxChunkWidth))
        for character in word {
            let characterWidth = displayWidth(of: character)
            if width + characterWidth > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
                width = 0
                limit = maxChunkWidth
            }
            current.append(character)
            width += characterWidth
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func displayWidth(of text: String) -> Int {
        text.reduce(0) { $0 + displayWidth(of: $1) }
    }

    static func displayWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.value {
        // Numeric XML entities contain repeated &/# glyphs. Treating those as
        // narrow letters overflowed a 231pt KaTeX column in the production fixture.
        case 0x0023, 0x0025, 0x0026, 0x0040, 0x004D, 0x0057,
             0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Makes untrusted text inert inside KaTeX text mode. Every TeX special is
    /// escaped and a source backslash becomes `\textbackslash{}`, so selected text
    /// can never close the formula with `\)`, open a group, or run a command.
    /// `*` becomes the lookalike U+2217, and brackets are braced, so Codex's
    /// composer cannot turn preview text into emphasis or a link. Doubled
    /// hyphens/quotes are split so KaTeX does not merge them into dashes or curly
    /// quotes. The exact characters remain in the XML tag.
    static func escapedTeX(_ text: String) -> String {
        let characters = Array(text)
        var escaped = ""
        for (offset, character) in characters.enumerated() {
            let next = offset + 1 < characters.count ? characters[offset + 1] : nil
            switch character {
            case "\\": escaped += "\\textbackslash{}"
            case "{": escaped += "\\{"
            case "}": escaped += "\\}"
            case "$": escaped += "\\$"
            case "&": escaped += "\\&"
            case "#": escaped += "\\#"
            case "%": escaped += "\\%"
            case "_": escaped += "\\_"
            case "^": escaped += "\\textasciicircum{}"
            case "~": escaped += "\\textasciitilde{}"
            case "*": escaped += "\u{2217}"
            case "[": escaped += "{[}"
            case "]": escaped += "{]}"
            case "-", "`", "'":
                escaped.append(character)
                if next == character { escaped += "{}" }
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    /// Drops characters that would break or disguise a formula: C0/C1 controls,
    /// line/paragraph separators, bidi overrides (which could visually reorder the
    /// preview), invisible separators, and combining accents. KaTeX rejects
    /// accents missing from its accent table, and would show that word as red raw
    /// source. Text is NFC-normalized first so common accented letters survive.
    /// Tabs become four spaces.
    static func sanitizedVisibleText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x09:
                scalars.append(contentsOf: "    ".unicodeScalars)
            case 0x00...0x1F, 0x7F...0x9F, 0x0300...0x036F,
                 0x061C, 0x200B, 0x200E, 0x200F, 0x2028...0x202E,
                 0x2066...0x2069, 0xFEFF:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// Optional captured context is for native agent/chat apps only. This is text
/// formatting, not delivery authority: Primary still owns no input or saved Mode
/// and still posts its single generic Cmd-V. Never inspect browser URLs, window
/// titles, AX editors or app contents to broaden this allowlist. Unknown apps and
/// browser-hosted chats deliberately get only authored speech/typing.
enum LiveContextPastePolicy {
    static let recipientBundleIdentifiers: Set<String> = [
        "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"
    ]

    static func includesSourceContext(
        destination: RecordingPasteDestination,
        currentApplicationBundleIdentifier: String?,
        savedTargetBundleIdentifier: String?
    ) -> Bool {
        let recipient = destination.usesBaseCurrentInputDelivery
            ? currentApplicationBundleIdentifier
            : savedTargetBundleIdentifier
        return recipient.map { recipientBundleIdentifiers.contains($0) } ?? false
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
              let selected = fields["selectedText"],
              selected.contains(where: { !$0.isWhitespace }),
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

    /// This reads only the current selection, its common DOM ancestor and
    /// active page identity. It does not install all-sites extension access,
    /// inspect surrounding text, mutate DOM, or send page content to GPT Live.
    /// A focused password input is excluded: its selection API would otherwise
    /// expose the secret behind the dots.
    static let selectionJavaScript = #"(()=>{const s=window.getSelection();let t=s?.toString()??'';let e=s?.rangeCount?s.getRangeAt(0).commonAncestorContainer:null;e=e?.nodeType===1?e:e?.parentElement;if(!t){const a=document.activeElement;if(a&&a.type!=='password'&&typeof a.selectionStart==='number'&&typeof a.selectionEnd==='number'&&typeof a.value==='string'){t=a.value.slice(a.selectionStart,a.selectionEnd);e=a}}const o={selectedText:t,url:location.href,title:document.title};if(e&&e!==document.body&&e!==document.documentElement){o.elementTag=e.tagName?.toLowerCase()??'';o.elementRole=e.getAttribute('role')??'';o.elementLabel=e.getAttribute('aria-label')??e.getAttribute('title')??''}return JSON.stringify(o)})()"#

    static func capture() async -> Context? {
        // Chrome's app-specific override runs before the generic Accessibility
        // chain only because it also yields scrubbed page context. If Chrome's
        // "Allow JavaScript from Apple Events" or Automation consent is off,
        // this returns nil and LiveSelectionCapture falls through to the
        // generic read-only tiers.
        let script = LiveSelectionBrowserScript.chromium(
            bundleID: "com.google.Chrome", javascript: selectionJavaScript
        )
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

/// Reads genuine selection gestures only while a VoiceInk recording owns the
/// microphone. Mouse edges come from the app-lifetime `SelectionGestureWatcher`,
/// which never reads text; this per-recording object is the only place that turns
/// a gesture into selected text. No copy command or pasteboard restoration is allowed here: an older
/// transcription may be writing the clipboard concurrently for Primary delivery.
/// Text comes from the ordered read-only fallback chain documented in
/// LiveSelectionTextReader.swift; an app with no readable selection fails
/// closed rather than borrowing the clipboard.
@MainActor
final class LiveSelectionCapture {
    typealias MouseEdge = SelectionGestureWatcher.MouseEdge

    /// `precedesSpeech` is true only for a highlight made before this capture
    /// attached; the session anchors it before all dictated words.
    private let onCapture: (_ reference: LiveSelectionReference, _ precedesSpeech: Bool) -> Void
    /// True between start() and stop(). Replaces this object's former private
    /// NSEvent monitor: edges now arrive from the shared watcher only while attached.
    private var isAttached = false
    private var attachedAt = Date.distantFuture
    private var mouseDownPoint: NSPoint?
    private var mouseDownDate: Date?
    private var captureTask: Task<Void, Never>?
    private var screenshotSource: DispatchSourceFileSystemObject?
    private var screenshotDirectory: URL?
    private var screenshotBaseline: Set<String> = []
    private var screenshotStart = Date.distantFuture
    private var screenshotScanTask: Task<Void, Never>?

    init(onCapture: @escaping (_ reference: LiveSelectionReference, _ precedesSpeech: Bool) -> Void) {
        self.onCapture = onCapture
    }

    func start() {
        guard !isAttached else { return }
        isAttached = true
        attachedAt = Date()
        let watcher = SelectionGestureWatcher.shared
        watcher.start()
        // A drag that began before capture attached (during microphone start-up,
        // or just before the start press) finishes normally during recording.
        // Before build 349 its mouse-down was never seen, so the gesture failed.
        let dragInProgress = SelectionGestureWatcher.adoptablePendingDown(
            watcher.pendingMouseDown, now: attachedAt
        )
        if let down = dragInProgress {
            mouseDownPoint = down.location
            mouseDownDate = down.occurredAt
        }
        watcher.listener = self
        startScreenshotWatch()
        // A drag in progress normally replaces the earlier highlight, and its own
        // mouse-up will be read live. Reading the earlier gesture now could catch
        // that newer selection and record it twice, so skip it.
        if dragInProgress == nil {
            capturePriorSelection(watcher.lastSelectionGesture)
        }
    }

    func stop() {
        if SelectionGestureWatcher.shared.listener === self {
            SelectionGestureWatcher.shared.listener = nil
        }
        isAttached = false
        attachedAt = .distantFuture
        captureTask?.cancel()
        captureTask = nil
        mouseDownPoint = nil
        mouseDownDate = nil
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
            onCapture(reference, false)
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

    /// Called by `SelectionGestureWatcher` for every mouse edge while attached.
    func handle(_ edge: MouseEdge) {
        guard isAttached else { return }
        switch edge.type {
        case .leftMouseDown:
            // A second gesture must not let an older in-flight read borrow its
            // newer selection before the next mouse-up cancels that task.
            captureTask?.cancel()
            mouseDownPoint = edge.location
            mouseDownDate = edge.occurredAt
        case .leftMouseUp:
            let endPoint = edge.location
            let startPoint = mouseDownPoint
            let gestureStartedAt = mouseDownDate ?? edge.occurredAt
            mouseDownPoint = nil
            mouseDownDate = nil
            guard let startPoint,
                  Self.isSelectionGesture(
                      from: startPoint,
                      to: endPoint,
                      clickCount: edge.clickCount
                  ),
                  let app = NSWorkspace.shared.frontmostApplication else {
                return
            }
            beginSelectionRead(
                from: startPoint, to: endPoint, gestureStartedAt: gestureStartedAt,
                app: app, precedesSpeech: false
            )
        default:
            break
        }
    }

    /// Reads, once, a highlight finished shortly before this recording's capture
    /// attached: made while reading before pressing start, or during microphone
    /// start-up. It becomes the first reference because the live transcript is
    /// still empty. Only the same frontmost app may be read, through the same
    /// gesture-bounded reader as a live highlight, so a stale or elsewhere
    /// selection fails closed rather than borrowing unrelated text.
    private func capturePriorSelection(_ gesture: SelectionGestureWatcher.CompletedGesture?) {
        guard let gesture,
              let app = NSWorkspace.shared.frontmostApplication,
              SelectionGestureWatcher.isEligiblePriorGesture(
                  gesture, now: Date(), captureStartedAt: attachedAt,
                  frontmostPID: app.processIdentifier
              ) else { return }
        beginSelectionRead(
            from: gesture.start, to: gesture.end, gestureStartedAt: gesture.startedAt,
            app: app, precedesSpeech: true
        )
    }

    /// Shared by live mouse-ups and the one prior-highlight read. A newer
    /// mouse-down or stop cancels an in-flight read so it cannot borrow a newer
    /// selection.
    private func beginSelectionRead(
        from startPoint: NSPoint,
        to endPoint: NSPoint,
        gestureStartedAt: Date,
        app: NSRunningApplication,
        precedesSpeech: Bool
    ) {
        // A drag can activate an app that was backgrounded at mouse-down.
        // Bind to the app at mouse-up, then require it to stay frontmost
        // throughout the asynchronous selected-text read.
        let sourcePID = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let gesture = LiveSelectionGesture.fromCocoa(
            mouseDown: startPoint,
            mouseUp: endPoint,
            screenFrames: NSScreen.screens.map(\.frame)
        )
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
            let threadsBefore = isCodex
                ? CodexConversationContextReader.visibleSelectionThreadIDsIfFrontmost(
                    frontmostApplication: app
                ) : []
            let startedAt = DispatchTime.now().uptimeNanoseconds
            // Chrome's DOM override has no selection geometry of its own.
            // If the gesture was visibly outside Chrome's windows, do not
            // borrow an older selection from its active tab.
            if bundleID == "com.google.Chrome",
               !LiveSelectionBrowserScriptReader.mayReadForGesture(
                   gesture, processIdentifier: sourcePID,
                   windows: LiveSelectionWindow.onScreen()
               ) {
                return
            }
            let chromeContext = bundleID == "com.google.Chrome"
                ? await ChromeSelectionContextReader.capture() : nil
            let selectedText: String?
            if let chromeContext {
                selectedText = chromeContext.selectedText
                LiveSelectionDiagnostics.captured(
                    tier: .chromeDOM, source: nil, evidence: nil, attempt: 1,
                    bundleID: bundleID, startedAt: startedAt
                )
            } else {
                selectedText = await Self.readSelectedText(
                    sourcePID: sourcePID,
                    bundleID: bundleID,
                    gesture: gesture,
                    gestureStartedAt: gestureStartedAt,
                    startedAt: startedAt
                )
            }
            guard !Task.isCancelled,
                  let text = selectedText,
                  Self.hasStableSource(expectedPID: sourcePID,
                                       currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
                  let reference = LiveSelectionReference(text) else {
                return
            }
            let labeled: LiveSelectionReference
            if isCodex {
                // Only the verified Codex app may add a task label. A task
                // switch during selection leaves the existing plain tag.
                let threadsAfter = CodexConversationContextReader.visibleSelectionThreadIDsIfFrontmost(
                    frontmostApplication: app
                )
                if threadsBefore == threadsAfter, threadsBefore.count == 1,
                   let id = threadsBefore.first {
                    labeled = reference.scopedToCodexThread(
                        id: id, title: CodexSelectionThreadTitleReader.title(for: id)
                    )
                } else if threadsBefore == threadsAfter {
                    labeled = reference.scopedToVisibleCodexThreads(threadsBefore)
                } else {
                    labeled = reference
                }
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
            self?.onCapture(labeled, precedesSpeech)
        }
    }

    /// Generic tiers after Chrome's override: app-scoped Accessibility (with one
    /// bounded settle re-read), then Safari/Edge read-only scripting. The source
    /// must stay frontmost before every attempt; any doubt yields no reference.
    private static func readSelectedText(
        sourcePID: pid_t,
        bundleID: String?,
        gesture: LiveSelectionGesture?,
        gestureStartedAt: Date,
        startedAt: UInt64
    ) async -> String? {
        // VS Code's default Monaco editor intentionally exposes no AX text.
        // Better Git can prove a fresh mouse selection in the focused editor;
        // ask only during capture, never enable screen-reader mode or copy.
        if VSCodeSelectionBridge.supports(bundleID),
           gesture?.touchesWindow(ownedBy: sourcePID, in: LiveSelectionWindow.onScreen()) == true,
           let text = await VSCodeSelectionBridge.read(sourcePID: sourcePID, gestureStartedAt: gestureStartedAt) {
            LiveSelectionDiagnostics.captured(
                tier: .vscodeBridge, source: nil, evidence: .atGesture, attempt: 1,
                bundleID: bundleID, startedAt: startedAt
            )
            return text
        }
        var last = LiveSelectionResolution()
        var attempts = 0
        for delay in LiveSelectionReadPolicy.accessibilityRetryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled,
                  hasStableSource(expectedPID: sourcePID,
                                  currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
                return nil
            }
            attempts += 1
            last = await LiveSelectionTextReader.resolveAccessibility(
                processIdentifier: sourcePID, gesture: gesture
            )
            if let candidate = last.candidate {
                LiveSelectionDiagnostics.captured(
                    tier: candidate.tier, source: candidate.source,
                    evidence: candidate.evidence, attempt: attempts,
                    bundleID: bundleID, startedAt: startedAt
                )
                return candidate.text
            }
            // Without Accessibility trust a re-read cannot succeed.
            if !last.accessibilityTrusted { break }
        }

        guard !Task.isCancelled,
              hasStableSource(expectedPID: sourcePID,
                              currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
            return nil
        }
        if LiveSelectionBrowserScriptReader.engine(for: bundleID) != nil,
           LiveSelectionBrowserScriptReader.mayReadForGesture(
               gesture, processIdentifier: sourcePID,
               windows: LiveSelectionWindow.onScreen()
           ),
           let text = await LiveSelectionBrowserScriptReader.read(bundleID: bundleID) {
            LiveSelectionDiagnostics.captured(
                tier: .browserScript, source: nil, evidence: nil, attempt: attempts,
                bundleID: bundleID, startedAt: startedAt
            )
            return text
        }
        LiveSelectionDiagnostics.unavailable(
            last, attempts: attempts, bundleID: bundleID, startedAt: startedAt
        )
        return nil
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
