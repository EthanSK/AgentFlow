import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

struct HistoryContextPresentationTests {
    @Test func copyActionUsesFullFormattingLabelAndContentSizedWidth() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let presentation = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/HistoryContextPresentation.swift"), encoding: .utf8)
        let button = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/Common/CopyIconButton.swift"), encoding: .utf8)
        #expect(presentation.contains("title: showsFormattingTitle ? \"Copy with flow markers\" : nil"))
        #expect(presentation.contains("accessibilityTitle: \"Copy with flow markers\""))
        #expect(presentation.contains("systemImage: \"doc.on.doc\""))
        #expect(!presentation.contains("systemImage: \"textformat\""))
        #expect(!presentation.contains("Copy with LaTeX"))
        #expect(!presentation.contains("LiveSelectionStyledMath.coloredXML"))
        #expect(button.contains("title == nil ? 28 : nil"))
        #expect(!button.contains("title == nil ? 28 : 142"))
    }

    @Test func retainedFlowTimelineIsTheMainHistoryMessage() {
        let xml = "<speech start_at=\"1\">\n\nEarlier words\n\n</speech>\n"
            + "<app_selection source=\"test\"><text>Quoted context</text></app_selection>"
        let row = Transcription(text: "Final corrected words and tail", duration: 1,
            realtimeDraftText: xml, transcriptionStatus: .completed)
        let message = HistoryContextPresentation.message(for: row)
        #expect(message.text == xml)
        #expect(message.hasFlowMarkers)
        #expect(message.rawText == "Final corrected words and tail")
        #expect(HistoryContextPresentation.copyText(message.text, format: .formatted) == xml)
        #expect(row.text == "Final corrected words and tail" && row.realtimeDraftText == xml)
    }

    @Test func finalFlowOutranksTheLiveDraftAndPlainEntriesStaySingle() {
        let xml = "<speech timing=\"approximate\">Final &amp; complete</speech>"
        let row = Transcription(text: xml, duration: 1, enhancedText: "Enhanced answer",
            realtimeDraftText: "<speech>Earlier partial</speech>", transcriptionStatus: .completed)
        let message = HistoryContextPresentation.message(for: row)
        #expect(message.text == xml && message.rawText == "Final & complete")
        let enhanced = HistoryContextPresentation.message(for: row, enhanced: true)
        #expect(enhanced.text == "Enhanced answer" && !enhanced.hasFlowMarkers)
        let plain = Transcription(text: "Plain words", duration: 0, realtimeDraftText: "Earlier")
        let plainMessage = HistoryContextPresentation.message(for: plain)
        #expect(plainMessage.text == "Plain words" && !plainMessage.hasFlowMarkers)
    }

    @Test func everyHistorySurfaceUsesTheSameFlowProjectionWithoutDuplicateDrafts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["InlineHistoryView.swift", "TranscriptionListItem.swift", "TranscriptionDetailView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/" + file), encoding: .utf8)
            #expect(source.contains("HistoryContextPresentation.message(for:"))
            #expect(!source.contains("HistoryRecoveredCodexView(text:"))
            #expect(!source.contains("text: draft"))
        }
    }

    @Test func historyPreviewsOwnAFullWidthRowBelowHeaderActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/InlineHistoryView.swift"), encoding: .utf8)
        let header = try #require(card.range(of: "private var header: some View"))
        let expanded = try #require(card.range(of: "// MARK: - Expanded Content", range: header.upperBound..<card.endIndex))
        let headerBody = card[header.lowerBound..<expanded.lowerBound]
        #expect(headerBody.contains("HistoryAudioRetryButton"))
        #expect(headerBody.contains("HistoryCopyButtons"))
        #expect(!headerBody.contains("listPreview("))
        #expect(card.contains(".frame(maxWidth: .infinity, alignment: .leading)\n                        .contentShape(Rectangle())"))
        let list = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/TranscriptionListItem.swift"), encoding: .utf8)
        let actions = try #require(list.range(of: "HistoryCopyButtons"))
        let preview = try #require(list.range(of: "Text(HistoryContextPresentation.listPreview"))
        #expect(actions.lowerBound < preview.lowerBound)
        #expect(list.contains("VStack(alignment: .leading, spacing: 4)"))
        #expect(list.contains(".frame(maxWidth: .infinity, alignment: .leading)\n                .accessibilityIdentifier(\"history-list-preview-"))
    }

    @Test func listPreviewRemovesOnlyPresentationAndDuplicateTimeline() {
        let source = #"\(\textsf{\color{#70fad8}Read}\) \(\textsf{\color{#70fafa}this}\)"#
            + "\n\n" + #"\(\textsf{\color{#94a3b8}\textit{<agent\_flow\_context\ preview="authored\_text\_above">}}\)"#
            + "\n\n<speech>Read this</speech></agent_flow_context>"
        #expect(HistoryContextPresentation.listPreview(source) == "Read this")
        #expect(source.contains("\\textsf"))
    }

    @Test func currentAndLegacyMetadataRenderWithUprightPayload() {
        let source = #"\(\textsf{\color{#f1f5f9}\textit{<speech\ start\_at="123.000">}}\)"#
            + "\n\n" + #"\(\textsf{\color{#f1f5f9}My\ exact\ words}\)"#
            + "\n\n" + #"\(\textsf{\color{#f1f5f9}\textit{</speech>}}\)"#
        let parsed = HistoryContextPresentation.document(source)
        #expect(parsed.hasFormatting)
        #expect(parsed.plainText == "<speech start_at=\"123.000\">\n\nMy exact words\n\n</speech>")
        #expect(parsed.runs.filter(\.italic).map(\.text) == ["<speech start_at=\"123.000\">", "</speech>"])
        #expect(parsed.runs.first(where: { $0.text == "My exact words" })?.italic == false)
        let legacy = HistoryContextPresentation.document(#"\(\textsf{\color{#67e8f9}<app\_selection>}\)"#)
        #expect(legacy.plainText == "<app_selection>")
        #expect(legacy.runs[0].colorHex == "#67e8f9")
        #expect(!legacy.runs[0].italic)
    }

    @Test func escapesAndAdjacentChunksPreserveExactVisibleText() {
        // Two raw-string delimiters preserve the literal TeX \# escape.
        let source = ##"\(\textsf{\color{#67e8f9}\textbackslash{}\_\&\%\#\$\{\}{[}{]}\textasciicircum{}\textasciitilde{}}\)"##
            + "\u{200B}" + #"\(\textsf{\color{#67e8f9}more}\)"#
        #expect(HistoryContextPresentation.document(source).plainText == "\\_&%#${}[]^~more")
        #expect(HistoryContextPresentation.document("plain\u{200B}text").plainText == "plain\u{200B}text")
    }

    @Test func unsupportedCommandsAndOrdinaryMathStayLiteral() {
        let values = [#"The expression \(x^2\) is literal source."#,
                      #"\(\textsf{\color{#67e8f9}\input{secret}}\)"#,
                      #"\(\textsf{\color{red}words}\)"#,
                      #"\(\textsf{\color{#67e8f9}unfinished"#]
        for value in values {
            let parsed = HistoryContextPresentation.document(value)
            #expect(parsed.plainText == value)
            #expect(!parsed.hasFormatting)
        }
    }

    @Test func plainHistoryAndRecoveryDraftsAreUnchanged() {
        let text = "Transcription Failed: The API returned an empty or invalid response."
        #expect(HistoryContextPresentation.listPreview(text) == text)
        let row = Transcription(text: "", duration: 0, realtimeDraftText: "recovered words")
        #expect(HistoryContextPresentation.listPreview(row.historyDisplayText) == "recovered words")
        #expect(row.realtimeDraftText == "recovered words")
        #expect(row.text.isEmpty)
    }

    @Test func recoveredWordsHaveCopyableCodexXMLWithoutInventedContext() {
        let recovered = Transcription(
            text: "Last live <words> & more",
            duration: 0,
            realtimeDraftText: "Last live <words> & more",
            transcriptionStatus: .recoveredAfterInterruption
        )
        let xml = HistoryContextPresentation.recoveredCodexText(for: recovered)
        #expect(xml == "<speech timing=\"unavailable\">\n\nLast live &lt;words&gt; &amp; more\n\n</speech>")
        #expect(recovered.text == "Last live <words> & more")
        #expect(!xml!.contains("<selection"))
        #expect(!xml!.contains("<screenshot"))

        let replayOnly = Transcription(text: "Replay this audio", duration: 0,
                                       transcriptionStatus: .recoveredAfterInterruption)
        #expect(HistoryContextPresentation.recoveredCodexText(for: replayOnly) == nil)
        let completed = Transcription(text: "Last live <words> & more", duration: 0,
                                      realtimeDraftText: "Last live <words> & more",
                                      transcriptionStatus: .completed)
        #expect(HistoryContextPresentation.recoveredCodexText(for: completed) == nil)
    }

    @Test func presentationDoesNotRewriteStoredOrCopiedText() throws {
        let text = #"\(\textsf{\color{#fa70b5}Original}\)"#
        let row = Transcription(text: text, duration: 0)
        _ = HistoryContextPresentation.listPreview(row.historyDisplayText)
        _ = HistoryContextPresentation.document(row.historyDisplayText)
        #expect(row.text == text)
        #expect(row.historyDisplayText == text)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let inline = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/InlineHistoryView.swift"), encoding: .utf8)
        let detail = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/History/TranscriptionDetailView.swift"), encoding: .utf8)
        #expect(inline.contains("HistoryCopyButtons(text: displayText"))
        #expect(detail.contains("HistoryCopyButtons(text: text)"))
        #expect(inline.contains("Text(draft)"))
    }

    @Test func copyChoicesPreserveWholeContextWithoutRewritingHistory() {
        let plain = "<speech start_at=\"123\">\nEvery word &amp; symbol 👋\n</speech>\n"
            + "<app_selection><text>" + String(repeating: "full context ", count: 2000) + "</text></app_selection>"
        let styled = LiveSelectionStyledMath.coloredXML(plain, color: LiveSelectionStyledMath.selectionColor)
        let row = Transcription(text: styled, duration: 0)
        #expect(HistoryContextPresentation.copyText(styled, format: .plain) == "Every word & symbol 👋")
        #expect(HistoryContextPresentation.copyText(styled, format: .formatted) == plain)
        #expect(HistoryContextPresentation.copyText(plain, format: .plain) == "Every word & symbol 👋")
        #expect(HistoryContextPresentation.copyText(plain, format: .formatted) == plain)
        #expect(row.text == styled && row.historyDisplayText == styled)
        // Native display colour is not stored markup. Copy must not synthesize
        // LaTeX even when the renderer recognises overlap XML.
        let overlap = "<potential_tts start_at=\"123\">Retained draft</potential_tts>"
        #expect(HistoryContextPresentation.copyText(overlap, format: .plain) == "Retained draft")
        #expect(HistoryContextPresentation.copyText(overlap, format: .formatted) == overlap)
    }

    @Test func normalCopyDoesNotInterpretUserMathOrMalformedFormatting() {
        for source in [#"Keep \(x^2\) and \input{private} literal."#,
                       #"\(\textsf{\color{#67e8f9}unfinished"#, "\t  unstyled\n\nending\n"] {
            #expect(HistoryContextPresentation.copyText(source, format: .plain) == source)
            #expect(HistoryContextPresentation.copyText(source, format: .formatted) == source)
        }
    }

    @MainActor @Test func nativeHistoryIgnoresRetiredColorsAndItalicMetadata() {
        let parsed = HistoryContextPresentation.document(#"\(\textsf{\color{#67e8f9}\textit{<text>}}\) \(\textsf{\color{#67e8f9}words}\)"#)
        let rendered = NSAttributedString(HistoryContextPresentation.attributed(parsed, fontSize: 14, foreground: .gray))
        #expect(rendered.string == "<text> words")
        let metadata = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let payload = rendered.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(metadata.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == false)
        #expect(payload.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == false)
        let color = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor(Color.gray))
        #expect(rendered.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == color)
    }

    @MainActor @Test func neutralHistoryRetainsEveryLegacyWordAndContextByte() {
        let source = LiveSelectionStyledMath.coloredXML("Every word 👋\n<speech>XML & symbols</speech>",
            color: "#fa7070")
        let row = Transcription(text: source, duration: 0)
        let parsed = HistoryContextPresentation.document(source)
        let rendered = NSAttributedString(HistoryContextPresentation.attributed(parsed, fontSize: 14, foreground: .primary))
        #expect(rendered.string == "Every word 👋\n<speech>XML & symbols</speech>")
        #expect(row.text == source)
        #expect(HistoryContextPresentation.copyText(source, format: .formatted) == rendered.string)
        // This legacy fixture is not valid XML (literal ampersand). Preserve it
        // as readable text rather than silently dropping an unparsed fragment.
        #expect(HistoryContextPresentation.copyText(source, format: .plain) == rendered.string)
    }

    @Test func legacyFormattedCopyMatchesVisibleCompleteXMLAndRawCopyExcludesContext() {
        let xml = "First request\n\n<speech start_at=\"1\">First request</speech>\n\n"
            + "<app_selection source=\"Code\"><text>not authored &amp; not omitted</text></app_selection>\n\n"
            + "<typed_text start_at=\"2\">  then typed  </typed_text>\n\n"
            + "<local_screenshot path=\"/private/example.png\"/>"
        let legacy = LiveSelectionStyledMath.coloredXML(xml, color: "#fa7070")
        let stored = Transcription(text: legacy, duration: 0)
        #expect(HistoryContextPresentation.copyText(legacy, format: .formatted) == xml)
        // The opening here is not a duplicate of the complete authored request,
        // so it must remain rather than guessing away potentially distinct prose.
        #expect(HistoryContextPresentation.copyText(legacy, format: .plain) == "First request\n\nFirst request\n\n  then typed  ")
        #expect(stored.text == legacy)
        let duplicate = "one two\n\n<speech>one</speech>\n\n<typed_text>two</typed_text>"
        #expect(HistoryContextPresentation.copyText(duplicate, format: .plain) == "one\n\ntwo")
    }

    @Test func rawCopyHandlesLegacyEnvelopeAndAdjacentSpeechWithoutEditingFullCopy() {
        let source = "one two\n\n<agent_flow_context preview=\"authored_text_above\">\n\n"
            + "<speech>one</speech><speech>two</speech>\n\n</agent_flow_context>"
        #expect(HistoryContextPresentation.copyText(source, format: .plain) == "one\n\ntwo")
        #expect(HistoryContextPresentation.copyText(source, format: .formatted) == source)
        let selectedOnly = "<app_selection><text>not dictated</text></app_selection>"
        #expect(HistoryContextPresentation.copyText(selectedOnly, format: .plain).isEmpty)
        #expect(HistoryContextPresentation.copyText(selectedOnly, format: .formatted) == selectedOnly)
    }
}
