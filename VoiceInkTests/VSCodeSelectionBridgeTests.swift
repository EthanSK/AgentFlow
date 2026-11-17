import Foundation
import ApplicationServices
import Testing
@testable import VoiceInkPlusPlus

struct VSCodeSelectionBridgeTests {
    @Test func startupSelectionUsesAFreshSnapshotWithoutANewGesture() {
        let startup = VSCodeSelectionBridge.Request(nonce: request.nonce, sourcePID: 42,
            gestureStartedAt: 10_000, requestedAt: 10_000, surface: "editor", captureKind: "startup")
        var snapshot = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: 42, changedAt: nil, text: "already selected", surface: "editor",
            observedAt: 10_020, captureKind: "startup")
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == "already selected")
        snapshot.captureKind = nil
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
        snapshot.captureKind = "startup"
        snapshot.surface = "terminal"
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
        snapshot.surface = "editor"
        for observed in [9999.0, 10_051, Double.nan] {
            snapshot.observedAt = observed
            #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
        }
    }

    @Test func startupSnapshotCannotSatisfyALiveGestureOrAnUnprovenPane() {
        let snapshot = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: 42, changedAt: 9500, text: "selected", surface: "editor",
            observedAt: 10_020, captureKind: "startup")
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: request, now: 10_050) == nil)
        var startup = request
        startup.captureKind = "startup"
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
    }

    @Test func startupTerminalSnapshotRequiresTheSamePaneAndFreshObservation() {
        let startup = VSCodeSelectionBridge.Request(nonce: request.nonce, sourcePID: 42,
            gestureStartedAt: 10_000, requestedAt: 10_000, surface: "terminal", captureKind: "startup")
        var snapshot = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: 42, changedAt: 5000, text: "old terminal highlight", surface: "terminal",
            observedAt: 10_020, captureKind: "startup")
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == "old terminal highlight")
        snapshot.surface = "editor"
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
        snapshot.surface = "terminal"
        snapshot.observedAt = nil
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: startup, now: 10_050) == nil)
    }

    @Test func vscodeBridgeOnlyWritesTheApprovedTreeRequest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/VSCodeSelectionBridge.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "AXUIElementSetAttributeValue(").count == 2)
        #expect(source.contains("AXUIElementSetAttributeValue(app, \"AXManualAccessibility\" as CFString, kCFBooleanTrue)"))
        for forbidden in ["NSPasteboard", "AXUIElementPerformAction", "kAXFocusedAttribute", "kCFBooleanFalse", "CGEvent"] {
            #expect(!source.contains(forbidden))
        }
    }
    @Test func terminalReadRejectsEditorRepliesAndRequiresFreshSnapshot() {
        let terminal = VSCodeSelectionBridge.Request(nonce: request.nonce, sourcePID: 42,
            gestureStartedAt: 9000, requestedAt: 10_000, surface: "terminal")
        let editor = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: 42, changedAt: 9500, text: "old editor")
        #expect(VSCodeSelectionBridge.validatedText(editor, for: terminal, now: 10_050) == nil)
        var snapshot = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: 42, changedAt: nil, text: "terminal", surface: "terminal", observedAt: 10_020)
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: terminal, now: 10_050) == "terminal")
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: request, now: 10_050) == nil)
        snapshot.observedAt = 9999
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: terminal, now: 10_050) == nil)
        snapshot.observedAt = 10_051
        #expect(VSCodeSelectionBridge.validatedText(snapshot, for: terminal, now: 10_050) == nil)
    }

    @Test func terminalFocusIsDistinctFromMonacoAndOtherTextFields() {
        #expect(VSCodeSelectionBridge.surface(role: kAXTextFieldRole, label: "Terminal 21, frontend") == "terminal")
        #expect(VSCodeSelectionBridge.surface(role: kAXTextFieldRole, label: "Terminal input") == "terminal")
        #expect(VSCodeSelectionBridge.surface(role: kAXTextAreaRole, label: "The editor is not accessible") == "editor")
        #expect(VSCodeSelectionBridge.surface(role: kAXTextFieldRole, label: "Search") == nil)
        #expect(VSCodeSelectionBridge.surface(role: kAXGroupRole, label: "Terminal 21, frontend") == nil)
    }
    @Test func keyboardBridgeRequiresMatchingInputKindAndPreservesOldMouseReplies() {
        let keyboard = VSCodeSelectionBridge.Request(nonce: "12345678-1234-1234-1234-123456789012",
            sourcePID: 42, gestureStartedAt: 9000, requestedAt: 10_000, inputKind: "keyboard")
        let response = VSCodeSelectionBridge.Response(version: 1, nonce: keyboard.nonce,
            sourcePID: 42, changedAt: 9500, text: "selected", inputKind: "keyboard")
        #expect(VSCodeSelectionBridge.validatedText(response, for: keyboard, now: 10_050) == "selected")
        var wrong = response
        wrong.inputKind = "mouse"
        #expect(VSCodeSelectionBridge.validatedText(wrong, for: keyboard, now: 10_050) == nil)
        wrong.inputKind = nil
        #expect(VSCodeSelectionBridge.validatedText(wrong, for: keyboard, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response, for: request, now: 10_050) == nil)
    }

    @Test func editorLocationTravelsWithValidatedSelection() throws {
        let location = VSCodeSelectionBridge.EditorLocation(
            documentKind: .git, filePath: "/repo/Source & Test.swift", documentName: nil, gitRef: "HEAD", diffSide: .original,
            documentVersion: 4, unsaved: false, startLine: 10, startColumn: 3, endLine: 13, endColumn: 6,
            capturedEndLine: 12, capturedEndColumn: 4
        )
        let response = VSCodeSelectionBridge.Response(version: 1, nonce: request.nonce,
            sourcePID: request.sourcePID, changedAt: 9500, text: "  let value = \"<source>\"", surface: "editor", location: location)
        let selection = try #require(VSCodeSelectionBridge.validatedSelection(response, for: request, now: 10_050))
        #expect(selection.location == location)

        let reference = try #require(LiveSelectionReference(selection.text, editorLocation: selection.location))
            .scopedToApplication(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        let xml = LiveSelectionReference.interleaving([reference], with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try AgentFlowPromptArchive.write(xml, recordID: UUID(), directory: directory)
        #expect(try String(contentsOf: archive, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + xml)
        #expect(xml.contains(#"file_path="/repo/Source &amp; Test.swift" git_ref="HEAD" diff_side="original""#))
        #expect(xml.contains(#"start_line="10" start_column="3" end_line="13" end_column="6""#))
        #expect(xml.contains(#"column_encoding="utf16" range_end="exclusive""#))
        #expect(xml.contains(#"captured_end_line="12" captured_end_column="4""#))
        #expect(xml.contains(#"truncated="true""#))
        #expect(xml.contains(#"<text>  let value = "&lt;source&gt;"</text>"#))

        var oldCompanion = response
        oldCompanion.location = nil
        #expect(VSCodeSelectionBridge.validatedSelection(oldCompanion, for: request, now: 10_050)?.text == selection.text)
        #expect(VSCodeSelectionBridge.validatedSelection(oldCompanion, for: request, now: 10_050)?.location == nil)
    }

    private let request = VSCodeSelectionBridge.Request(
        nonce: "12345678-1234-1234-1234-123456789012", sourcePID: 42,
        gestureStartedAt: 9000, requestedAt: 10_000
    )

    @Test func vscodeBridgeAcceptsOnlyFreshMatchingGestureAndProcess() {
        func response(nonce: String? = nil, pid: Int32 = 42, time: Double = 9500, text: String = "chosen code") -> VSCodeSelectionBridge.Response {
            .init(version: 1, nonce: nonce ?? request.nonce, sourcePID: pid, changedAt: time, text: text)
        }
        #expect(VSCodeSelectionBridge.validatedText(response(), for: request, now: 10_050) == "chosen code")
        #expect(VSCodeSelectionBridge.validatedText(response(nonce: "old"), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(pid: 43), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: 8000), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: .nan), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(time: 11_000), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(), for: request, now: 12_000) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(text: " \n"), for: request, now: 10_050) == nil)
        #expect(VSCodeSelectionBridge.validatedText(response(text: String(repeating: "a", count: 8193)), for: request, now: 10_050) == nil)
    }

    @Test func vscodeBridgeDoesNotClaimOtherAppsOrChangeXMLBudget() throws {
        #expect(VSCodeSelectionBridge.supports("com.microsoft.VSCode"))
        #expect(VSCodeSelectionBridge.supports("com.microsoft.VSCodeInsiders"))
        #expect(!VSCodeSelectionBridge.supports("com.google.Chrome"))
        #expect(!VSCodeSelectionBridge.supports(nil))
        let reference = try #require(LiveSelectionReference("let selected = true"))
        #expect(reference.scopedToApplication(name: "Code", bundleID: "com.microsoft.VSCode").preview == reference.preview)
        // Transport limits belong to the bridge, not the canonical archive.
        #expect(try #require(LiveSelectionReference(String(repeating: "a", count: 20_000))).truncated == false)
    }
}
