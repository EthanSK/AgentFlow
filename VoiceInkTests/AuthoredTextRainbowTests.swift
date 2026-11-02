import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct AuthoredTextRainbowTests {
    @Test func oneAppCursorContinuesAcrossFinalOutputsWithoutDiskState() {
        let cursor = AuthoredTextRainbow.Cursor()
        #expect(cursor.reserve(wordCount: 23) == 0)
        #expect(cursor.reserve(wordCount: 3) == 23)
        #expect(cursor.reserve(wordCount: 0) == 2)
        #expect(cursor.reserve(wordCount: 1) == 2)
    }

    @Test func rainbowUsesTheSharedPalettePerWordAndWrapsTheOffset() throws {
        #expect(AuthoredTextRainbow.palette == [
            "#fa7070", "#fa9370", "#fab570", "#fad870", "#fafa70", "#d8fa70",
            "#b5fa70", "#93fa70", "#70fa70", "#70fa93", "#70fab5", "#70fad8",
            "#70fafa", "#70d8fa", "#70b5fa", "#7093fa", "#7070fa", "#9370fa",
            "#b570fa", "#d870fa", "#fa70fa", "#fa70d8", "#fa70b5", "#fa7093"
        ])
        let expected = "\\(\\textsf{\\color{#fa7093}One}\\) \\(\\textsf{\\color{#fa7070}two}\\) \\(\\textsf{\\color{#fa9370}three}\\)"
        #expect(AuthoredTextRainbow.render("One two three", startIndex: 23) == expected)
        #expect(AuthoredTextRainbow.render("One two three", startIndex: -1) == expected)
        let long = String(repeating: "W", count: 30)
        let rendered = try #require(AuthoredTextRainbow.render(long + " next", startIndex: 4))
        #expect(rendered.components(separatedBy: "#fafa70").count == 4)
        #expect(rendered.hasSuffix("\\(\\textsf{\\color{#d8fa70}next}\\)"))
        #expect(AuthoredTextRainbow.render(String(repeating: "word ", count: 20_000), startIndex: 0, maxUTF16Count: 100) == nil)
    }

    @Test func renderingACopyDoesNotAdvanceTheFinalOutputCursor() {
        let cursor = AuthoredTextRainbow.Cursor()
        let start = cursor.reserve(wordCount: 3)
        let first = AuthoredTextRainbow.render("one two three", startIndex: start)
        #expect(first == AuthoredTextRainbow.render("one two three", startIndex: start))
        #expect(cursor.reserve(wordCount: 1) == 3)
    }

    @Test func finalRainbowReservationReusesArchiveOffsetWithoutRecipientReads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"), encoding: .utf8)
        let colors = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/AuthoredTextRainbow.swift"), encoding: .utf8)
        #expect(!source.contains("AuthoredTextRainbow.reserve"))
        #expect(source.contains("let rainbowStart = archivedRainbowStartIndex"))
        #expect(source.contains("rainbowStartIndex: rainbowStart"))
        #expect(!colors.contains("FileManager") && !colors.contains("chatID") && !colors.contains("processIdentifier"))
        #expect(!colors.contains("response-preferences/"))
    }
}
