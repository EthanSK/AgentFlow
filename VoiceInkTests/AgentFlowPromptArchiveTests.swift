import AppKit
import CryptoKit
import ImageIO
import Testing
@testable import VoiceInkPlusPlus

@MainActor
struct AgentFlowPromptArchiveTests {
    private func withoutRainbowSpans(_ html: String) -> String {
        html.replacingOccurrences(of: #"<span class="rainbow-word" style="color:#[0-9a-f]{6}">([^<]*)</span>"#,
            with: "$1", options: .regularExpression)
    }

    @Test func viewerRainbowContinuesAcrossNewlinesSectionsAndContext() throws {
        let source = "<speech>one\n  two\tthree</speech>\n" +
            "<app_selection><text>ignored colour positions</text></app_selection>\n" +
            "<local_screenshot path=\"/tmp/missing.png\"/>\n" +
            "<typed_text>four &amp; &lt;five&gt;</typed_text>"
        let html = AgentFlowPromptViewer.html(source, rainbowStartIndex: 22)
        for (word, color) in zip(["one", "two", "three", "four", "&amp;", "&lt;five&gt;"],
                                ["#fa70b5", "#fa7093", "#fa7070", "#fa9370", "#fab570", "#fad870"]) {
            #expect(html.contains("style=\"color:\(color)\">\(word)</span>"))
        }
        #expect(withoutRainbowSpans(html).contains("one\n  two\tthree"))
        #expect(!html.contains("linear-gradient") && !html.contains("background-clip:text"))
        #expect(AgentFlowPromptViewer.authoredWordCount(source) == 6)
        var index = 7
        #expect(AgentFlowPromptViewer.authoredHTML("", nextIndex: &index).isEmpty)
        #expect(index == 7)
        if let path = ProcessInfo.processInfo.environment["AGENTFLOW_RAINBOW_FIXTURE_PATH"] {
            let fixture = "<speech>" + String(repeating: "one two three four five six seven eight nine ten ", count: 8)
                + "\nExplicit newline continues here.</speech><app_selection><text>Context stays cyan.</text></app_selection>"
                + "<typed_text>The next authored section continues the palette too.</typed_text>"
            try Data(AgentFlowPromptViewer.html(fixture, rainbowStartIndex: 22).utf8)
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test func viewerReservationContinuesMessagesIndependentlyPerChat() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID().uuidString
        let second = UUID().uuidString
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: first, wordCount: 23, directory: directory) == 0)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: first, wordCount: 3, directory: directory) == 23)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: second, wordCount: 1, directory: directory) == 0)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: first, wordCount: 2, directory: directory) == 2)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: first, wordCount: 0, directory: directory) == 0)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: first, wordCount: 1, directory: directory) == 4)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: nil, wordCount: 2, directory: directory) == 0)
        #expect(AuthoredTextRainbow.reserveViewerStartIndex(chatID: "ambiguous", wordCount: 1, directory: directory) == 2)
        let source = "<typed_text>six seven</typed_text>"
        let html = AgentFlowPromptViewer.html(source, rainbowStartIndex: 5)
        #expect(html == AgentFlowPromptViewer.html(source, rainbowStartIndex: 5))
        #expect(html.contains("color:#d8fa70\">six</span>"))
        #expect(html.contains("color:#b5fa70\">seven</span>"))
    }
    private func withoutTrustedCloseScript(_ html: String) -> String {
        html.replacingOccurrences(of: "<script>\(AgentFlowPromptViewer.closeScript)</script>", with: "")
    }

    @Test func viewerCloseButtonAllowsOnlyFixedHashAuthorizedScript() {
        let html = AgentFlowPromptViewer.html("</script><script>evil()</script>")
        let digest = Data(SHA256.hash(data: Data(AgentFlowPromptViewer.closeScript.utf8))).base64EncodedString()
        #expect(html.contains("script-src 'sha256-\(digest)'"))
        #expect(!html.contains("script-src 'unsafe-inline'"))
        #expect(html.components(separatedBy: "<script>").count == 2)
        #expect(!withoutTrustedCloseScript(html).contains("<script"))
        #expect(html.contains("<button id=\"close-prompt\" class=\"close-button\" type=\"button\">Close</button>"))
        #expect(html.contains(".close-actions{margin-left:auto;"))
        #expect(html.contains("role=\"status\" hidden>Use the tab’s close button.</p>"))
        #expect(!html.contains("onclick="))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentFlowPromptTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func archivePreservesEveryUTF8ByteAndUsesPrivatePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Prompts")
        let text = "Full 😀 <speech start_at=\"1.001\">\n" + String(repeating: "exact &amp; words\n", count: 20_000)
        let file = try AgentFlowPromptArchive.write(text, recordID: UUID(), directory: directory)
        #expect(try Data(contentsOf: file) == Data((AgentFlowPromptArchive.interpretationReminder + text).utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func canonicalPromptNamesInterpretationSkillWithoutAddingViewerEvent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = "<speech start_at=\"1.000\" end_at=\"2.000\" timing=\"approximate\">request</speech>"
        let file = try AgentFlowPromptArchive.write(timeline, recordID: UUID(), directory: root)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.hasPrefix(AgentFlowPromptArchive.interpretationReminder))
        #expect(saved.contains("$interpret-agent-flow-context"))
        #expect(saved.hasSuffix(timeline))
        try AgentFlowPromptArchive.writeViewer(timeline, for: file)
        let viewer = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("html"), encoding: .utf8)
        #expect(!viewer.contains(AgentFlowPromptArchive.interpretationReminder))
        #expect(AgentFlowPromptViewer.events(timeline).map(\.tag) == ["speech"])
    }

    @Test func repeatRecordNeverOverwritesPreviousPrompt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let first = try AgentFlowPromptArchive.write("first", recordID: id, directory: root)
        let second = try AgentFlowPromptArchive.write("second", recordID: id, directory: root)
        #expect(first != second)
        #expect(first.lastPathComponent.contains(id.uuidString.lowercased()))
        #expect(try String(contentsOf: first, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + "second")
    }

    @Test func redirectedPromptDirectoryIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try AgentFlowPromptArchive.write("private prompt", recordID: UUID(), directory: link)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func invalidArchiveLocationCannotProduceLinkOrOverwriteFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("already-a-file")
        try Data("unrelated".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try AgentFlowPromptArchive.write("new prompt", recordID: UUID(), directory: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unrelated")
    }

    @Test func emptySessionDoesNotCreatePromptFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try AgentFlowPromptArchive.write(" \n\t", recordID: UUID(), directory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func compactPromptIsLimitedToNativeCodexHostsWithoutVersionPinning() {
        for name in ["Codex.app", "ChatGPT.app"] {
            for (version, build) in [("26.928.31416", "12553"), ("future-host-version", "future-build")] {
                #expect(AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: "com.openai.codex",
                    bundleURL: URL(fileURLWithPath: "/Applications/\(name)"), version: version, build: build))
            }
        }
        #expect(AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: "com.openai.codex", bundleURL: nil))
        for name in ["Claude.app", "Google Chrome.app", "Unrecognized.app"] {
            #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: "com.openai.codex",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name)")))
        }
        for bundleID in AgentFlowPromptPreview.inlineContextRecipientBundleIdentifiers {
            #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: bundleID, bundleURL: nil))
        }
        for bundleID in ["com.google.Chrome", "com.apple.Safari", "com.microsoft.VSCode", "com.apple.Terminal", "unknown", nil] {
            #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: bundleID, bundleURL: nil))
        }
    }

    @Test func shortInlinePromptPreservesExactCanonicalContextWithoutFileRead() throws {
        let canonical = "<speech start_at=\"1.000\">before</speech>\n" +
            "<app_selection source=\"Code\" captured_at=\"2.000\"><text>  exact &amp; quote\nnext  </text></app_selection>\n" +
            "<local_screenshot path=\"/tmp/image.png\" captured_at=\"3.000\"/>\n" +
            "<potential_tts>possible unrelated speech</potential_tts>\n<typed_text>after</typed_text>"
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "before after", sections: [
            .init(tag: "speech", text: "before", color: "#f1f5f9"),
            .init(tag: "selection", text: "compact omitted quote", color: "#67e8f9"),
            .init(tag: "screenshot", text: "image.png", color: "#e879f9"),
            .init(tag: "typed_text", text: "after", color: "#f4f4f5")
        ], fileURL: URL(fileURLWithPath: "/tmp/never-created.md"), completePromptText: canonical))
        #expect(preview == "[↗](/tmp/never-created.md) before `<selection>` `<screenshot>` after\n\n\n" + AgentFlowPromptPreview.coloredInlineTimeline(canonical))
        #expect(!preview.contains(AgentFlowPromptArchive.interpretationReminder))
        #expect(preview.utf16.count < 5_000)
        #expect(!preview.contains("Read the [full prompt]"))
        #expect(preview.contains("\\color{#67e8f9}"))
        #expect(HistoryContextPresentation.document(preview).plainText.hasSuffix(AgentFlowPromptPreview.compactTimeline(canonical)))
    }

    @Test func inlinePasteBudgetCountsEditableOpeningLinksAndUTF16AtExactBoundary() throws {
        let file = URL(fileURLWithPath: "/tmp/full (😀) prompt.md")
        let viewer = URL(fileURLWithPath: "/tmp/full (😀) prompt.html")
        let encoded = "/tmp/full%20%28%F0%9F%98%80%29%20prompt.html"
        let prefix = "[↗](\(encoded)) keep these words `<selection>`\n\n\n"
        let sections = [AgentFlowPromptPreview.Section(tag: "speech", text: "keep these words", color: "#f1f5f9"),
                        AgentFlowPromptPreview.Section(tag: "selection", text: "hidden", color: "#67e8f9")]
        for length in [4_999, 5_000, 5_001] {
            // Emoji and combining characters must use the same length as JS,
            // not Swift's grapheme count; include their real serialized bytes.
            let section = "<app_selection><text>selected</text></app_selection>"
            let end = "\n😀e\u{301}"
            let padding = length - (prefix + AgentFlowPromptPreview.coloredInlineTimeline(section) + end).utf16.count
            let canonical = section + end + String(repeating: "x", count: padding)
            let preview = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: sections,
                fileURL: file, viewerURL: viewer, completePromptText: canonical))
            if length < 5_000 {
                #expect(preview == prefix + AgentFlowPromptPreview.coloredInlineTimeline(canonical))
                #expect(preview.utf16.count == length)
            } else {
                #expect(!preview.contains(canonical))
                #expect(preview.contains("`<selection>`"))
                #expect(preview.hasSuffix("Read the [full prompt](\(encoded)) before answering."))
                #expect(!preview.contains("\\color{"))
            }
        }
    }

    @Test func inlineAuthoredRainbowKeepsTypeColorsAndPlainArchivePreview() throws {
        let canonical = "<speech>spoken words</speech>\n<typed_text>typed words</typed_text>\n"
            + "<app_selection source=\"Code\"><text>quoted words</text></app_selection>\n"
            + "<local_screenshot path=\"/tmp/image.png\"/>"
        let colored = AgentFlowPromptPreview.coloredInlineTimeline(canonical)
        for color in [LiveSelectionStyledMath.speechColor, LiveSelectionStyledMath.typedColor,
                      LiveSelectionStyledMath.selectionColor, LiveSelectionStyledMath.screenshotColor] {
            #expect(colored.contains("\\color{\(color)}"))
        }
        #expect(HistoryContextPresentation.document(colored).plainText == AgentFlowPromptPreview.compactTimeline(canonical))
        #expect(colored.contains("#fa7070"))
        let plainPreview = try #require(AgentFlowPromptPreview.make(authoredText: "spoken words", sections: [
            .init(tag: "speech", text: "spoken words", color: "#fa7070"),
            .init(tag: "selection", text: "quoted", color: "#67e8f9")
        ], fileURL: URL(fileURLWithPath: "/tmp/large.md"), completePromptText: String(repeating: canonical, count: 30)))
        #expect(plainPreview.contains("Read the [full prompt]"))
        #expect(!plainPreview.contains("\\color{"))
    }

    @Test func compactBlocksKeepPayloadParagraphsButRemoveTagFraming() {
        let selected = "\n\n  selected first\n\nselected last  \n"
        let spoken = "\n\nspoken first\n\nspoken last\n\n"
        let source = "<app_selection source=\"Code\">\n\n  <text>" + selected
            + "</text>\n\n</app_selection>\n\n<speech start_at=\"1\">\n\n" + spoken + "\n\n</speech>"
        let expected = "<app_selection source=\"Code\"><text>" + selected
            + "</text></app_selection>\n\n<speech start_at=\"1\">" + spoken + "</speech>"
        #expect(AgentFlowPromptPreview.compactTimeline(source) == expected)
        let colored = AgentFlowPromptPreview.coloredInlineTimeline(source)
        #expect(HistoryContextPresentation.document(colored).plainText == expected)
        #expect(HistoryContextPresentation.copyText(colored, format: .formatted) == expected)
        let malformed = "<app_selection>\n\n<text>unfinished"
        #expect(AgentFlowPromptPreview.compactTimeline(malformed) == malformed)
    }

    @Test func inlineRainbowContinuesOnlyAcrossAuthoredWordsAndPreservesWhitespace() throws {
        let source = "<speech>one\n\ntwo</speech>\n\n<app_selection><text>quoted</text></app_selection>\n\n<typed_text>  three  </typed_text>"
        let colored = AgentFlowPromptPreview.coloredInlineTimeline(source, rainbowStartIndex: 23)
        #expect(colored.contains(try #require(AuthoredTextRainbow.render("one\n\ntwo", startIndex: 23, preserveWhitespace: true))))
        #expect(colored.contains(try #require(AuthoredTextRainbow.render("  three  ", startIndex: 1, preserveWhitespace: true))))
        #expect(HistoryContextPresentation.document(colored).plainText == source)
        #expect(HistoryContextPresentation.copyText(colored, format: .formatted) == source)
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "one two three", sections: [
            .init(tag: "speech", text: "one two", color: "#fff"),
            .init(tag: "selection", text: "quoted", color: "#67e8f9"),
            .init(tag: "typed_text", text: "three", color: "#fff")
        ], fileURL: URL(fileURLWithPath: "/tmp/full.md"), completePromptText: source, rainbowStartIndex: 23))
        #expect(!preview.components(separatedBy: "\n\n\n")[0].contains("\\color"))
        #expect(preview.hasSuffix(colored))
    }

    @Test func duplicatedAuthoredOpeningCanRequireTheArchiveEvenWhenTimelineAloneFits() throws {
        let words = String(repeating: "editable words ", count: 120).trimmingCharacters(in: .whitespaces)
        let canonical = "<speech>" + words + "</speech><app_selection><text>" +
            String(repeating: "context ", count: 220) + "</text></app_selection>"
        #expect(canonical.utf16.count < 5_000)
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: words, sections: [
            .init(tag: "speech", text: words, color: "#f1f5f9"),
            .init(tag: "selection", text: "hidden", color: "#67e8f9")
        ], fileURL: URL(fileURLWithPath: "/tmp/full.md"), completePromptText: canonical))
        #expect(preview.hasPrefix("[↗](/tmp/full.md) " + words + " `<selection>`"))
        #expect(preview.hasSuffix("Read the [full prompt](/tmp/full.md) before answering."))
        #expect(!preview.contains(canonical))
        #expect(preview.utf16.count < 5_000)
    }

    @Test func inlineContextBudgetDoesNotChangeAuthoredOnlyOrMissingCanonicalFallback() throws {
        let file = URL(fileURLWithPath: "/tmp/full.md")
        let plain = try #require(AgentFlowPromptPreview.make(authoredText: "editable words", sections: [],
            fileURL: file, completePromptText: "<speech>editable words</speech>"))
        #expect(plain == "[↗](/tmp/full.md) editable words")
        for canonical in [nil, " \n\t", String(repeating: "large context ", count: 500)] {
            let result = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: [
                .init(tag: "unknown_context", text: "private", color: "#67e8f9"),
                .init(tag: "speech", text: "keep every word", color: "#f1f5f9")
            ], fileURL: file, completePromptText: canonical))
            #expect(result == "[↗](/tmp/full.md) `<unknown_context>` keep every word\n\nRead the [full prompt](/tmp/full.md) before answering.")
        }
    }

    @Test func compactPreviewKeepsEditableWordsAndOnlyContextMarkers() throws {
        let selected = try #require(LiveSelectionReference("beginning " + String(repeating: "middle ", count: 100) + "ending"))
            .timed(at: Date(timeIntervalSince1970: 12))
        let sections = LiveSelectionReference.compactPromptSections([selected], with: "hello test")
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "hello test", sections: sections,
            fileURL: URL(fileURLWithPath: "/tmp/full prompt.md")))
        // This unanchored capture precedes the speech; keep the real event order
        // without moving the marker or forcing the words onto another row.
        #expect(preview.contains("`<selection>` hello test"))
        #expect(!preview.components(separatedBy: "\n\n")[0].contains("\\color{"))
        #expect(!preview.contains("beginning") && !preview.contains("ending"))
        #expect(!preview.contains("</"))
        #expect(!preview.contains("captured") && !preview.contains("bundle") && !preview.contains("characters="))
        #expect(preview.hasSuffix("Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)](/tmp/full%20prompt.md) before answering."))
        #expect(!preview.contains("not just this preview"))
        #expect(preview.hasPrefix("[↗](/tmp/full%20prompt.md) `<selection>`"))
        #expect(!preview.contains("IMPORTANT:"))
    }

    @Test func previewRetainsAllAuthoredWordsBeyondTheOldPasteBudget() throws {
        let words = (0..<2_000).map { "word\($0)" }
        let parts = [
            AgentFlowPromptPreview.Section(tag: "speech", text: words.prefix(1_000).joined(separator: " "), color: "#f1f5f9"),
            .init(tag: "selection", text: String(repeating: "private quoted context ", count: 200), color: "#67e8f9"),
            .init(tag: "typed_text", text: words.suffix(1_000).joined(separator: " "), color: "#f4f4f5"),
            .init(tag: "screenshot", text: "private image path", color: "#e879f9")
        ]
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: parts,
            fileURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/AgentFlow/Prompts/full.md")))
        #expect(preview.utf16.count > 4_000)
        #expect(!preview.contains("…"))
        for word in words { #expect(preview.contains(word)) }
        #expect(!preview.contains("private quoted context") && !preview.contains("private image path"))
        #expect(preview.hasSuffix("before answering."))
        let firstTail = try #require(preview.range(of: "word1000"))
        let lastHead = try #require(preview.range(of: "word999"))
        #expect(lastHead.lowerBound < firstTail.lowerBound)
        // Even one huge unbroken word survives without a needless full-file read.
        let huge = String(repeating: "z", count: 70_000)
        let hugePreview = try #require(AgentFlowPromptPreview.make(authoredText: huge, sections: [],
            fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        #expect(hugePreview.filter { $0 == "z" }.count == huge.count)
        #expect(!hugePreview.contains("…") && !hugePreview.contains("before answering."))
        #expect(hugePreview.hasPrefix("[↗](/tmp/full.md) "))
    }

    @Test func exactFullArchiveKeepsMetadataHiddenFromPreview() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = try #require(LiveSelectionReference("  exact\n  selected text & stuff  "))
            .scopedToApplication(name: "Code", bundleID: "com.microsoft.VSCode").timed(at: date)
        let typed = try #require(LiveSelectionReference(typedText: "my typed request"))
            .timed(at: date.addingTimeInterval(5), startedAt: date.addingTimeInterval(1))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/tmp/image.png"))).timed(at: date)
        let full = LiveSelectionReference.interleaving([selection, typed, screenshot], with: "", includeTiming: true, includeReadablePreview: true)
        #expect(full.contains("bundle_id=\"com.microsoft.VSCode\""))
        #expect(full.contains("captured_at=\"1800000000.000\""))
        #expect(full.contains("<typed_text start_at=\"1800000001.000\" end_at=\"1800000005.000\">"))
        #expect(full.contains("  exact\n  selected text &amp; stuff  "))
        #expect(full.contains("path=\"/tmp/image.png\""))
        #expect(!full.contains("\\color"))
    }

    @Test func compactTimelinePreservesSpeechTypingAndContextOrder() throws {
        let selection = try #require(LiveSelectionReference("quoted"))
        let typed = try #require(LiveSelectionReference(typedText: "keyboard"))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/tmp/picture.png")))
        let parts = LiveSelectionReference.compactPromptSections([
            selection.anchored(after: "first"), typed.anchored(after: "first"), screenshot.anchored(after: "first second")
        ], with: "first second third")
        #expect(parts.map(\.tag) == ["speech", "selection", "typed_text", "speech", "screenshot", "speech"])
        #expect(parts[2].text == "keyboard")
        #expect(parts[4].text == "picture.png")
    }

    @Test func authoredOnlyPreviewDoesNotRepeatTimingScaffolding() throws {
        let typed = try #require(LiveSelectionReference(typedText: "typed"))
        #expect(LiveSelectionReference.compactPromptSections([typed], with: "spoken").map(\.tag) == ["typed_text", "speech"])
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "typed", sections: [],
            fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        #expect(preview == "[↗](/tmp/full.md) typed")
        #expect(!preview.contains("start_at"))
    }

    @Test func plainPreviewQuotesAngularMarkersInsteadOfCreatingRawHTMLBlocks() throws {
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "request", sections: [
            .init(tag: "selection", text: "quote ` code <secret>", color: "#67e8f9")
        ], fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        #expect(preview.contains("`<selection>`"))
        #expect(!preview.contains("[selection]") && !preview.contains("\\("))
        #expect(!preview.contains("quote") && !preview.contains("secret"))
    }

    @Test func eventsInterleaveWithEditableWordsInOneParagraph() throws {
        let sections: [AgentFlowPromptPreview.Section] = [
            .init(tag: "speech", text: "spoken", color: LiveSelectionStyledMath.speechColor),
            .init(tag: "screenshot", text: "private.png", color: LiveSelectionStyledMath.screenshotColor),
            .init(tag: "selection", text: "quoted", color: LiveSelectionStyledMath.selectionColor),
            .init(tag: "typed_text", text: "typed", color: LiveSelectionStyledMath.typedColor),
            .init(tag: "selection", text: "quoted again", color: LiveSelectionStyledMath.selectionColor)
        ]
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "request", sections: sections,
            fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        let paragraphs = preview.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        let expectedParts = sections.map { section -> String in
            if section.tag == "speech" || section.tag == "typed_text" {
                return section.text
            }
            return "`<\(section.tag)>`"
        }
        let expected = expectedParts.joined(separator: " ")
        #expect(paragraphs[0] == "[↗](/tmp/full.md) " + expected)
        #expect(!paragraphs[0].contains("\n"))
        #expect(!preview.contains("request") && !preview.contains("quoted"))
    }

    @Test func consecutiveAngularContextMarkersRemainInline() throws {
        let sections: [AgentFlowPromptPreview.Section] = [
            .init(tag: "speech", text: "before", color: LiveSelectionStyledMath.speechColor),
            .init(tag: "selection", text: "private", color: LiveSelectionStyledMath.selectionColor),
            .init(tag: "screenshot", text: "/private/image.png", color: LiveSelectionStyledMath.screenshotColor),
            .init(tag: "speech", text: "after", color: LiveSelectionStyledMath.speechColor)
        ]
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "before after", sections: sections,
            fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        let selection = "`<selection>`"
        let screenshot = "`<screenshot>`"
        #expect(preview.contains("before " + selection + " " + screenshot + " after"))
        #expect(!preview.components(separatedBy: "\n\n")[0].contains("\n"))
        #expect(!preview.contains("private") && !preview.contains("/private/image.png"))
        #expect(preview.contains("after"))
    }

    @Test func optionalViewerLinkOpensWithExplicitExactPlainSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "my request\n\n<speech start_at=\"1.000\" end_at=\"2.000\" timing=\"approximate\">\n\nmy request\n\n</speech>"
        let file = try AgentFlowPromptArchive.write(text, recordID: UUID(), directory: root)
        #expect(AgentFlowPromptArchive.viewerURL(for: file) == nil)
        try AgentFlowPromptArchive.writeViewer(text, for: file)
        let viewer = try #require(AgentFlowPromptArchive.viewerURL(for: file))
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "my request", sections: [], fileURL: file, viewerURL: viewer))
        #expect(preview.hasPrefix("[↗](\(viewer.path)) "))
        #expect(preview.components(separatedBy: viewer.path).count == 2)
        #expect(preview == "[↗](\(viewer.path)) my request")
        let html = try String(contentsOf: viewer, encoding: .utf8)
        #expect(html.contains("class=\"event authored\""))
        #expect(html.contains("class=\"rainbow-word\""))
        #expect(html.contains("<meta name=\"agent-flow-source\" content=\"\(file.path)\">"))
        #expect(html.contains("<a class=\"source-link\" href=\"\(file.absoluteString)\">Source</a>"))
        #expect(!html.contains("For the agent") && !html.contains("Complete prompt for the agent"))
        #expect(!html.contains("this viewer shows the same request and context"))
        #expect(!html.contains("Full source") && !html.contains("class=\"source\""))
        #expect(withoutRainbowSpans(html).components(separatedBy: "my request").count == 2)
        #expect(!html.contains("Your words"))
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + text)
        #expect(try FileManager.default.attributesOfItem(atPath: viewer.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: (any Error).self) { try AgentFlowPromptArchive.writeViewer("replacement", for: file) }
    }

    @Test func promptViewerEscapesUntrustedMarkupAndRetainsAllMetadata() {
        let source = "hi\n\n<app_selection index=\"1\" captured_at=\"42.123\">\n<text>&lt;script&gt;evil&lt;/script&gt; &amp; exact</text>\n</app_selection>\n<script>alert(1)</script>"
        let html = AgentFlowPromptViewer.html(source)
        #expect(html.contains("#67e8f9") && html.contains("font-style:italic"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!withoutTrustedCloseScript(html).contains("<script>") && !html.contains("<img") && !html.contains("https://"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("<dt>captured_at</dt><dd>42.123</dd>"))
        #expect(html.contains("<div class=\"payload\">&lt;script&gt;evil&lt;/script&gt; &amp; exact</div>"))
        #expect(html.contains("<details class=\"metadata\"><summary>Details</summary>"))
        #expect(!html.contains("<details class=\"source\">"))
    }

    @Test func viewerParsesTimelineWithoutPromotingQuotedXMLOrLosingWhitespace() throws {
        let source = "My words\n\n<speech start_at=\"1.1\" end_at=\"2.2\" timing=\"approximate\">\n\nfirst &amp; next\n\n</speech>\n\n<app_selection source=\"Code &amp; editor\" task_id=\"abc\"><text>  &lt;speech&gt;not speech&lt;/speech&gt;\n\t&amp;lt;literal entity&amp;gt;  </text></app_selection>\n\n<typed_text start_at=\"3\" end_at=\"4\">\n\n  typed  \n\n</typed_text>"
        let events = AgentFlowPromptViewer.events(source)
        #expect(events.map(\.tag) == ["opening", "speech", "app_selection", "typed_text"])
        #expect(events[2].text == "  <speech>not speech</speech>\n\t&lt;literal entity&gt;  ")
        #expect(events[2].attributes == ["source": "Code & editor", "task_id": "abc"])
        let html = AgentFlowPromptViewer.html(source)
        #expect(html.contains("<h2>Speech</h2>") && html.contains("<h2>Typed text</h2>"))
        #expect(withoutRainbowSpans(html).contains("<div class=\"payload\">first &amp; next</div>"))
        #expect(withoutRainbowSpans(html).contains("<div class=\"payload\">  typed  </div>"))
        #expect(html.contains("&amp;lt;literal entity&amp;gt;"))
        #expect(html.contains("<h2>Text</h2>") && html.contains("My words"))
        #expect(!html.contains("<summary>Your words</summary>"))
    }

    @Test func canonicalArchiveNeedsNoOpeningAndLegacyViewerShowsAuthoredWordsOnce() {
        let reference = LiveSelectionReference.speechTiming(after: "exact request",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2))
        let canonical = LiveSelectionReference.interleaving([reference], with: "exact request",
            includeTiming: true, includeReadablePreview: false)
        #expect(canonical.hasPrefix("<speech "))
        #expect(canonical.components(separatedBy: "exact request").count == 2)
        let canonicalViewer = AgentFlowPromptViewer.html(canonical)
        #expect(withoutRainbowSpans(canonicalViewer).components(separatedBy: "exact request").count == 2)
        #expect(!canonicalViewer.contains("Your words"))

        let legacy = "exact request\n\n" + canonical
        let legacyViewer = AgentFlowPromptViewer.html(legacy)
        #expect(withoutRainbowSpans(legacyViewer).components(separatedBy: "exact request").count == 2)
        #expect(!legacyViewer.contains("Your words"))
        let unmatched = AgentFlowPromptViewer.html("Extra instruction\n\n" + canonical)
        #expect(unmatched.contains("Extra instruction"))
        #expect(unmatched.contains("<h2>Text</h2>"))
    }

    @Test func viewerScreenshotIsLocalLinkAndExactDuplicateOnlyIsHidden() {
        let path = "/tmp/example (1) & 2.png"
        let reference = LiveSelectionStyledMath.localImageReference(path: path)
        let source = "<local_screenshot path=\"/tmp/example (1) &amp; 2.png\" captured_at=\"1.234\"/>\n\n\(reference)\n\nUnmatched prose remains\n<speech timing=\"unavailable\">hello</speech>"
        let events = AgentFlowPromptViewer.events(source)
        #expect(events.map(\.tag) == ["local_screenshot", "text", "speech"])
        #expect(events[1].text.contains("Unmatched prose remains"))
        #expect(!events[1].text.contains("![Screenshot]"))
        let html = AgentFlowPromptViewer.html(source)
        #expect(html.contains("href=\"file:///tmp/example%20(1)%20&amp;%202.png\""))
        #expect(!html.contains("<img"))
        #expect(html.contains("Preview unavailable"))
        let unsafe = AgentFlowPromptViewer.html("<local_screenshot path=\"javascript:alert(1)\"/>")
        #expect(!unsafe.contains("href="))
    }

    private func screenshotFixture(in root: URL, width: Int = 8) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.bitmapData).initialize(repeating: 120, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let file = root.appendingPathComponent("screenshot.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    @Test func screenshotViewerEmbedsActualPixelsWithoutNetworkOrFileFetches() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try screenshotFixture(in: root)
        let original = try Data(contentsOf: file)
        let prompt = "<local_screenshot path=\"\(file.path)\" captured_at=\"1.234\"/>"
        let archive = try AgentFlowPromptArchive.write(prompt, recordID: UUID(), directory: root)
        try AgentFlowPromptArchive.writeViewer(prompt, for: archive)
        let html = try String(contentsOf: try #require(AgentFlowPromptArchive.viewerURL(for: archive)), encoding: .utf8)
        let encoded = try #require(html.components(separatedBy: "src=\"data:image/jpeg;base64,").last?.components(separatedBy: "\"").first)
        let data = try #require(Data(base64Encoded: encoded))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 8 && image.pixelsHigh == 4)
        #expect(html.contains("img-src data:") && !withoutTrustedCloseScript(html).contains("<script"))
        #expect(html.contains("captured_at</dt><dd>1.234"))
        #expect(!html.contains("Preview unavailable"))
        #expect(try Data(contentsOf: file) == original)
        #expect(try String(contentsOf: archive, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + prompt)
    }

    @Test func screenshotPreviewRejectsMissingNonRasterRedirectedAndSpecialFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try screenshotFixture(in: root)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("<svg onload='alert(1)'><image href='https://example.com'/></svg>".utf8).write(to: invalid)
        let pipe = root.appendingPathComponent("pipe.png")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        for path in ["https://example.com/image.png", "relative.png", root.path + "/missing", root.path,
                     link.path, invalid.path, pipe.path, image.path + "\0ignored"] {
            #expect(AgentFlowPromptViewer.screenshotPreview(path: path) == nil)
        }
        let selected = "<app_selection><text>&lt;local_screenshot path=\"\(image.path)\"/&gt;</text></app_selection>"
        #expect(!AgentFlowPromptViewer.html(selected).contains("<img"))
    }

    @Test func screenshotPreviewResizesPixelsAndBoundsTotalEmbeddedBytesWithoutDroppingPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try screenshotFixture(in: root, width: 3_000)
        let data = try #require(AgentFlowPromptViewer.screenshotPreview(path: image.path))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(max(decoded.pixelsWide, decoded.pixelsHigh) == 2_048)
        let prompt = "<local_screenshot path=\"\(image.path)\"/>\n<local_screenshot path=\"\(image.path)\"/>"
        let html = AgentFlowPromptViewer.html(prompt, imageBudget: data.count)
        #expect(html.components(separatedBy: "<img ").count == 2)
        #expect(html.contains("Preview unavailable"))
        #expect(html.components(separatedBy: "class=\"screenshot\"").count == 3)
        #expect(!AgentFlowPromptViewer.html(prompt, imageBudget: 0).contains("<img"))
    }

    @Test func screenshotSourceReferenceIsEscapedAndPrecedesEmbeddedImageData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try screenshotFixture(in: root)
        let source = URL(fileURLWithPath: root.path + "/a & \"<>.md")
        let html = AgentFlowPromptViewer.html("<local_screenshot path=\"\(image.path)\"/>", sourceURL: source)
        #expect(html.contains("a &amp; &quot;&lt;&gt;.md"))
        #expect(try #require(html.range(of: "name=\"agent-flow-source\"")).lowerBound < #require(html.range(of: "data:image/jpeg;base64,")).lowerBound)
        #expect(!AgentFlowPromptViewer.html("request", sourceURL: URL(string: "https://example.com")).contains("name=\"agent-flow-source\""))
    }

    @Test func viewerMalformedUnknownAndEntityDeclarationsRemainInertAndVisible() {
        for fragment in [
            "<speech><!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>&secret;</speech>",
            "<speech>&unknown;</speech>",
            "<speech><img src='https://example.com'/></speech>",
            "<app_selection><text>partial",
            "<future_type value=\"1\">future payload</future_type>"
        ] {
            #expect(AgentFlowPromptViewer.events(fragment).map(\.text).joined() == fragment)
            let html = AgentFlowPromptViewer.html(fragment)
            #expect(!html.contains("<img") && !withoutTrustedCloseScript(html).contains("<script"))
            #expect(!html.contains("Full source"))
        }
    }

    @Test func fullSelectionSurvivesArchiveAndParsedViewerBeyondOldCharacterAndLineCaps() throws {
        let selected = "  start\n" + String(repeating: "\tfull 😀 selected line & <>\n", count: 5_000) + "  exact end  "
        let reference = try #require(LiveSelectionReference(selected))
        #expect(!reference.truncated && reference.preview.count < 110)
        let canonical = LiveSelectionReference.interleaving([reference], with: "read all", includeTiming: true, includeReadablePreview: true)
        let events = AgentFlowPromptViewer.events(canonical)
        #expect(try #require(events.first { $0.tag == "codex_selection" }).text == selected)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try AgentFlowPromptArchive.write(canonical, recordID: UUID(), directory: root)
        try AgentFlowPromptArchive.writeViewer(canonical, for: file)
        #expect(try Data(contentsOf: file) == Data((AgentFlowPromptArchive.interpretationReminder + canonical).utf8))
        let html = try String(contentsOf: try #require(AgentFlowPromptArchive.viewerURL(for: file)), encoding: .utf8)
        #expect(html.contains("  exact end  </div>"))
        #expect(html.components(separatedBy: "\tfull 😀 selected line &amp; &lt;&gt;\n").count == 5_001)
    }

    @Test func invalidFileReferencesAreNeverEmitted() {
        for url in [URL(string: "https://example.com/prompt")!, URL(fileURLWithPath: "/tmp/line\nbreak.md"), URL(fileURLWithPath: "/tmp/<bad>.md")] {
            #expect(AgentFlowPromptPreview.make(authoredText: "text", sections: [], fileURL: url) == nil)
        }
    }

    @Test func encodedPromptLinksResolveToTheExactSavedFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Application Support/Prompt (100%) [é] #? `test`")
        let full = "Complete request\n<typed_text start_at=\"1\" end_at=\"2\">exact 😀 text</typed_text>"
        let file = try AgentFlowPromptArchive.write(full, recordID: UUID(), directory: folder)
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "request", sections: [],
            fileURL: file))
        let linkStart = try #require(preview.range(of: "[↗](")).upperBound
        let linkEnd = try #require(preview[linkStart...].firstIndex(of: ")"))
        let target = String(preview[linkStart..<linkEnd])
        #expect(!target.contains(where: { $0.isWhitespace || "<>()[ ]`".contains($0) }))
        #expect(target.contains("Application%20Support") && target.contains("%25"))
        let decoded = try #require(target.removingPercentEncoding)
        #expect(decoded == file.path)
        #expect(try String(contentsOfFile: decoded, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + full)
        #expect(preview == "[↗](\(target)) request")
    }

    @Test func queuedPreviewStartsWithClickableLinkOnSameLineAsWords() throws {
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "first words", sections: [],
            fileURL: URL(fileURLWithPath: "/tmp/prompt.md")))
        let firstLine = try #require(preview.split(separator: "\n").first)
        #expect(firstLine.hasPrefix("[↗](/tmp/prompt.md) first words"))
        #expect(preview == "[↗](/tmp/prompt.md) first words")
    }

    @Test func emptyPreviewKeepsOnlyFooterWithoutLeadingWhitespace() throws {
        for text in ["", " \n\t"] {
            let preview = try #require(AgentFlowPromptPreview.make(authoredText: text, sections: [],
                fileURL: URL(fileURLWithPath: "/tmp/prompt.md")))
            #expect(preview == "Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)](/tmp/prompt.md) before answering.")
        }
    }

    @Test func plainFooterContainsNoMathAndPreservesBothLinkTargets() throws {
        let label = AgentFlowPromptPreview.fullPromptLinkLabel
        #expect(label == "full prompt")
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: [
            .init(tag: "speech", text: "editable words", color: "#f1f5f9"),
            .init(tag: "selection", text: "hidden reference", color: "#67e8f9")
        ],
            fileURL: URL(fileURLWithPath: "/tmp/full.md"), viewerURL: URL(fileURLWithPath: "/tmp/full.html")))
        #expect(preview.components(separatedBy: "\n\n")[0] == "[↗](/tmp/full.html) editable words `<selection>`")
        #expect(preview.hasSuffix("Read the [\(label)](/tmp/full.html) before answering."))
        #expect(preview.components(separatedBy: "/tmp/full.html").count == 3)
        #expect(!preview.contains("$$") && !preview.contains("\\textsf") && !preview.contains("\\color"))
    }

    @Test func authoredSpeechAndTypingOmitMandatoryReadEvenWhenMentioningReferences() throws {
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: [
            .init(tag: "speech", text: "Discuss <selection> and screenshots", color: "#f1f5f9"),
            .init(tag: "typed_text", text: "without attaching either", color: "#f4f4f5")
        ], fileURL: URL(fileURLWithPath: "/tmp/full.md"), viewerURL: URL(fileURLWithPath: "/tmp/full.html")))
        #expect(preview == "[↗](/tmp/full.html) Discuss <selection> and screenshots without attaching either")
    }

    @Test(arguments: ["selection", "screenshot", "potential_tts", "future_reference"])
    func hiddenContextRetainsMandatoryRead(tag: String) throws {
        let preview = try #require(AgentFlowPromptPreview.make(authoredText: "", sections: [
            .init(tag: "speech", text: "Look at this", color: "#f1f5f9"),
            .init(tag: tag, text: "context payload", color: "#67e8f9")
        ], fileURL: URL(fileURLWithPath: "/tmp/full.md")))
        #expect(preview.hasSuffix("\n\nRead the [full prompt](/tmp/full.md) before answering."))
    }

    @Test func headTailPreviewDoesNotPretendToContainEntireSelection() {
        let full = "start " + String(repeating: "middle ", count: 100) + " end"
        let preview = AgentFlowPromptPreview.excerpt(full, limit: 96)
        #expect(preview.hasPrefix("start") && preview.hasSuffix("end"))
        #expect(preview.contains(" … ") && preview.count <= 96)
    }

    @Test func notificationCopyRetainsCompleteSessionPayloadNotWarningOrPreview() {
        let board = NSPasteboard(name: .init("AgentFlowTests-\(UUID())"))
        defer { board.releaseGlobally() }
        let full = "authored words\n<typed_text start_at=\"123\">exact 😀 &amp; text</typed_text>\n" + String(repeating: "context\n", count: 1500)
        let action = NotificationManager.makeCopyAction(title: "Couldn’t save the prompt file — full text saved in History", copyText: full, on: board)
        board.setString("unrelated later contents", forType: .string)
        action.action()
        #expect(board.string(forType: .string)?.utf8.elementsEqual(full.utf8) == true)
        #expect(board.string(forType: ClipboardManager.pasteSessionType) == nil)
    }

    @Test func ordinaryDiagnosticCopyKeepsItsExistingBehavior() {
        let board = NSPasteboard(name: .init("AgentFlowTests-\(UUID())"))
        defer { board.releaseGlobally() }
        NotificationManager.makeCopyAction(title: "original diagnostic", copyText: nil, on: board).action()
        #expect(board.string(forType: .string) == "original diagnostic")
    }

    @Test func typingSectionKeepsFirstAndLastEditTimes() {
        let session = RecordingSession()
        session.updateTypedInput("first", at: Date(timeIntervalSince1970: 1800000000))
        session.updateTypedInput("first and last", at: Date(timeIntervalSince1970: 1800000003))
        session.endTypingRun()
        session.updateTypedInput("next section", at: Date(timeIntervalSince1970: 1800000007))
        // Republishing unchanged text (an editor flush at commit) is not an edit.
        session.updateTypedInput("next section", at: Date(timeIntervalSince1970: 1800000009))
        // Capture end commits the open section; commit time never replaces edit times.
        session.endLiveSelectionCapture()
        let text = LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "", includeTiming: true)
        #expect(text.contains("<typed_text start_at=\"1800000000.000\" end_at=\"1800000003.000\">"))
        #expect(text.contains("<typed_text start_at=\"1800000007.000\" end_at=\"1800000007.000\">"))
    }

    @Test func deliveryContainsNoAttachmentChoreographyAndKeepsOnePrimaryPaste() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"), encoding: .utf8)
        #expect(!source.contains("CodexLongPaste") && !source.contains("deliverCodexLongMessage"))
        let primary = try #require(source.range(of: "if target.destination.usesBaseCurrentInputDelivery {"))
        let exact = try #require(source.range(of: "precondition(", range: primary.upperBound..<source.endIndex))
        let branch = source[primary.lowerBound..<exact.lowerBound]
        #expect(branch.components(separatedBy: "await deliverPrimaryToCurrentSystemInput(").count == 2)
        #expect(!branch.contains("capture") && !branch.contains("NSWorkspace"))
        let pipeline = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"), encoding: .utf8)
        #expect(pipeline.contains("pasteTargetForDelivery.destination == .primaryCurrentInput"))
        #expect(pipeline.contains("includesSourceContext && !skipPostProcessingNow && !assistant.isFollowUp"))
        #expect(pipeline.contains("copyText: completePromptText ?? completedText"))
        #expect(pipeline.contains("includeTiming: !skipPostProcessingNow, includeReadablePreview: false"))
    }

    @Test func compactRendererFixtureUsesProductionSerialization() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let selected = try #require(LiveSelectionReference("Start of the selected passage " + String(repeating: "middle context ", count: 100) + " end of the selected passage."))
            .timed(at: date)
        let typed = try #require(LiveSelectionReference(typedText: "And this part was typed."))
            .anchored(after: "Here is my request.").timed(at: date, startedAt: date.addingTimeInterval(-2))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/Users/test/Screenshots/Example.png")))
            .anchored(after: "Here is my request.").timed(at: date)
        let references = [selected, typed, screenshot]
        let sections = LiveSelectionReference.compactPromptSections(references, with: "Here is my request. Then I continued.")
        let fixturePath = ProcessInfo.processInfo.environment["AGENTFLOW_PROMPT_PREVIEW_FIXTURE_PATH"]
        let canonical = LiveSelectionReference.interleaving(references,
            with: "Here is my request. Then I continued.", includeTiming: true, includeReadablePreview: true)
        let url: URL
        if let fixturePath {
            // Keep a synthetic real archive beside the explicit test artifact so
            // the host-parser check can open its resolved target and compare bytes.
            let directory = URL(fileURLWithPath: fixturePath).deletingLastPathComponent()
                .appendingPathComponent("Prompt Link Fixture (100%) [é] #?")
            url = try AgentFlowPromptArchive.write(canonical, recordID: UUID(), directory: directory)
            try AgentFlowPromptArchive.writeViewer(canonical, for: url)
        } else {
            url = URL(fileURLWithPath: "/Users/test/Library/Application Support/AgentFlow/Prompts/full-prompt.md")
        }
        let messages = [try #require(AgentFlowPromptPreview.make(
            authoredText: "Here is my request. And this part was typed. Then I continued.",
            sections: sections, fileURL: url,
            viewerURL: AgentFlowPromptArchive.viewerURL(for: url)))]
        #expect(messages.allSatisfy { $0.utf16.count <= 4_000 })
        if let path = fixturePath {
            // Explicit test-only export; synthetic text only, never a live prompt.
            struct Fixture: Encodable { let messages: [String]; let filePath: String; let content: String }
            try JSONEncoder().encode(Fixture(messages: messages, filePath: url.path, content: canonical))
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
