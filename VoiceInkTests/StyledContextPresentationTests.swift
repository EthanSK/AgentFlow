import Foundation
import Testing
@testable import VoiceInkPlusPlus

/// Styled highlight previews are display-only KaTeX paragraphs above the exact
/// context XML. These tests pin the renderer-safety, ordering, budget, Mode, and
/// route boundaries established from the installed Codex bundle (see the
/// `LiveSelectionStyledMath` comment). They cannot prove live bubble pixels.
struct StyledContextPresentationTests {
    @Test func plainPresentationIsTheUnchangedCanonicalGrammar() throws {
        let selection = try #require(LiveSelectionReference("Look at <this> & that"))
        let typed = try #require(LiveSelectionReference(typedText: "typed words"))
        let screenshot = try #require(LiveSelectionReference(
            screenshotURL: URL(fileURLWithPath: "/Users/test/Screenshots/shot.png")
        ))
        let references = [
            selection.anchored(after: "Compare"),
            typed.anchored(after: "Compare this"),
            screenshot.anchored(after: "Compare this")
        ]
        let byDefault = LiveSelectionReference.interleaving(references, with: "Compare this now")
        let plain = LiveSelectionReference.interleaving(
            references, with: "Compare this now", presentation: .plain
        )

        #expect(plain == byDefault)
        #expect(!plain.contains("\\("))
        #expect(!plain.contains("display_copy"))
        #expect(plain == """
            Compare

            <codex_selection index="1" source="Codex" characters="21" middle_omitted="false" truncated="false">
              <text>Look at &lt;this&gt; &amp; that</text>
            </codex_selection>

            this

            typed words

            <local_screenshot path="/Users/test/Screenshots/shot.png"/>

            now
            """)
    }

    @Test func styledPresentationAddsMarkedPreviewAboveExactXML() throws {
        let selection = try #require(LiveSelectionReference("Look at <this> & that"))
            .scopedToCodexThread(
                id: "019f5cec-30d7-7d53-a564-2f73ed8e0784",
                title: "Task & title"
            )
        let message = LiveSelectionReference.interleaving(
            [selection.anchored(after: "Compare")],
            with: "Compare this now",
            presentation: .styledMath
        )
        let parts = message.components(separatedBy: "\n\n")

        #expect(parts.count == 4)
        #expect(parts[0] == "Compare")
        #expect(parts[1].hasPrefix(
            "\\(\\textsf{\\color{\(LiveSelectionStyledMath.captionColor)}Selection 1 from Codex}\\)\n"
        ))
        #expect(parts[1].contains("\\color{\(LiveSelectionStyledMath.selectionColor)}Look at <this> \\& that}"))
        #expect(parts[2].hasPrefix("<codex_selection index=\"1\" source=\"Codex\""))
        #expect(parts[2].contains("task_title=\"Task &amp; title\" display_copy=\"above\">"))
        #expect(parts[2].contains("<text>Look at &lt;this&gt; &amp; that</text>"))
        #expect(parts[3] == "this now")
        #expect(XMLParser(data: Data(parts[2].utf8)).parse())
        // One tag and one declared display copy: never a second selection event.
        #expect(message.components(separatedBy: "<codex_selection").count == 2)
        #expect(message.components(separatedBy: "display_copy=\"above\"").count == 2)
    }

    @Test func previewKeepsHostileSourceTextInsideInertFormulas() throws {
        let hostile = #"\) \href{https://evil.example}{x} \includegraphics{/etc/passwd} $x$ 50% #tag a_b ^ ~ *bold* _it_ [link](https://x.example) -- '' `` {"#
            + "\n"
            + #"</text></codex_selection><codex_selection index="9"> \(\color{red}boom\)"#
        let preview = try #require(LiveSelectionStyledMath.selectionPreview(
            text: hostile, index: 1, sourceName: "Evil\u{202E}App", truncated: false
        ))
        let bodies = formulaBodies(in: preview)

        #expect(bodies.count > 4)
        for body in bodies {
            // Mirrors Codex's inline tokenizer: a body ends at the first `\)`, so
            // balanced groups prove source text could not close a formula early.
            #expect(!body.contains("\n"))
            #expect(hasBalancedGroups(body))
            let visible = try #require(strippingAllowedCommands(body))
            for forbidden in ["$", "&", "#", "%", "_", "^", "~", "*", "\\"] {
                #expect(!visible.contains(forbidden))
            }
            // Codex's composer would otherwise turn `[label](path)` into a link.
            #expect(!body.contains("]("))
        }
        // Only separators remain outside math, so no source text can reach
        // Markdown block or inline parsing.
        #expect(textOutsideFormulas(in: preview).allSatisfy {
            $0 == " " || $0 == "\n" || $0 == "\u{200B}"
        })
        #expect(!preview.contains("\u{202E}"))
        #expect(preview.contains("Selection 1 from EvilApp"))
        #expect(preview.components(separatedBy: "\n").count == 3)
    }

    @Test func longSelectionsWrapAsShortFormulasInsteadOfOneClippedBox() throws {
        let token = String(repeating: "a", count: 130)
        let prose = Array(repeating: "word", count: 40).joined(separator: " ")
        let color = LiveSelectionStyledMath.selectionColor
        let preview = LiveSelectionStyledMath.formulas(for: token + " " + prose, color: color)
        let bodies = formulaBodies(in: preview)
        let prefix = "\\textsf{\\color{\(color)}"

        #expect(bodies.count > 6)
        for body in bodies {
            #expect(body.hasPrefix(prefix))
            #expect(body.hasSuffix("}"))
            let visible = body.dropFirst(prefix.count).dropLast()
            #expect(visible.count <= LiveSelectionStyledMath.maxChunkWidth)
        }
        // The over-long token is split without inserting a visible space.
        let fullPiece = "\\(" + prefix + String(repeating: "a", count: 24) + "}\\)"
        #expect(preview.hasPrefix(
            Array(repeating: fullPiece, count: 5).joined(separator: "\u{200B}") + "\u{200B}"
        ))
        #expect(!preview.contains("\n"))
    }

    @Test func multilineCodeGetsOneFormulaLinePerSourceLineWithInertIndentation() throws {
        let code = "func greet() {\n    print(\"hi\")\n\n\t// done\n}"
        let preview = try #require(LiveSelectionStyledMath.selectionPreview(
            text: code, index: 2, sourceName: "Xcode", truncated: false
        ))
        let lines = preview.components(separatedBy: "\n")
        let color = LiveSelectionStyledMath.selectionColor

        // Caption plus four non-blank source lines; the blank line collapses.
        #expect(lines.count == 5)
        for line in lines {
            #expect(line.hasPrefix("\\(\\textsf{\\color{"))
            #expect(line.hasSuffix("}\\)"))
        }
        #expect(lines[0].contains("Selection 2 from Xcode"))
        #expect(lines[1].contains("func greet() \\{"))
        #expect(lines[2].hasPrefix("\\(\\textsf{\\color{\(color)}\\ \\ \\ \\ print("))
        #expect(lines[3].hasPrefix("\\(\\textsf{\\color{\(color)}\\ \\ \\ \\ //"))
        #expect(lines[4] == "\\(\\textsf{\\color{\(color)}\\}}\\)")
    }

    @Test func indentationAndWideLatinLettersShareTheFormulaWidthBudget() throws {
        let color = LiveSelectionStyledMath.selectionColor
        let prefix = "\\textsf{\\color{\(color)}"
        let preview = LiveSelectionStyledMath.formulas(
            for: "        " + String(repeating: "W", count: 50), color: color
        )
        let bodies = formulaBodies(in: preview)
        #expect(bodies.count == 5)
        for body in bodies {
            let visible = String(body.dropFirst(prefix.count).dropLast())
                .replacingOccurrences(of: "\\ ", with: " ")
            #expect(LiveSelectionStyledMath.displayWidth(of: visible) <= 24)
        }
        #expect(bodies[0].contains(String(repeating: "W", count: 8)))
        #expect(!bodies[0].contains(String(repeating: "W", count: 9)))
    }

    /// Optional synthetic-only fixture for the release renderer check. It calls
    /// the production serializer, never reads a user's selections or screenshots.
    @Test func styledRendererFixtureUsesProductionSerialization() throws {
        let examples = [
            "Selected context stays cyan, with source text preserved below.",
            "func greet() {\n    print(\"Hello & goodbye\")\n}",
            "        " + String(repeating: "W", count: 70),
            "cafe\u{0301} 😀 漢字 العربية नमस्ते a\u{1AB0} <tag> 50% a_b \\) [link](x) *bold*",
            "First line\nSecond line\nThird line\nFourth line\nFifth line"
        ]
        var messages: [String] = []
        for text in examples {
            let reference = try #require(LiveSelectionReference(text))
            messages.append(LiveSelectionReference.interleaving(
                [reference.anchored(after: "Look")], with: "Look here", presentation: .styledMath
            ))
        }
        let screenshot = try #require(LiveSelectionReference(
            screenshotURL: URL(fileURLWithPath: "/Users/test/Screenshots/Screenshot 2026-09-26 at 20.59.11.png")
        ))
        messages.append(LiveSelectionReference.interleaving(
            [screenshot], with: "Screenshot example", presentation: .styledMath
        ))
        #expect(messages.allSatisfy { $0.contains("display_copy=\"above\"") })
        if let path = ProcessInfo.processInfo.environment["AGENTFLOW_STYLED_CONTEXT_FIXTURE_PATH"] {
            try JSONEncoder().encode(messages).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test func unicodeStaysRenderableAndControlsCannotDisguiseThePreview() throws {
        let color = LiveSelectionStyledMath.selectionColor
        let wide = LiveSelectionStyledMath.formulas(
            for: String(repeating: "漢", count: 30), color: color
        )
        // Wide characters count twice: 12 per formula.
        #expect(formulaBodies(in: wide).count == 3)

        let accents = LiveSelectionStyledMath.formulas(for: "cafe\u{0301} a\u{0331}", color: color)
        #expect(accents.contains("caf\u{00E9} a"))
        #expect(!accents.unicodeScalars.contains { (0x0300...0x036F).contains($0.value) })

        let disguised = LiveSelectionStyledMath.formulas(
            for: "safe\u{202E}txt.exe\u{0007}\u{0000}😀", color: color
        )
        #expect(!disguised.contains("\u{202E}"))
        #expect(!disguised.unicodeScalars.contains { $0.value < 0x20 })
        #expect(disguised.contains("safetxt.exe😀"))
    }

    @Test func previewsStayInsideCodexPasteBudgetAndNeverMarkAMissingPreview() throws {
        let long = (0..<5)
            .map { line in String(repeating: "word\(line) ", count: 16) }
            .joined(separator: "\n")
        let selection = try #require(LiveSelectionReference(long))
        let references = Array(repeating: selection.anchored(after: "Look"), count: 4)
        let plain = LiveSelectionReference.interleaving(references, with: "Look")
        let styled = LiveSelectionReference.interleaving(
            references, with: "Look", presentation: .styledMath
        )
        let parts = styled.components(separatedBy: "\n\n")
        let marked = styled.components(separatedBy: "display_copy=\"above\"").count - 1
        let captions = styled.components(separatedBy: "}Selection ").count - 1

        #expect(plain.utf16.count < LiveSelectionStyledMath.messageUTF16Budget)
        #expect(styled.utf16.count <= LiveSelectionStyledMath.messageUTF16Budget)
        #expect(marked >= 1)
        #expect(marked < references.count)
        #expect(marked == captions)
        // Capture order wins the budget; a tag without a preview stays canonical.
        let first = try #require(parts.first { $0.hasPrefix("<codex_selection index=\"1\"") })
        let last = try #require(parts.first { $0.hasPrefix("<codex_selection index=\"4\"") })
        #expect(first.contains("display_copy=\"above\""))
        #expect(!last.contains("display_copy"))
        // Removing previews and markers recovers the exact plain message.
        let restored = parts
            .filter { !$0.hasPrefix("\\(") }
            .joined(separator: "\n\n")
            .replacingOccurrences(of: " display_copy=\"above\"", with: "")
        #expect(restored == plain)

        let crowded = Array(repeating: selection.anchored(after: "Look"), count: 9)
        let crowdedPlain = LiveSelectionReference.interleaving(crowded, with: "Look")
        #expect(crowdedPlain.utf16.count > LiveSelectionStyledMath.messageUTF16Budget)
        #expect(LiveSelectionReference.interleaving(
            crowded, with: "Look", presentation: .styledMath
        ) == crowdedPlain)
    }

    @Test func screenshotPreviewIsPurpleAndKeepsExactPathTag() throws {
        let screenshot = try #require(LiveSelectionReference(
            screenshotURL: URL(fileURLWithPath: "/Users/test/Screenshots/Screenshot & <one> at 20.59.11.png")
        ))
        let message = LiveSelectionReference.interleaving(
            [screenshot], with: "", presentation: .styledMath
        )
        let parts = message.components(separatedBy: "\n\n")

        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix(
            "\\(\\textsf{\\color{\(LiveSelectionStyledMath.captionColor)}Screenshot}\\) "
            + "\\(\\textsf{\\color{\(LiveSelectionStyledMath.screenshotColor)}"
        ))
        #expect(parts[0].contains("\\&"))
        #expect(parts[1] == "<local_screenshot path=\"/Users/test/Screenshots/Screenshot &amp; &lt;one&gt; at 20.59.11.png\" display_copy=\"above\"/>")
        #expect(XMLParser(data: Data(parts[1].utf8)).parse())
        // A saved path only: no Markdown image or pixel payload is invented.
        #expect(!message.contains("!["))
        #expect(!message.contains("includegraphics"))
    }

    @Test func styledPresentationKeepsSpeechTypedTextAndReferenceOrder() throws {
        let first = try #require(LiveSelectionReference("first highlight"))
        let typed = try #require(LiveSelectionReference(typedText: "typed *words* stay_verbatim"))
        let second = try #require(LiveSelectionReference("second highlight"))
            .scopedToApplication(name: "TextEdit", bundleID: "com.apple.TextEdit")
        let message = LiveSelectionReference.interleaving(
            [
                first.anchored(after: "One"),
                typed.anchored(after: "One two"),
                second.anchored(after: "One two")
            ],
            with: "One two three",
            presentation: .styledMath
        )
        let parts = message.components(separatedBy: "\n\n")

        #expect(parts.count == 8)
        #expect(parts[0] == "One")
        #expect(parts[1].contains("Selection 1 from Codex"))
        #expect(parts[2].hasPrefix("<codex_selection index=\"1\""))
        #expect(parts[3] == "two")
        // Authored keyboard prose is neither styled nor escaped.
        #expect(parts[4] == "typed *words* stay_verbatim")
        // The caption names the app where text was highlighted, not a recipient.
        #expect(parts[5].contains("Selection 2 from"))
        #expect(parts[5].contains("TextEdit"))
        #expect(parts[6].hasPrefix("<app_selection index=\"2\" source=\"TextEdit\""))
        #expect(parts[6].contains("bundle_id=\"com.apple.TextEdit\" display_copy=\"above\">"))
        #expect(parts[7] == "three")
    }

    @Test func truncatedSelectionPreviewEndsWithQuietEllipsis() throws {
        let reference = try #require(LiveSelectionReference(String(repeating: "abc ", count: 200)))
        #expect(reference.truncated)
        let message = LiveSelectionReference.interleaving(
            [reference], with: "", presentation: .styledMath
        )
        let preview = try #require(message.components(separatedBy: "\n\n").first)
        #expect(preview.hasSuffix(
            " \\(\\textsf{\\color{\(LiveSelectionStyledMath.captionColor)}…}\\)"
        ))
        #expect(message.contains("truncated=\"true\" display_copy=\"above\">"))
    }

    @Test @MainActor func styledHighlightsModeSettingDefaultsOffAndRoundTrips() throws {
        let legacy = #"{"id":"6F1A1D1E-0000-4000-8000-000000000001","name":"Codex","isAIEnhancementEnabled":false}"#
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: Data(legacy.utf8))
        #expect(!decoded.isStyledContextEnabled)
        #expect(!ModeConfig(name: "New", isAIEnhancementEnabled: false).isStyledContextEnabled)

        var enabled = decoded
        enabled.isStyledContextEnabled = true
        let roundTripped = try JSONDecoder().decode(
            ModeConfig.self, from: JSONEncoder().encode(enabled)
        )
        #expect(roundTripped.isStyledContextEnabled)
        // The pipeline reads the flag from the Mode the route already resolved.
        #expect(ModeRuntimeResolver.pasteTargetOutputConfiguration(
            mode: roundTripped
        ).mode?.isStyledContextEnabled == true)
        #expect(ModeRuntimeResolver.pasteTargetOutputConfiguration(
            mode: nil
        ).mode == nil)
    }

    @Test func styledContextUsesResolvedRouteModeWithoutTouchingDeliveryRoutes() throws {
        let pipeline = try repositorySource("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift")
        let clipboardBranch = try #require(pipeline.range(
            of: "        if completionDispositionNow == .clipboardOnly {"
        ))
        let pasteTarget = try #require(pipeline.range(
            of: "        let pasteTargetForDelivery = await resolvePasteTarget()",
            range: clipboardBranch.upperBound..<pipeline.endIndex
        ))
        let clipboardBody = pipeline[clipboardBranch.lowerBound..<pasteTarget.lowerBound]
        // Clipboard-only resolves no Mode output, so it keeps the plain grammar.
        #expect(clipboardBody.contains("attachLiveSelectionsToFinalText()"))
        #expect(!clipboardBody.contains("styledMath"))

        let routeOutput = try #require(pipeline.range(
            of: "let outputForPasteTarget = routeResolvedOutput",
            range: pasteTarget.upperBound..<pipeline.endIndex
        ))
        let lease = try #require(pipeline.range(
            of: "guard await acquireDeliveryLease(deliveryLeasePolicy)",
            range: routeOutput.upperBound..<pipeline.endIndex
        ))
        let decision = pipeline[routeOutput.upperBound..<lease.lowerBound]
        #expect(decision.contains("outputForPasteTarget.mode?.isStyledContextEnabled == true"))
        #expect(decision.contains("outputForPasteTarget.outputMode == .paste"))
        #expect(decision.contains("!skipPostProcessingNow"))
        let finalBoundary = try #require(pipeline.range(of: "pipeline: about to DELIVER", range: lease.upperBound..<pipeline.endIndex))
        let afterQueue = pipeline[lease.upperBound..<finalBoundary.lowerBound]
        #expect(afterQueue.contains("presentation: contextPresentation"))
        #expect(afterQueue.contains("LiveContextPastePolicy.includesSourceContext("))

        // Presentation never reaches Primary/Next delivery, paste, or capture code.
        for path in [
            "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift",
            "VoiceInk/Paste/CursorPaster.swift",
            "VoiceInk/Paste/ClipboardManager.swift",
            "VoiceInk/Transcription/Engine/RecordingSession.swift"
        ] {
            let source = try repositorySource(path)
            #expect(!source.contains("styledMath"))
            #expect(!source.contains("isStyledContextEnabled"))
            #expect(!source.contains("LiveSelectionStyledMath"))
        }
        // Screenshot pixels are never read or attached by the styled path.
        let capture = try repositorySource("VoiceInk/Services/LiveSelectionCapture.swift")
        #expect(!capture.contains("NSPasteboard"))
        #expect(!capture.contains("NSImage"))
        #expect(!capture.contains("Data(contentsOf"))
    }

    @Test func capturedContextIsOnlyPastedIntoNativeAgentApps() {
        for bundle in ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"] {
            #expect(LiveContextPastePolicy.includesSourceContext(
                destination: .primaryCurrentInput,
                currentApplicationBundleIdentifier: bundle,
                savedTargetBundleIdentifier: "com.google.Chrome"
            ))
            for route in [RecordingPasteDestination.recordingStart, .focusedDuringTranscription] {
                #expect(LiveContextPastePolicy.includesSourceContext(
                    destination: route,
                    currentApplicationBundleIdentifier: "com.google.Chrome",
                    savedTargetBundleIdentifier: bundle
                ))
            }
        }
        for bundle in [nil, "com.google.Chrome", "com.apple.Safari", "com.microsoft.VSCode",
                       "com.apple.Terminal", "ru.keepcoder.Telegram", "unknown.app"] as [String?] {
            #expect(!LiveContextPastePolicy.includesSourceContext(
                destination: .primaryCurrentInput,
                currentApplicationBundleIdentifier: bundle,
                savedTargetBundleIdentifier: "com.openai.codex"
            ))
            for route in [RecordingPasteDestination.recordingStart, .focusedDuringTranscription] {
                #expect(!LiveContextPastePolicy.includesSourceContext(
                    destination: route,
                    currentApplicationBundleIdentifier: "com.openai.codex",
                    savedTargetBundleIdentifier: bundle
                ))
            }
        }
    }

    @Test func excludingCapturedContextKeepsInterleavedTypingAndSpeech() throws {
        let highlight = try #require(LiveSelectionReference("selected source"))
        let screenshot = try #require(LiveSelectionReference(
            screenshotURL: URL(fileURLWithPath: "/Users/test/shot.png")
        ))
        let typed = try #require(LiveSelectionReference(typedText: "typed words"))
        let references = [highlight, typed, screenshot].map { $0.anchored(after: "One") }
        let proseOnly = LiveSelectionReference.interleaving(
            references.filter(\.isTypedText), with: "One two", presentation: .styledMath
        )
        #expect(proseOnly == "One\n\ntyped words\n\ntwo")
        #expect(!proseOnly.contains("<"))
        #expect(!proseOnly.contains("\\("))
    }

    // MARK: - Helpers

    /// Mirrors Codex's inline math tokenizer: `\(` up to the first `\)`.
    private func formulaBodies(in text: String) -> [String] {
        var bodies: [String] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "\\(", range: searchStart..<text.endIndex) {
            guard let close = text.range(of: "\\)", range: open.upperBound..<text.endIndex) else {
                break
            }
            bodies.append(String(text[open.upperBound..<close.lowerBound]))
            searchStart = close.upperBound
        }
        return bodies
    }

    private func textOutsideFormulas(in text: String) -> String {
        var outside = ""
        var searchStart = text.startIndex
        while let open = text.range(of: "\\(", range: searchStart..<text.endIndex),
              let close = text.range(of: "\\)", range: open.upperBound..<text.endIndex) {
            outside += text[searchStart..<open.lowerBound]
            searchStart = close.upperBound
        }
        outside += text[searchStart...]
        return outside
    }

    private func hasBalancedGroups(_ body: String) -> Bool {
        var depth = 0
        var escaped = false
        for character in body {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return false }
            default:
                break
            }
        }
        return depth == 0 && !escaped
    }

    /// Returns the characters KaTeX would typeset after removing the only
    /// commands the preview may emit, or nil if any other command appears.
    private func strippingAllowedCommands(_ body: String) -> String? {
        let commands = [
            "\\textbackslash{}", "\\textasciicircum{}", "\\textasciitilde{}", "\\textsf{",
            "\\{", "\\}", "\\$", "\\&", "\\#", "\\%", "\\_", "\\ "
        ]
        var visible = ""
        var index = body.startIndex
        while index < body.endIndex {
            let rest = body[index...]
            if rest.hasPrefix("\\color{") {
                guard let close = rest.firstIndex(of: "}") else { return nil }
                index = body.index(after: close)
                continue
            }
            if body[index] == "\\" {
                guard let command = commands.first(where: { rest.hasPrefix($0) }) else {
                    return nil
                }
                index = body.index(index, offsetBy: command.count)
                continue
            }
            visible.append(body[index])
            index = body.index(after: index)
        }
        return visible
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
