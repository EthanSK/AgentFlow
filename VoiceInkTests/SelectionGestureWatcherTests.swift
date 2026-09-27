import AppKit
import Foundation
import Testing
@testable import VoiceInkPlusPlus

/// Build 349: highlights made just before a recording's capture attaches (while
/// reading before pressing start, or during microphone start-up) were missed
/// because each recording owned its own mouse monitor from its start onward.
struct SelectionGestureWatcherTests {
    @Test @MainActor func delayedMouseEdgesKeepTheirEventPositions() throws {
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 123, y: 456), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
            location: NSPoint(x: 323, y: 456), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 0.5,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let start = SelectionGestureWatcher.edge(from: down, primaryScreenTop: 900)
        let end = SelectionGestureWatcher.edge(from: up, primaryScreenTop: 900)
        #expect(end.location.x - start.location.x == 200)
        #expect(LiveSelectionCapture.isSelectionGesture(from: start.location, to: end.location, clickCount: 1))
        #expect(start.occurredAt < end.occurredAt)
        let shifted = SelectionGestureWatcher.edge(from: down, primaryScreenTop: 1200)
        #expect(shifted.location.y - start.location.y == 300)
    }
    @Test func mouseRecipientWinsOverDelayedForegroundActivation() {
        #expect(SelectionGestureWatcher.sourcePID(targetPID: 42, frontmostPID: 7) == 42)
        #expect(SelectionGestureWatcher.sourcePID(targetPID: 0, frontmostPID: 7) == 7)
        #expect(SelectionGestureWatcher.sourcePID(targetPID: nil, frontmostPID: nil) == nil)
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
        let capture = try #require(engine.range(of: "session.beginLiveSelectionCapture()"))
        let audio = try #require(engine.range(of: "session.recordingInputDevice = try await self.recorder.startRecording("))
        let focus = try #require(engine.range(of: "session.typingFocus.requestInitialFocus()", range: capture.upperBound..<engine.endIndex))
        #expect(capture.lowerBound < audio.lowerBound && capture.lowerBound < focus.lowerBound)
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
                .scopedToCodexThread(id: "abc", title: "Source chat"))
        #expect(session.liveSelectionReferences.count == 2)
        let output = LiveSelectionReference.interleaving(session.liveSelectionReferences,
            with: "spoken before and after", includeTiming: true)
        #expect(output.contains("first highlight") && !output.contains("must not overwrite text"))
        #expect(output.contains("task_id=\"abc\"") && output.contains("captured_at=\"1970-01-01T00:16:40.000Z\""))
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
