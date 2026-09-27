import AppKit
import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

struct RecorderTypedInputTests {
    @Test @MainActor func protocolTypedInputWitnessRetainsTextAndTiming() {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        provider.updateTypedInput("Text through the production HUD interface")
        #expect(session.typedInput == "Text through the production HUD interface")
        #expect(session.liveSelectionReferences.count == 1)
        let timed = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "", includeTiming: true)
        #expect(timed.contains("<typed_text started_at=\"") && timed.contains(" ended_at=\""))
        #expect(timed.contains("Text through the production HUD interface\n</typed_text>"))
        session.endLiveSelectionCapture()
    }

    @Test @MainActor func typedOnlyProductionPipelineCompletesWithoutCallingAudioAndDeliversOnce() async throws {
        for text in ["Typed words\nand another line", ""] {
            let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let modelProvider = TypingTestModelProvider()
            let registry = TranscriptionServiceRegistry(modelProvider: modelProvider,
                modelsDirectory: URL(fileURLWithPath: "/tmp"), modelContext: context)
            let output = TypingTestDelivery()
            let audio = TypingTestAudioSession()
            let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry,
                enhancementService: nil, delivery: output)
            let recording = RecordingSession()
            let provider: any RecorderStateProvider = recording
            provider.updateTypedInput(text)
            recording.endLiveSelectionCapture()
            let record = Transcription(text: "", duration: 0)
            context.insert(record)
            let url = URL(fileURLWithPath: "/tmp/agentflow-typed-only-\(UUID()).wav")
            let model = NativeAppleModel(name: "unused", displayName: "Unused audio provider",
                description: "Test only", isMultilingualModel: false, supportedLanguages: [:])
            var failures: [String] = []
            await pipeline.run(transcription: record, audioURL: url,
                transcriptionConfiguration: .init(mode: nil, model: model, language: "en",
                    isRealtimeEnabled: false, requestContext: .init(language: "en", prompt: nil)),
                jobIdentity: .init(generation: 1, enqueueSequence: 1, recordingSessionID: recording.id,
                    transcriptionID: record.id, audioURL: url),
                formattingConfiguration: { .init(mode: nil, isTextFormattingEnabled: false) },
                session: audio, hasCapturedAudio: false,
                enhancementConfiguration: { nil },
                liveSelectionReferences: { recording.liveSelectionReferences },
                pasteTarget: { .init(destination: .primaryCurrentInput, focusedInput: nil) },
                outputConfiguration: { .init(mode: nil, outputMode: .paste, autoSendKey: .none, customCommand: nil) },
                // Raw output makes this deterministic regardless of the test host's frontmost app.
                skipPostProcessing: { true },
                onStateChange: { _ in }, shouldCancel: { false }, isDeliveryAuthorized: { true },
                onCancel: {}, onDismiss: {}, onTranscriptionFailure: { failures.append($0) })
            #expect(audio.transcriptionCalls == 0)
            #expect(failures.isEmpty)
            #expect(record.transcriptionStatus == TranscriptionStatus.completed.rawValue)
            #expect(output.messages == (text.isEmpty ? [] : [text]))
            #expect(output.routes.allSatisfy { $0 == .primaryCurrentInput })
            #expect(record.text == text)
        }
    }
    @Test func bothCommandShortcutUsesBothPhysicalSidesAndOneStart() {
        let command = NSEvent.ModifierFlags.command.rawValue
        var down = false
        var starts = 0
        for (key, flags) in [(55, command | 0x08), (54, command | 0x18),
                             (54, command | 0x18), (55, command | 0x10), (54, 0)] {
            let result = ShortcutMonitor.bothCommandTransition(wasDown: down, keyCode: UInt16(key), rawFlags: flags)
            if result.dispatchKeyDown { starts += 1 }
            if flags & 0x18 != 0x18 { #expect(!result.suppressDownstream) }
            down = result.isDown
        }
        #expect(starts == 1 && !down)
        #expect(!ShortcutMonitor.bothCommandTransition(wasDown: false, keyCode: 55,
            rawFlags: command).dispatchKeyDown)
        #expect(!ShortcutMonitor.bothCommandTransition(wasDown: false, keyCode: 54,
            rawFlags: command | 0x18 | NSEvent.ModifierFlags.shift.rawValue).dispatchKeyDown)
    }

    @Test @MainActor func typingOffRemainsFinishableAndKeepsAuthoredText() {
        let session = RecordingSession()
        session.microphoneOff = true
        session.hasCapturedAudio = false
        #expect(session.liveRecordingState == .recording && session.canTypeInHUD)
        session.updateTypedInput("Only typed <text> & a newline\nkept")
        session.endLiveSelectionCapture()
        #expect(LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "")
            == "Only typed <text> & a newline\nkept")
        #expect(!session.hasCapturedAudio)
    }

    @Test @MainActor func timingGroupsSpeechTypingAndSelectionWithoutChangingPlainPaste() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = RecordingSession()
        session.recordSpeechActivity("Speech first", at: start)
        session.partialTranscript = "Speech first"
        session.flushSpeechTiming()
        session.recordLiveSelection(try #require(LiveSelectionReference("a <source>")).timed(at: start.addingTimeInterval(2)))
        session.updateTypedInput("typed & exact", at: start.addingTimeInterval(3))
        session.endTypingRun()
        session.recordSpeechActivity("Speech first and later", at: start.addingTimeInterval(9))
        session.partialTranscript = "Speech first and later"
        session.endLiveSelectionCapture()
        let xml = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: session.partialTranscript, includeTiming: true)
        #expect(xml.components(separatedBy: "<speech_segment ").count == 3)
        #expect(xml.contains("timing=\"approximate_transcript_activity\">\nSpeech first\n</speech_segment>"))
        #expect(xml.contains("captured_at=\""))
        #expect(xml.contains("<typed_text started_at=\"") && xml.contains("typed &amp; exact\n</typed_text>"))
        #expect(!LiveSelectionReference.previewParts(session.liveSelectionReferences,
            with: session.partialTranscript).contains(.selection("timing")))
        let plain = LiveSelectionReference.interleaving(session.liveSelectionReferences.filter(\.isTypedText), with: "")
        #expect(plain == "typed & exact")
    }

    @Test @MainActor func timingFlushUsesLastActivityNotDebounceExpiryAndDoesNotDuplicate() {
        let session = RecordingSession()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        session.recordSpeechActivity("hello", at: date)
        session.partialTranscript = "hello"
        session.recordSpeechActivity("hello", at: date.addingTimeInterval(30))
        session.flushSpeechTiming()
        session.flushSpeechTiming()
        #expect(session.liveSelectionReferences.count == 1)
        session.endLiveSelectionCapture()
        #expect(session.liveSelectionReferences.count == 1)
    }

    @Test @MainActor func miniRecorderSitsAboveOtherFloatingUtilitiesWithoutActivation() {
        let panel = MiniRecorderPanel(contentRect: .zero)
        #expect(panel.level > .floating)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func typingOnlySkipsAudioNetworkAndEmptyReturnAtProductionBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pipeline = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"), encoding: .utf8)
        #expect(pipeline.contains("if !hasCapturedAudio {"))
        #expect(pipeline.contains("} else if let session {"))
        #expect(pipeline.contains("if hasCapturedAudio, !skipPostProcessingNow,"))
        let emptyGuard = try #require(pipeline.range(of: "guard let completedText = finalText"))
        let deliver = try #require(pipeline.range(of: "await delivery.deliver("))
        #expect(emptyGuard.lowerBound < deliver.lowerBound)
        let engine = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/VoiceInkEngine.swift"), encoding: .utf8)
        #expect(engine.contains("initiallyPaused: startedWithMicrophoneOff"))
        #expect(engine.contains("if session.microphoneOff { return }"))
        #expect(engine.contains("hasCapturedAudio: session.hasCapturedAudio"))
        let enables = engine.components(separatedBy: "try await recorder.enableMicrophoneCapture()")
        #expect(enables.count == 3)
        for continuation in enables.dropFirst() {
            let captured = try #require(continuation.range(of: "session.hasCapturedAudio = true"))
            let liveGuard = try #require(continuation.range(of: "guard activeRecordingSession === session"))
            #expect(captured.lowerBound < liveGuard.lowerBound)
        }
    }
    @Test @MainActor func typingStartIntentBindsOnlyTheNewPrimaryReservation() async {
        let requestID = UUID()
        var state: RecordingState = .idle
        var bound: [UUID] = []
        var started: [UUID] = []
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { state != .idle },
            recordingState: { state }, toggleRecorderPanel: { _, _ in },
            cancelRecording: {}, reserveRecordingStart: { requestID },
            startReservedRecording: { id, _ in started.append(id); state = .recording }
        )
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 100, mode: .toggle,
                                    didReserveStart: { bound.append($0) })
        #expect(bound == [requestID] && started == [requestID])
        await handler.handleKeyUp(action: .primaryRecording, eventTime: 100.01, mode: .toggle)
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 102, mode: .toggle,
                                    didReserveStart: { bound.append($0) })
        #expect(bound == [requestID])
        handler.reset()
    }

    @Test @MainActor func liveTypingHeightGrowsBeforeBlurAndCapsAtScreenBudget() {
        let short = MiniRecorderLayoutMetrics.typingHeight(text: "hello", width: 640, maxHeight: 500)
        let long = MiniRecorderLayoutMetrics.typingHeight(text: String(repeating: "long typed line\n", count: 15), width: 640, maxHeight: 500)
        #expect(short == MiniRecorderLayoutMetrics.typedInputHeight)
        #expect(long > short)
        #expect(MiniRecorderLayoutMetrics.typingHeight(text: String(repeating: "word ", count: 900), width: 640, maxHeight: 500) == 500)
        let empty = MiniRecorderLayoutMetrics.contextHeight(parts: [], typedText: "", width: 640, maxHeight: 500)
        let active = MiniRecorderLayoutMetrics.contextHeight(parts: [], typedText: String(repeating: "line\n", count: 12), width: 640, maxHeight: 500)
        #expect(active > empty)
        #expect(active <= 500)
    }

    @Test @MainActor func emptyTypingPanelHugsOneLineInEachSection() {
        // Regression for build 347: the empty editor sat in a fixed 60pt box and
        // the preview above kept a 56pt minimum, leaving tall empty bands.
        let line = MiniRecorderLayoutMetrics.singleLineHeight
        #expect(line < MiniRecorderLayoutMetrics.liveTranscriptHeight)
        #expect(MiniRecorderLayoutMetrics.typingHeight(text: "", width: 688, maxHeight: 500) == line)
        #expect(MiniRecorderLayoutMetrics.contextHeight(
            parts: [], typedText: "", width: 688, maxHeight: 500
        ) == line * 2)
        // Without an editor (after stop) the long-standing preview minimum stays.
        #expect(MiniRecorderLayoutMetrics.contextHeight(
            parts: [.speech("Hello")], typedText: nil, width: 688, maxHeight: 500
        ) == MiniRecorderLayoutMetrics.liveTranscriptHeight)
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

@MainActor private final class TypingTestModelProvider: WhisperModelProvider {
    var isModelLoaded: Bool { false }
    var whisperContext: WhisperContext? { nil }
    var loadedWhisperModel: WhisperModelFile? { nil }
    var availableModels: [WhisperModelFile] { [] }
}

@MainActor private final class TypingTestAudioSession: TranscriptionSession {
    var transcriptionCalls = 0
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? { nil }
    func transcribe(audioURL: URL) async throws -> String {
        transcriptionCalls += 1
        throw VoiceInkEngineError.transcriptionFailed
    }
    func cancel() {}
}

@MainActor private final class TypingTestDelivery: TranscriptionDelivering {
    var messages: [String] = []
    var routes: [RecordingPasteDestination] = []
    func deliver(_ request: TranscriptionDelivery.Request, actions: TranscriptionDelivery.Actions) async {
        if let text = request.text { messages.append(text) }
        routes.append(request.pasteTarget.destination)
    }
}
