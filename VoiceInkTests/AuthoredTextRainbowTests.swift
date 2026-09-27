import Darwin
import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct AuthoredTextRainbowTests {
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

    @Test func rainbowCounterMatchesPythonLockAndAtomicStateProtocol() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("rainbow-next-index.txt")
        #expect(AuthoredTextRainbow.reserve(at: state) == 0)
        #expect(try String(contentsOf: state, encoding: .utf8) == "1\n")
        try Data("23\n".utf8).write(to: state)
        #expect(AuthoredTextRainbow.reserve(at: state) == 23)
        #expect(try String(contentsOf: state, encoding: .utf8) == "0\n")

        let lock = directory.appendingPathComponent("rainbow-next-index.lock")
        let descriptor = Darwin.open(lock.path, O_RDWR)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        #expect(Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let started = Date()
        #expect(AuthoredTextRainbow.reserve(at: state) == nil)
        #expect(Date().timeIntervalSince(started) < 0.2)
        #expect(try String(contentsOf: state, encoding: .utf8) == "0\n")
        #expect(Darwin.flock(descriptor, LOCK_UN) == 0)
        #expect(AuthoredTextRainbow.reserve(at: state) == 0)

        try Data("not an index\n".utf8).write(to: state)
        #expect(AuthoredTextRainbow.reserve(at: state) == nil)
        #expect(try String(contentsOf: state, encoding: .utf8) == "not an index\n")
        try Data(repeating: 49, count: 100).write(to: state)
        #expect(AuthoredTextRainbow.reserve(at: state) == nil)
    }

    @Test func finalRainbowReservationLeavesPlainAndRawRoutesUntouched() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "AuthoredTextRainbow.reserveStartIndex()").count == 2)
        #expect(source.contains("presentation == .styledMath && includeSourceContext"))
        #expect(source.contains("&& !skipPostProcessingNow && hasAuthoredWords ? AuthoredTextRainbow.reserveStartIndex() : 0"))
        #expect(source.contains("rainbowStartIndex: rainbowStart"))
    }
}
