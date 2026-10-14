import AppKit
import Foundation
import Testing
@testable import VoiceInkPlusPlus

/// Build 349: highlights made just before a recording's capture attaches (while
/// reading before pressing start, or during microphone start-up) were missed
/// because each recording owned its own mouse monitor from its start onward.
struct SelectionGestureWatcherTests {
    @Test @MainActor func shiftClickRetainsDownModifierWithoutInventingADrag() {
        let watcher = SelectionGestureWatcher()
        let now = Date()
        var down = edge(.leftMouseDown, 100, at: now)
        down.extendsSelection = true
        watcher.handle(down, frontmostPID: 7)
        // Shift can be released before mouse-up; its selection intent is frozen.
        watcher.handle(edge(.leftMouseUp, 100, at: now.addingTimeInterval(0.1)), frontmostPID: 7)
        #expect(watcher.lastSelectionGesture?.extendsSelection == true)
        #expect(watcher.lastSelectionGesture?.start == watcher.lastSelectionGesture?.end)
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: .zero, endPoint: .zero,
            clickCount: 1, sourcePID: 7, ownPID: 42, extendsSelection: true) == "read")
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: .zero, endPoint: .zero,
            clickCount: 1, sourcePID: 42, ownPID: 42, extendsSelection: true) == "no-source")
        #expect(!LiveSelectionCapture.usesPointerGeometry(from: .zero, to: .zero,
            clickCount: 1, extendsSelection: true))
        #expect(LiveSelectionCapture.usesPointerGeometry(from: .zero, to: NSPoint(x: 20, y: 0),
            clickCount: 1, extendsSelection: true))
    }

    @Test @MainActor func keyboardSelectionWaitsForReleaseAndRejectsTypingAndSourceChanges() {
        var sequence = SelectionGestureWatcher.KeyboardSequence()
        let now = Date(timeIntervalSince1970: 1000)
        #expect(sequence.handle(type: .keyDown, keyCode: 0, modifiers: .command, at: now, sourcePID: 7) == nil)
        let all = sequence.handle(type: .keyUp, keyCode: 0, modifiers: [],
            at: now.addingTimeInterval(0.1), sourcePID: 7)
        #expect(all?.inputKind == .selectAll && all?.startedAt == now && all?.inputDirection == nil)
        for flags in [NSEvent.ModifierFlags.shift, [.shift, .option], [.shift, .command]] {
            #expect(sequence.handle(type: .keyDown, keyCode: 124, modifiers: flags, at: now, sourcePID: 7) == nil)
            #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: [],
                at: now.addingTimeInterval(0.2), sourcePID: 7)?.inputKind == .keyboard)
        }
        _ = sequence.handle(type: .keyDown, keyCode: 124, modifiers: .shift, at: now, sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: [],
            at: now.addingTimeInterval(0.2), sourcePID: 8) == nil)
        _ = sequence.handle(type: .keyDown, keyCode: 124, modifiers: .shift, at: now, sourcePID: 7)
        _ = sequence.handle(type: .keyDown, keyCode: 2, modifiers: [], at: now, sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: [], at: now, sourcePID: 7) == nil)
        #expect(SelectionGestureWatcher.KeyboardSequence.selectionKind(keyCode: 0, modifiers: [.command, .shift]) == nil)
        #expect(SelectionGestureWatcher.KeyboardSequence.selectionKind(keyCode: 124, modifiers: [.control, .shift]) == nil)
        #expect(SelectionGestureWatcher.KeyboardSequence.selectionKind(keyCode: 124, modifiers: [.command, .option, .shift]) == nil)
        #expect(SelectionGestureWatcher.KeyboardSequence.direction(keyCode: 124) == "right")
        #expect(SelectionGestureWatcher.KeyboardSequence.direction(keyCode: 126) == "up")
    }

    @Test @MainActor func keyboardRepeatsUseOneBoundedGestureAndNeverBorrowStaleIntent() {
        var sequence = SelectionGestureWatcher.KeyboardSequence()
        let now = Date(timeIntervalSince1970: 1000)
        _ = sequence.handle(type: .keyDown, keyCode: 124, modifiers: .shift, at: now, sourcePID: 7)
        _ = sequence.handle(type: .keyDown, keyCode: 124, modifiers: .shift,
            at: now.addingTimeInterval(0.5), sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: [],
            at: now.addingTimeInterval(1), sourcePID: 7)?.startedAt == now)
        #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: [], at: now, sourcePID: 7) == nil)
        _ = sequence.handle(type: .keyDown, keyCode: 0, modifiers: .command, at: now, sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 0, modifiers: [],
            at: now.addingTimeInterval(11), sourcePID: 7) == nil)
    }

    @Test @MainActor func shiftNavigationCommitsOnlyWhenTheSelectionModifierIsReleased() {
        var sequence = SelectionGestureWatcher.KeyboardSequence()
        let now = Date(timeIntervalSince1970: 1000)
        _ = sequence.handle(type: .keyDown, keyCode: 124, modifiers: .shift, at: now, sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 124, modifiers: .shift,
            at: now.addingTimeInterval(0.1), sourcePID: 7) == nil)
        _ = sequence.handle(type: .keyDown, keyCode: 125, modifiers: .shift,
            at: now.addingTimeInterval(0.2), sourcePID: 7)
        #expect(sequence.handle(type: .keyUp, keyCode: 125, modifiers: .shift,
            at: now.addingTimeInterval(0.3), sourcePID: 7) == nil)
        let completed = sequence.handle(type: .flagsChanged, keyCode: 56, modifiers: [],
            at: now.addingTimeInterval(0.4), sourcePID: 7)
        #expect(completed?.startedAt == now && completed?.inputDirection == "down")
        #expect(completed?.endedAt == now.addingTimeInterval(0.4))
        #expect(sequence.handle(type: .flagsChanged, keyCode: 56, modifiers: [], at: now, sourcePID: 7) == nil)
    }

    @Test @MainActor func freshAndPriorGesturesRetainBothCallbackLagsAndClickUnits() throws {
        let watcher = SelectionGestureWatcher()
        let now = Date()
        var down = edge(.leftMouseDown, 10, at: now)
        down.callbackLagMilliseconds = 60
        var up = edge(.leftMouseUp, 80, clicks: 3, at: now.addingTimeInterval(0.4))
        up.callbackLagMilliseconds = 2
        watcher.handle(down, frontmostPID: 7)
        #expect(watcher.pendingMouseDown?.callbackLagMilliseconds == 60)
        watcher.handle(up, frontmostPID: 7)
        #expect(watcher.lastSelectionGesture?.callbackLagMilliseconds == 60)
        #expect(watcher.lastSelectionGesture?.clickCount == 3)
        #expect(SelectionGestureWatcher.combinedCallbackLag(nil, 2) == nil)
        #expect(SelectionGestureWatcher.combinedCallbackLag(2, nil) == nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let capture = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/LiveSelectionCapture.swift"), encoding: .utf8)
        #expect(capture.contains("clickCount: gesture.clickCount"))
        #expect(capture.contains("callbackLagMilliseconds: gesture.callbackLagMilliseconds"))
        #expect(capture.contains("mouseDownCallbackLag = down.callbackLagMilliseconds"))
        #expect(capture.contains("checksDragSpan: bundleID == \"com.openai.codex\""))
    }

    @Test func selectionNoticesRetainDecisionsWithoutTextOrCoordinates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/LiveSelectionTextReader.swift"), encoding: .utf8)
        let start = try #require(reader.range(of: "enum LiveSelectionDiagnostics {"))
        let notices = String(reader[start.lowerBound...])
        #expect(notices.contains("logger.notice("))
        #expect(!notices.contains("logger.info("))
        #expect(notices.contains("preventedWidening="))
        #expect(notices.contains("overextended="))
        #expect(!notices.contains("candidate.text"))
        #expect(!notices.contains("mouseDown.x"))
        #expect(!notices.contains("mouseUp.y"))
    }
    @Test @MainActor func gestureDropReasonsAndCallbackLagAreTextFreeAndBounded() {
        let start = NSPoint(x: 100, y: 100)
        let end = NSPoint(x: 200, y: 100)
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: nil, endPoint: end,
            clickCount: 1, sourcePID: 7, ownPID: 42) == "no-mouse-down")
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: start, endPoint: start,
            clickCount: 1, sourcePID: 7, ownPID: 42) == "not-selection-shaped")
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: start, endPoint: end,
            clickCount: 1, sourcePID: 42, ownPID: 42) == "no-source")
        #expect(LiveSelectionCapture.selectionGestureDisposition(startPoint: start, endPoint: end,
            clickCount: 1, sourcePID: 7, ownPID: 42) == "read")
        let now = Date(timeIntervalSince1970: 1000)
        #expect(SelectionGestureWatcher.callbackLagMilliseconds(occurredAt: now.addingTimeInterval(-0.125), now: now) == 125)
        #expect(SelectionGestureWatcher.callbackLagMilliseconds(occurredAt: now.addingTimeInterval(1), now: now) == 0)
        #expect(SelectionGestureWatcher.callbackLagMilliseconds(occurredAt: now.addingTimeInterval(-100), now: now) == 60_000)
    }

    @Test @MainActor func mouseEdgesUseCallbackSnapshotNotReconstructedCGEvent() throws {
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 123, y: 456), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
            location: NSPoint(x: 323, y: 456), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 0.5,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let start = SelectionGestureWatcher.edge(from: down, mouseLocation: NSPoint(x: -800, y: 100))
        let end = SelectionGestureWatcher.edge(from: up, mouseLocation: NSPoint(x: -600, y: 100))
        #expect(end.location.x - start.location.x == 200)
        #expect(LiveSelectionCapture.isSelectionGesture(from: start.location, to: end.location, clickCount: 1))
        #expect(start.occurredAt < end.occurredAt)
        #expect(start.location == NSPoint(x: -800, y: 100))
        #expect(end.location == NSPoint(x: -600, y: 100))
        // Event-local coordinates deliberately differ from the real global
        // snapshot; a fabricated NSEvent.cgEvent must not replace that snapshot.
        #expect(start.location != down.locationInWindow)
    }
    @Test func mouseSourceUsesForegroundAndNeverTheRecorder() {
        #expect(SelectionGestureWatcher.sourcePID(frontmostPID: 7, ownPID: 42) == 7)
        #expect(SelectionGestureWatcher.sourcePID(frontmostPID: 42, ownPID: 42) == nil)
        #expect(SelectionGestureWatcher.sourcePID(frontmostPID: 0, ownPID: 42) == nil)
        #expect(SelectionGestureWatcher.sourcePID(frontmostPID: nil, ownPID: 42) == nil)
    }

    @Test func watcherDoesNotTrustReconstructedEventRouting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/SelectionGestureWatcher.swift"), encoding: .utf8)
        #expect(!source.contains("event.cgEvent"))
        #expect(!source.contains("eventTargetUnixProcessID"))
        #expect(source.contains("mouseLocation: NSEvent.mouseLocation"))
        #expect(source.contains("MainActor.assumeIsolated"))
    }

    @Test @MainActor func startupHighlightsAreRetainedAtTheGestureSpeechAnchor() throws {
        let session = RecordingSession()
        session.liveRecordingState = .starting
        let first = try #require(LiveSelectionReference("during microphone startup"))
        session.recordLiveSelection(first, spokenAnchor: "")
        session.liveRecordingState = .recording
        session.partialTranscript = "words arriving while AX reads"
        let second = try #require(LiveSelectionReference("first new chat highlight"))
        session.recordLiveSelection(second, spokenAnchor: "words")
        #expect(session.liveSelectionReferences == [first.anchored(after: ""), second.anchored(after: "words")])
        session.shouldCancel = true
        session.recordLiveSelection(first)
        #expect(session.liveSelectionReferences.count == 2)
    }

    @Test func selectionAttachesBeforeAudioHandshakeAndTypingFocus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/VoiceInkEngine.swift"), encoding: .utf8)
        let capture = try #require(engine.range(of: "session.beginLiveSelectionCapture(activationTime: activationTime)"))
        let audio = try #require(engine.range(of: "session.recordingInputDevice = try await self.recorder.startRecording("))
        let focus = try #require(engine.range(of: "session.typingFocus.requestInitialFocus()", range: capture.upperBound..<engine.endIndex))
        #expect(capture.lowerBound < audio.lowerBound && capture.lowerBound < focus.lowerBound)
        #expect(focus.lowerBound < audio.lowerBound)
    }

    @Test func optionalCodexLabelsNeverScanLogsOnTheMainActor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/CodexConversationContext.swift"), encoding: .utf8)
        let capture = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/LiveSelectionCapture.swift"), encoding: .utf8)
        #expect(reader.contains("private actor CodexSelectionLogWorker"))
        #expect(reader.contains("nonisolated static func readSelectionThreadIDs"))
        #expect(capture.contains("await CodexConversationContextReader.selectionThreadIDs"))
        #expect(!capture.contains("visibleSelectionThreadIDsIfFrontmost("))
        #expect(capture.contains("hasGesture: false"))
        let commit = try #require(capture.range(of: "self.onCapture(captured.timed"))
        let labels = try #require(capture.range(of: "let threadsBefore = await beforeLabels"))
        #expect(commit.lowerBound < labels.lowerBound)
    }

    @Test @MainActor func optionalLabelsCannotLoseOrReorderCapturedWords() throws {
        let session = RecordingSession()
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let first = try #require(LiveSelectionReference("first highlight"))
            .timed(at: date).identifiedForCapture(id)
        session.recordLiveSelection(first, spokenAnchor: "spoken before")
        let second = try #require(LiveSelectionReference("next highlight"))
        session.recordLiveSelection(second, spokenAnchor: "spoken before and after")
        session.updateLiveSelectionLabels(captureID: id,
            reference: try #require(LiveSelectionReference("must not overwrite text"))
                .scopedToCodexThread(id: "11111111-2222-3333-4444-555555555555", title: "Source chat"))
        #expect(session.liveSelectionReferences.count == 2)
        let output = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "spoken before and after", includeTiming: true)
        #expect(output.contains("first highlight") && !output.contains("must not overwrite text"))
        #expect(output.contains("task_id=\"11111111-2222-3333-4444-555555555555\"") && output.contains("captured_at=\"1000.000\""))
        #expect(session.liveSelectionReferences[1] == second.anchored(after: "spoken before and after"))
    }
    private func edge(_ type: NSEvent.EventType, _ x: CGFloat, clicks: Int = 1, at time: Date)
        -> SelectionGestureWatcher.MouseEdge {
        SelectionGestureWatcher.MouseEdge(
            type: type, clickCount: clicks, location: NSPoint(x: x, y: 100), occurredAt: time
        )
    }

    @Test @MainActor func idleWatcherRemembersOnlyTheLatestSelectionGesture() {
        let watcher = SelectionGestureWatcher()
        let t0 = Date(timeIntervalSince1970: 1_000)
        watcher.handle(edge(.leftMouseDown, 10, at: t0), frontmostPID: 42)
        #expect(watcher.pendingMouseDown == SelectionGestureWatcher.MouseDown(
            location: NSPoint(x: 10, y: 100), occurredAt: t0
        ))
        watcher.handle(edge(.leftMouseUp, 80, at: t0.addingTimeInterval(0.4)), frontmostPID: 42)
        #expect(watcher.pendingMouseDown == nil)
        #expect(watcher.lastSelectionGesture == SelectionGestureWatcher.CompletedGesture(
            start: NSPoint(x: 10, y: 100), end: NSPoint(x: 80, y: 100),
            startedAt: t0, endedAt: t0.addingTimeInterval(0.4), processIdentifier: 42
        ))
        // A plain click is not a selection and must not replace the drag.
        watcher.handle(edge(.leftMouseDown, 300, at: t0.addingTimeInterval(2)), frontmostPID: 42)
        watcher.handle(edge(.leftMouseUp, 300, at: t0.addingTimeInterval(2.1)), frontmostPID: 42)
        #expect(watcher.lastSelectionGesture?.start == NSPoint(x: 10, y: 100))
        // A double-click word selection counts, like the live capture rule.
        watcher.handle(edge(.leftMouseDown, 400, clicks: 2, at: t0.addingTimeInterval(3)), frontmostPID: 7)
        watcher.handle(edge(.leftMouseUp, 400, clicks: 2, at: t0.addingTimeInterval(3.1)), frontmostPID: 7)
        #expect(watcher.lastSelectionGesture?.processIdentifier == 7)
    }

    @Test @MainActor func idleWatcherNeverRemembersItsOwnHUDAsSelectionSource() {
        let watcher = SelectionGestureWatcher()
        let now = Date()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        watcher.handle(edge(.leftMouseDown, 10, at: now), frontmostPID: ownPID)
        watcher.handle(edge(.leftMouseUp, 80, at: now), frontmostPID: ownPID)
        #expect(watcher.pendingMouseDown == nil)
        #expect(watcher.lastSelectionGesture == nil)
    }

    @Test func priorHighlightMustBeRecentSameAppAndBeforeCapture() {
        let ended = Date(timeIntervalSince1970: 2_000)
        let gesture = SelectionGestureWatcher.CompletedGesture(
            start: .zero, end: NSPoint(x: 50, y: 0), startedAt: ended.addingTimeInterval(-0.5),
            endedAt: ended, processIdentifier: 9
        )
        let start = ended.addingTimeInterval(20)
        #expect(SelectionGestureWatcher.isEligiblePriorGesture(
            gesture, now: start, captureStartedAt: start, frontmostPID: 9))
        // Another app is frontmost now: the reader cannot prove a stable source.
        #expect(!SelectionGestureWatcher.isEligiblePriorGesture(
            gesture, now: start, captureStartedAt: start, frontmostPID: 10))
        #expect(!SelectionGestureWatcher.isEligiblePriorGesture(
            gesture, now: start, captureStartedAt: start, frontmostPID: nil))
        // Too old to still be the reason for this dictation.
        let late = ended.addingTimeInterval(SelectionGestureWatcher.priorSelectionMaxAge + 1)
        #expect(!SelectionGestureWatcher.isEligiblePriorGesture(
            gesture, now: late, captureStartedAt: late, frontmostPID: 9))
        // Finished after capture attached: already read live, never twice.
        #expect(!SelectionGestureWatcher.isEligiblePriorGesture(
            gesture, now: start, captureStartedAt: ended.addingTimeInterval(-1), frontmostPID: 9))
    }

    @Test func onlyARecentDragInProgressIsAdopted() {
        let now = Date(timeIntervalSince1970: 3_000)
        let recent = SelectionGestureWatcher.MouseDown(location: .zero, occurredAt: now.addingTimeInterval(-0.3))
        let stale = SelectionGestureWatcher.MouseDown(
            location: .zero,
            occurredAt: now.addingTimeInterval(-SelectionGestureWatcher.pendingMouseDownMaxAge - 1)
        )
        #expect(SelectionGestureWatcher.adoptablePendingDown(recent, now: now) == recent)
        #expect(SelectionGestureWatcher.adoptablePendingDown(stale, now: now) == nil)
        #expect(SelectionGestureWatcher.adoptablePendingDown(nil, now: now) == nil)
    }

    @Test @MainActor func priorHighlightIsAnchoredBeforeSpeech() throws {
        let session = RecordingSession()
        let reference = try #require(LiveSelectionReference("highlighted before starting"))
        session.partialTranscript = "words that arrived during the read"
        session.recordLiveSelection(reference, precedesSpeech: true)
        #expect(session.liveSelectionReferences == [reference.anchored(after: "")])
    }

    @Test func watcherStaysTextFreeAndIsTheOnlyMouseMonitor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let watcher = try source("VoiceInk/Services/SelectionGestureWatcher.swift")
        for forbidden in [
            "LiveSelectionTextReader", "AXUIElement", "NSPasteboard", "BrowserScript",
            "ChromeSelectionContextReader", "VSCodeSelectionBridge", "Timer", "asyncAfter"
        ] {
            #expect(!watcher.contains(forbidden), "idle watcher must not use \(forbidden)")
        }
        #expect(watcher.components(separatedBy: "addGlobalMonitorForEvents").count == 2)
        #expect(watcher.contains("guard monitor == nil else { return }"))
        #expect(watcher.contains("weak var listener: LiveSelectionCapture?"))
        let capture = try source("VoiceInk/Services/LiveSelectionCapture.swift")
        #expect(!capture.contains("addGlobalMonitorForEvents"))
        #expect(capture.contains("SelectionGestureWatcher.shared.listener = nil"))
        let delegate = try source("VoiceInk/AppDelegate.swift")
        #expect(delegate.contains("SelectionGestureWatcher.shared.start()"))
    }
}
