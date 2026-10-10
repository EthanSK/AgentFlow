import AppKit
import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

struct RecorderTypedInputTests {
    @Test @MainActor func transcriptDragMovesPanelWithoutBreakingClickOrScroll() throws {
        @MainActor func dragView(in view: NSView) -> RecorderPanelDragView? {
            if let drag = view as? RecorderPanelDragView { return drag }
            for child in view.subviews {
                if let drag = dragView(in: child) { return drag }
            }
            return nil
        }
        for scale: CGFloat in [0.5, 0.85, 1] {
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100,
                width: 320 * scale, height: 140 * scale))
            let originalKeyWindow = NSApp.keyWindow
            defer { panel.close() }
            let host = ScaledRecorderHostingView(rootView: AnyView(LiveTranscriptView(
                text: String(repeating: "Long read-only transcript context.\n", count: 100),
                selectionReferences: [], height: 140, width: 320, dragsWindow: true
            ).frame(width: 320, height: 140)), scale: scale)
            panel.contentView = host
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let drag = try #require(dragView(in: host))
            let scroll = try #require(drag.enclosingScrollView)
            let point = NSPoint(x: 100 * scale, y: 70 * scale)
            #expect(host.hitTest(point) === drag)
            var clicks = 0
            drag.onClick = { clicks += 1 }
            func mouse(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: point.x + offset, y: point.y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.sendEvent(try mouse(.leftMouseDown))
            NSApp.sendEvent(try mouse(.leftMouseUp))
            #expect(clicks == 1 && panel.frame.origin.x == 100)
            NSApp.sendEvent(try mouse(.leftMouseDown))
            NSApp.sendEvent(try mouse(.leftMouseDragged, offset: 30))
            NSApp.sendEvent(try mouse(.leftMouseUp))
            #expect(clicks == 1 && panel.frame.origin.x == 130 && panel.wasDraggedByUser)
            #expect(NSApp.keyWindow === originalKeyWindow)

            // Start in the middle so either wheel direction can prove that the
            // real enclosing SwiftUI scroll view received the forwarded event.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
            scroll.reflectScrolledClipView(scroll.contentView)
            let before = scroll.contentView.bounds.origin.y
            let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: 80, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: wheel))
            drag.scrollWheel(with: event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            #expect(scroll.contentView.bounds.origin.y != before)
            #expect(panel.frame.origin.x == 130 && clicks == 1)
        }
    }

    @Test @MainActor func widerContextRemainsWithinQuarterScreenAtEveryScale() {
        let long = String(repeating: "A long line of typed or spoken context.\n", count: 200)
        for screen in [CGSize(width: 1024, height: 600), CGSize(width: 1512, height: 900),
                       CGSize(width: 2560, height: 1440)] {
            for scale: CGFloat in [0.5, 0.85, 1] {
                let width = MiniRecorderLayoutMetrics.contextWidth(screenWidth: screen.width, scale: scale)
                #expect((width + 32) * scale <= screen.width)
                #expect(width > 688)
                for controls: CGFloat in [40, 43] {
                    let cap = MiniRecorderLayoutMetrics.contextHeightLimit(
                        screenHeight: screen.height, scale: scale, controlsHeight: controls)
                    for typed in [nil, "", long] as [String?] {
                        let height = MiniRecorderLayoutMetrics.contextHeight(
                            parts: [.speech(long)], typedText: typed, width: width, maxHeight: cap)
                        #expect((height + controls + 1) * scale <= screen.height * 0.25 + 0.01)
                        #expect(height <= cap)
                    }
                }
            }
        }
        #expect(MiniRecorderLayoutMetrics.liveTranscriptFontSize == 18)
    }

    @Test @MainActor func commandEnterSubmitIsOwnedByFocusedEditorAndFlushesText() throws {
        let session = RecordingSession()
        let input = RecorderTypedInput(
            text: Binding(get: { session.typedInput }, set: { session.updateTypedInput($0) }),
            focusRequest: UUID(), onEndEditing: { session.endTypingRun() })
        let coordinator = input.makeCoordinator()
        let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 80))
        let editor = RecorderTypingTextView(frame: panel.contentView!.bounds)
        editor.isRichText = false
        editor.delegate = coordinator
        editor.onEndEditing = input.onEndEditing
        var submitted: [String] = []
        editor.onSubmit = { submitted.append(session.typedInput) }
        panel.contentView = editor
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        defer { panel.orderOut(nil); panel.close() }
        #expect(panel.isKeyWindow && panel.firstResponder === editor)
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 1, windowNumber: panel.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: repeatKey, keyCode: code))
        }
        editor.string = "Latest uncommitted edit"
        #expect(editor.performKeyEquivalent(with: try key(36, flags: .command)))
        #expect(submitted == ["Latest uncommitted edit"])
        #expect(editor.performKeyEquivalent(with: try key(36, flags: .command, repeatKey: true)))
        #expect(submitted.count == 1 && !editor.string.contains("\n"))
        editor.keyDown(with: try key(76, flags: [.command, .numericPad]))
        #expect(submitted.count == 2)
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(!RecorderTypingTextView.isSubmitGesture(try key(36, flags: flags)))
        }
        // Command+Return remains finish/send/steer only; it is never a run commit
        // or line break, and neither of those gestures can submit the session.
        for code: UInt16 in [36, 76] {
            #expect(RecorderTypingTextView.isRunCommitGesture(try key(code, flags: [])))
            #expect(RecorderTypingTextView.isRunCommitGesture(try key(code, flags: .numericPad)))
            #expect(RecorderTypingTextView.isLineBreakGesture(try key(code, flags: .shift)))
            for flags: NSEvent.ModifierFlags in [.command, [.command, .shift], .option, .control] {
                #expect(!RecorderTypingTextView.isRunCommitGesture(try key(code, flags: flags)))
                #expect(!RecorderTypingTextView.isLineBreakGesture(try key(code, flags: flags)))
            }
        }
        // Shift+Return keeps one multiline run; nothing is committed or submitted.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: try key(36, flags: .shift))
        #expect(editor.string == "Latest uncommitted edit\n" && submitted.count == 2)
        #expect(session.typedInput == "Latest uncommitted edit\n")
        #expect(session.liveSelectionReferences.isEmpty)
        editor.insertText("second line", replacementRange: editor.selectedRange())
        // Bare Return commits this run while recording continues and the editor
        // keeps keyboard focus for the next run.
        editor.keyDown(with: try key(36, flags: []))
        #expect(editor.string.isEmpty && session.typedInput.isEmpty && submitted.count == 2)
        #expect(panel.firstResponder === editor && session.phase == .recording)
        #expect(LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "")
            == "Latest uncommitted edit\nsecond line")
        // Held/repeated Return and a later blur find no run left to commit.
        editor.keyDown(with: try key(36, flags: [], repeatKey: true))
        panel.makeFirstResponder(nil)
        #expect(session.liveSelectionReferences.count == 1)
        _ = editor.performKeyEquivalent(with: try key(36, flags: .command))
        #expect(submitted.count == 2)
    }

    @Test @MainActor func typingSubmitWaitsForStartupAndCannotRepeatOrCrossSessions() {
        let session = RecordingSession()
        session.microphoneOff = true
        session.liveRecordingState = .starting
        session.updateTypedInput("Fast typing")
        var finishes = 0
        session.onTypingSubmit = { finishes += 1 }
        let provider: any RecorderStateProvider = session
        provider.submitTypedInput()
        provider.submitTypedInput()
        #expect(session.typingSubmitRequested && finishes == 0)
        #expect(session.typedInput == "Fast typing")
        session.liveRecordingState = .recording
        session.dispatchPendingTypingSubmit()
        session.dispatchPendingTypingSubmit()
        provider.submitTypedInput()
        #expect(finishes == 1)
        let next = RecordingSession()
        next.onTypingSubmit = { finishes += 1 }
        next.dispatchPendingTypingSubmit()
        #expect(!next.typingSubmitRequested && finishes == 1)
        let cancelled = RecordingSession()
        cancelled.microphoneOff = true
        cancelled.liveRecordingState = .starting
        cancelled.onTypingSubmit = { finishes += 1 }
        cancelled.submitTypedInput()
        cancelled.shouldCancel = true
        cancelled.liveRecordingState = .recording
        cancelled.dispatchPendingTypingSubmit()
        #expect(finishes == 1)
        let paused = RecordingSession()
        paused.liveRecordingState = .paused
        paused.onTypingSubmit = { finishes += 1 }
        paused.submitTypedInput()
        #expect(finishes == 2)
    }

    @Test func typingSubmitOverridesOnlyPrimaryAutoSend() {
        for route: RecordingPasteDestination in [.primaryCurrentInput, .recordingStart, .focusedDuringTranscription] {
            for key: AutoSendKey in [.none, .enter, .shiftEnter, .commandEnter] {
                #expect(RecordingAutoSendDisposition.commandEnterOnce.resolvedKey(
                    destination: route, configuredKey: key) == (route == .primaryCurrentInput ? .commandEnter : key))
                #expect(RecordingAutoSendDisposition.suppressOnce.resolvedKey(destination: route, configuredKey: key) == .none)
                #expect(RecordingAutoSendDisposition.configured.resolvedKey(destination: route, configuredKey: key) == key)
            }
        }
    }

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
        var clipboardFinishes = 0
        var callbacks = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { state != .idle },
            recordingState: { state },
            toggleRecorderPanel: { _, route in finishes.append(route); state = .idle },
            finishRecordingToClipboard: { _ in clipboardFinishes += 1; state = .idle; return true },
            cancelRecording: {}, reserveRecordingStart: { UUID() },
            startReservedRecording: { _, _ in starts += 1; state = .recording }
        )
        recording.start(shortcuts: [.primaryRecording: .modifierOnly(keyCode: nil,
            modifierFlags: [.shift, .control, .option])],
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in },
            onTypingStart: { clipboardOnly in
                callbacks += 1
                Task { @MainActor in
                    await handler.handleTypingToggle(clipboardOnly: clipboardOnly) { _ in }
                }
            }, installSystemEventTap: false)
        panel.start(shortcuts: RecorderPanelShortcutPolicy.shortcuts(
            explicitCancelShortcut: nil, canUseModeShortcuts: true),
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in }, installSystemEventTap: false)
        modes.start(shortcuts: [.mode(UUID()): .key(keyCode: 18, modifierFlags: [.control])],
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in }, installSystemEventTap: false)
        func chord(through monitors: [ShortcutMonitor], rightFirst: Bool = false,
                   shift: Bool = false) async throws {
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
                if shift { flags |= CGEventFlags.maskShift.rawValue }
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
        for active: RecordingState in [.recording, .paused] {
            state = active
            try await chord(through: [panel, modes, recording], shift: true)
            #expect(state == .idle)
        }
        #expect(clipboardFinishes == 2 && finishes.count == 2 && starts == 2)
        try await chord(through: [panel, modes, recording], shift: true)
        #expect(state == .idle && clipboardFinishes == 2 && starts == 2)
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
            var pauseStates: [RecordingState] = []
            let session = RecordingSession()
            session.partialTranscript = "Keep every spoken word"
            session.updateTypedInput("Keep keyboard words too")
            let sessionID = session.id
            session.onPauseToggle = {
                session.liveRecordingState = session.liveRecordingState == .paused ? .recording : .paused
                pauseStates.append(session.liveRecordingState)
            }
            session.microphoneOff = true
            session.onMicrophoneToggle = {
                session.microphoneOff.toggle()
                micStates.append(session.microphoneOff)
            }
            // The old fifth Unfocus control was removed at Ethan's request.
            // Keep real click regression coverage for all remaining controls.
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100,
                width: 400 * scale, height: 100 * scale))
            let originalKeyWindow = NSApp.keyWindow
            defer { panel.close(); session.onMicrophoneToggle = nil; session.onPauseToggle = nil }
            let host = ScaledRecorderHostingView(rootView: AnyView(
                HStack(spacing: 0) {
                    RecorderRecordButton(recordingState: .recording, action: { stopped += 1 })
                        .frame(width: 80, height: 40)
                    RecorderCancelButton(action: { cancelled += 1 }).frame(width: 80, height: 40)
                    RecorderSkipProcessingButton(isEngaged: Binding(get: { skipped }, set: { skipped = $0 }))
                        .frame(width: 80, height: 40)
                    RecorderMicrophoneButton(stateProvider: session).frame(width: 80, height: 40)
                    RecorderPauseButton(stateProvider: session).frame(width: 80, height: 40)
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
            try click(40); try click(120); try click(200); try click(280); try click(280)
            #expect(stopped == 1 && cancelled == 1 && skipped)
            #expect(micStates == [false, true])
            #expect(RecorderPauseButton(stateProvider: session).symbolName == "pause.fill")
            try click(360)
            #expect(RecorderPauseButton(stateProvider: session).symbolName == "play.fill")
            #expect(RecorderPauseButton(stateProvider: session).actionTitle == String(localized: "Resume recording"))
            try click(360)
            #expect(RecorderPauseButton(stateProvider: session).symbolName == "pause.fill")
            #expect(pauseStates == [.paused, .recording])
            #expect(session.id == sessionID && session.phase == .recording)
            #expect(session.partialTranscript == "Keep every spoken word")
            #expect(session.typedInput == "Keep keyboard words too")
            #expect(NSApp.keyWindow === originalKeyWindow)
            #expect(host.bounds.size == host.frame.size)
        }
    }

    @Test @MainActor func bothHUDLayoutsRenderPauseAndResumeWithoutClipping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentflow-hud-pause-405")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = Recorder()
        let assistant = AssistantSession()
        for paused in [false, true] {
            let session = RecordingSession()
            session.liveRecordingState = paused ? .paused : .recording
            session.partialTranscript = "Every spoken word remains here while capture pauses and resumes."
            session.microphoneOff = true
            for style in ["mini", "notch"] {
                let view: AnyView
                if style == "mini" {
                    view = AnyView(MiniRecorderView(stateProvider: session,
                        liveTranscriptHeight: 120, liveTranscriptWidth: 900, recorder: recorder,
                        assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                } else {
                    view = AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                        assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                        liveTranscriptHeight: 120, liveTranscriptWidth: 900,
                        onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {},
                        onAssistantFollowUp: { _ in }))
                }
                let host = NSHostingView(rootView: view.frame(width: 940, height: 190).background(.black))
                host.frame = NSRect(x: 0, y: 0, width: 940, height: 190)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let path = directory.appendingPathComponent("\(style)-\(paused ? "paused" : "recording").png")
                try png.write(to: path)
                print("HUD_LAYOUT_FIXTURE \(path.path)")
                #expect(RecorderPauseButton(stateProvider: session).symbolName == (paused ? "play.fill" : "pause.fill"))
            }
        }
    }

    @Test @MainActor func hudPauseRejectsTransitionCancelledAndFinishedCards() {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        var requests = 0
        session.onPauseToggle = { requests += 1 }
        provider.togglePause()
        session.liveRecordingState = .paused
        provider.togglePause()
        #expect(requests == 2)
        session.microphoneTransitionPending = true
        provider.togglePause()
        session.finishMicrophoneTransition()
        session.shouldCancel = true
        provider.togglePause()
        session.shouldCancel = false
        for phase: RecordingSession.Phase in [.transcribing, .delivering, .done] {
            session.phase = phase
            provider.togglePause()
        }
        session.phase = .recording
        session.liveRecordingState = .starting
        provider.togglePause()
        #expect(requests == 2)
    }

    @Test @MainActor func cachedHUDPreviewKeepsFullSelectionsAndRefreshesAfterEveryEdit() throws {
        let session = RecordingSession()
        session.partialTranscript = "first spoken words"
        let massiveSelection = "SELECTION START " + String(repeating: "private selected body ", count: 10_000) + "SELECTION END"
        session.recordLiveSelection(try #require(LiveSelectionReference(massiveSelection)))
        let provider: any RecorderStateProvider = session
        let first = provider.liveContextPreviewParts
        #expect(first == LiveSelectionReference.previewParts(provider.liveContextPreviewReferences,
                                                             with: session.partialTranscript))
        for _ in 0..<100 { #expect(provider.liveContextPreviewParts == first) }
        #expect(!first.contains { part in
            if case .selection(let text) = part { return text.contains("private selected body private selected body") }
            return false
        })
        let full = LiveSelectionReference.interleaving(session.liveSelectionReferencesForRecovery,
                                                       with: session.partialTranscript, includeTiming: true)
        #expect(full.contains(massiveSelection))
        session.partialTranscript += " and later speech"
        #expect(provider.liveContextPreviewParts != first)
        session.updateTypedInput("keyboard words stay in the editor")
        let whileTyping = provider.liveContextPreviewParts
        #expect(!whileTyping.contains(.speech("keyboard words stay in the editor")))
        session.endTypingRun()
        #expect(provider.liveContextPreviewParts.contains(.speech("keyboard words stay in the editor")))
        session.recordLiveSelection(try #require(LiveSelectionReference("new highlight")))
        #expect(provider.liveContextPreviewParts != whileTyping)
        #expect(session.liveSelectionReferencesForRecovery.filter(\.isSelection).count == 2)
        session.microphoneOff = false
        session.recordSpeechActivity("first spoken words and revised later speech", at: Date())
        session.partialTranscript = "first spoken words and revised later speech"
        let duringSpeech = provider.liveContextPreviewParts
        session.flushSpeechTiming()
        #expect(provider.liveContextPreviewParts == duringSpeech)
        let retry = RecordingSession()
        retry.phase = .transcribing
        _ = retry.liveContextPreviewParts
        retry.restoreLiveContextForRetry(session.liveSelectionReferencesForRecovery)
        #expect(!retry.liveContextPreviewReferences.isEmpty)
        #expect(LiveSelectionReference.interleaving(retry.liveSelectionReferencesForRecovery,
            with: session.partialTranscript, includeTiming: true).contains(massiveSelection))
    }

    @Test func bothHUDStylesPauseTheSameSessionAndCancelUndecidedStops() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        for style in ["Mini", "Notch"] {
            let view = try source("VoiceInk/Views/Recorder/\(style)RecorderView.swift")
            #expect(view.contains("if stateProvider.recordingState.isRecordingOrPaused {\n                        RecorderPauseButton(stateProvider: stateProvider)"))
        }
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let start = try #require(engine.range(of: "    func toggleRecordingPauseFromHUD("))
        let end = try #require(engine.range(of: "    /// Toggles capture", range: start.upperBound..<engine.endIndex))
        let body = engine[start.lowerBound..<end.lowerBound]
        #expect(body.contains("activeRecordingSession === session"))
        #expect(body.contains("session.phase == .recording"))
        #expect(body.contains("!session.microphoneTransitionPending"))
        #expect(body.contains("onHUDPauseRequested?()"))
        #expect(body.contains("await toggleRecordingPause()"))
        #expect(!body.contains("stopRecording") && !body.contains("toggleMicrophone") && !body.contains("deliver"))
        #expect(engine.contains("await self.toggleRecordingPauseFromHUD(session)"))
        let shortcuts = try source("VoiceInk/Shortcuts/RecordingShortcutManager.swift")
        #expect(shortcuts.contains("engine.onHUDPauseRequested = { [weak shortcutModeHandler] in\n            shortcutModeHandler?.cancelPendingPrimaryDecisions()"))
        let components = try source("VoiceInk/Views/Recorder/RecorderComponents.swift")
        let viewStart = try #require(components.range(of: "struct LiveTranscriptView:"))
        let viewEnd = try #require(components.range(of: "struct RecorderPauseButton", range: viewStart.upperBound..<components.endIndex))
        let transcriptView = String(components[viewStart.lowerBound..<viewEnd.lowerBound])
        #expect(transcriptView.components(separatedBy: "LiveSelectionReference.previewParts(").count == 2)
        #expect(transcriptView.contains("previewText(parts)") && transcriptView.contains(".onChange(of: parts)"))
        #expect(transcriptView.contains("cachedPreviewParts ?? LiveSelectionReference.previewParts"))
        for style in ["Mini", "Notch"] {
            #expect(try source("VoiceInk/Views/Recorder/\(style)RecorderView.swift")
                .contains("cachedPreviewParts: stateProvider.liveContextPreviewParts"))
        }
        #expect(try source("VoiceInk/Views/Recorder/RecorderStackView.swift")
            .components(separatedBy: "LiveSelectionReference.previewParts(").count == 1)
    }

    @Test @MainActor func protocolTypedInputWitnessRetainsTextAndTiming() {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        provider.updateTypedInput("Text through the production HUD interface")
        #expect(session.typedInput == "Text through the production HUD interface")
        // Still editable: no timeline position yet, but durably recoverable.
        #expect(session.liveSelectionReferences.isEmpty)
        let recovered = LiveSelectionReference.interleaving(session.liveSelectionReferencesForRecovery,
            with: "", includeTiming: true)
        #expect(recovered.contains("Text through the production HUD interface\n\n</typed_text>"))
        // The HUD's end callback commits through the same protocol witness.
        provider.endTypingRun()
        #expect(session.liveSelectionReferences.count == 1 && session.typedInput.isEmpty)
        let timed = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "", includeTiming: true)
        #expect(timed.contains("<typed_text start_at=\"") && timed.contains(" end_at=\""))
        #expect(timed.contains("Text through the production HUD interface\n\n</typed_text>"))
        session.endLiveSelectionCapture()
        #expect(session.liveSelectionReferences.count == 1)
    }

    @Test @MainActor func typedOnlyProductionPipelineCompletesWithoutCallingAudioAndDeliversOnce() async throws {
        for (text, raw, disposition) in [
            ("Typed words\nand another line", true, RecordingAutoSendDisposition.configured),
            ("", true, .configured),
            ("Submit typed words", false, .commandEnterOnce),
            ("Raw never submits", true, .commandEnterOnce),
            ("", false, .commandEnterOnce)
        ] {
            let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let modelProvider = TypingTestModelProvider()
            let registry = TranscriptionServiceRegistry(modelProvider: modelProvider,
                modelsDirectory: URL(fileURLWithPath: "/tmp"), modelContext: context)
            let output = TypingTestDelivery()
            let audio = TypingTestAudioSession()
            var archivedPrompts: [String] = []
            let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry,
                enhancementService: nil, delivery: output, archivePrompt: { text, _ in
                    archivedPrompts.append(text)
                    return URL(fileURLWithPath: "/tmp/test-prompt.md")
                }, currentPromptRecipient: {
                    .init(bundleID: "com.openai.codex", bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"))
                })
            let recording = RecordingSession()
            let provider: any RecorderStateProvider = recording
            provider.updateTypedInput(text)
            recording.endLiveSelectionCapture()
            recording.autoSendDisposition = disposition
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
                skipPostProcessing: { raw },
                completionPolicy: { .init(completionDisposition: .normalDelivery,
                    autoSendDisposition: recording.autoSendDisposition) },
                onStateChange: { _ in }, shouldCancel: { false }, isDeliveryAuthorized: { true },
                onCancel: {}, onDismiss: {}, onTranscriptionFailure: { failures.append($0) })
            #expect(audio.transcriptionCalls == 0)
            #expect(failures.isEmpty)
            #expect(record.transcriptionStatus == TranscriptionStatus.completed.rawValue)
            #expect(output.messages.count == (text.isEmpty ? 0 : 1))
            if raw { #expect(output.messages == (text.isEmpty ? [] : [text])) }
            #expect(output.keys == (text.isEmpty ? [] : [raw ? .none : .commandEnter]))
            #expect(output.routes.allSatisfy { $0 == .primaryCurrentInput })
            #expect(archivedPrompts.count == (text.isEmpty ? 0 : 1))
            if !text.isEmpty { #expect(archivedPrompts[0].contains(text)) }
            if !raw && !text.isEmpty {
                #expect(output.messages[0].hasPrefix("[↗]("))
                #expect(output.messages[0] == "[↗](/tmp/test-prompt.md) Submit typed words")
                #expect(!output.messages[0].contains("Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)]"))
                #expect(!output.messages[0].contains("start_at"))
                #expect(record.text.contains("start_at"))
                #expect(!record.text.contains("Read the [full prompt]"))
            }
            if raw { #expect(record.text == text) }
        }
    }
    @Test @MainActor func productionPipelineArchivesTypedRunsWhereTheyWereCommitted() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let recording = RecordingSession()
        let provider: any RecorderStateProvider = recording
        func hear(_ text: String, _ offset: TimeInterval) {
            recording.recordSpeechActivity(text, at: t.addingTimeInterval(offset))
            recording.partialTranscript = text
        }
        hear("Speech before typing", 0)
        recording.updateTypedInput("typed during speech", at: t.addingTimeInterval(1))
        hear("Speech before typing and while typing", 2)
        provider.endTypingRun() // Enter commits here, after speech already shown
        hear("Speech before typing and while typing then after Enter", 3)
        recording.updateTypedInput("left open at stop", at: t.addingTimeInterval(4))
        recording.endLiveSelectionCapture(at: t.addingTimeInterval(5))

        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let registry = TranscriptionServiceRegistry(modelProvider: TypingTestModelProvider(),
            modelsDirectory: URL(fileURLWithPath: "/tmp"), modelContext: context)
        let output = TypingTestDelivery()
        let audio = TypingTestAudioSession()
        // The provider's final result is longer than the last live partial.
        audio.completedText = "Speech before typing and while typing then after Enter plus unstreamed tail"
        var archivedPrompts: [String] = []
        let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry,
            enhancementService: nil, delivery: output, archivePrompt: { text, _ in
                archivedPrompts.append(text)
                return URL(fileURLWithPath: "/tmp/test-prompt.md")
            }, currentPromptRecipient: {
                .init(bundleID: "com.openai.codex", bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"))
            })
        let record = Transcription(text: "", duration: 0)
        context.insert(record)
        let url = URL(fileURLWithPath: "/tmp/agentflow-typed-chronology-\(UUID()).wav")
        let model = NativeAppleModel(name: "unused", displayName: "Unused audio provider",
            description: "Test only", isMultilingualModel: false, supportedLanguages: [:])
        await pipeline.run(transcription: record, audioURL: url,
            transcriptionConfiguration: .init(mode: nil, model: model, language: "en",
                isRealtimeEnabled: false, requestContext: .init(language: "en", prompt: nil)),
            jobIdentity: .init(generation: 1, enqueueSequence: 1, recordingSessionID: recording.id,
                transcriptionID: record.id, audioURL: url),
            formattingConfiguration: { .init(mode: nil, isTextFormattingEnabled: false) },
            session: audio, hasCapturedAudio: true,
            enhancementConfiguration: { nil },
            liveSelectionReferences: { recording.liveSelectionReferencesForDelivery },
            pasteTarget: { .init(destination: .primaryCurrentInput, focusedInput: nil) },
            outputConfiguration: { .init(mode: nil, outputMode: .paste, autoSendKey: .none, customCommand: nil) },
            skipPostProcessing: { false },
            completionPolicy: { .normal },
            onStateChange: { _ in }, shouldCancel: { false }, isDeliveryAuthorized: { true },
            onCancel: {}, onDismiss: {}, onTranscriptionFailure: { Issue.record("Unexpected failure: \($0)") })
        #expect(audio.transcriptionCalls == 1 && output.messages.count == 1)
        let archive = try #require(archivedPrompts.first)
        let ordered = [
            "<speech start_at=\"1800000000.000\" end_at=\"1800000003.000\" timing=\"approximate\">\n\nSpeech before typing and while typing\n\n</speech>",
            "<typed_text start_at=\"1800000001.000\" end_at=\"1800000001.000\">\n\ntyped during speech\n\n</typed_text>",
            "\n\nthen after Enter\n\n</speech>",
            "\n\nplus unstreamed tail\n\n</speech>",
            "<typed_text start_at=\"1800000004.000\" end_at=\"1800000004.000\">\n\nleft open at stop\n\n</typed_text>"
        ]
        let positions = try ordered.map { try #require(archive.range(of: $0)).lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(archive.hasSuffix("left open at stop\n\n</typed_text>"))
        let opening = try #require(output.messages.first?.components(separatedBy: "\n\n").first)
        let authored = ["Speech before typing and while typing", "typed during speech",
                        "then after Enter", "plus unstreamed tail", "left open at stop"]
        let openingPositions = try authored.map { try #require(opening.range(of: $0)).lowerBound }
        #expect(zip(openingPositions, openingPositions.dropFirst()).allSatisfy { $0 < $1 })
        for words in authored {
            #expect(opening.components(separatedBy: words).count == 2)
        }
    }

    @Test @MainActor func lateShiftClipboardCompletionRetainsFormattedPromptAndHistory() async throws {
        let typed = "Every typed word survives the late Shift choice"
        let speech = "Speech before selection and after it"
        let result = try await clipboardPipelineFixture(typed: typed, speech: speech, lateShift: true)
        #expect(result.message.hasPrefix("[↗]("))
        #expect(!result.message.contains("Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)]"))
        #expect(result.message.contains(typed) && result.archive.contains(typed))
        #expect(result.archive.contains("Selected exact content &amp; metadata"))
        // History stores the styled canonical message, whose adjacent LaTeX
        // chunks can split a word. Verify the actual History renderer's lossless
        // text projection rather than treating formatting bytes as missing prose.
        let readableHistory = HistoryContextPresentation.document(result.history).plainText
        #expect(readableHistory.contains(typed) && readableHistory.contains("Speech before"))
        #expect(readableHistory.contains("<typed_text start_at=\"98.000\" end_at=\"99.000\">"))
    }

    @Test @MainActor func clipboardOnlyMatchesNormalCompactPromptAndRetainsEveryWord() async throws {
        for styled in [false, true] {
            for speech in ["", "Speech before selection and after it"] {
                let typed = "Typed first\n" + String(repeating: "complete keyboard content 😀 ", count: 350)
                let normal = try await clipboardPipelineFixture(clipboardOnly: false, typed: typed, speech: speech, styled: styled)
                let copied = try await clipboardPipelineFixture(typed: typed, speech: speech, styled: styled)
                // Each session has its own immutable filename. The remaining
                // editable serialized message must be the same.
                func normalized(_ result: ClipboardPipelineResult) -> String {
                    result.message.replacingOccurrences(of: result.link, with: "PROMPT")
                }
                #expect(normalized(normal) == normalized(copied))
                #expect(!copied.message.contains("…"))
                #expect(copied.message.contains("Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)]"))
                #expect(!copied.message.contains("start_at") && !copied.message.contains("Selected exact content"))
                #expect(copied.archive == normal.archive)
                #expect(copied.archive.contains(typed) && copied.history.count >= typed.count)
                #expect(copied.archive.contains("Selected exact content &amp; metadata"))
                #expect(copied.archive.contains("captured_at=\"100.000\"") && copied.archive.contains("start_at="))
                #expect(!copied.history.contains("Read the [full prompt]"))
                #expect(!copied.message.components(separatedBy: "\n\n")[0].contains("\\color{"))
                #expect(copied.message.contains("`<selection>`"))
            }
        }
    }

    @Test @MainActor func updatedUnifiedCodexHostIncludesCompleteShortPlainContextInline() async throws {
        for (version, build) in [("26.928.20755", "12246"), ("26.928.31416", "12553"),
                                 ("future-host-version", "future-build")] {
            try await assertUnifiedCodexInlinePrompt(version: version, build: build)
        }
    }

    @MainActor private func assertUnifiedCodexInlinePrompt(version: String, build: String) async throws {
        let host = AgentFlowPromptPreview.Recipient(bundleID: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            version: version, build: build)
        let result = try await clipboardPipelineFixture(clipboardOnly: false,
            typed: "Editable typed words", speech: "Speech before selection and after it",
            styled: true, recipientOverride: host)
        #expect(result.message.hasPrefix("[↗]("))
        let opening = result.message.components(separatedBy: "\n\n")[0]
        #expect(opening.contains("Editable typed words") && opening.contains("Speech before"))
        #expect(opening.contains("`<selection>`") && opening.contains("`<screenshot>`"))
        #expect(!opening.contains("<codex_selection") && !opening.contains("<speech "))
        #expect(result.message.hasSuffix("\n\n" + result.archive))
        #expect(!result.message.contains(AgentFlowPromptArchive.interpretationReminder))
        #expect(result.message.utf16.count < 5_000)
        #expect(!result.message.contains("Read the [full prompt]"))
        #expect(!result.message.contains("\\color{"))
        #expect(result.message.contains("start_at=") && result.message.contains("Selected exact content &amp; metadata"))
        #expect(result.message.contains("<codex_selection") && result.message.contains("<local_screenshot"))
        let copied = try await clipboardPipelineFixture(typed: "Editable typed words",
            speech: "Speech before selection and after it", styled: true, recipientOverride: host)
        #expect(result.message.replacingOccurrences(of: result.link, with: "PROMPT")
            == copied.message.replacingOccurrences(of: copied.link, with: "PROMPT"))
        #expect(result.archive == copied.archive)
    }

    @Test @MainActor func ordinaryAutomaticPasteContainsOnlyAuthoredWordsWhileAgentContextSurvives() async throws {
        let typed = "Every typed word\nand its line break"
        let speech = "Spoken context survives"
        for bundleID in ["com.google.Chrome", "com.apple.Safari", "com.microsoft.VSCode", "com.apple.Terminal", "unknown",
                         "com.openai.chat", "com.anthropic.claudefordesktop",
                         "com.tinyspeck.slackmacgap", "com.hnc.Discord"] {
            for styled in [true, false] {
                let host = AgentFlowPromptPreview.Recipient(bundleID: bundleID, bundleURL: nil)
                let result = try await clipboardPipelineFixture(clipboardOnly: false,
                    typed: typed, speech: speech, styled: styled, recipientOverride: host)
                let withoutContext = try await clipboardPipelineFixture(clipboardOnly: false,
                    typed: typed, speech: speech, styled: styled, includeContext: false, recipientOverride: host)
                #expect(result.message == withoutContext.message)
                #expect(result.message.contains(typed) && result.message.contains(speech))
                for forbidden in ["[↗]", "full prompt", "<selection>", "<screenshot>", "<speech", "<typed_text", "Selected exact content", "\\(", "captured_at="] {
                    #expect(!result.message.contains(forbidden))
                }
                #expect(result.archive.contains("Selected exact content") && result.archive.contains("start_at="))
                let archivedSpeech = AgentFlowPromptViewer.events(result.archive)
                    .filter { $0.tag == "speech" }
                    .flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.joined(separator: " ")
                #expect(result.archive.contains(typed) && archivedSpeech == speech)
            }
        }
        for bundleID in ["com.openai.codex", "ru.keepcoder.Telegram", "org.telegram.desktop"] {
            let host = AgentFlowPromptPreview.Recipient(bundleID: bundleID,
                bundleURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                version: "future-host-version", build: "future-build")
            let result = try await clipboardPipelineFixture(clipboardOnly: false,
                typed: typed, speech: speech, styled: true, recipientOverride: host)
            let compact = bundleID == "com.openai.codex"
            #expect(!result.message.contains("Read the [full prompt]"))
            #expect(result.message.hasPrefix("[↗](") == compact)
            if compact {
                let opening = result.message.components(separatedBy: "\n\n")[0]
                #expect(opening.contains("Every typed word") && !opening.contains("<typed_text "))
                #expect(result.message.hasSuffix("\n\n" + result.archive))
                #expect(!result.message.contains(AgentFlowPromptArchive.interpretationReminder))
            } else {
                #expect(HistoryContextPresentation.document(result.message).plainText.contains("Selected exact content"))
            }
            #expect(result.archive.contains(typed) && result.archive.contains("Selected exact content"))
            let readableHistory = HistoryContextPresentation.document(result.history).plainText
            #expect(readableHistory.contains("Every typed word") && readableHistory.contains(speech))
        }
        let raw = try await clipboardPipelineFixture(clipboardOnly: false,
            typed: "Raw stays verbatim", raw: true)
        #expect(raw.message == "Raw stays verbatim" && raw.history == raw.message)
    }

    @Test @MainActor func clipboardOnlyArchiveFailureRawAndOtherRecipientsRetainFullText() async throws {
        let typed = "Keep every typed word\nand second line"
        let failed = try await clipboardPipelineFixture(typed: typed, speech: "spoken words", archiveFails: true)
        #expect(failed.message == failed.archive)
        #expect(failed.message.contains(typed) && failed.message.contains("Selected exact content &amp; metadata"))
        #expect(!failed.message.contains("[full prompt]") && !failed.message.contains("\\color{"))
        let raw = try await clipboardPipelineFixture(typed: typed, raw: true)
        #expect(raw.message == typed && raw.history == typed && raw.archive == typed)
        for outputMode in [ModeOutputMode.respond, .customCommand] {
            let other = try await clipboardPipelineFixture(typed: typed, outputMode: outputMode)
            // These older direct-recipient messages retain their queue-readable
            // opening; the durable source no longer duplicates its timed text.
            #expect(other.message.hasSuffix(other.archive))
            #expect(other.archive.hasPrefix("<typed_text "))
            #expect(!other.message.contains("[full prompt]"))
        }
    }

    @Test @MainActor func clipboardPromptDoesNotDependOnTheAppFocusedAtFinish() async throws {
        // Won't paste has no recipient yet. The recorder, source app or a different
        // workspace may be focused now; manual Cmd-V happens later in Codex.
        for recipient in ["com.ethansk.VoiceInkPlusPlus", "com.microsoft.VSCode",
                          "com.google.Chrome", "org.telegram.desktop", "unknown"] {
            for speech in ["", "spoken before source app switch"] {
                let copied = try await clipboardPipelineFixture(typed: "typed after source app switch",
                    speech: speech, recipient: recipient)
                #expect(!copied.message.contains("Read the [\(AgentFlowPromptPreview.fullPromptLinkLabel)]"))
                // Clipboard-only must reuse the same editable Codex preview,
                // even if another app owns focus when the session finishes.
                #expect(!copied.message.components(separatedBy: "\n\n")[0].contains("\\color{") && !copied.message.contains("\\("))
                #expect(copied.message.contains("typed after source app switch"))
                #expect(copied.archive.contains("typed after source app switch"))
                let opening = copied.message.components(separatedBy: "\n\n")[0]
                #expect(opening.contains("typed after source app switch"))
                #expect(opening.contains("`<selection>`") && opening.contains("`<screenshot>`"))
                #expect(copied.message.hasSuffix("\n\n" + copied.archive))
                #expect(!copied.message.contains(AgentFlowPromptArchive.interpretationReminder))
            }
        }
    }

    @Test @MainActor func emptyClipboardOnlySessionLeavesExistingClipboardUntouched() async throws {
        let result = try await clipboardPipelineFixture(typed: "", includeContext: false)
        #expect(result.message == "previous clipboard")
        #expect(result.archive.isEmpty && result.history.isEmpty)
    }

    private struct ClipboardPipelineResult {
        var message: String
        var history: String
        var archive: String
        var link: String
    }

    @Test @MainActor func lateShiftSurvivesProviderFreezeArchiveAndDeliveryQueue() async throws {
        for stage in ["afterPolicy", "archive", "lease"] {
            for speech in ["", "Spoken context survives"] {
                let result = try await clipboardPipelineFixture(typed: "Every editable typed word",
                    speech: speech, lateShift: true, lateShiftStage: stage)
                #expect(result.message.contains("Every editable typed word"))
                #expect(!result.message.contains("Read the [full prompt]"))
                #expect(result.archive.contains("Selected exact content"))
                #expect(result.archive.contains("start_at=") && !result.link.isEmpty)
                #expect(HistoryContextPresentation.document(result.history).plainText.contains("Every editable typed word"))
            }
        }
    }

    @Test @MainActor func typingStopGraceKeepsFastResultsSelectableAndSealsBeforeEffects() async throws {
        let stopped = RecordingSession()
        stopped.armTypingClipboardOnlyCompletion(minimumInterval: 0.06)
        stopped.phase = .transcribing
        #expect(await stopped.freezeCompletionPolicy() == .normal)
        #expect(!stopped.acceptsCompletionDispositionChanges)
        let commit = Task { @MainActor in await stopped.commitTypingCompletion() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(stopped.acceptsTypingClipboardOnlyCompletion)
        #expect(stopped.selectTypingClipboardOnlyCompletion())
        #expect(await commit.value)
        #expect(!stopped.acceptsTypingClipboardOnlyCompletion)
        #expect(!stopped.selectTypingClipboardOnlyCompletion())

        let ordinary = RecordingSession()
        ordinary.armTypingClipboardOnlyCompletion(minimumInterval: 0.02)
        ordinary.phase = .transcribing
        let started = ContinuousClock.now
        #expect(!(await ordinary.commitTypingCompletion()))
        #expect(started.duration(to: .now) >= .milliseconds(10))
        #expect(!ordinary.acceptsTypingClipboardOnlyCompletion)
    }

    @Test @MainActor func lateShiftSuppressesRespondAndCustomCommandOutput() async throws {
        for output in [ModeOutputMode.respond, .customCommand] {
            let result = try await clipboardPipelineFixture(typed: "Keep the request, run no output action",
                outputMode: output, lateShift: true, lateShiftStage: "afterPolicy")
            #expect(result.archive.contains("Keep the request, run no output action"))
            #expect(result.message.hasSuffix(result.archive))
        }
    }

    @MainActor private func clipboardPipelineFixture(
        clipboardOnly: Bool = true, typed: String, speech: String = "", styled: Bool = true,
        raw: Bool = false, recipient: String = "com.openai.codex", archiveFails: Bool = false,
        includeContext: Bool = true, outputMode: ModeOutputMode = .paste,
        recipientOverride: AgentFlowPromptPreview.Recipient? = nil, lateShift: Bool = false,
        lateShiftStage: String = "beforePolicy", providerFails: Bool = false,
        canceled: Bool = false, authorized: Bool = true, emptyProvider: Bool = false,
        realRecoveryGate: Bool = false, hudRecovery: String = "", enhancementResult: String? = nil
    ) async throws -> ClipboardPipelineResult {
        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let enhancement = enhancementResult.map { result in
            TypingTestEnhancement(modelContext: context, result: result)
        }
        let registry = TranscriptionServiceRegistry(modelProvider: TypingTestModelProvider(),
            modelsDirectory: URL(fileURLWithPath: "/tmp"), modelContext: context)
        let output = TypingTestDelivery()
        let realDelivery = TranscriptionDelivery(recoveryPasteOverride: { request, actions in
            #expect(request.allowsTypedRecoveryPaste)
            await output.deliver(request, actions: actions)
        })
        let audio = TypingTestAudioSession()
        audio.completedText = providerFails && !emptyProvider ? nil : speech
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(ClipboardManager.setClipboard("previous clipboard", on: board))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardPrompt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var archived = "", link = ""
        var copies = 0, targets = 0, leases = 0, outputReads = 0, recipientReads = 0
        var onArchive: (() async -> Void)?
        let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry,
            enhancementService: enhancement, delivery: realRecoveryGate ? realDelivery : output, archivePrompt: { text, id in
                archived = text
                if archiveFails { throw CocoaError(.fileWriteNoPermission) }
                let file = try AgentFlowPromptArchive.write(text, recordID: id, directory: directory)
                try AgentFlowPromptArchive.writeViewer(text, for: file)
                #expect(try String(contentsOf: file, encoding: .utf8) == AgentFlowPromptArchive.interpretationReminder + text)
                let viewer = try #require(AgentFlowPromptArchive.viewerURL(for: file))
                #expect(FileManager.default.fileExists(atPath: viewer.path))
                link = viewer.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                await onArchive?()
                return file
            }, currentPromptRecipient: {
                recipientReads += 1
                return recipientOverride ?? .init(bundleID: recipient, bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"))
            }, copyCompletedText: { text in
                copies += 1
                return ClipboardManager.setClipboard(text, transient: false, on: board)
            })
        var failureCopy = "", failureCount = 0
        var references: [LiveSelectionReference] = []
        if let entry = LiveSelectionReference(typedText: typed) {
            references.append(entry.timed(at: Date(timeIntervalSince1970: 99), startedAt: Date(timeIntervalSince1970: 98)))
        }
        if includeContext {
            references.append(try #require(LiveSelectionReference("Selected exact content & metadata"))
                .anchored(after: "Speech before").timed(at: Date(timeIntervalSince1970: 100)))
            references.append(try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/tmp/no-private-image.png")))
                .anchored(after: "Speech before selection").timed(at: Date(timeIntervalSince1970: 101)))
        }
        if !speech.isEmpty {
            references.append(.speechTiming(after: speech, startedAt: Date(timeIntervalSince1970: 97), endedAt: Date(timeIntervalSince1970: 102)))
        }
        let frozenReferences = references
        let record = Transcription(text: "", duration: 0)
        context.insert(record)
        let url = directory.appendingPathComponent("unused.wav")
        let model = NativeAppleModel(name: "unused", displayName: "Unused", description: "Test", isMultilingualModel: false, supportedLanguages: [:])
        let mode = ModeConfig(name: "Test", isAIEnhancementEnabled: false, outputMode: outputMode,
            autoSendKey: .enter, isStyledContextEnabled: styled)
        let stoppedSession = RecordingSession()
        var state: RecordingState = .recording
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { true },
            recordingState: { state },
            toggleRecorderPanel: { _, _ in state = .idle; stoppedSession.phase = .transcribing },
            pendingClipboardOnlySessionID: { stoppedSession.acceptsCompletionDispositionChanges ? stoppedSession.id : nil },
            activeRecordingSessionID: { stoppedSession.id },
            selectPendingClipboardOnlyCompletion: { id in
                id == stoppedSession.id && stoppedSession.selectPendingClipboardOnlyCompletion()
            }, armTypingClipboardOnlyCompletion: { id in
                #expect(id == stoppedSession.id)
                stoppedSession.armTypingClipboardOnlyCompletion(minimumInterval: 0.01)
            }, pendingTypingClipboardOnlySessionID: {
                stoppedSession.acceptsTypingClipboardOnlyCompletion ? stoppedSession.id : nil
            }, selectTypingClipboardOnlyCompletion: { id in
                id == stoppedSession.id && stoppedSession.selectTypingClipboardOnlyCompletion()
            }, cancelRecording: {})
        defer { handler.reset() }
        if lateShift {
            await handler.handleTypingToggle { _ in Issue.record("Finish must not start typing") }
            if lateShiftStage == "beforePolicy" { #expect(handler.handleTypingStopSecondChanceShift()) }
            if lateShiftStage == "archive" {
                onArchive = {
                    await Task.yield()
                    #expect(!stoppedSession.acceptsCompletionDispositionChanges)
                    #expect(handler.handleTypingStopSecondChanceShift())
                }
            }
        }
        await pipeline.run(transcription: record, audioURL: url,
            transcriptionConfiguration: .init(mode: mode, model: model, language: "en", isRealtimeEnabled: false,
                requestContext: .init(language: "en", prompt: nil)),
            jobIdentity: .init(generation: 1, enqueueSequence: 1, recordingSessionID: UUID(), transcriptionID: record.id, audioURL: url),
            formattingConfiguration: { .init(mode: mode, isTextFormattingEnabled: false) },
            session: audio, hasCapturedAudio: providerFails || !speech.isEmpty,
            enhancementConfiguration: {
                enhancement == nil ? nil : .init(mode: mode, isEnabled: true, prompt: nil,
                    provider: nil, modelName: nil, useClipboardContext: false,
                    useSelectedTextContext: false, useScreenCaptureContext: false)
            }, liveSelectionReferences: { frozenReferences },
            pasteTarget: { targets += 1; return .init(destination: .primaryCurrentInput, focusedInput: nil) },
            outputConfiguration: { outputReads += 1; return .init(mode: mode, outputMode: outputMode, autoSendKey: .enter, customCommand: nil) },
            skipPostProcessing: { raw },
            completionPolicy: {
                if lateShift {
                    let policy = await stoppedSession.freezeCompletionPolicy()
                    if lateShiftStage == "afterPolicy" { #expect(handler.handleTypingStopSecondChanceShift()) }
                    return policy
                }
                return .init(completionDisposition: clipboardOnly ? .clipboardOnly : .normalDelivery, autoSendDisposition: .configured)
            },
            pendingTypingClipboardOnly: { stoppedSession.typingClipboardOnlySelected },
            commitTypingCompletion: { await stoppedSession.commitTypingCompletion() },
            recoverablePartialTranscript: { hudRecovery },
            onStateChange: { _ in }, shouldCancel: { canceled }, isDeliveryAuthorized: { authorized },
            acquireDeliveryLease: { _ in
                leases += 1
                if lateShift && lateShiftStage == "lease" {
                    await Task.yield()
                    #expect(!stoppedSession.acceptsCompletionDispositionChanges)
                    #expect(handler.handleTypingStopSecondChanceShift())
                }
                return true
            }, onCancel: {}, onDismiss: {}, onTranscriptionFailure: { _ in failureCount += 1 },
            onFailureCopyText: { failureCopy = $0 })
        if providerFails || canceled {
            #expect(record.preservesOriginalAudioForRecovery)
            #expect(output.keys.allSatisfy { $0 == .none })
            #expect(record.transcriptionStatus == (canceled
                ? TranscriptionStatus.canceledWithResult.rawValue : TranscriptionStatus.failed.rawValue))
            if clipboardOnly || canceled || !authorized {
                #expect(output.messages.isEmpty && targets == 0 && leases == 0)
            } else if !typed.isEmpty {
                #expect(output.messages.count == 1 && targets == 1 && leases == 1)
                #expect(failureCopy == output.messages.first)
            } else {
                #expect(output.messages.isEmpty && targets == 0 && leases == 0)
            }
            if clipboardOnly || canceled { #expect(failureCount == 0) }
            return .init(message: output.messages.first ?? (board.string(forType: .string) ?? ""),
                history: record.enhancedText ?? record.text, archive: archived, link: link)
        }
        if let enhancementResult {
            if outputMode == .respond {
                #expect(enhancement?.inputs.first?.contains(typed) == true)
                if !enhancementResult.isEmpty {
                    #expect(output.messages == [enhancementResult])
                    #expect(record.text.contains(typed))
                }
            }
            if enhancementResult.isEmpty {
                #expect(record.enhancedText == nil)
                // Inline context can legitimately divide a spoken sentence.
                // Require every authored word, not adjacent words across a marker.
                #expect(speech.split(separator: " ").allSatisfy {
                    output.messages.first?.contains(String($0)) == true
                })
            }
            return .init(message: output.messages.first ?? "", history: record.enhancedText ?? record.text,
                archive: archived, link: link)
        }
        #expect(record.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(audio.transcriptionCalls == (speech.isEmpty ? 0 : 1))
        if clipboardOnly {
            let reachedQueue = lateShift && lateShiftStage == "lease"
            #expect(targets == (reachedQueue ? 1 : 0) && leases == (reachedQueue ? 1 : 0))
            #expect(output.messages.isEmpty && output.keys.isEmpty)
            #expect(outputReads == (reachedQueue ? 2 : 1))
            #expect(recipientReads == 0)
            #expect(copies == (archived.isEmpty ? 0 : 1))
            #expect(board.data(forType: ClipboardManager.pasteSessionType) == nil)
            #expect(board.data(forType: .init("org.nspasteboard.TransientType")) == nil)
        } else {
            #expect(copies == 0 && targets == 1 && leases == 1 && output.messages.count == 1)
        }
        return .init(message: clipboardOnly ? (board.string(forType: .string) ?? "") : (output.messages.first ?? ""),
            history: record.enhancedText ?? record.text, archive: archived, link: link)
    }

    @Test @MainActor func failedVoiceStillPastesTypedDraftWithoutSubmitOrModeEffects() async throws {
        for mode in [ModeOutputMode.paste, .respond, .customCommand] {
            for raw in [false, true] {
                let result = try await clipboardPipelineFixture(clipboardOnly: false,
                    typed: "Exact keyboard words\nwith another line", raw: raw,
                    outputMode: mode, providerFails: true)
                #expect(result.message.contains("Exact keyboard words"))
                #expect(result.archive.contains("with another line"))
                #expect(!result.message.contains("Transcription Failed:"))
                if !raw {
                    #expect(result.message.hasPrefix("[↗]("))
                    #expect(result.archive.contains("<typed_text start_at="))
                    #expect(result.archive.contains("Selected exact content &amp; metadata"))
                }
            }
        }
    }

    @Test @MainActor func failedVoiceUsesProductionRecoveryGateAndCopyPayload() async throws {
        let result = try await clipboardPipelineFixture(clipboardOnly: false,
            typed: "All independently authored keyboard words", outputMode: .respond,
            providerFails: true, realRecoveryGate: true)
        #expect(result.message.contains("All independently authored keyboard words"))
        #expect(result.message.contains(result.link))
    }

    @Test @MainActor func emptyProviderResultUsesSameTypedRecoveryWithoutReturn() async throws {
        let result = try await clipboardPipelineFixture(clipboardOnly: false,
            typed: "Never silently drop these", providerFails: true, emptyProvider: true,
            realRecoveryGate: true)
        #expect(result.message.contains("Never silently drop these"))
    }

    @Test @MainActor func voiceOnlyFailureNeverAcquiresDestinationAndWontPasteStaysFailed() async throws {
        _ = try await clipboardPipelineFixture(clipboardOnly: false, typed: "", providerFails: true)
        let retained = try await clipboardPipelineFixture(typed: "", providerFails: true,
            hudRecovery: "Saved provisional speech")
        #expect(retained.message == "Saved provisional speech")
    }

    @Test @MainActor func productionRecoveryGateRejectsSubmitCommandResponseAndUnownedFailures() async {
        let record = Transcription(text: "Typed content", duration: 0, transcriptionStatus: .failed)
        var calls = 0, dismissals = 0
        let delivery = TranscriptionDelivery(recoveryPasteOverride: { _, _ in calls += 1 })
        let actions = TranscriptionDelivery.Actions(setState: { _ in }, dismiss: { dismissals += 1 },
            sendFollowUp: { _, _ in Issue.record("No follow-up") },
            showResponse: { _, _ in Issue.record("No response") }, failResponse: { _ in })
        for (mode, key, followUp, text) in [
            (ModeOutputMode.paste, AutoSendKey.enter, false, "typed"),
            (.respond, .none, false, "typed"), (.customCommand, .none, false, "typed"),
            (.paste, .none, true, "typed"), (.paste, .none, false, " ")
        ] {
            await delivery.deliver(.init(transcription: record, text: text,
                output: .init(mode: nil, outputMode: mode, autoSendKey: key, customCommand: nil),
                responseConfig: nil, responseError: nil, isAssistantFollowUp: followUp,
                pasteTarget: .init(destination: .primaryCurrentInput, focusedInput: nil),
                resolveQueuedPrimaryAutoSend: { .unchanged($0) }, onQueuedPrimaryAutoSendIssued: {},
                recoversTypedDraft: true), actions: actions)
        }
        #expect(calls == 0 && dismissals == 5)
    }

    @Test @MainActor func emptyEnhancementKeepsSpeechAndTypingInsteadOfDroppingSpeech() async throws {
        let result = try await clipboardPipelineFixture(clipboardOnly: false, typed: "Keyboard words",
            speech: "Speech which must not be lost", styled: false, enhancementResult: "")
        #expect(result.history.contains("Keyboard words"))
        #expect(result.history.contains("Speech which must not be lost"))
    }

    @Test @MainActor func respondModeUsesTypedAndMixedAuthoredInputButNeverSplicesItIntoAnswer() async throws {
        for speech in ["", "Spoken part"] {
            let result = try await clipboardPipelineFixture(clipboardOnly: false,
                typed: "Authored keyboard request", speech: speech, outputMode: .respond,
                enhancementResult: "Actual assistant answer")
            #expect(result.message == "Actual assistant answer")
            #expect(result.archive.contains("Authored keyboard request"))
        }
    }

    @Test @MainActor func failedVoiceClipboardOnlyRetainsFormattedTypedPrompt() async throws {
        let result = try await clipboardPipelineFixture(typed: "Keep these keyboard words",
            providerFails: true)
        #expect(result.message.hasPrefix("[↗]("))
        #expect(result.message.contains("Keep these keyboard words"))
        #expect(result.archive.contains("Keep these keyboard words"))
    }

    @Test @MainActor func canceledMixedSessionRetainsTypingWithoutProviderOrHUDText() async throws {
        let result = try await clipboardPipelineFixture(typed: "Retain independently authored typing",
            providerFails: true, canceled: true)
        #expect(result.message.contains("Retain independently authored typing"))
        #expect(result.history.contains("Retain independently authored typing"))
    }

    @Test @MainActor func staleFailedVoiceNeverResolvesOrPastesTypedDraft() async throws {
        let result = try await clipboardPipelineFixture(clipboardOnly: false,
            typed: "Keep this in History", providerFails: true, authorized: false)
        #expect(result.archive.contains("Keep this in History"))
        #expect(!result.message.contains("Keep this in History"))
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

    @Test @MainActor func typingToggleReservesMicrophoneOffBeforeStarting() async {
        let requestID = UUID()
        var calls: [String] = []
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { false },
            recordingState: { .idle }, toggleRecorderPanel: { _, _ in },
            cancelRecording: {},
            reserveRecordingStart: { calls.append("voice"); return nil },
            reserveTypingRecordingStart: { calls.append("typing"); return requestID },
            startReservedRecording: { id, _ in
                #expect(id == requestID); calls.append("start")
            }
        )
        await handler.handleTypingToggle { id in
            #expect(id == requestID); calls.append("focus")
        }
        #expect(calls == ["typing", "focus", "start"])
        handler.reset()
    }

    @Test @MainActor func typingChordFinishesWithoutRefocusingUnfocusedEditor() async throws {
        for active: RecordingState in [.recording, .paused] {
            var state = active
            var finishes: [RecordingPasteDestination] = []
            var dispositionWrites = 0
            var microphoneChanges = 0
            let window = TypingFocusProbeWindow()
            let editor = RecorderTypingTextView()
            window.contentView = editor
            let handler = RecordingShortcutModeHandler(
                canHandleShortcutAction: { true }, isRecorderVisible: { true },
                recordingState: { state },
                toggleRecorderPanel: { _, route in finishes.append(route); state = .transcribing },
                toggleRecordingPause: { microphoneChanges += 1; return true },
                setActiveRecordingCompletionDisposition: { _ in dispositionWrites += 1 },
                setActiveRecordingAutoSendDisposition: { _ in dispositionWrites += 1 },
                cancelRecording: {})
            await handler.handleTypingToggle { _ in
                Issue.record("Active finish must not request a new microphone-off start")
            }
            #expect(finishes == [.primaryCurrentInput] && state == .transcribing)
            #expect(window.focusRequests == 0 && !window.isKeyWindow)
            // Finishing clears any pending Primary gesture policy before the
            // ordinary current-input route; that reset is not a refocus or mic toggle.
            #expect(dispositionWrites == 2 && microphoneChanges == 0)
            handler.reset()
        }
    }

    @Test @MainActor func standaloneShiftTapObservesOnlyReleasedShiftWithoutSwallowingEvents() throws {
        let monitor = ShortcutMonitor()
        defer { monitor.stop() }
        var requests = 0
        monitor.start(shortcuts: [.primaryRecording: .modifierOnly(keyCode: nil,
            modifierFlags: [.shift, .control, .option])],
            onKeyDown: { _, _ in }, onKeyUp: { _, _ in },
            onStandaloneShift: { requests += 1 }, installSystemEventTap: false)
        func event(_ key: UInt16, _ flags: CGEventFlags, type: CGEventType = .flagsChanged) throws {
            let e = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
            e.type = type; e.flags = flags
            #expect(!monitor.handleCGEvent(type: type, event: e))
        }
        for key: UInt16 in [56, 60] {
            let before = requests
            try event(key, .maskShift)
            #expect(requests == before)
            try event(key, [])
            #expect(requests == before + 1)
        }
        // Capital-letter typing and a Shift-prefixed modifier chord are not
        // standalone taps. Their eventual Shift releases remain balanced too.
        try event(56, .maskShift)
        try event(0, .maskShift, type: .keyDown)
        try event(0, .maskShift, type: .keyUp)
        try event(56, [])
        try event(56, .maskShift)
        try event(59, [.maskShift, .maskControl])
        try event(59, .maskShift)
        try event(56, [])
        // Shift added before releasing the Command/Option stop is not a new tap.
        try event(56, [.maskCommand, .maskAlternate, .maskShift])
        try event(55, [.maskAlternate, .maskShift])
        try event(58, .maskShift)
        try event(56, [])
        #expect(requests == 2)
    }

    @Test @MainActor func typingStopSecondChanceShiftIsExactOneShotAndRejectsStaleResults() async {
        for rejection in ["none", "newer", "frozen", "active", "starting", "cancel", "reset", "shiftedStop", "otherStop"] {
            let stopped = RecordingSession(), replacement = RecordingSession()
            var state: RecordingState = .recording
            var pendingID: UUID? = stopped.id
            var selections: [UUID] = []
            var cancels = 0
            let handler = RecordingShortcutModeHandler(
                canHandleShortcutAction: { true }, isRecorderVisible: { true }, recordingState: { state },
                toggleRecorderPanel: { _, route in
                    #expect(route == .primaryCurrentInput)
                    stopped.phase = .transcribing; state = .idle
                }, finishRecordingToClipboard: { _ in state = .idle; return true },
                pendingClipboardOnlySessionID: { pendingID }, activeRecordingSessionID: { stopped.id },
                selectPendingClipboardOnlyCompletion: { id in
                    selections.append(id)
                    return stopped.selectPendingClipboardOnlyCompletion()
                }, armTypingClipboardOnlyCompletion: { _ in stopped.armTypingClipboardOnlyCompletion(minimumInterval: 0) },
                pendingTypingClipboardOnlySessionID: {
                    stopped.acceptsTypingClipboardOnlyCompletion ? pendingID : nil
                }, selectTypingClipboardOnlyCompletion: { id in
                    selections.append(id)
                    return stopped.selectTypingClipboardOnlyCompletion()
                }, cancelRecording: { cancels += 1 })
            if rejection != "otherStop" {
                await handler.handleTypingToggle(clipboardOnly: rejection == "shiftedStop") { _ in
                    Issue.record("Active finish must not start typing")
                }
            } else { state = .idle; stopped.phase = .transcribing }
            switch rejection {
            case "newer": pendingID = replacement.id
            case "frozen": _ = await stopped.commitTypingCompletion(); pendingID = nil
            case "active": state = .recording
            case "starting": state = .starting
            case "cancel": stopped.shouldCancel = true; pendingID = nil
            case "reset": handler.reset()
            default: break
            }
            #expect(handler.handleTypingStopSecondChanceShift() == (rejection == "none"))
            #expect(stopped.completionDisposition == (rejection == "none" ? .clipboardOnly : .normalDelivery))
            #expect(replacement.completionDisposition == .normalDelivery && cancels == 0)
            #expect(selections == (rejection == "none" ? [stopped.id] : []))
            #expect(!handler.handleTypingStopSecondChanceShift())
            handler.reset()
        }
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
        for (order, shiftHeld) in orders(keys).flatMap({ order in
            [false, true].map { (order, $0) }
        }) {
            var held: UInt = 0
            var down = false
            var actions = 0
            for (index, keyAndBit) in (order + order).enumerated() {
                let (key, bit) = keyAndBit
                if index < 4 { held |= bit } else { held &= ~bit }
                var flags = held | 0x100 // Real event's unrelated non-coalesced bit.
                if held & 0x18 != 0 { flags |= NSEvent.ModifierFlags.command.rawValue }
                if held & 0x60 != 0 { flags |= NSEvent.ModifierFlags.option.rawValue }
                if shiftHeld { flags |= NSEvent.ModifierFlags.shift.rawValue }
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
        #expect(ShortcutMonitor.typingToggleTransition(wasDown: false, keyCode: 61,
            rawFlags: full | NSEvent.ModifierFlags.shift.rawValue).dispatchKeyDown)
        // Shift changes after the chord was consumed cannot turn one finish
        // into a second action; the four owned keys must be released first.
        for shiftFlags in [UInt(0), NSEvent.ModifierFlags.shift.rawValue] {
            let lateShift = ShortcutMonitor.typingToggleTransition(wasDown: true,
                keyCode: 56, rawFlags: full | shiftFlags)
            #expect(lateShift.isDown && !lateShift.dispatchKeyDown)
            #expect(!lateShift.suppressDownstream)
        }
        for extra in [NSEvent.ModifierFlags.control, .function] {
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

    @Test @MainActor func typingIsReadyDuringMicrophoneOffStartupWithoutRefocusingLater() async throws {
        let session = RecordingSession()
        session.liveRecordingState = .starting
        #expect(!session.canTypeInHUD)
        session.microphoneOff = true
        session.hasCapturedAudio = false
        #expect(session.canTypeInHUD)
        session.typingFocus.requestInitialFocus()
        // Exercise the real registration path: the request precedes mounting.
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        editor.typingFocus = session.typingFocus
        window.contentView = editor
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1 && !session.typingFocus.initialFocusPending)
        session.updateTypedInput("Typed before audio startup finishes")
        session.liveRecordingState = .recording
        session.typingFocus.register(editor)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        session.endLiveSelectionCapture()
        #expect(LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "")
            == "Typed before audio startup finishes")
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

    @Test @MainActor func shortSpeechWithoutCallbacksKeepsFrozenSessionTimestamps() {
        let session = RecordingSession()
        let finish = session.createdAt.addingTimeInterval(3)
        session.endLiveSelectionCapture(at: finish)
        let original = session.liveSelectionReferencesForDelivery
        session.endLiveSelectionCapture(at: finish.addingTimeInterval(40))
        #expect(session.liveSelectionReferencesForDelivery == original)
        #expect(session.liveSelectionReferences.isEmpty)
        let xml = LiveSelectionReference.interleaving(original, with: "Short speech", includeTiming: true)
        let stamp = { (date: Date) in String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970) }
        #expect(xml.contains("start_at=\"\(stamp(session.createdAt))\""))
        #expect(xml.contains("end_at=\"\(stamp(finish))\" timing=\"session_window\""))
        #expect(!xml.contains("unavailable"))
        #expect(LiveSelectionReference.interleaving(original, with: "Short speech") == "Short speech")
    }

    @Test @MainActor func liveSpeechTimingOutranksSessionWindowFallback() {
        let session = RecordingSession()
        session.recordSpeechActivity("Live speech", at: session.createdAt.addingTimeInterval(1))
        session.partialTranscript = "Live speech"
        session.endLiveSelectionCapture(at: session.createdAt.addingTimeInterval(3))
        #expect(session.liveSelectionReferencesForDelivery == session.liveSelectionReferences)
        let xml = LiveSelectionReference.interleaving(session.liveSelectionReferencesForDelivery,
            with: "Live speech", includeTiming: true)
        #expect(xml.contains("timing=\"approximate\""))
        #expect(!xml.contains("session_window"))
    }

    @Test @MainActor func typingOnlyNeverInventsSpeechWindow() {
        let session = RecordingSession()
        session.hasCapturedAudio = false
        session.microphoneOff = true
        session.updateTypedInput("Typed only")
        session.endLiveSelectionCapture()
        #expect(session.liveSelectionReferencesForDelivery == session.liveSelectionReferences)
        let xml = LiveSelectionReference.interleaving(session.liveSelectionReferencesForDelivery,
            with: "", includeTiming: true)
        #expect(xml.contains("<typed_text start_at="))
        #expect(!xml.contains("<speech") && !xml.contains("session_window"))
    }

    @Test @MainActor func retryPreservesOriginalSessionWindowWithoutNewDates() {
        let original = RecordingSession()
        original.endLiveSelectionCapture(at: original.createdAt.addingTimeInterval(2))
        let references = original.liveSelectionReferencesForDelivery
        let retry = RecordingSession(phase: .transcribing)
        retry.restoreLiveContextForRetry(references)
        retry.endLiveSelectionCapture(at: original.createdAt.addingTimeInterval(100))
        #expect(retry.liveSelectionReferencesForDelivery == references)
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
            let firstSelection = LiveSelectionReference.interleaving([selection], with: "", includeTiming: true)
            let renderedSelection = presentation == .plain ? firstSelection
                : LiveSelectionStyledMath.coloredXML(firstSelection.replacingOccurrences(
                    of: #">\s+<"#, with: "><", options: .regularExpression),
                    color: LiveSelectionStyledMath.selectionColor)
            #expect(result.hasPrefix(opening + "\n\n" + renderedSelection))
            #expect(result.components(separatedBy: opening + "\n\n").count == 2)
            #expect(!result.contains("agent_flow_context") && !result.contains("authored_text_above"))
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
        #expect(pipeline.contains("if (hasCapturedAudio || shouldRespondInRecorder),"))
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

    @Test @MainActor func automaticTypingFocusReturnCanBeDisabledWithoutDisablingExplicitFocus() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentFlow.Focus.\(UUID())"))
        #expect(RecorderTypingFocus.automaticReturnEnabled(in: defaults))
        defaults.set(false, forKey: RecorderTypingFocus.automaticReturnDefaultsKey)
        let focus = RecorderTypingFocus(automaticReturnEnabled: {
            RecorderTypingFocus.automaticReturnEnabled(in: defaults)
        })
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.register(editor)
        focus.enable(editor)
        #expect(focus.isEnabled)
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0)

        // The keyboard typing shortcut is an explicit request, not the disabled
        // automatic return after selecting text or taking a screenshot.
        focus.requestInitialFocus()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1 && !focus.initialFocusPending)
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        focus.disable(releaseKeyboard: false)
    }

    @Test @MainActor func acceptedSelectionAndScreenshotReturnOnlyEngagedTypingFocus() async throws {
        let session = RecordingSession()
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        let selection = try #require(LiveSelectionReference("captured exact selection"))
        let screenshot = try #require(LiveSelectionReference(screenshotURL:
            URL(fileURLWithPath: "/Users/test/Screenshot.png")))
        session.recordLiveSelection(selection)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0)
        session.typingFocus.enable(editor)
        session.recordLiveSelection(selection)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        session.recordLiveSelection(screenshot)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 2)
        session.typingFocus.disable(releaseKeyboard: false)
        session.recordLiveSelection(selection)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 2)
    }

    @Test @MainActor func automaticTypingFocusReturnRechecksFlagAndFinishAtFocusBoundary() async throws {
        var enabled = true
        let focus = RecorderTypingFocus(automaticReturnEnabled: { enabled })
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.enable(editor)
        #expect(focus.isEnabled)
        focus.returnAfterContext()
        enabled = false
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0)
        enabled = true
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1)
        focus.returnAfterContext()
        focus.disable(releaseKeyboard: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 1 && !focus.isEnabled)
    }

    @Test @MainActor func contextReturnWaitsForMouseReleaseAndVerifiesKeyboardOwnership() async throws {
        var held = true
        let focus = RecorderTypingFocus(mouseButtonsPressed: { held }, retryDelay: 5_000_000)
        let window = TypingFocusProbeWindow()
        window.refusedFocusAttempts = 1
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.enable(editor)
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 0)
        held = false
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(window.focusRequests == 2)
        #expect(window.isKeyWindow && window.firstResponder === editor)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(window.focusRequests == 2) // no focus chasing after success
        focus.disable(releaseKeyboard: false)
    }

    @Test @MainActor func initialSelectionCannotDropFocusWhileEditorIsMounting() async throws {
        let focus = RecorderTypingFocus(retryDelay: 5_000_000)
        focus.requestInitialFocus()
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 15_000_000)
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.register(editor)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(window.focusRequests == 1 && !focus.initialFocusPending)
        #expect(window.firstResponder === editor)
        focus.disable(releaseKeyboard: false)
    }

    @Test @MainActor func contextReturnIsBoundedCoalescedAndCancelledOnFinish() async throws {
        var held = true
        var checks = 0
        let focus = RecorderTypingFocus(mouseButtonsPressed: {
            checks += 1
            return held
        }, retryDelay: 5_000_000, maximumAttempts: 3)
        let window = TypingFocusProbeWindow()
        let editor = RecorderTypingTextView()
        window.contentView = editor
        focus.enable(editor)
        focus.returnAfterContext()
        focus.returnAfterContext()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(checks == 3 && window.focusRequests == 0)
        held = false
        try await Task.sleep(nanoseconds: 15_000_000)
        #expect(window.focusRequests == 0) // expired context does not steal focus later
        focus.returnAfterContext()
        focus.disable(releaseKeyboard: false)
        try await Task.sleep(nanoseconds: 15_000_000)
        #expect(window.focusRequests == 0)
    }

    @Test func unfocusControlAndItsEmptyGutterAreRemoved() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let components = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/Recorder/RecorderComponents.swift"))
        let editor = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/Recorder/RecorderTypedInput.swift"))
        let metrics = try String(contentsOf: root.appendingPathComponent("VoiceInk/Views/Recorder/MiniRecorderPanel.swift"))
        #expect(!components.contains("RecorderTypingFocusControl("))
        #expect(!editor.contains("Button(\"Unfocus\""))
        #expect(!metrics.contains("typedInputControlWidth"))
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

    @Test @MainActor func nativeEditorKeepsInsertedNewlinesInOneRunAndBlurSealsOnlyOnce() {
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
        // Programmatic/pasted newlines are text, not a Return key commit.
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

    @Test @MainActor func returnCommitsEachRunAtItsOwnSpeechAndRespectsIMEAndMirrors() throws {
        let session = RecordingSession()
        func makeEditor() -> (RecorderTypingTextView, RecorderTypedInput.Coordinator) {
            let input = RecorderTypedInput(
                text: Binding(get: { session.typedInput }, set: { session.updateTypedInput($0) }),
                focusRequest: UUID(), onEndEditing: { session.endTypingRun() })
            let coordinator = input.makeCoordinator()
            let editor = RecorderTypingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
            editor.isRichText = false
            editor.delegate = coordinator
            editor.onEndEditing = input.onEndEditing
            return (editor, coordinator)
        }
        let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 80))
        let (editor, coordinator) = makeEditor()
        // A second monitor's mirrored editor shares the session but is not focused.
        let (mirror, mirrorCoordinator) = makeEditor()
        panel.contentView = editor
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        defer { panel.orderOut(nil); panel.close(); _ = coordinator; _ = mirrorCoordinator }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        func type(_ text: String) { editor.insertText(text, replacementRange: editor.selectedRange()) }

        session.partialTranscript = "spoken before"
        type("first run")
        session.partialTranscript = "spoken before and during typing"
        mirror.string = session.typedInput // SwiftUI mirror update
        try editor.keyDown(with: key(36))
        // The mirror's own end callback (or a later blur) commits nothing twice.
        mirror.string = session.typedInput
        _ = mirror.resignFirstResponder()
        session.endTypingRun()
        #expect(session.liveSelectionReferences.filter(\.isTypedText).count == 1)

        // An input method owns Return while it has marked (composing) text. What
        // AppKit then does with the key depends on the host's input source, so
        // assert only that this run was neither committed nor cleared.
        type("second ")
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try editor.keyDown(with: key(36))
        #expect(session.liveSelectionReferences.filter(\.isTypedText).count == 1)
        #expect(editor.string.hasPrefix("second "))
        editor.unmarkText()
        editor.didChangeText()
        let secondRun = session.typedInput
        #expect(secondRun.hasPrefix("second ") && secondRun == editor.string)
        session.partialTranscript = "spoken before and during typing then after"
        try editor.keyDown(with: key(76, .numericPad))
        #expect(session.typedInput.isEmpty && panel.firstResponder === editor)

        let plain = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "spoken before and during typing then after")
        #expect(plain == "spoken before and during typing\n\nfirst run\n\nthen after\n\n" + secondRun)
        #expect(session.phase == .recording && session.liveRecordingState == .recording)
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
        // The editable run has no timeline position until it is committed.
        #expect(session.liveSelectionReferences.isEmpty)
        #expect(session.liveContextPreviewReferences.isEmpty)
        // Recovery treats the snapshot as the commit: after all speech so far.
        #expect(LiveSelectionReference.interleaving(
            session.liveSelectionReferencesForRecovery, with: session.partialTranscript
        ) == "Speech first and later\n\ntyped words")
        // Enter/blur commits at the speech observed now, never the first keystroke.
        session.endTypingRun()
        session.partialTranscript = "Speech first and later revised again"
        #expect(LiveSelectionReference.interleaving(
            session.liveSelectionReferences, with: session.partialTranscript
        ) == "Speech first and later\n\ntyped words\n\nrevised again")
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
            session.liveSelectionReferencesForRecovery, with: ""
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
        session.endTypingRun()
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
        #expect(session.liveSelectionReferencesForRecovery.count == 1)
        session.updateTypedInput("replacement")
        #expect(session.liveSelectionReferencesForRecovery.count == 2)
        session.endTypingRun()
        #expect(session.liveSelectionReferences.count == 2)
        #expect(session.liveSelectionReferences.first?.isSelection == true)
        let message = LiveSelectionReference.interleaving(session.liveSelectionReferences, with: "")
        #expect(message.hasSuffix("replacement") && !message.contains("remove this"))
    }

    @Test @MainActor func typedRunsLandAtCommitAcrossSpeechHighlightAndCaptureEnd() throws {
        // Ethan, 2026-10-10: prose typed while speaking must enter the timeline
        // where it is committed (Enter, leaving the editor, accepted context, or
        // finishing), not where its first character was typed.
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        func hear(_ text: String, _ offset: TimeInterval) {
            session.recordSpeechActivity(text, at: t.addingTimeInterval(offset))
            session.partialTranscript = text
        }
        hear("Before typing", 0)
        session.updateTypedInput("first", at: t.addingTimeInterval(1))
        hear("Before typing while I type", 2)
        session.updateTypedInput("first run", at: t.addingTimeInterval(3))
        hear("Before typing while I type this sentence", 4)
        provider.endTypingRun() // Enter
        provider.endTypingRun() // a later blur or mirrored end callback
        hear("Before typing while I type this sentence and then more", 5)
        session.updateTypedInput("second run", at: t.addingTimeInterval(6))
        hear("Before typing while I type this sentence and then more words", 7)
        // The highlight's read finishes after one more partial; its gesture-time
        // anchor also places the prose run that it ended.
        session.recordLiveSelection(try #require(LiveSelectionReference("highlighted source"))
            .timed(at: t.addingTimeInterval(6.5)),
            spokenAnchor: "Before typing while I type this sentence and then more")
        session.updateTypedInput("third run", at: t.addingTimeInterval(8))
        session.updateTypedInput("third run", at: t.addingTimeInterval(8.5)) // flush, not an edit

        // HUD: committed runs inline in order; the open run only in its editor.
        #expect(session.liveContextPreviewParts == [
            .speech("Before typing while I type this sentence"), .speech("first run"),
            .speech("and then more"), .speech("second run"),
            .selection("“highlighted source”"), .speech("words")
        ])
        // Recovery while still editable keeps the open run once, after all speech.
        let recovery = LiveSelectionReference.interleaving(session.liveSelectionReferencesForRecovery,
            with: session.partialTranscript, includeTiming: true)
        #expect(recovery.components(separatedBy: "third run").count == 2)
        #expect(recovery.hasSuffix("third run\n\n</typed_text>"))

        // Finishing commits the open run after every final word, including a
        // provider tail that never appeared as a live partial. Idempotent.
        session.endLiveSelectionCapture(at: t.addingTimeInterval(9))
        session.endLiveSelectionCapture(at: t.addingTimeInterval(9))
        let final = "Before typing while I type this sentence and then more words final tail"
        let delivery = session.liveSelectionReferencesForDelivery
        #expect(delivery.filter(\.isTypedText).count == 3)
        let plain = LiveSelectionReference.interleaving(delivery, with: final)
        let order = ["Before typing while I type this sentence", "first run", "and then more",
                     "second run", "<codex_selection", "words", "final tail", "third run"]
        let positions = try order.map { try #require(plain.range(of: $0)).lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(plain.hasSuffix("\n\nthird run"))
        for run in ["first run", "second run", "third run"] {
            #expect(plain.components(separatedBy: run).count == 2)
        }
        let xml = LiveSelectionReference.interleaving(delivery, with: final, includeTiming: true)
        #expect(xml.contains("<typed_text start_at=\"1800000001.000\" end_at=\"1800000003.000\">\n\nfirst run"))
        #expect(xml.contains("<typed_text start_at=\"1800000006.000\" end_at=\"1800000006.000\">\n\nsecond run"))
        #expect(xml.contains("<typed_text start_at=\"1800000008.000\" end_at=\"1800000008.000\">\n\nthird run"))
        #expect(xml.hasSuffix("third run\n\n</typed_text>"))
        // The readable opening and compact archive preview follow the same order.
        let opening = LiveSelectionReference.compactPromptSections(delivery, with: final)
            .filter { $0.tag == "speech" || $0.tag == "typed_text" }.map(\.text)
        #expect(opening == ["Before typing while I type this sentence", "first run", "and then more",
                            "second run", "words", "final tail", "third run"])
    }

    @Test @MainActor func commandReturnFinishFlushesWithoutSealingSoCaptureEndPlacesTheRun() throws {
        let session = RecordingSession()
        let input = RecorderTypedInput(
            text: Binding(get: { session.typedInput }, set: { session.updateTypedInput($0) }),
            focusRequest: UUID(), onEndEditing: { session.endTypingRun() })
        let coordinator = input.makeCoordinator()
        let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 80))
        let editor = RecorderTypingTextView(frame: panel.contentView!.bounds)
        editor.isRichText = false
        editor.delegate = coordinator
        editor.onEndEditing = input.onEndEditing
        var submits = 0
        editor.onSubmit = { submits += 1 }
        panel.contentView = editor
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        defer { panel.orderOut(nil); panel.close() }
        try #require(NSApp.keyWindow === panel && panel.firstResponder === editor)
        session.partialTranscript = "spoken words so far"
        editor.insertText("typed while speaking", replacementRange: NSRange(location: 0, length: 0))
        let submit = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(editor.performKeyEquivalent(with: submit) && submits == 1)
        // The engine's finish path: release this editor, then end capture.
        RecorderTypingTextView.releaseKeyboardBeforeFinish()
        #expect(panel.firstResponder !== editor)
        #expect(session.liveSelectionReferences.isEmpty && session.typedInput == "typed while speaking")
        session.phase = .transcribing
        session.endLiveSelectionCapture()
        #expect(session.typedInput.isEmpty)
        let plain = LiveSelectionReference.interleaving(session.liveSelectionReferencesForDelivery,
            with: "spoken words so far and the final tail")
        #expect(plain == "spoken words so far and the final tail\n\ntyped while speaking")
        _ = coordinator
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
        // An uncommitted run is not in the committed timeline; startup failure
        // must still find and preserve it rather than discarding typed prose.
        #expect(engine.contains("session.liveSelectionReferencesForRecovery.contains(where: \\.isTypedText)"))
        // Finish releases the editor without sealing at the last partial; every
        // release site must end capture, which commits the run after all speech.
        #expect(editor.contains("editor.isReleasingForCaptureEnd = true"))
        let releases = engine.components(separatedBy: "RecorderTypingTextView.releaseKeyboardBeforeFinish()").dropFirst()
        #expect(!releases.isEmpty)
        for following in releases {
            #expect(following.prefix(240).contains("endLiveSelectionCapture()"))
        }
    }
}

// Observe focus requests without displaying a panel or changing system focus.
// The separate scaled-control fixture covers real window event dispatch.
@MainActor private final class TypingFocusProbeWindow: NSWindow {
    var focusRequests = 0
    var refusedFocusAttempts = 0
    private var key = false
    private var responder: NSResponder?
    func dropFocus() { key = false; responder = nil }
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { key }
    override var firstResponder: NSResponder? { responder }
    override func makeKey() {
        focusRequests += 1
        key = focusRequests > refusedFocusAttempts
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard key else { return false }
        self.responder = responder
        return true
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
    var completedText: String?
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? { nil }
    func transcribe(audioURL: URL) async throws -> String {
        transcriptionCalls += 1
        if let completedText { return completedText }
        throw VoiceInkEngineError.transcriptionFailed
    }
    func cancel() {}
}

@MainActor private final class TypingTestDelivery: TranscriptionDelivering {
    var messages: [String] = []
    var routes: [RecordingPasteDestination] = []
    var keys: [AutoSendKey] = []
    func deliver(_ request: TranscriptionDelivery.Request, actions: TranscriptionDelivery.Actions) async {
        if let text = request.text { messages.append(text) }
        routes.append(request.pasteTarget.destination)
        keys.append(request.output.autoSendKey)
    }
}

@MainActor private final class TypingTestEnhancement: AIEnhancementService {
    let result: String
    var inputs: [String] = []
    init(modelContext: ModelContext, result: String) {
        self.result = result
        super.init(modelContext: modelContext)
    }
    override func isConfigured(for configuration: EnhancementRuntimeConfiguration) -> Bool { true }
    override func enhance(_ text: String, configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot? = nil) async throws -> (String, TimeInterval, String?) {
        inputs.append(text)
        return (result, 0, nil)
    }
}
