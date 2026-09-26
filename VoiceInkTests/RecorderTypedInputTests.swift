import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

struct RecorderTypedInputTests {
    @Test @MainActor func liveTypingHeightGrowsBeforeBlurAndCapsAtScreenBudget() {
        let short = MiniRecorderLayoutMetrics.typingHeight(text: "hello", width: 640, maxHeight: 500)
        let long = MiniRecorderLayoutMetrics.typingHeight(text: String(repeating: "long typed line\n", count: 15), width: 640, maxHeight: 500)
        #expect(short == 60)
        #expect(long > short)
        #expect(MiniRecorderLayoutMetrics.typingHeight(text: String(repeating: "word ", count: 900), width: 640, maxHeight: 500) == 500)
        let empty = MiniRecorderLayoutMetrics.contextHeight(parts: [], typedText: "", width: 640, maxHeight: 500)
        let active = MiniRecorderLayoutMetrics.contextHeight(parts: [], typedText: String(repeating: "line\n", count: 12), width: 640, maxHeight: 500)
        #expect(active > empty)
        #expect(active <= 500)
    }

    @Test @MainActor func trailingNewlineAndNarrowerEditorIncreaseHeight() {
        let text = "one\ntwo\nthree"
        #expect(MiniRecorderLayoutMetrics.typingHeight(text: text + "\n", width: 640, maxHeight: 500)
            > MiniRecorderLayoutMetrics.typingHeight(text: text, width: 640, maxHeight: 500))
        let prose = String(repeating: "a few typed words ", count: 30)
        #expect(MiniRecorderLayoutMetrics.typingHeight(text: prose, width: 300, maxHeight: 1000)
            > MiniRecorderLayoutMetrics.typingHeight(text: prose, width: 640, maxHeight: 1000))
    }

    @Test @MainActor func focusIsOptInAndFinishDisarmsIt() throws {
        let session = RecordingSession()
        session.recordLiveSelection(try #require(LiveSelectionReference("before typing")))
        #expect(!session.typingFocus.isEnabled)
        let editor = RecorderTypingTextView()
        session.typingFocus.enable(editor)
        #expect(session.typingFocus.isEnabled)
        session.recordLiveSelection(try #require(LiveSelectionReference("after typing")))
        #expect(session.typingFocus.isEnabled)
        session.typingFocus.disable(releaseKeyboard: false)
        session.recordLiveSelection(try #require(LiveSelectionReference("after unfocus")))
        #expect(!session.typingFocus.isEnabled)
        session.typingFocus.enable(editor)
        session.endLiveSelectionCapture()
        #expect(!session.typingFocus.isEnabled)
    }

    @Test @MainActor func initialFocusCannotArmFinishedSessionOrSurviveUnfocus() {
        let finished = RecordingSession(phase: .transcribing)
        finished.typingFocus.requestInitialFocus()
        #expect(!finished.typingFocus.isEnabled)
        let active = RecordingSession()
        active.typingFocus.requestInitialFocus()
        #expect(active.typingFocus.initialFocusPending)
        active.typingFocus.disable(releaseKeyboard: false)
        #expect(!active.typingFocus.initialFocusPending)
        #expect(!active.typingFocus.isEnabled)
    }

    @Test func commandExtendedPrimaryChordKeepsOnePressAndForwardsReleases() {
        let shortcut = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.shift, .control, .option])
        #expect(ShortcutMonitor.supportsTypingVariant(shortcut))
        #expect(ShortcutMonitor.isTypingModifierChord([.shift, .control, .option, .command]))
        for commandFirst in [false, true] {
            var down = false
            var starts = 0
            var stops = 0
            let keys: [(UInt16, NSEvent.ModifierFlags)] = commandFirst ? [
                (55, [.command]), (56, [.command, .shift]), (59, [.command, .shift, .control]),
                (58, [.command, .shift, .control, .option]), (55, [.shift, .control, .option]),
                (58, [.shift, .control]), (59, [.shift]), (56, [])
            ] : [
                (56, [.shift]), (59, [.shift, .control]), (58, [.shift, .control, .option]),
                (55, [.command, .shift, .control, .option]), (55, [.shift, .control, .option]),
                (58, [.shift, .control]), (59, [.shift]), (56, [])
            ]
            for (index, event) in keys.enumerated() {
                let result = ShortcutMonitor.typingAwareModifierTransition(shortcut: shortcut,
                    typingVariant: true, wasDown: down, keyCode: event.0, modifierFlags: event.1)
                down = result.isDown
                if result.dispatchKeyDown { starts += 1 }
                if result.dispatchKeyUp { stops += 1 }
                if index >= 4 { #expect(!result.suppressDownstream) }
            }
            #expect(starts == 1 && stops == 1 && !down)
        }
    }

    @Test @MainActor func nativeEditorReturnAddsNewlineAndBlurSealsOnlyOnce() {
        let session = RecordingSession()
        let input = RecorderTypedInput(
            text: Binding(get: { session.typedInput }, set: { session.updateTypedInput($0) }),
            focusRequest: UUID(), onEndEditing: { session.endTypingRun() }
        )
        let coordinator = input.makeCoordinator()
        let editor = RecorderTypingTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 60))
        editor.isRichText = false
        editor.delegate = coordinator
        editor.onEndEditing = input.onEndEditing
        editor.insertText("line one", replacementRange: NSRange(location: 0, length: 0))
        editor.insertNewline(nil)
        editor.insertText("line two", replacementRange: editor.selectedRange())
        #expect(session.typedInput == "line one\nline two")
        #expect(session.phase == .recording)
        _ = editor.resignFirstResponder()
        _ = editor.resignFirstResponder()
        #expect(session.typedInput.isEmpty)
        #expect(session.liveSelectionReferences.count == 1)
        #expect(LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "") == "line one\nline two")
        #expect(session.phase == .recording)
    }

    @Test func typedProseIsVerbatimAndDoesNotConsumeSelectionNumbers() throws {
        let typed = try #require(LiveSelectionReference(typedText: "Use <T> & keep\nthese words."))
        let selection = try #require(LiveSelectionReference("a source"))
        let message = LiveSelectionReference.interleaving([typed, selection], with: "")
        #expect(message.hasPrefix("Use <T> & keep\nthese words.\n\n"))
        #expect(message.contains("<codex_selection index=\"1\""))
        #expect(typed.isTypedText && !typed.isSelection)
        #expect(LiveSelectionReference(typedText: " \n\t") == nil)
        #expect(LiveSelectionReference.previewParts([typed], with: "") == [
            .speech("Use <T> & keep\nthese words.")
        ])
    }

    @Test @MainActor func typingEditsOneRunAndRecognitionCannotOverwriteIt() {
        let session = RecordingSession()
        session.partialTranscript = "Speech first"
        session.updateTypedInput("typed")
        session.updateTypedInput("typed words")
        session.partialTranscript = "Speech first and later"
        #expect(session.typedInput == "typed words")
        #expect(session.liveSelectionReferences.count == 1)
        #expect(session.liveContextPreviewReferences.isEmpty)
        #expect(LiveSelectionReference.interleaving(
            session.liveSelectionReferences, with: session.partialTranscript
        ) == "Speech first\n\ntyped words\n\nand later")
    }

    @Test @MainActor func blurOnlySealsTypingAndNeverFinishesDictation() {
        let session = RecordingSession()
        session.updateTypedInput("first segment")
        session.endTypingRun()
        session.endTypingRun()
        #expect(session.phase == .recording)
        #expect(session.liveRecordingState == .recording)
        #expect(session.typedInput.isEmpty)
        #expect(session.liveContextPreviewReferences.count == 1)
        session.updateTypedInput("next segment")
        #expect(LiveSelectionReference.interleaving(
            session.liveSelectionReferences, with: ""
        ) == "first segment\n\nnext segment")
    }

    @Test @MainActor func typingHighlightsAndScreenshotsKeepCaptureOrderWithoutSpeech() throws {
        let session = RecordingSession()
        session.updateTypedInput("Before")
        session.recordLiveSelection(try #require(LiveSelectionReference("highlight one")))
        session.updateTypedInput("Between")
        session.recordLiveSelection(try #require(LiveSelectionReference(
            screenshotURL: URL(fileURLWithPath: "/tmp/screenshot.png")
        )))
        session.recordLiveSelection(try #require(LiveSelectionReference("highlight two")))
        session.updateTypedInput("After")
        let message = LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "")
        let markers = ["Before", "highlight one", "Between", "<local_screenshot", "highlight two", "After"]
        let positions = try markers.map { try #require(message.range(of: $0)).lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(message.contains("<codex_selection index=\"2\""))
        #expect(session.liveSelectionReferences.count == 6)
    }

    @Test @MainActor func deletingActiveTypingDoesNotDeleteEarlierContext() throws {
        let session = RecordingSession()
        session.recordLiveSelection(try #require(LiveSelectionReference("keep this")))
        session.updateTypedInput("remove this")
        session.updateTypedInput("")
        #expect(session.liveSelectionReferences.count == 1)
        session.updateTypedInput("replacement")
        #expect(session.liveSelectionReferences.count == 2)
        #expect(session.liveSelectionReferences.first?.isSelection == true)
    }

    @Test @MainActor func pausedTypingIsAllowedButFinishedAndAssistantSessionsRejectEdits() {
        let session = RecordingSession()
        session.liveRecordingState = .paused
        #expect(session.canTypeInHUD)
        session.updateTypedInput("paused prose")
        session.endLiveSelectionCapture()
        session.phase = .transcribing
        session.updateTypedInput("too late")
        #expect(session.typedInput.isEmpty)
        #expect(LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "") == "paused prose")
        let other = RecordingSession()
        #expect(other.liveSelectionReferences.isEmpty)
        other.useCase = .assistantFollowUp
        #expect(!other.canTypeInHUD)
        other.updateTypedInput("not accepted")
        #expect(other.liveSelectionReferences.isEmpty)
    }

    @Test @MainActor func retryRestoresAuthoredContextWithoutStartingCapture() throws {
        let references = [try #require(LiveSelectionReference(typedText: "keep keyboard prose"))]
        let session = RecordingSession(phase: .transcribing)
        session.restoreLiveContextForRetry(references)
        #expect(session.liveSelectionReferences == references)
        #expect(!session.canTypeInHUD)
        #expect(session.typedInput.isEmpty)
    }

    @Test func typingUsesLocalFocusOnlyAndGuardsOwnPasteDestination() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let editor = try source("VoiceInk/Views/Recorder/RecorderTypedInput.swift")
        #expect(editor.contains("NSWindow.didResignKeyNotification"))
        #expect(editor.contains("override func resignFirstResponder()"))
        #expect(!editor.contains("addGlobalMonitorForEvents"))
        #expect(!editor.contains("activate("))
        #expect(!editor.contains("toggleRecord("))
        #expect(!editor.contains("CGEvent("))
        let paste = try source("VoiceInk/Paste/CursorPaster.swift")
        #expect(paste.contains("!RecorderTypingTextView.ownsKeyboard && canPost()"))
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        #expect(engine.contains("RecorderTypingTextView.releaseKeyboardBeforeFinish()\n            active.phase = .transcribing"))
        #expect(engine.contains("session.restoreLiveContextForRetry(liveContextReferences)"))
    }
}
