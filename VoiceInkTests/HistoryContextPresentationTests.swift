import AppKit
import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct HistoryContextPresentationTests {
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
        #expect(inline.contains("CopyIconButton(textToCopy: displayText)"))
        #expect(detail.contains("CopyIconButton(textToCopy: text)"))
        #expect(inline.contains("Text(draft)"))
    }

    @MainActor @Test func nativeAttributesCarryColorsAndItalicMetadata() {
        let parsed = HistoryContextPresentation.document(#"\(\textsf{\color{#67e8f9}\textit{<text>}}\) \(\textsf{\color{#67e8f9}words}\)"#)
        let rendered = NSAttributedString(HistoryContextPresentation.attributed(parsed, fontSize: 14, foreground: .primary))
        #expect(rendered.string == "<text> words")
        let metadata = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let payload = rendered.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(metadata.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        #expect(payload.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == false)
        let color = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(abs((color?.redComponent ?? 0) - 103.0 / 255) < 0.001)
    }
}
