import Darwin
import Foundation
import Testing
import AppKit
import ApplicationServices
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderResponsivenessTests {
    @Test @MainActor func batchedContextTraversalPreservesBreadthFirstOrderAndDepthLimit() {
        let edges = [0: [1, 2], 1: [2, 3], 2: [0, 4], 3: [5], 4: [6]]
        var observations: [(Int, Bool)] = []
        let nodes = FocusLockService.contextAnchorTraversal(
            root: 0, maximumDepth: 2, identity: { $0 },
            read: { element, readsChildren in
                observations.append((element, readsChildren))
                return ("role-\(element)", readsChildren ? edges[element] ?? [] : [])
            }
        )
        #expect(nodes.map(\.element) == [0, 1, 2, 3, 4])
        #expect(nodes.map(\.role) == ["role-0", "role-1", "role-2", "role-3", "role-4"])
        #expect(observations.map(\.0) == [0, 1, 2, 3, 4])
        #expect(observations.map(\.1) == [true, true, true, false, false])
    }

    @Test @MainActor func batchedContextTraversalKeepsEveryNodeAndHalvesPairedReadCalls() {
        var pairedReadCalls = 0
        let nodes = FocusLockService.contextAnchorTraversal(
            root: 0, identity: { $0 },
            read: { element, _ in
                pairedReadCalls += 1
                return (element.isMultiple(of: 2) ? "AXStaticText" : nil,
                        element == 0 ? Array(1...3_900) + [1, 2] : [0])
            }
        )
        #expect(nodes.map(\.element) == Array(0...3_900))
        #expect(pairedReadCalls == 3_901)
        // Original traversal + role pass performs two reads per distinct node;
        // this counts the production traversal seam, not a live AX benchmark.
        #expect(pairedReadCalls * 2 == 7_802)
    }

    @Test @MainActor func contextAttributePairsPreserveErrorsEmptyValuesAndOneShotFallback() {
        var fallbackCalls = 0
        func fallback() -> (Any?, Any?) {
            fallbackCalls += 1
            return ("individual-value", "individual-title")
        }
        let valid = FocusLockService.contextAnchorAttributePair(
            values: ["", "title must not replace a readable empty value"], fallback: fallback
        )
        #expect((valid.0 as? String ?? valid.1 as? String) == "")
        #expect(fallbackCalls == 0)
        let unreadable = FocusLockService.contextAnchorAttributePair(
            values: [NSNull(), "readable fallback title"], fallback: fallback
        )
        #expect((unreadable.0 as? String ?? unreadable.1 as? String) == "readable fallback title")
        var axError = AXError.attributeUnsupported
        let errorValue = AXValueCreate(.axError, &axError)!
        let perAttributeError = FocusLockService.contextAnchorAttributePair(
            values: [errorValue, NSNull()], fallback: fallback
        )
        #expect(perAttributeError.0 as? String == nil)
        #expect(perAttributeError.1 as? String == nil)
        #expect(fallbackCalls == 0)
        let failed = FocusLockService.contextAnchorAttributePair(values: nil, fallback: fallback)
        #expect(failed.0 as? String == "individual-value")
        #expect(fallbackCalls == 1)
        _ = FocusLockService.contextAnchorAttributePair(values: ["malformed"], fallback: fallback)
        #expect(fallbackCalls == 2)
    }

    @Test func passiveOpenAIWinnerKeepsItsFirstFingerprintAndFinalBoundaryChecks() throws {
        let focus = try source("VoiceInk/Modes/FocusLockService.swift")
        let start = try #require(focus.range(of: "    private func captureAuditedOpenAIComposerAtRecordingStart("))
        let end = try #require(focus.range(of: "    func captureFocusedInput(", range: start.upperBound..<focus.endIndex))
        let body = String(focus[start.lowerBound..<end.lowerBound])
        #expect(body.components(separatedBy: "exactInputIdentity(").count - 1 == 1)
        #expect(body.contains("candidates.append((element, identity))"))
        #expect(body.contains("let identity = candidate.identity"))
        #expect(body.contains("let structureStillMatches = exactStructureMatches("))
        #expect(body.contains("focusedWindowMatches,"))
        #expect(body.contains("currentFocusMatches,"))
        #expect(body.contains("buildStillMatches,"))
    }

    @Test func reservedStartRejectsFurtherPreChordCaptureWithoutChangingItsTarget() throws {
        let manager = try source("VoiceInk/Shortcuts/RecordingShortcutManager.swift")
        let start = try #require(manager.range(of: "            onModifierOnlySequenceProgress:"))
        let end = try #require(manager.range(of: "            onNextTrackKeyDown:", range: start.upperBound..<manager.endIndex))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        let reservationGuard = try #require(body.range(of: "!self.engine.hasPendingRecordingStart else"))
        let capture = try #require(body.range(of: ".stageRecordingStartInputBeforeShortcutCompletion("))
        #expect(reservationGuard.lowerBound < capture.lowerBound)
        #expect(!body.contains("cancelRecordingStartReservation"))
        #expect(!body.contains("preparedRecordingStart ="))
    }

    @Test @MainActor func delayedModifierCaptureCannotRepeatAnExpiredAXScan() throws {
        #expect(FocusLockService.isFreshRecordingStartModifierEvent(10, now: 10))
        #expect(FocusLockService.isFreshRecordingStartModifierEvent(10, now: 10.5))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(10, now: 10.501))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(10, now: 11.163))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(11, now: 10))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(.nan, now: 10))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(.infinity, now: 10))
        #expect(!FocusLockService.isFreshRecordingStartModifierEvent(10, now: .infinity))
        #expect(FocusLockService.isFreshRecordingStartModifierEvent(nil, now: 10))

        let focus = try source("VoiceInk/Modes/FocusLockService.swift")
        let start = try #require(focus.range(of: "    func stageRecordingStartInputBeforeShortcutCompletion("))
        let end = try #require(focus.range(of: "    static func isFreshRecordingStartModifierEvent(", range: start.upperBound..<focus.endIndex))
        let body = String(focus[start.lowerBound..<end.lowerBound])
        let freshGuard = try #require(body.range(of: "guard Self.isFreshRecordingStartModifierEvent(eventTime, now: now)"))
        let capture = try #require(body.range(of: "captureFocusedInputSnapshot()"))
        let clear = try #require(body.range(of: "stagedRecordingStartInput = nil"))
        #expect(freshGuard.lowerBound < capture.lowerBound)
        #expect(freshGuard.lowerBound < clear.lowerBound)
        // Expired partials must not substitute for, or remove, the independent
        // completed-chord identity capture used only by the two Next routes.
        let completed = try #require(focus.range(of: "    func captureRecordingStartInputSnapshot() -> Target? {"))
        let completedEnd = try #require(focus.range(of: "    private func captureAuditedOpenAIComposerAtRecordingStart(", range: completed.upperBound..<focus.endIndex))
        #expect(focus[completed.lowerBound..<completedEnd.lowerBound].contains("captureFocusedInputSnapshot(\n            allowApplicationFallback: true"))
    }

    @Test func captureInteractionHasExplicitInteractivePriorityWithoutPromotingIdlePreparation() {
        #expect(RecorderWorkPriority.captureInteraction.qosClass == .userInteractive)
        #expect(RecorderWorkPriority.idleHardware.qosClass == .userInitiated)
        #expect(RecorderWorkPriority.interactionFlags.contains(.enforceQoS))
    }

    @Test func interactiveStartKeepsHardwareFIFOAndRunsAtRequestedQoS() async {
        // Microphone-free scheduler fixture: a higher-priority Start still follows
        // a preceding hardware operation, and later cleanup cannot overtake it.
        let queue = DispatchQueue(label: "AgentFlow.tests.hardware-priority", qos: RecorderWorkPriority.idleHardware)
        let observations = PriorityObservations()
        queue.async { observations.append("previous-stop") }
        queue.async(qos: RecorderWorkPriority.captureInteraction, flags: RecorderWorkPriority.interactionFlags) {
            observations.append("start", qos: qos_class_self())
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                observations.append("later-maintenance")
                continuation.resume()
            }
        }
        let result = observations.snapshot()
        #expect(result.order == ["previous-stop", "start", "later-maintenance"])
        #expect(result.startQoS == QOS_CLASS_USER_INTERACTIVE)
    }

    @Test func priorityChangeIsBoundedToInitialStartAndResumeWithoutGlobalSchedulingOrFocusMutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Recorder.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "audioSetupQueue.async(qos: RecorderWorkPriority.captureInteraction").count - 1 == 3)
        #expect(!source.contains("setpriority("))
        #expect(!source.contains(".latencyCritical"))
        #expect(!source.contains("NSApplication.shared.activate"))
        let preparation = try #require(source.range(of: "private func schedulePrepareForCurrentDevice(reason: String)"))
        let preparationTail = String(source[preparation.lowerBound...])
        #expect(!preparationTail.contains("qos: RecorderWorkPriority.captureInteraction"))
    }

    @Test func startupPlaceholderDoesNotAppearForAnUncommittedReservation() throws {
        var reservation = RecordingStartReservation()
        var presentation = RecorderStartupPresentation()
        let reservedID = reservation.reserve()
        let id = try #require(reservedID)
        #expect(presentation.requestID == nil)
        #expect(!presentation.shouldShow(sessionCount: 0, assistantVisible: false))
        presentation.commit(id, activationUptime: 100)
        #expect(presentation.requestID == id)
        #expect(presentation.shouldShow(sessionCount: 0, assistantVisible: false))
        // A second commit for the same token cannot reset the measured start.
        presentation.commit(id, activationUptime: 500)
        #expect(presentation.firstDraw(id, uptime: 100.125) == 125)
    }

    @Test func startupPlaceholderClearAndHandoffCannotAffectAnotherRequest() {
        let first = UUID(), second = UUID()
        var presentation = RecorderStartupPresentation()
        presentation.commit(first, activationUptime: 100)
        presentation.clear(second)
        presentation.handoff(second)
        #expect(presentation.requestID == first)
        presentation.handoff(first)
        #expect(presentation.requestID == nil)
        #expect(presentation.isHandingOff(to: first))
        #expect(!presentation.isHandingOff(to: nil))
        #expect(!presentation.shouldShow(sessionCount: 0, assistantVisible: false))
        presentation.commit(second, activationUptime: 200)
        presentation.clear(first)
        presentation.handoff(first)
        #expect(presentation.requestID == second)
        #expect(!presentation.isHandingOff(to: first))
        presentation.clear(second)
        #expect(presentation == RecorderStartupPresentation())
    }

    @Test func startupDrawTimingIsOneShotAndRejectsStaleOrInvalidCallbacks() {
        let first = UUID(), second = UUID()
        var presentation = RecorderStartupPresentation()
        presentation.commit(first, activationUptime: 100)
        #expect(presentation.firstDraw(first, uptime: 99) == nil)
        #expect(presentation.firstDraw(first, uptime: .nan) == nil)
        #expect(presentation.firstDraw(second, uptime: 101) == nil)
        presentation.handoff(first)
        // The draw callback is dispatched after draw(), so it can legitimately
        // arrive just after the synchronous real-card handoff for this same ID.
        #expect(presentation.firstDraw(first, uptime: 100.25) == 250)
        #expect(presentation.firstDraw(first, uptime: 101) == nil)
        presentation.commit(second, activationUptime: 200)
        #expect(presentation.firstDraw(first, uptime: 201) == nil)
        #expect(presentation.firstDraw(second, uptime: .greatestFiniteMagnitude) == Int(Int32.max))
    }

    @Test func startupPlaceholderDoesNotHideOlderCardsOrAssistantContent() {
        var presentation = RecorderStartupPresentation()
        presentation.commit(UUID(), activationUptime: 100)
        #expect(presentation.shouldShow(sessionCount: 0, assistantVisible: false))
        #expect(!presentation.shouldShow(sessionCount: 1, assistantVisible: false))
        #expect(!presentation.shouldShow(sessionCount: 0, assistantVisible: true))
        #expect(!presentation.shouldShow(sessionCount: 2, assistantVisible: true))
    }

    @Test func startupShellYieldsAndRevalidatesBeforeSessionSetup() throws {
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let start = try #require(engine.range(of: "// ── START branch"))
        let end = try #require(engine.range(of: "// MARK: - Start a fresh session", range: start.upperBound..<engine.endIndex))
        let body = String(engine[start.lowerBound..<end.lowerBound])
        let commit = try #require(body.range(of: "guard commitRecordingStartPresentation(startRequestID)"))
        let flush = try #require(body.range(of: "await recorderUIManager?.flushStartupPresentation(requestID: startRequestID)"))
        let recheck = try #require(body.range(of: "guard canCommitRecordingStartReservation(startRequestID)"))
        let consumePrepared = try #require(body.range(of: "self.preparedRecordingStart = nil"))
        #expect(commit.lowerBound < flush.lowerBound)
        #expect(flush.lowerBound < recheck.lowerBound)
        #expect(recheck.lowerBound < consumePrepared.lowerBound)
        #expect(!body.contains("recordingState = .starting"))
        let handoff = try #require(engine.range(of: "startupPresentation.handoff(startRequestID)"))
        let append = try #require(engine.range(of: "sessions.append(session)", range: handoff.upperBound..<engine.endIndex))
        #expect(!engine[handoff.upperBound..<append.lowerBound].contains("await"))
        #expect(engine.contains("record start: cleanup wait completed durationMs="))
    }

    @Test func startupShellClearPathsAndBothLayoutsRemainPresentationOnly() throws {
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        #expect(engine.components(separatedBy: "recordingStartReservation.cancel(").count - 1 == 1)
        let cancel = try #require(engine.range(of: "func cancelRecordingStartReservation(_ requestID: UUID)"))
        let cancelEnd = try #require(engine.range(of: "func canCommitRecordingStartReservation", range: cancel.upperBound..<engine.endIndex))
        let cancelBody = String(engine[cancel.lowerBound..<cancelEnd.lowerBound])
        let clear = try #require(cancelBody.range(of: "startupPresentation.clear(requestID)"))
        let pendingGuard = try #require(cancelBody.range(of: "guard recordingStartReservation.pendingID == requestID"))
        #expect(clear.lowerBound < pendingGuard.lowerBound)
        #expect(engine.contains("startupPresentation = RecorderStartupPresentation()\n        recordingStartReservation.invalidate()"))
        #expect(engine.contains("startupPresentation.clear(session.startID)"))
        let stacks = try source("VoiceInk/Views/Recorder/RecorderStackView.swift")
        #expect(stacks.components(separatedBy: "RecorderStartupPlaceholder(requestID: requestID)").count - 1 == 2)
        #expect(stacks.components(separatedBy: "engine?.recordStartupPlaceholderDraw(requestID: id, uptime: uptime)").count - 1 == 2)
        #expect(stacks.components(separatedBy: ".accessibilityHidden(true)").count - 1 == 2)
        #expect(stacks.contains("NSGraphicsContext.current?.isDrawingToScreen == true"))
        let ui = try source("VoiceInk/Transcription/Engine/RecorderUIManager.swift")
        #expect(ui.contains("guard showsAssistant || baseSession != nil || showsStartup else { return nil }"))
        #expect(ui.contains("if engine.activeRecordingSession == nil {\n                guard let id = reservedStartRequestID ?? engine.reserveRecordingStart()"))
        let notch = try source("VoiceInk/Views/Recorder/NotchRecorderView.swift")
        let starting = try #require(notch.range(of: "        case .starting:\n"))
        let recording = try #require(notch.range(of: "        case .recording, .paused:", range: starting.upperBound..<notch.endIndex))
        #expect(notch[starting.upperBound..<recording.lowerBound].contains("return .active"))
    }

    @Test func startupFrameFlushUsesOnlyOwnedVisibleWindowsWithoutFocusOrSleep() throws {
        let ui = try source("VoiceInk/Transcription/Engine/RecorderUIManager.swift")
        let protocolStart = try #require(ui.range(of: "protocol RecorderPanelPresenting: AnyObject {"))
        let protocolEnd = try #require(ui.range(of: "\n}", range: protocolStart.upperBound..<ui.endIndex))
        #expect(ui[protocolStart.lowerBound..<protocolEnd.lowerBound].contains("func flushStartupPresentation(requestID: UUID) async"))
        let start = try #require(ui.range(of: "func flushStartupPresentation(requestID: UUID) async {"))
        let end = try #require(ui.range(of: "func toggleRecorderPanel(", range: start.upperBound..<ui.endIndex))
        let flush = String(ui[start.lowerBound..<end.lowerBound])
        #expect(flush.contains("DispatchQueue.main.async"))
        #expect(flush.contains("startupPresentation.requestID == requestID"))
        #expect(flush.contains("self.isRecorderPanelVisible"))
        #expect(!flush.contains("Task.sleep"))
        #expect(!flush.contains("makeKey"))
        #expect(!flush.contains("activate("))
        for file in ["MiniWindowManager.swift", "NotchWindowManager.swift"] {
            let manager = try source("VoiceInk/Views/Recorder/" + file)
            let display = try #require(manager.range(of: "func displayIfNeeded()"))
            let next = try #require(manager.range(of: "private func refreshScale()", range: display.upperBound..<manager.endIndex))
            let body = String(manager[display.lowerBound..<next.lowerBound])
            #expect(body.contains("where entry.panel.isVisible"))
            #expect(body.contains("entry.host.layoutSubtreeIfNeeded()"))
            #expect(!body.contains("orderFront"))
        }
    }

    @MainActor
    @Test func startupShellRendersNeutralBlackAndNeverTakesPointerInput() throws {
        for height in [40.0, 50.0] {
            let view = RecorderStartupPlaceholderView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
            var acknowledgements = 0
            view.configure(requestID: UUID()) { _, _ in acknowledgements += 1 }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let black = try #require(bitmap.colorAt(x: 20, y: Int(height / 2))?.usingColorSpace(.deviceRGB))
            #expect(black.alphaComponent > 0.99)
            #expect(black.redComponent < 0.01 && black.greenComponent < 0.01 && black.blueComponent < 0.01)
            let dots = try #require(bitmap.colorAt(x: 140, y: Int(height / 2))?.usingColorSpace(.deviceRGB))
            #expect(dots.redComponent > 0.3 && dots.redComponent < 0.6)
            #expect(abs(dots.redComponent - dots.greenComponent) < 0.01)
            #expect(abs(dots.greenComponent - dots.blueComponent) < 0.01)
            #expect(view.hitTest(NSPoint(x: 140, y: height / 2)) == nil)
            #expect(view.window == nil)
            // An offscreen cache is useful pixel evidence, never a live frame.
            #expect(acknowledgements == 0)
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

private final class PriorityObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var startQoS: qos_class_t?

    func append(_ name: String, qos: qos_class_t? = nil) {
        lock.lock()
        defer { lock.unlock() }
        order.append(name)
        if let qos { startQoS = qos }
    }

    func snapshot() -> (order: [String], startQoS: qos_class_t?) {
        lock.lock()
        defer { lock.unlock() }
        return (order, startQoS)
    }
}
