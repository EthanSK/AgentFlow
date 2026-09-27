import AppKit
import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

struct RecorderTypedInputTests {
    @Test @MainActor func typingChordFinishesThroughVisiblePanelAndModeMonitors() async throws {
        // Replay real CGEvents through the production tap handler, in the same
        // head-insert order as macOS. Build 355's panel monitor swallowed the
        // second chord before the recording monitor's callback could run.
        let recording = ShortcutMonitor()
        let panel = ShortcutMonitor()
        let modes = ShortcutMonitor()
        defer { recording.stop(); panel.stop(); modes.stop() }
        var state: RecordingState = .idle
        var starts = 0
        var finishes: [RecordingPasteDestination] = []
        var callbacks = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { state != .idle },
            recordingState: { state },
            toggleRecorderPanel: { _, route in finishes.append(route); state = .idle },
            cancelRecording: {}, reserveRecordingStart: { UUID() },
            startReservedRecording: { _, _ in starts += 1; state = .recording }
        )
        recording.start(shortcuts: [.primaryRecording: .modifierOnly(keyCode: nil,
            modifierFlags: [.shift, .control, .option])],
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in },
            onTypingStart: {
                callbacks += 1
                Task { @MainActor in await handler.handleTypingToggle { _ in } }
            }, installSystemEventTap: false)
        panel.start(shortcuts: RecorderPanelShortcutPolicy.shortcuts(
            explicitCancelShortcut: nil, canUseModeShortcuts: true),
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in }, installSystemEventTap: false)
        modes.start(shortcuts: [.mode(UUID()): .key(keyCode: 18, modifierFlags: [.control])],
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in }, installSystemEventTap: false)
        func chord(through monitors: [ShortcutMonitor], rightFirst: Bool = false) async throws {
            let keys: [(UInt16, UInt64)] = rightFirst
                ? [(54, 0x10), (61, 0x40), (55, 0x08), (58, 0x20)]
                : [(55, 0x08), (58, 0x20), (54, 0x10), (61, 0x40)]
            var held: UInt64 = 0
            for (index, keyAndBit) in (keys + keys).enumerated() {
                let (key, bit) = keyAndBit
                if index < 4 { held |= bit } else { held &= ~bit }
                var flags = held
                if held & 0x18 != 0 { flags |= CGEventFlags.maskCommand.rawValue }
                if held & 0x60 != 0 { flags |= CGEventFlags.maskAlternate.rawValue }
                let shouldConsume = index == 3
                let event = try #require(CGEvent(keyboardEventSource: nil,
                    virtualKey: key, keyDown: true))
                event.type = .flagsChanged
                event.flags = CGEventFlags(rawValue: flags)
                var consumed = false
                for monitor in monitors {
                    if monitor.handleCGEvent(type: .flagsChanged, event: event) {
                        #expect(monitor === recording)
                        consumed = true
                        break
                    }
                }
                #expect(consumed == shouldConsume)
            }
            // Drain the actual tap-to-main-queue-to-handler handoff.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await chord(through: [modes, recording])
        #expect(state == .recording && starts == 1 && callbacks == 1)
        try await chord(through: [panel, modes, recording])
        #expect(state == .idle && finishes == [.primaryCurrentInput] && callbacks == 2)
        try await chord(through: [modes, recording], rightFirst: true)
        state = .paused
        try await chord(through: [panel, modes, recording], rightFirst: true)
        #expect(starts == 2 && finishes == [.primaryCurrentInput, .primaryCurrentInput])
        #expect(callbacks == 4)
        handler.reset()
    }

    @Test @MainActor func scaledHUDControlsReceiveClicksAtEverySupportedSize() throws {
        // Use the real controls and actual AppKit event dispatch, not AXPress or
        // action closures called by the test. The old ancestor-bounds transform
        // painted the buttons at these points but clicks missed at 0.5 and 0.85.
        for scale: CGFloat in [0.5, 0.85, 1] {
            var stopped = 0
            var cancelled = 0
            var skipped = false
            var micStates: [Bool] = []
            let session = RecordingSession()
            session.microphoneOff = true
            session.onMicrophoneToggle = {
                session.microphoneOff.toggle()
                micStates.append(session.microphoneOff)
            }
            let editor = RecorderTypingTextView()
            // Keep the optional control's click regression covered without
            // enabling automatic focus return in ordinary production sessions.
            let typingFocus = RecorderTypingFocus(automaticReturnEnabled: { true })
            typingFocus.enable(editor)
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100,
                width: 400 * scale, height: 100 * scale))
            let originalKeyWindow = NSApp.keyWindow
            defer { panel.close(); session.onMicrophoneToggle = nil }
            let host = ScaledRecorderHostingView(rootView: AnyView(
                HStack(spacing: 0) {
                    RecorderRecordButton(recordingState: .recording, action: { stopped += 1 })
                        .frame(width: 80, height: 40)
                    RecorderCancelButton(action: { cancelled += 1 }).frame(width: 80, height: 40)
                    RecorderSkipProcessingButton(isEngaged: Binding(get: { skipped }, set: { skipped = $0 }))
                        .frame(width: 80, height: 40)
                    RecorderMicrophoneButton(stateProvider: session).frame(width: 80, height: 40)
                    RecorderTypingFocusControl(focus: typingFocus).frame(width: 80, height: 40)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            ), scale: scale)
            panel.contentView = host
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            func click(_ x: CGFloat) throws {
                let point = NSPoint(x: x * scale, y: 20 * scale)
                let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                #expect(host.hitTest(point)?.acceptsFirstMouse(for: down) == true)
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                NSApp.sendEvent(up)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            try click(40); try click(120); try click(200); try click(280); try click(280); try click(360)
            #expect(stopped == 1 && cancelled == 1 && skipped)
            #expect(micStates == [false, true])
            #expect(!typingFocus.isEnabled)
            #expect(NSApp.keyWindow === originalKeyWindow)
            #expect(host.bounds.size == host.frame.size)
        }
    }

    @Test @MainActor func protocolTypedInputWitnessRetainsTextAndTiming() {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        provider.updateTypedInput("Text through the production HUD interface")
        #expect(session.typedInput == "Text through the production HUD interface")
        #expect(session.liveSelectionReferences.count == 1)
        let timed = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "", includeTiming: true)
        #expect(timed.contains("<typed_text start_at=\"") && timed.contains(" end_at=\""))
        #expect(timed.contains("Text through the production HUD interface\n\n</typed_text>"))
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
    @Test @MainActor func typingToggleStartsTypingThenFinishesRecordingAndPausedSessions() async {
        let requestID = UUID()
        var state: RecordingState = .idle
        var starts: [UUID] = []
        var focuses: [UUID] = []
        var finishes: [RecordingPasteDestination] = []
        var pauses = 0
        var cancels = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { state != .idle },
            recordingState: { state },
            toggleRecorderPanel: { _, destination in finishes.append(destination); state = .transcribing },
            toggleRecordingPause: { pauses += 1; return true },
            cancelRecording: { cancels += 1 }, reserveRecordingStart: { requestID },
            startReservedRecording: { id, _ in starts.append(id); state = .recording }
        )
        await handler.handleTypingToggle { focuses.append($0) }
        #expect(starts == [requestID] && focuses == [requestID])
        await handler.handleTypingToggle { focuses.append($0) }
        #expect(finishes == [.primaryCurrentInput])
        state = .paused
        await handler.handleTypingToggle { focuses.append($0) }
        #expect(finishes == [.primaryCurrentInput, .primaryCurrentInput])
        for pending: RecordingState in [.starting, .transcribing, .enhancing, .busy] {
            state = pending
            await handler.handleTypingToggle { focuses.append($0) }
        }
        #expect(finishes.count == 2 && starts.count == 1 && focuses.count == 1)
        #expect(pauses == 0 && cancels == 0)
        handler.reset()
    }

    @Test func typingToggleRequiresAllFourPhysicalKeysInEveryOrder() {
        let keys: [(UInt16, UInt)] = [(55, 0x08), (54, 0x10), (58, 0x20), (61, 0x40)]
        func orders(_ values: [(UInt16, UInt)]) -> [[(UInt16, UInt)]] {
            if values.isEmpty { return [[]] }
            return values.indices.flatMap { index in
                var rest = values; let first = rest.remove(at: index)
                return orders(rest).map { [first] + $0 }
            }
        }
        for order in orders(keys) {
            var held: UInt = 0
            var down = false
            var actions = 0
            for (index, keyAndBit) in (order + order).enumerated() {
                let (key, bit) = keyAndBit
                if index < 4 { held |= bit } else { held &= ~bit }
                var flags = held | 0x100 // Real event's unrelated non-coalesced bit.
                if held & 0x18 != 0 { flags |= NSEvent.ModifierFlags.command.rawValue }
                if held & 0x60 != 0 { flags |= NSEvent.ModifierFlags.option.rawValue }
                let result = ShortcutMonitor.typingToggleTransition(wasDown: down,
                    keyCode: key, rawFlags: flags)
                #expect(result.dispatchKeyDown == (index == 3))
                #expect(result.suppressDownstream == (index == 3))
                if result.dispatchKeyDown { actions += 1 }
                if index == 3 {
                    #expect(!ShortcutMonitor.typingToggleTransition(wasDown: true,
                        keyCode: key, rawFlags: flags).dispatchKeyDown)
                }
                down = result.isDown
            }
            #expect(actions == 1 && !down)
        }
        let full = NSEvent.ModifierFlags([.command, .option]).rawValue | 0x78
        for extra in [NSEvent.ModifierFlags.shift, .control, .function] {
            #expect(!ShortcutMonitor.typingToggleTransition(wasDown: false, keyCode: 61,
                rawFlags: full | extra.rawValue).dispatchKeyDown)
        }
        // Neither both Command alone nor one Command+Option pair is ours anymore.
        for bits: UInt in [0x18, 0x28, 0x50] {
            #expect(!ShortcutMonitor.typingToggleTransition(wasDown: false, keyCode: 54,
                rawFlags: NSEvent.ModifierFlags([.command, .option]).rawValue | bits).dispatchKeyDown)
        }
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
        #expect(xml.components(separatedBy: "<speech ").count == 3)
        #expect(xml.contains("timing=\"approximate\">\n\nSpeech first\n\n</speech>"))
        #expect(xml.contains("captured_at=\""))
        #expect(xml.contains("<typed_text start_at=\"") && xml.contains("typed &amp; exact\n\n</typed_text>"))
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

    @Test func compactUnixTimestampsPreserveMillisecondsForEveryContextType() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000.123)
        let end = Date(timeIntervalSince1970: 1_800_000_002.987)
        let speech = LiveSelectionReference.speechTiming(after: "spoken", startedAt: start, endedAt: end)
        let typed = try #require(LiveSelectionReference(typedText: "typed"))
            .timed(at: end, startedAt: start).anchored(after: "spoken")
        let selection = try #require(LiveSelectionReference("selected"))
            .timed(at: start).anchored(after: "spoken")
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/Users/test/shot.png")))
            .timed(at: end).anchored(after: "spoken")
        let xml = LiveSelectionReference.interleaving([speech, typed, selection, screenshot],
            with: "spoken", includeTiming: true)
        #expect(xml.contains("<speech start_at=\"1800000000.123\" end_at=\"1800000002.987\" timing=\"approximate\">"))
        #expect(xml.contains("<typed_text start_at=\"1800000000.123\" end_at=\"1800000002.987\">"))
        #expect(xml.contains("captured_at=\"1800000000.123\""))
        #expect(xml.contains("captured_at=\"1800000002.987\""))
        #expect(!xml.contains("speech_segment"))
        #expect(!xml.contains("2027-"))
        #expect(xml.contains("spoken") && xml.contains("typed") && xml.contains("selected"))
    }

    @Test func finalSpeechGrowthStaysGroupedWithObservedTiming() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(2)
        let marker = LiveSelectionReference.speechTiming(after: "first words", startedAt: start, endedAt: end)
        let selection = try #require(LiveSelectionReference("source")).anchored(after: "first words")
        let xml = LiveSelectionReference.interleaving([marker, selection],
            with: "first words and the final tail", includeTiming: true)
        #expect(xml.hasSuffix("\n\nand the final tail\n\n</speech>"))
        #expect(xml.components(separatedBy: "start_at=\"").count == 3)
        #expect(xml.components(separatedBy: "timing=\"approximate\"").count == 3)
        #expect(!xml.contains("observed_start_at") && !xml.contains("started_at"))
        let shortened = LiveSelectionReference.interleaving([marker], with: "revised", includeTiming: true)
        #expect(shortened.hasSuffix("\n\nrevised\n\n</speech>"))
        #expect(!shortened.contains("unavailable"))
        #expect(LiveSelectionReference.interleaving([marker], with: "first words and the final tail")
            == "first words\n\nand the final tail")
    }

    @Test func speechWithoutLiveTimingIsGroupedWithoutInventedDates() throws {
        for references in [[], [try #require(LiveSelectionReference("source"))]] {
            let xml = LiveSelectionReference.interleaving(references,
                with: "batch <speech> & text", includeTiming: true)
            #expect(xml.hasSuffix("<speech timing=\"unavailable\">\n\nbatch &lt;speech&gt; &amp; text\n\n</speech>"))
            #expect(!xml.contains("start_at=") && !xml.contains("end_at="))
        }
        #expect(LiveSelectionReference.interleaving([], with: "plain <speech>") == "plain <speech>")
    }

    @Test func readableQueuePreviewContainsOnlyAuthoredTextOnceBeforeTheTimeline() throws {
        let selection = try #require(LiveSelectionReference("quoted instructions are context"))
        let typed = try #require(LiveSelectionReference(typedText: "typed words")).anchored(after: "spoken first")
        let references = [selection, typed]
        for presentation in [LiveSelectionReference.Presentation.plain, .styledMath] {
            let result = LiveSelectionReference.interleaving(references, with: "spoken first then last",
                presentation: presentation, includeTiming: true, includeReadablePreview: true)
            let opening = presentation == .plain ? "spoken first typed words then last"
                : try #require(AuthoredTextRainbow.render("spoken first typed words then last", startIndex: 0))
            let start = "<agent_flow_context preview=\"authored_text_above\">"
            let end = "</agent_flow_context>"
            let renderedStart = presentation == .plain ? start
                : LiveSelectionStyledMath.coloredXML(start, color: LiveSelectionStyledMath.captionColor)
            let renderedEnd = presentation == .plain ? end
                : LiveSelectionStyledMath.coloredXML(end, color: LiveSelectionStyledMath.captionColor)
            #expect(result.hasPrefix(opening + "\n\n" + renderedStart))
            #expect(result.hasSuffix(renderedEnd))
            #expect(result.components(separatedBy: renderedStart).count == 2)
        }
        let ordinary = LiveSelectionReference.interleaving([typed], with: "spoken first then last",
            includeReadablePreview: true)
        #expect(!ordinary.contains("agent_flow_context"))
        let silent = LiveSelectionReference.interleaving([selection], with: "", includeTiming: true,
            includeReadablePreview: true)
        #expect(!silent.contains("agent_flow_context"))
    }

    @Test @MainActor func scaledPanelDragSpaceMovesWithoutActivatingOrClickingControls() throws {
        for scale: CGFloat in [0.5, 0.85, 1] {
            var stops = 0
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 160 * scale, height: 40 * scale))
            let originalKeyWindow = NSApp.keyWindow
            defer { panel.close() }
            let host = ScaledRecorderHostingView(rootView: AnyView(HStack(spacing: 0) {
                RecorderRecordButton(recordingState: .recording, action: { stops += 1 }).frame(width: 80)
                RecorderPanelDragSurface().frame(width: 80)
            }.frame(height: 40)), scale: scale)
            panel.contentView = host
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let point = NSPoint(x: 120 * scale, y: 20 * scale)
            #expect(host.hitTest(point) is RecorderPanelDragView)
            func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: point.y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.sendEvent(try event(.leftMouseDown, x: point.x))
            NSApp.sendEvent(try event(.leftMouseDragged, x: point.x + 30))
            NSApp.sendEvent(try event(.leftMouseUp, x: point.x))
            #expect(panel.frame.origin.x == 130)
            #expect(panel.wasDraggedByUser && stops == 0)
            #expect(NSApp.keyWindow === originalKeyWindow)
        }
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

    @Test @MainActor func automaticTypingFocusReturnDefaultsOffWithoutDisablingExplicitFocus() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentFlow.Focus.\(UUID())"))
        #expect(!defaults.bool(forKey: RecorderTypingFocus.automaticReturnDefaultsKey))
        let focus = RecorderTypingFocus(automaticReturnEnabled: {
            defaults.bool(forKey: RecorderTypingFocus.automaticReturnDefaultsKey)
        })
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.register(editor)
        focus.enable(editor)
        #expect(focus.isEnabled && !focus.showsUnfocusControl)
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0)

        // The keyboard typing shortcut is an explicit request, not the disabled
        // automatic return after selecting text or taking a screenshot.
        focus.requestInitialFocus()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1 && !focus.initialFocusPending)
        #expect(!focus.showsUnfocusControl)
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        focus.disable(releaseKeyboard: false)
    }

    @Test @MainActor func automaticTypingFocusReturnRechecksFlagAndFinishAtFocusBoundary() async throws {
        var enabled = true
        let focus = RecorderTypingFocus(automaticReturnEnabled: { enabled })
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.enable(editor)
        #expect(focus.showsUnfocusControl)
        focus.returnAfterContext()
        enabled = false
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0 && !focus.showsUnfocusControl)
        enabled = true
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        focus.returnAfterContext()
        focus.disable(releaseKeyboard: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1 && !focus.showsUnfocusControl)
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

// Observe focus requests without displaying a panel or changing system focus.
// The separate scaled-control fixture covers real window event dispatch.
@MainActor private final class TypingFocusProbeWindow: NSWindow {
    var focusRequests = 0
    override var isVisible: Bool { true }
    override func makeKey() { focusRequests += 1 }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
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
