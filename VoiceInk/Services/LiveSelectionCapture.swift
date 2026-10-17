import AppKit
import CoreServices
import Darwin
import Foundation
import SQLite3

/// A per-recording reference to text selected in the frontmost app. The HUD
/// shows only a compact preview; the full captured selection is added to the final
/// destination message after transcription, never to live provider context.
struct LiveSelectionReference: Equatable {
    // The durable prompt is the agent's complete input. Neither the HUD nor
    // the short chat bubble may impose a line/character cap on captured text.
    // Individual source transports can still have their own documented limits.

    private enum Source: Equatable {
        case codex
        case application(name: String, bundleID: String?)
    }

    enum PreviewPart: Equatable {
        case speech(String)
        case potentialTTS(String)
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
    /// Build 351 instead coloured the XML itself, once, with reversible TeX escaping.
    /// A raw XML envelope without a following blank line suppresses inline math.
    /// Keep that Markdown boundary explicit: only the opening uses a rainbow;
    /// each timeline section has one fixed colour and decodes to canonical XML.
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
        case authoredXML(String, color: String)
        case reference(LiveSelectionReference, index: Int)

        func canonical(separateContent: Bool) -> String {
            switch self {
            case .text(let text), .authoredXML(let text, _):
                return text
            case let .reference(reference, index):
                return reference.xml(index: index, hasDisplayCopy: false, separateContent: separateContent)
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
    private var capturedAt: Date?
    private var runStartedAt: Date?
    private var speechBoundary = false
    private var speechTimingSource = "approximate"
    private var potentialTTS = false
    private var spokenPrefix = ""
    // Anchors are immutable snapshots. Counting the entire cumulative prefix on
    // each HUD/journal render made successive partial updates increasingly costly.
    // Keep the prefix for identity; refresh its derived count only when anchoring.
    private var anchoredWordCount = 0
    // Prose committed by capture end follows every final word, including a
    // provider tail longer than the last live partial. Not a timing claim.
    private var followsAllSpeech = false
    private var codexThreadID: String?
    private var codexThreadTitle: String?
    private var visibleCodexThreadIDs: [String] = []
    private var chromeContext: ChromeSelectionContextReader.Context?
    private var source: Source = .codex
    private(set) var captureID: UUID?

    func identifiedForCapture(_ id: UUID) -> Self {
        var copy = self
        copy.captureID = id
        return copy
    }

    /// Optional labels may arrive later, but never replace authored text,
    /// timing, or the gesture's already-frozen position in the timeline.
    func updatingSourceLabels(from labeled: Self) -> Self {
        var copy = self
        copy.source = labeled.source
        copy.codexThreadID = labeled.codexThreadID
        copy.codexThreadTitle = labeled.codexThreadTitle
        copy.visibleCodexThreadIDs = labeled.visibleCodexThreadIDs
        copy.chromeContext = labeled.chromeContext
        return copy
    }

    private var hudPreview: String {
        if case let .application(name, _) = source {
            return "\(name) — \(preview)"
        }
        return preview
    }

    init?(_ selectedText: String) {
        guard selectedText.contains(where: { !$0.isWhitespace }) else { return nil }
        let normalized = selectedText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        characterCount = selectedText.count
        screenshotPath = nil
        self.selectedText = selectedText
        omittedMiddle = false
        truncated = false
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
        copy.anchoredWordCount = spokenText.split(whereSeparator: \.isWhitespace).count
        copy.followsAllSpeech = false
        return copy
    }

    /// For a boundary known to come after all captured audio (capture end).
    /// Interleaving clamps this to the final transcript's word count, so the
    /// reference follows every recognized word without inventing a position.
    func anchoredAfterAllSpeech(observed spokenText: String) -> Self {
        var copy = anchored(after: spokenText)
        copy.followsAllSpeech = true
        return copy
    }

    func timed(at date: Date, startedAt: Date? = nil) -> Self {
        var copy = self
        copy.capturedAt = date
        copy.runStartedAt = startedAt
        return copy
    }

    static func speechTiming(after transcript: String, startedAt: Date, endedAt: Date,
                             sessionWindow: Bool = false) -> Self {
        // An internal timing marker, never a selected passage or HUD row.
        var marker = Self(typedText: "timing")!
        marker.typedText = nil
        marker.speechBoundary = true
        marker.speechTimingSource = sessionWindow ? "session_window" : "approximate"
        return marker.anchored(after: transcript).timed(at: endedAt, startedAt: startedAt)
    }

    /// Recognition callbacks can be late or revised; these are conservative utterance
    /// windows, never claimed word timestamps. Keep retry/recovery annotation intact.
    static func annotatingSpeech(_ references: [Self], overlaps: [DateInterval],
                                 sessionStartedAt: Date, captureEndedAt: Date?) -> [Self] {
        let lastTiming = references.lastIndex(where: \.speechBoundary)
        var previous = sessionStartedAt
        return references.enumerated().map { index, reference in
            guard reference.speechBoundary, let end = reference.capturedAt else { return reference }
            let upper = index == lastTiming ? max(end, captureEndedAt ?? end) : end
            var copy = reference
            copy.potentialTTS = copy.potentialTTS || overlaps.contains {
                $0.start < upper && $0.end > previous
            }
            previous = max(previous, end)
            return copy
        }
    }

    private static func timestamp(_ date: Date) -> String {
        // Unix seconds retain the existing millisecond precision with ten fewer
        // characters per current-date value. POSIX formatting makes the unit and
        // decimal separator independent of the user's locale and time zone.
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970)
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
    var hasSpeechTiming: Bool { speechBoundary }
    var isSelection: Bool { screenshotPath == nil && !isTypedText && !speechBoundary }

    var spokenWordCount: Int {
        anchoredWordCount
    }

    /// Timeline position among `totalWords` final words. Capture-end prose
    /// follows all of them; every other reference uses its observed anchor.
    private func placementWordCount(totalWords: Int) -> Int {
        followsAllSpeech ? totalWords : anchoredWordCount
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
        compactPromptSections(references, with: partialTranscript).map { section in
            switch section.tag {
            case "speech", "typed_text": return .speech(section.text)
            case "potential_tts": return .potentialTTS(section.text)
            case "screenshot": return .screenshot(section.text)
            default: return .selection(section.text)
            }
        }
    }

    /// Reader-only timeline for the bounded message bubble. Full metadata and
    /// exact captured excerpts still come from interleaving() into the archive.
    /// Reuse its cumulative speech anchors, never infer order from wall clocks.
    static func compactPromptSections(_ references: [Self], with transcript: String) -> [AgentFlowPromptPreview.Section] {
        let wordEnds = wordEndIndices(in: transcript)
        let speechTimings = references.filter(\.speechBoundary)
        var lastWordCount = 0
        var previousEnd = transcript.startIndex
        var parts: [AgentFlowPromptPreview.Section] = []
        func speechSection(_ text: String, through wordCount: Int) -> AgentFlowPromptPreview.Section {
            // Preserve first matching marker (including revised/non-monotonic
            // provider anchors), then the last-marker fallback, without filtering
            // the same references again for every visible speech section.
            let timing = speechTimings.first { $0.spokenWordCount >= wordCount } ?? speechTimings.last
            let flagged = timing?.potentialTTS == true
            return .init(tag: flagged ? "potential_tts" : "speech", text: text,
                         color: flagged ? LiveSelectionStyledMath.potentialTTSColor : LiveSelectionStyledMath.speechColor)
        }
        for reference in references {
            let wordCount = min(max(lastWordCount, reference.placementWordCount(totalWords: wordEnds.count)),
                                wordEnds.count)
            let insertion = wordCount == 0 ? transcript.startIndex : wordEnds[wordCount - 1]
            let speech = String(transcript[previousEnd..<insertion]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty { parts.append(speechSection(speech, through: wordCount)) }
            if reference.speechBoundary {
                // Internal timing/annotation marker: no context row.
            } else if let typed = reference.typedText {
                parts.append(.init(tag: "typed_text", text: typed, color: LiveSelectionStyledMath.typedColor))
            } else if reference.screenshotPath != nil {
                parts.append(.init(tag: "screenshot", text: reference.preview, color: LiveSelectionStyledMath.screenshotColor))
            } else {
                parts.append(.init(tag: "selection", text: reference.hudPreview, color: LiveSelectionStyledMath.selectionColor))
            }
            previousEnd = insertion
            lastWordCount = wordCount
        }
        let tail = String(transcript[previousEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(speechSection(tail, through: wordEnds.count)) }
        // Keep authored-only events too: the bubble interleaves rainbow prose
        // and context markers instead of repeating speech in a separate trail.
        return parts
    }

    static func interleaving(
        _ references: [Self],
        with transcript: String,
        presentation: Presentation = .plain,
        includeTiming: Bool = false,
        includeReadablePreview: Bool = false,
        rainbowStartIndex: Int = 0
    ) -> String {
        guard includeTiming || !references.isEmpty else {
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
        let speechTimings = references.filter(\.speechBoundary)
        func timedSpeech(_ speech: String, through wordCount: Int) -> String {
            guard includeTiming else { return speech }
            // The final provider result may grow beyond its last live partial.
            // Keep that revised tail grouped with the last observed speech run;
            // never invent a finish-time/audio timestamp or let words escape XML.
            // New short/batch-only recordings carry a frozen session-window
            // fallback. Historical/imported text without any observed window
            // stays unavailable rather than receiving invented dates.
            let timing = speechTimings.first(where: { $0.spokenWordCount >= wordCount })
                ?? speechTimings.last
            guard let started = timing?.runStartedAt, let ended = timing?.capturedAt,
                  started <= ended else {
                return "<speech timing=\"unavailable\">\n\n"
                    + xmlEscaped(speech, attribute: false) + "\n\n</speech>"
            }
            // Recognition callbacks are delayed and may revise words. These are
            // observed transcript-activity ranges, never precise audio alignment.
            // session_window explicitly means the broader composing-session bounds.
            let timingSource = timing?.speechTimingSource ?? "approximate"
            let tag = timing?.potentialTTS == true ? "potential_tts" : "speech"
            let note = timing?.potentialTTS == true
                ? " overlap_timing=\"utterance_window\" reason=\"possible_unrelated_tts\" note=\"May include unrelated text-to-speech from another chat; ignore only words that do not fit my request. My own speech may be included.\"" : ""
            return "<\(tag) start_at=\"\(timestamp(started))\" end_at=\"\(timestamp(ended))\" timing=\"\(timingSource)\"\(note)>\n\n"
                + xmlEscaped(speech, attribute: false) + "\n\n</\(tag)>"
        }
        for reference in references {
            let spokenWordCount = reference.placementWordCount(totalWords: wordEnds.count)
            let wordCount = min(max(lastWordCount, spokenWordCount), wordEnds.count)
            let insertion = wordCount == 0 ? transcript.startIndex : wordEnds[wordCount - 1]
            let speech = String(transcript[previousEnd..<insertion])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speech.isEmpty {
                let text = timedSpeech(speech, through: wordCount)
                parts.append(includeTiming ? .authoredXML(text, color: text.hasPrefix("<potential_tts") ? LiveSelectionStyledMath.potentialTTSColor : LiveSelectionStyledMath.speechColor) : .text(text))
            }
            if reference.isSelection { selectionIndex += 1 }
            if reference.speechBoundary {
                // The timestamp belongs to the grouped speech, not a free-floating tag.
            } else if includeTiming, reference.isTypedText, let ended = reference.capturedAt {
                let started = reference.runStartedAt ?? ended
                parts.append(.authoredXML("<typed_text start_at=\"\(timestamp(started))\" end_at=\"\(timestamp(ended))\">\n\n"
                    + xmlEscaped(reference.typedText ?? "", attribute: false) + "\n\n</typed_text>", color: LiveSelectionStyledMath.typedColor))
            } else {
                parts.append(.reference(reference, index: selectionIndex))
            }
            previousEnd = insertion
            lastWordCount = wordCount
        }
        let remainingSpeech = String(transcript[previousEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingSpeech.isEmpty {
            let text = timedSpeech(remainingSpeech, through: wordEnds.count)
            parts.append(includeTiming ? .authoredXML(text, color: text.hasPrefix("<potential_tts") ? LiveSelectionStyledMath.potentialTTSColor : LiveSelectionStyledMath.speechColor) : .text(text))
        }
        // Untimed/plain output keeps its accepted grammar. Timed AI output uses
        // uniform start_at/end_at; the skill also accepts historical field names.
        let canonical = parts.map { $0.canonical(separateContent: includeTiming) }
        var readablePreview: String?
        if includeTiming && includeReadablePreview {
            // Queue previews must begin with authored words, never a source XML tag or a
            // highlighted quote. This is one display copy; the speech/typing
            // timeline below is authoritative for context placement and is not a
            // second request. The interpretation skill explains the duplicate
            // without an outer envelope. Ordinary-app paste never enters this AI-only presentation.
            // Ethan now wants this opening rainbow-coloured where styled output
            // is enabled; queue surfaces that do not render math may show LaTeX.
            let readable = previewParts(references, with: transcript).compactMap { part -> String? in
                switch part {
                case .speech(let text), .potentialTTS(let text): return text
                default: return nil
                }
            }.joined(separator: " ")
            if !readable.isEmpty {
                readablePreview = readable
            }
        }
        if presentation == .styledMath {
            return styled(parts, canonical: canonical, readablePreview: readablePreview,
                          rainbowStartIndex: rainbowStartIndex, compactMetadata: includeTiming)
        }
        let structured = canonical.joined(separator: "\n\n")
        if let readablePreview {
            return readablePreview + "\n\n" + structured
        }
        return structured
    }

    /// The previous implementation added previews in capture order only while the message stayed inside
    /// the renderer's paste budget. A preview that does not fit is omitted and its
    /// tag stays exactly canonical, so `display_copy="above"` never appears without
    /// the preview it described. The canonical message itself was never shortened.
    /// Styling that XML in place subsequently showed raw TeX inside the context
    /// envelope. Current output omits that outer envelope and retains the paragraph
    /// boundary after the readable opening. Raw XML can still swallow following
    /// math on a plain fallback; validate complete messages, not isolated formulas.
    /// Optional colour still yields to complete source context at the paste budget; local
    /// screenshot links are part of the base output, never an attached pixel payload.
    private static func styled(_ parts: [InterleavedPart], canonical: [String],
                               readablePreview: String? = nil, rainbowStartIndex: Int = 0,
                               compactMetadata: Bool = false) -> String {
        let base = parts.enumerated().map { offset, part -> String in
            guard case let .reference(reference, _) = part,
                  let path = reference.screenshotPath else { return canonical[offset] }
            return canonical[offset] + "\n\n" + LiveSelectionStyledMath.localImageReference(path: path)
        }
        let beforeTimeline = "\n\n"
        if compactMetadata {
            // Metadata is quiet scaffolding, not a paragraph per tag. Styling the
            // individual tags avoids the raw-HTML parser boundary that swallowed
            // colour in build 359. No outer envelope is emitted; the skill owns
            // duplicate-preview interpretation. Keep payload whitespace and image links intact.
            // Compact only contiguous sections of the same type/colour. A colour
            // change is a reading boundary and needs one visible paragraph gap;
            // otherwise a selection's closing tag touches the next speech tag.
            var timeline = ""
            var previousColor: String?
            for (offset, part) in parts.enumerated() {
                let color: String
                var path: String?
                switch part {
                case .text:
                    timeline += "\n\n" + base[offset] + "\n\n"
                    previousColor = nil
                    continue
                case .authoredXML(_, let authoredColor): color = authoredColor
                case .reference(let reference, _):
                    path = reference.screenshotPath
                    color = path == nil ? LiveSelectionStyledMath.selectionColor : LiveSelectionStyledMath.screenshotColor
                }
                // Only whitespace BETWEEN actual tags is scaffolding. All source
                // angles are XML-escaped; never collapse whitespace inside <text>.
                let compact = canonical[offset].replacingOccurrences(
                    of: #">\s+<"#, with: "><", options: .regularExpression)
                if timeline.hasSuffix("\\)") {
                    timeline += previousColor == color ? LiveSelectionStyledMath.zeroWidthSpace : "\n\n"
                }
                timeline += LiveSelectionStyledMath.coloredXML(compact, color: color)
                previousColor = color
                if let path {
                    timeline += "\n\n" + LiveSelectionStyledMath.localImageReference(path: path) + "\n\n"
                }
            }
            // Keep a real paragraph boundary after the readable opening even
            // without an outer marker; each inner metadata tag remains italic.
            let opening = readablePreview.flatMap {
                AuthoredTextRainbow.render($0, startIndex: rainbowStartIndex,
                    maxUTF16Count: LiveSelectionStyledMath.messageUTF16Budget)
            }
            let candidate = opening.map { $0 + "\n\n" + timeline } ?? timeline
            if (readablePreview == nil || opening != nil),
               candidate.utf16.count <= LiveSelectionStyledMath.messageUTF16Budget {
                return candidate
            }
            // Fall back as one unit. Mixing raw XML with later math can recreate
            // the host's swallowed-colour bug; never clip words to buy styling.
            let plain = base.joined(separator: "\n\n")
            return readablePreview.map { $0 + beforeTimeline + plain } ?? plain
        }
        let previewSize = readablePreview.map { $0.utf16.count + beforeTimeline.utf16.count } ?? 0
        var remaining = LiveSelectionStyledMath.messageUTF16Budget
            - base.joined(separator: "\n\n").utf16.count - previewSize
        var opening = readablePreview
        if let readablePreview, remaining > 0 {
            // The opening alone is a per-word rainbow. Timeline sections use
            // fixed type colours, sharing this one content-first budget.
            // Colour must never crowd out authored words or source context.
            if let rainbow = AuthoredTextRainbow.render(readablePreview, startIndex: rainbowStartIndex,
                maxUTF16Count: readablePreview.utf16.count + remaining) {
                opening = rainbow
                remaining -= rainbow.utf16.count - readablePreview.utf16.count
            }
        }
        let output = parts.enumerated().map { offset, part -> String in
            guard remaining > 0 else { return base[offset] }
            let color: String
            var screenshotPath: String?
            switch part {
            case .text:
                return base[offset]
            case .authoredXML(_, let authoredColor):
                color = authoredColor
            case .reference(let reference, _):
                guard !reference.isTypedText else { return base[offset] }
                screenshotPath = reference.screenshotPath
                color = screenshotPath == nil ? LiveSelectionStyledMath.selectionColor : LiveSelectionStyledMath.screenshotColor
            }
            var colored = LiveSelectionStyledMath.coloredXML(canonical[offset], color: color)
            if let path = screenshotPath {
                colored += "\n\n" + LiveSelectionStyledMath.localImageReference(path: path)
            }
            let cost = colored.utf16.count - base[offset].utf16.count
            guard cost <= remaining else { return base[offset] }
            remaining -= cost
            return colored
        }
        let timeline = output.joined(separator: "\n\n")
        if let opening { return opening + beforeTimeline + timeline }
        return timeline
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

    private func xml(index: Int, hasDisplayCopy: Bool, separateContent: Bool = false) -> String {
        if let typedText { return typedText }
        // Emitted only when the preview paragraph directly above was included.
        let displayCopy = hasDisplayCopy ? " display_copy=\"above\"" : ""
        let timing = capturedAt.map { " captured_at=\"\(Self.timestamp($0))\"" } ?? ""
        if let screenshotPath {
            return "<local_screenshot path=\"\(Self.xmlEscaped(screenshotPath))\"\(timing)\(displayCopy)/>"
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
        attributes += timing + displayCopy
        // Separate metadata from the payload visibly without adding whitespace
        // inside <text>: source indentation and leading/trailing lines stay exact.
        let gap = separateContent ? "\n\n" : "\n"
        return "<\(tag) \(attributes)>" + gap
            + "  <text>\(Self.xmlEscaped(selectedText, attribute: false))</text>" + gap
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

    static func xmlEscaped(_ text: String, attribute: Bool = true) -> String {
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
        let escaped = xmlSafe.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Quotes/apostrophes are ordinary XML character data. Escape them only
        // in attributes: rendering &apos; in the prose made normal words harder
        // to read. Keep ampersands and angles escaped so quoted XML stays inert.
        guard attribute else { return escaped }
        return escaped
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
/// production uses reversible `coloredXML` for the fixed-colour XML timeline and
/// the authored rainbow opening, never the lossy preview sanitization.
/// XML entities protect unsupported/invisible scalars without deleting source data.
enum LiveSelectionStyledMath {
    /// Fixed colours identify context types; only the authored opening is rainbow.
    static let selectionColor = "#67e8f9"
    /// Screenshot XML is magenta, distinct from selected-text context.
    static let screenshotColor = "#e879f9"
    /// Authored XML uses bright cool silver speech and warmer silver typing.
    /// Keep these near-white for dark chat bubbles without changing type colours.
    static let speechColor = "#f1f5f9"
    static let potentialTTSColor = "#fbbf24"
    static let typedColor = "#f4f4f5"
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
        // Canonical payloads escape < and > before reaching presentation. Only
        // real tags/attributes are italic; even quoted XML remains upright text.
        var metadata = false
        var runs: [(String, Bool)] = []
        var current = ""
        for character in renderable {
            if character == "<" {
                if !current.isEmpty { runs.append((current, metadata)) }
                current = ""
                metadata = true
            }
            current.append(character)
            if character == ">", metadata {
                runs.append((current, true))
                current = ""
                metadata = false
            }
        }
        if !current.isEmpty { runs.append((current, metadata)) }
        return runs.map { text, italic in
            text.components(separatedBy: "\n").map { line in
                pieces(of: line).map { piece in
                    let escaped = escapedTeX(piece).replacingOccurrences(of: " ", with: "\\ ")
                    let body = italic ? "\\textit{\(escaped)}" : escaped
                    return "\\(\\textsf{\\color{\(color)}\(body)}\\)"
                }.joined(separator: zeroWidthSpace)
            }.joined(separator: "\n")
        }.reduce("") { output, run in
            output + (output.hasSuffix("\\)") && run.hasPrefix("\\(") ? zeroWidthSpace : "") + run
        }
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

/// Format captured context only for Codex, Telegram and Claude, the approved
/// per-app overrides. Ordinary apps (including Chrome) receive authored
/// speech/typing without links, XML or math. Use Primary's current app after the
/// queue wait and Next's saved app; the highlight source never owns this choice.
/// This is text formatting only, never input capture, focus or paste authority.
enum LiveContextPastePolicy {
    static func includesSourceContext(
        destination: RecordingPasteDestination,
        currentApplicationBundleIdentifier: String?,
        savedTargetBundleIdentifier: String?
    ) -> Bool {
        let recipient = destination.usesBaseCurrentInputDelivery
            ? currentApplicationBundleIdentifier : savedTargetBundleIdentifier
        guard let recipient else { return false }
        return recipient == "com.openai.codex"
            || AgentFlowPromptPreview.inlineContextRecipientBundleIdentifiers.contains(recipient)
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
    private let onCapture: (_ reference: LiveSelectionReference, _ precedesSpeech: Bool, _ spokenAnchor: String) -> Void
    private let onLabels: (_ captureID: UUID, _ reference: LiveSelectionReference) -> Void
    private let speechSnapshot: () -> String
    /// True between start() and stop(). Replaces this object's former private
    /// NSEvent monitor: edges now arrive from the shared watcher only while attached.
    private var isAttached = false
    private var attachedAt = Date.distantFuture
    private var mouseDownPoint: NSPoint?
    private var mouseDownDate: Date?
    private var mouseDownCallbackLag: Int?
    private var mouseDownExtendsSelection = false
    private var captureTask: Task<Void, Never>?
    private var screenshotSource: DispatchSourceFileSystemObject?
    private var screenshotDirectory: URL?
    private var screenshotBaseline: Set<String> = []
    private var screenshotStart = Date.distantFuture
    private var screenshotScanTask: Task<Void, Never>?

    init(speechSnapshot: @escaping () -> String,
         onCapture: @escaping (_ reference: LiveSelectionReference, _ precedesSpeech: Bool, _ spokenAnchor: String) -> Void,
         onLabels: @escaping (_ captureID: UUID, _ reference: LiveSelectionReference) -> Void) {
        self.speechSnapshot = speechSnapshot
        self.onCapture = onCapture
        self.onLabels = onLabels
    }

    func start(activationTime: Date = Date()) {
        guard !isAttached else { return }
        isAttached = true
        attachedAt = Date()
        let watcher = SelectionGestureWatcher.shared
        watcher.start()
        watcher.resetKeyboardGesture()
        // A drag that began before capture attached (during microphone start-up,
        // or just before the start press) finishes normally during recording.
        // Before build 349 its mouse-down was never seen, so the gesture failed.
        let dragInProgress = SelectionGestureWatcher.adoptablePendingDown(
            watcher.pendingMouseDown, now: attachedAt
        )
        if let down = dragInProgress {
            mouseDownPoint = down.location
            mouseDownDate = down.occurredAt
            mouseDownCallbackLag = down.callbackLagMilliseconds
            mouseDownExtendsSelection = down.extendsSelection
        }
        watcher.listener = self
        startScreenshotWatch(activationTime: activationTime)
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
            SelectionGestureWatcher.shared.resetKeyboardGesture()
        }
        isAttached = false
        attachedAt = .distantFuture
        captureTask?.cancel()
        captureTask = nil
        mouseDownPoint = nil
        mouseDownDate = nil
        mouseDownCallbackLag = nil
        mouseDownExtendsSelection = false
        screenshotScanTask?.cancel()
        screenshotScanTask = nil
        screenshotSource?.cancel()
        screenshotSource = nil
        screenshotDirectory = nil
        screenshotBaseline.removeAll()
        screenshotStart = .distantFuture
    }

    private func startScreenshotWatch(activationTime: Date) {
        let directory = Self.screenshotDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        screenshotDirectory = directory
        // Keep the native screenshot event time, not the later mic/AX handshake,
        // as the two-second boundary. Never enumerate Desktop on MainActor while
        // the newly requested recorder panel is trying to render.
        screenshotStart = activationTime
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
        scheduleScreenshotScan()
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
            // Search immediately for a screenshot saved just before Start, then
            // retry boundedly for a save whose metadata is still being written.
            for delay in [0, 250_000_000, 750_000_000, 1_500_000_000] as [UInt64] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self,
                      self.isAttached, let directory = self.screenshotDirectory else { return }
                let activationTime = self.screenshotStart
                let found = await Task.detached(priority: .utility) {
                    Self.findNativeScreenshots(in: directory, activatedAt: activationTime)
                }.value
                guard !Task.isCancelled, self.isAttached,
                      self.screenshotDirectory == directory else { return }
                for (url, created) in found {
                    guard self.screenshotBaseline.insert(url.lastPathComponent).inserted,
                          let reference = LiveSelectionReference(screenshotURL: url) else { continue }
                    self.onCapture(reference.timed(at: created), created < activationTime,
                                   created < activationTime ? "" : self.speechSnapshot())
                }
            }
        }
    }

    nonisolated static func findNativeScreenshots(in directory: URL, activatedAt: Date) -> [(URL, Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let cutoff = activatedAt.addingTimeInterval(-2)
        return names.compactMap { name -> (URL, Date)? in
            let url = directory.appendingPathComponent(name)
            guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created >= cutoff,
                  Self.isNativeScreenshot(url, since: cutoff.addingTimeInterval(1)) else { return nil }
            return (url, created)
        }.sorted { first, second in
            first.1 == second.1 ? first.0.lastPathComponent < second.0.lastPathComponent
                : first.1 < second.1
        }
    }

    nonisolated static func isNativeScreenshot(_ url: URL, since start: Date) -> Bool {
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

    nonisolated static func isScreenshotMarker(_ data: Data) -> Bool {
        let value = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return (value as? NSNumber)?.boolValue == true
    }

    /// A fresh key-down cancels a pending older read before it can borrow the
    /// range changed by typing or another keyboard selection.
    func selectionWillChange() {
        captureTask?.cancel()
    }

    func handle(_ gesture: SelectionGestureWatcher.KeyboardGesture) {
        guard isAttached, Self.isFrontmost(gesture.processIdentifier),
              let app = NSRunningApplication(processIdentifier: gesture.processIdentifier) else { return }
        // Keyboard selection has no pointer endpoints. Read only the focused
        // public range, never fabricate a drag from the idle mouse position.
        beginSelectionRead(from: .zero, to: .zero, gestureStartedAt: gesture.startedAt,
            selectedAt: gesture.endedAt, app: app, precedesSpeech: false, hasGesture: false,
            bridgeInputKind: gesture.inputKind.rawValue, bridgeInputDirection: gesture.inputDirection)
    }

    func handle(_ edge: MouseEdge, sourcePID: pid_t?) {
        guard isAttached else { return }
        switch edge.type {
        case .leftMouseDown:
            // A second gesture must not let an older in-flight read borrow its
            // newer selection before the next mouse-up cancels that task.
            captureTask?.cancel()
            mouseDownPoint = edge.location
            mouseDownDate = edge.occurredAt
            mouseDownCallbackLag = edge.callbackLagMilliseconds
            mouseDownExtendsSelection = edge.extendsSelection
        case .leftMouseUp:
            let endPoint = edge.location
            let startPoint = mouseDownPoint
            let gestureStartedAt = mouseDownDate ?? edge.occurredAt
            let callbackLag = SelectionGestureWatcher.combinedCallbackLag(
                mouseDownCallbackLag, edge.callbackLagMilliseconds)
            let extendsSelection = mouseDownExtendsSelection
            mouseDownPoint = nil
            mouseDownDate = nil
            mouseDownCallbackLag = nil
            mouseDownExtendsSelection = false
            let disposition = Self.selectionGestureDisposition(
                startPoint: startPoint, endPoint: endPoint, clickCount: edge.clickCount,
                sourcePID: sourcePID, ownPID: ProcessInfo.processInfo.processIdentifier,
                extendsSelection: extendsSelection
            )
            LiveSelectionDiagnostics.gesture(
                outcome: disposition, clickCount: edge.clickCount,
                callbackLagMilliseconds: SelectionGestureWatcher.callbackLagMilliseconds(
                    occurredAt: edge.occurredAt, now: Date()
                )
            )
            guard disposition == "read", let startPoint, let sourcePID,
                  let app = NSRunningApplication(processIdentifier: sourcePID) else {
                return
            }
            beginSelectionRead(
                from: startPoint, to: endPoint, gestureStartedAt: gestureStartedAt, selectedAt: edge.occurredAt,
                app: app, precedesSpeech: false, clickCount: edge.clickCount,
                callbackLagMilliseconds: callbackLag,
                hasGesture: Self.usesPointerGeometry(from: startPoint, to: endPoint,
                    clickCount: edge.clickCount, extendsSelection: extendsSelection),
                bridgeInputKind: extendsSelection ? "mouse" : nil
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
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let gesture, SelectionGestureWatcher.isEligiblePriorGesture(
                  gesture, now: Date(), captureStartedAt: attachedAt,
                  frontmostPID: app.processIdentifier
              ) {
            beginSelectionRead(
                from: gesture.start, to: gesture.end, gestureStartedAt: gesture.startedAt, selectedAt: gesture.endedAt,
                app: app, precedesSpeech: true, clickCount: gesture.clickCount,
                callbackLagMilliseconds: gesture.callbackLagMilliseconds,
                hasGesture: Self.usesPointerGeometry(from: gesture.start, to: gesture.end,
                    clickCount: gesture.clickCount, extendsSelection: gesture.extendsSelection),
                bridgeInputKind: gesture.extendsSelection ? "mouse" : nil
            )
        } else {
            // A keyboard highlight or one predating the watcher has no mouse
            // history. Read the current app's focused AX selection once, without
            // inventing gesture geometry from the pointer's unrelated location.
            // This records observation time, not a fabricated mouse-up time.
            let point = NSEvent.mouseLocation
            beginSelectionRead(from: point, to: point, gestureStartedAt: attachedAt,
                               selectedAt: attachedAt, app: app, precedesSpeech: true,
                               hasGesture: false)
        }
    }

    /// Shared by live mouse-ups and the one prior-highlight read. A newer
    /// mouse-down or stop cancels an in-flight read so it cannot borrow a newer
    /// selection.
    private func beginSelectionRead(
        from startPoint: NSPoint,
        to endPoint: NSPoint,
        gestureStartedAt: Date,
        selectedAt: Date,
        app: NSRunningApplication,
        precedesSpeech: Bool,
        clickCount: Int = 1,
        callbackLagMilliseconds: Int? = nil,
        hasGesture: Bool = true,
        bridgeInputKind: String? = nil,
        bridgeInputDirection: String? = nil
    ) {
        // A drag can activate an app that was backgrounded at mouse-down.
        // Bind to the frontmost app sampled synchronously at mouse-up and its
        // visible source window, never a reconstructed event's recipient PID.
        // Later background AX reads additionally need selection-range geometry;
        // APIs without that proof retain their foreground-only restriction.
        let sourcePID = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let spokenAnchor = precedesSpeech ? "" : speechSnapshot()
        let gesture = hasGesture ? LiveSelectionGesture.fromCocoa(
            mouseDown: startPoint,
            mouseUp: endPoint,
            screenFrames: NSScreen.screens.map(\.frame),
            clickCount: clickCount, callbackLagMilliseconds: callbackLagMilliseconds
        ) : nil
        let identity = LiveSelectionReadIdentity(processIdentifier: sourcePID, gesture: gesture,
                                                 windows: LiveSelectionWindow.onScreen())
        let isCodex = CodexConversationContextReader.isSupportedCodexApplication(
            app, fileManager: .default
        )
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            async let beforeLabels: [String] = isCodex
                ? CodexConversationContextReader.selectionThreadIDs(processIdentifier: sourcePID) : []
            let startedAt = DispatchTime.now().uptimeNanoseconds
            var outcome = "canceled-by-new-gesture-or-stop"
            defer {
                LiveSelectionDiagnostics.finished(
                    outcome: outcome, bundleID: bundleID, startedAt: startedAt
                )
            }
            // The target app finishes its own mouse-up selection update before
            // this read. A newer gesture or stop cancels the pending read.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            guard Self.canRead(identity) else {
                outcome = "source-changed-before-read"
                return
            }
            // Chrome's DOM override has no selection geometry of its own.
            // If the gesture was visibly outside Chrome's windows, do not
            // borrow an older selection from its active tab.
            if bundleID == "com.google.Chrome",
               !LiveSelectionBrowserScriptReader.mayReadForGesture(
                   gesture, processIdentifier: sourcePID,
                   windows: LiveSelectionWindow.onScreen()
               ) {
                outcome = "gesture-outside-source-window"
                return
            }
            let chromeContext = bundleID == "com.google.Chrome" && Self.isFrontmost(sourcePID)
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
                    identity: identity,
                    bundleID: bundleID,
                    gesture: gesture,
                    gestureStartedAt: gestureStartedAt,
                    bridgeInputKind: bridgeInputKind,
                    bridgeInputDirection: bridgeInputDirection,
                    startedAt: startedAt
                )
            }
            guard !Task.isCancelled else { return }
            guard Self.canRead(identity) else {
                outcome = "source-changed-during-read"
                return
            }
            guard let text = selectedText, let reference = LiveSelectionReference(text) else {
                outcome = "selection-unavailable"
                return
            }
            guard let self, self.isAttached else { return }
            let captureID = UUID()
            let captured = isCodex ? reference : reference.scopedToApplication(
                name: app.localizedName, bundleID: app.bundleIdentifier
            ).scopedToChrome(chromeContext)
            // Commit proven text before optional labels. A new click can cancel
            // metadata work, but must not erase an already-read highlight or
            // move it after newer speech/context while a log scan finishes.
            self.onCapture(captured.timed(at: selectedAt).identifiedForCapture(captureID),
                           precedesSpeech, spokenAnchor)
            outcome = "emitted-to-session"
            guard isCodex else { return }
            let labeled: LiveSelectionReference
            if isCodex {
                // Only the verified Codex app may add a task label. A task
                // switch during selection leaves the existing plain tag.
                let threadsBefore = await beforeLabels
                let threadsAfter = await CodexConversationContextReader.selectionThreadIDs(processIdentifier: sourcePID)
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
            guard !Task.isCancelled else { return }
            guard Self.canRead(identity) else {
                outcome = "emitted-without-labels-source-changed"
                return
            }
            guard self.isAttached else { return }
            self.onLabels(captureID, labeled)
        }
    }

    /// Generic tiers after Chrome's override: app-scoped Accessibility (with one
    /// bounded settle re-read, plus two late Codex/ChatGPT retries), then Safari/Edge
    /// read-only scripting. Every attempt revalidates the source window; a
    /// background source additionally needs gesture-bounded AX evidence.
    private static func readSelectedText(
        sourcePID: pid_t,
        identity: LiveSelectionReadIdentity,
        bundleID: String?,
        gesture: LiveSelectionGesture?,
        gestureStartedAt: Date,
        bridgeInputKind: String?,
        bridgeInputDirection: String?,
        startedAt: UInt64
    ) async -> String? {
        // VS Code's default Monaco editor intentionally exposes no AX text.
        // Better Git proves a matching mouse, keyboard-extension or Select All
        // selection in the focused editor. A stationary Shift-click's range
        // starts at the prior caret, so it uses focused-only reading. Real
        // Shift-drags keep the existing window and range-geometry safeguards;
        // ask only during capture, never enable screen-reader mode or copy.
        if isFrontmost(sourcePID), VSCodeSelectionBridge.supports(bundleID),
           (gesture == nil ? bridgeInputKind != nil :
               gesture?.touchesWindow(ownedBy: sourcePID, in: LiveSelectionWindow.onScreen()) == true),
           let text = await VSCodeSelectionBridge.read(sourcePID: sourcePID,
               gestureStartedAt: gestureStartedAt, inputKind: bridgeInputKind,
               inputDirection: bridgeInputDirection) {
            LiveSelectionDiagnostics.captured(
                tier: .vscodeBridge, source: nil, evidence: .atGesture, attempt: 1,
                bundleID: bundleID, startedAt: startedAt
            )
            return text
        }
        var last = LiveSelectionResolution()
        var attempts = 0
        for delay in LiveSelectionReadPolicy.accessibilityRetryDelays(for: bundleID) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, canRead(identity) else {
                return nil
            }
            attempts += 1
            last = await LiveSelectionTextReader.resolveAccessibility(
                processIdentifier: sourcePID, gesture: gesture,
                requiresGestureBounds: !isFrontmost(sourcePID),
                checksDragSpan: bundleID == "com.openai.codex",
                sourceWindowBounds: identity.window?.bounds
            )
            if let candidate = last.candidate,
               isFrontmost(sourcePID) || candidate.evidence == .atGesture {
                LiveSelectionDiagnostics.captured(
                    tier: candidate.tier, source: candidate.source,
                    evidence: candidate.evidence, attempt: attempts,
                    bundleID: bundleID, startedAt: startedAt,
                    span: candidate.spanEvidence, length: candidate.text.utf16.count,
                    observedOverextended: last.observedOverextended,
                    preventedWidening: last.preventedWidening,
                    acceptedMarkerExpansion: last.acceptedMarkerExpansion,
                    clickCount: gesture?.clickCount,
                    callbackLagMilliseconds: gesture?.callbackLagMilliseconds
                )
                return candidate.text
            }
            // Without Accessibility trust a re-read cannot succeed.
            if !last.accessibilityTrusted { break }
        }

        guard !Task.isCancelled, canRead(identity), isFrontmost(sourcePID) else {
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

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func canRead(_ identity: LiveSelectionReadIdentity) -> Bool {
        identity.isValid(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                         windows: LiveSelectionWindow.onScreen())
    }

    /// Counts-only rejection before any Accessibility read. Preserve the drag
    /// threshold; frozen Shift adds the stationary caret-to-click extension.
    static func selectionGestureDisposition(
        startPoint: NSPoint?, endPoint: NSPoint, clickCount: Int,
        sourcePID: pid_t?, ownPID: pid_t, extendsSelection: Bool = false
    ) -> String {
        guard let startPoint else { return "no-mouse-down" }
        guard isSelectionGesture(from: startPoint, to: endPoint, clickCount: clickCount,
                                 extendsSelection: extendsSelection) else {
            return "not-selection-shaped"
        }
        guard let sourcePID, sourcePID > 0, sourcePID != ownPID else { return "no-source" }
        return "read"
    }

    static func isSelectionGesture(
        from start: NSPoint,
        to end: NSPoint,
        clickCount: Int,
        extendsSelection: Bool = false
    ) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return extendsSelection || clickCount >= 2 || dx * dx + dy * dy >= 16
    }

    static func usesPointerGeometry(from start: NSPoint, to end: NSPoint,
                                    clickCount: Int, extendsSelection: Bool) -> Bool {
        // Only the new stationary extension lacks mouse-range evidence. Do not
        // remove established pointer/window checks from an existing Shift-drag.
        !extendsSelection || isSelectionGesture(from: start, to: end, clickCount: clickCount)
    }

    static func hasStableSource(expectedPID: pid_t?, currentPID: pid_t?) -> Bool {
        guard let expectedPID, let currentPID else { return false }
        return expectedPID > 0 && expectedPID == currentPID
    }
}
