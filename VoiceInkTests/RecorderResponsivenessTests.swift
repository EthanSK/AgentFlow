// Exercise real hosted recorder layouts without microphone capture or shortcuts.
import Darwin
import Foundation
import Testing
import AppKit
import ApplicationServices
import SwiftUI
import SwiftData
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderPanelDismissalTests {
    @Test func reservedStartsCancelTheOldFadeBeforeYieldingOrOpeningAudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Transcription/Engine/RecorderUIManager.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    func flushStartupPresentation(requestID: UUID) async {"))
        let end = try #require(source.range(of: "    func toggleRecorderPanel(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let identity = try #require(body.range(of: "engine.startupPresentation.requestID == requestID"))
        let cancel = try #require(body.range(of: "showRecorderPanel(reason: \"reserved recording restart during completion fade\")"))
        let yield = try #require(body.range(of: "await withCheckedContinuation"))
        #expect(identity.lowerBound < cancel.lowerBound && cancel.lowerBound < yield.lowerBound)
        #expect(body.contains("engine.cancelRecordingStartReservation(requestID)"))
        #expect(!body.contains("Task.sleep"))
    }

    @Test @MainActor func completionFadeDoesNotWaitOrHideANewerPresentation() {
        for panel in [MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60)),
                      NotchRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60))] as [NSPanel] {
            var completions: [@MainActor () -> Void] = []
            var finished = 0
            let fade = RecorderPanelDismissal { panels, duration, completion in
                #expect(panels.count == 1)
                #expect(duration == 0.22)
                completions.append(completion)
            }
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.close() }
            fade.hide(panels: [panel], animated: true, reducedMotion: false) { finished += 1 }
            #expect(fade.isFading && panel.isVisible && panel.ignoresMouseEvents)
            #expect(finished == 0)
            fade.hide(panels: [panel], animated: true, reducedMotion: false)
            #expect(completions.count == 1)
            fade.cancel(panels: [panel])
            completions[0]()
            #expect(panel.isVisible && panel.alphaValue == 1 && !panel.ignoresMouseEvents)
            #expect(!fade.isFading && finished == 0)
            fade.hide(panels: [panel], animated: true, reducedMotion: false) { finished += 1 }
            completions[1]()
            #expect(!panel.isVisible && !fade.isFading && finished == 1)
            #expect(panel.alphaValue == 1 && !panel.ignoresMouseEvents)
        }
    }

    @Test @MainActor func resetAndReducedMotionHideImmediatelyAndPreserveMouseState() {
        var animateCalls = 0
        var finished = 0
        let fade = RecorderPanelDismissal { _, _, _ in animateCalls += 1 }
        let panels = (0..<2).map { _ in NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false) }
        defer { panels.forEach { $0.orderOut(nil); $0.close() } }
        panels[1].ignoresMouseEvents = true
        panels.forEach { $0.orderFrontRegardless() }
        fade.hide(panels: panels, animated: true, reducedMotion: true) { finished += 1 }
        #expect(animateCalls == 0 && finished == 1 && panels.allSatisfy { !$0.isVisible })
        panels.forEach { $0.orderFrontRegardless() }
        fade.hide(panels: panels, animated: true, reducedMotion: false)
        fade.hide(panels: panels, animated: false) { finished += 1 }
        #expect(animateCalls == 1 && finished == 2 && !fade.isFading)
        #expect(panels.allSatisfy { !$0.isVisible && $0.alphaValue == 1 })
        #expect(!panels[0].ignoresMouseEvents && panels[1].ignoresMouseEvents)
    }

    @Test @MainActor func nativeFadeInterpolatesBothLayoutsAndReleasesEveryMirror() async throws {
        let panels: [NSPanel] = [
            MiniRecorderPanel(contentRect: NSRect(x: 60, y: 60, width: 300, height: 60)),
            NotchRecorderPanel(contentRect: NSRect(x: 60, y: 140, width: 300, height: 60))
        ]
        defer { panels.forEach { $0.orderOut(nil); $0.close() } }
        for panel in panels {
            panel.contentView = NSHostingView(rootView: Text("Transcribing…").foregroundStyle(.white)
                .frame(width: 300, height: 60).background(.black))
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
        }
        let fade = RecorderPanelDismissal()
        var finished = false
        fade.hide(panels: panels, animated: true, reducedMotion: false) { finished = true }
        #expect(!finished && fade.isFading)
        let sampleStarted = ContinuousClock.now
        let interpolated = try await observeNativeAnimation {
            panels.allSatisfy { $0.isVisible && $0.alphaValue > 0 && $0.alphaValue < 1 }
        }
        #expect(interpolated,
                "Native fade sample after \(sampleStarted.duration(to: .now)): \(panels.map { ($0.isVisible, $0.alphaValue) })")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished && !fade.isFading && panels.allSatisfy { !$0.isVisible })
        #expect(panels.allSatisfy { $0.alphaValue == 1 && !$0.ignoresMouseEvents })
    }

    @Test @MainActor func nativeCancelPreemptsAnObservedFadeWithoutHidingEitherLayout() async throws {
        let panels: [NSPanel] = [
            MiniRecorderPanel(contentRect: NSRect(x: 60, y: 60, width: 300, height: 60)),
            NotchRecorderPanel(contentRect: NSRect(x: 60, y: 140, width: 300, height: 60))
        ]
        defer { panels.forEach { $0.orderOut(nil); $0.close() } }
        for panel in panels {
            panel.contentView = NSHostingView(rootView: Color.black.frame(width: 300, height: 60))
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
        }
        // Observe cancellation on its own real animation. The hosted fixture sometimes
        // missed its second animation after immediate reordering; its exact cause was
        // not measured, so it did not prove that cancellation was actually exercised.
        // The original intermediate-alpha, full completion and reset checks stay above.
        // — GPT-6.1 Sol
        let fade = RecorderPanelDismissal()
        var finished = false
        fade.hide(panels: panels, animated: true, reducedMotion: false) { finished = true }
        let cancellationStarted = ContinuousClock.now
        let cancellationInterpolated = try await observeNativeAnimation {
            panels.allSatisfy { $0.isVisible && $0.alphaValue > 0 && $0.alphaValue < 1 }
        }
        #expect(cancellationInterpolated,
                "Cancellation fade sample after \(cancellationStarted.duration(to: .now)): \(panels.map { ($0.isVisible, $0.alphaValue) })")
        fade.cancel(panels: panels)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panels.allSatisfy { $0.isVisible && $0.alphaValue == 1 && !$0.ignoresMouseEvents })
        #expect(!finished && !fade.isFading)
    }

    @Test(arguments: RecorderPanelStyle.allCases, [false, true])
    @MainActor func finalSessionRetirementKeepsVisibleContentForTheCompletionFade(
        style: RecorderPanelStyle, reducedMotion: Bool
    ) async throws {
        let schema = Schema([Transcription.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let models = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let whisper = WhisperModelManager(modelsDirectory: models)
        let transcriptionModels = TranscriptionModelManager(whisperModelManager: whisper,
            fluidAudioModelManager: FluidAudioModelManager())
        let engine = VoiceInkEngine(modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: transcriptionModels)
        let session = RecordingSession(phase: .transcribing)
        session.liveRecordingState = .transcribing
        engine.sessions = [session]
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let destroy: () -> Void
        switch style {
        case .mini:
            let manager = MiniWindowManager(engine: engine, recorder: engine.recorder,
                assistantSession: engine.assistantSession, onRecordButtonTapped: {}, onCloseTapped: {},
                onCancelTapped: {}, onAssistantFollowUp: { _ in }, onCancelSession: { _ in })
            #expect(manager.show().isComplete)
            destroy = { manager.destroyWindow() }
        case .notch:
            let manager = NotchWindowManager(engine: engine, recorder: engine.recorder,
                assistantSession: engine.assistantSession, onRecordButtonTapped: {}, onCloseTapped: {},
                onCancelTapped: {}, onAssistantFollowUp: { _ in }, onCancelSession: { _ in })
            #expect(manager.show().isComplete)
            destroy = { manager.destroyWindow() }
        }
        let panels = NSApp.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) }
            .compactMap { $0 as? NSPanel }
        let dismissal = RecorderPanelDismissal()
        defer { dismissal.cancel(panels: panels); destroy() }
        #expect(!panels.isEmpty && panels.allSatisfy(\.isVisible))
        let initialMouseHandling = panels.map(\.ignoresMouseEvents)
        let fixtureName = "\(style)-reduced-\(reducedMotion)"
        try await Task.sleep(for: .milliseconds(150))
        let initial = try panels.map { try paintedSamples(in: $0, name: "\(fixtureName)-before") }
        #expect(initial.allSatisfy { $0 > 100 })

        // Exercise the real stack and window-manager boundary after retirement, rather than
        // fading a permanent Text fixture. No audio, provider, paste or shortcut runs.
        // The pipeline may yield for resource cleanup before its empty-panel dismissal.
        // Direct managers avoid changing global recorder-style preferences in parallel tests.
        // — GPT-6.1 Sol
        session.phase = .done
        session.clearContext()
        engine.sessions = []
        await Task.yield()
        // Materialize the retirement update before starting the window-only sample.
        // A cold NSHostingView layout consumed211ms in the focused native fixture,
        // leaving no observable frame of the220ms window animation. Keep that
        // synthetic layout cost outside the measured native-alpha interval; capture
        // still requires real retired content at strict intermediate window alpha.
        // This does not add a delay or flush to the app. — GPT-6.1 Sol
        panels.forEach { $0.contentView?.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
        var finished = false
        // The hosted Mac enables Reduce Motion. Its real managers correctly hide
        // immediately under that policy, so an animated-frame test cannot inherit
        // the machine preference. Exercise the same production dismissal with both
        // policies explicitly, retaining strict animated-content checks in every run.
        // No system preference or live app is changed. — GPT-6.1 Sol
        let started = ContinuousClock.now
        dismissal.hide(panels: panels, animated: true, reducedMotion: reducedMotion) { finished = true }
        if reducedMotion {
            #expect(finished && !dismissal.isFading && panels.allSatisfy { !$0.isVisible })
            #expect(panels.allSatisfy { $0.alphaValue == 1 })
            #expect(zip(panels, initialMouseHandling).allSatisfy { $0.0.ignoresMouseEvents == $0.1 })
            return
        }
        var during: [Int] = []
        let sampled = try await observeNativeAnimation {
            guard panels.allSatisfy({ $0.isVisible && $0.alphaValue > 0.1 && $0.alphaValue < 0.6 }) else {
                return false
            }
            // Capture in the native sample callback. Resuming this test task can be
            // delayed until the window has already finished and ordered out.
            // — GPT-6.1 Sol
            during = try panels.map { try self.paintedSamples(in: $0, name: "\(fixtureName)-during") }
            return true
        }
        if !sampled {
            print("RecorderFadeDiagnostic style=\(style) systemReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) explicitReducedMotion=\(reducedMotion) elapsed=\(started.duration(to: .now)) finished=\(finished) panels=\(panels.map { ($0.isVisible, $0.alphaValue) })")
        }
        #expect(sampled, "Completion fade never exposed an intermediate native frame")
        for (before, after) in zip(initial, during) {
            #expect(after > before / 2, "Recorder content vanished before its window fade: \(before) -> \(after)")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished && panels.allSatisfy { !$0.isVisible })
        #expect(panels.allSatisfy { $0.alphaValue == 1 })
        #expect(zip(panels, initialMouseHandling).allSatisfy { $0.0.ignoresMouseEvents == $0.1 })
    }

    /// Count recorder-owned painted pixels, independent of the window's animated alpha,
    /// and retain synthetic native frames for visual inspection. — GPT-6.1 Sol
    @MainActor private func paintedSamples(in panel: NSPanel, name: String) throws -> Int {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var painted = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { painted += 1 }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("completion-fade-\(name).png"))
        }
        return painted
    }

    @Test func fadingKeepsNextOwnedAndPrimaryCanStartWithoutWaiting() throws {
        #expect(RecorderPanelLifecyclePolicy.idleToggleAction(sessionCount: 0,
            hasPendingStart: false, hasCaptureOwner: false, hasOutlineFeedback: true) == .startRecording)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Transcription/Engine/RecorderUIManager.swift"), encoding: .utf8)
        #expect(source.contains("hasOutlineFeedback: engine.noPasteOutlineFeedback != nil || panelDismissalID != nil"))
        #expect(source.contains("if panelDismissalID != nil,\n                           !showRecorderPanel(reason: \"recording restart during completion fade\") { return }"))
        let start = try #require(source.range(of: "    func dismissRecorderPanel() async {"))
        let end = try #require(source.range(of: "    // Force-hide the panel", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let fade = try #require(body.range(of: "hideRecorderPanel(animated: true)"))
        let release = try #require(body.range(of: "self.isRecorderPanelVisible = false"))
        #expect(fade.lowerBound < release.lowerBound)
        #expect(body.contains("self.panelDismissalID == dismissalID"))
        #expect(!body.contains("Task.sleep"))
        for file in ["MiniWindowManager", "NotchWindowManager"] {
            let manager = try String(contentsOf: root.appendingPathComponent(
                "VoiceInk/Views/Recorder/\(file).swift"), encoding: .utf8)
            #expect(manager.contains("dismissal.cancel(panels: windows.map(\\.panel))"))
            #expect(manager.contains("guard !dismissal.isFading else { return }"))
        }
    }

    // A full target measured a 155ms test-task resumption gap inside a 220ms fade.
    // Observe on AppKit's own main run loop, while the async test yields, so native
    // frame observation does not depend on Swift task resumption. Preserve the same
    // one-second bound and strict intermediate-alpha/content requirements.
    // — GPT-6.1 Sol
    @MainActor private func observeNativeAnimation(_ condition: @escaping @MainActor () throws -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(1))
        var last = started
        var maxGap = Duration.zero
        var samples = 0
        let result: Bool = try await withCheckedThrowingContinuation { continuation in
            var timer: Timer?
            let nativeTimer = Timer(timeInterval: 0.002, repeats: true) { _ in
                // This timer is installed only on RunLoop.main. — GPT-6.1 Sol
                MainActor.assumeIsolated {
                    let now = ContinuousClock.now
                    maxGap = max(maxGap, last.duration(to: now))
                    last = now
                    samples += 1
                    do {
                        let observed = try condition()
                        guard observed || now >= deadline else { return }
                        timer?.invalidate()
                        timer = nil
                        if !observed {
                            print("RecorderFadeDiagnostic observer elapsed=\(started.duration(to: .now)) samples=\(samples) maxGap=\(maxGap) appRunning=\(NSApplication.shared.isRunning) appActive=\(NSApplication.shared.isActive)")
                        }
                        continuation.resume(returning: observed)
                    } catch {
                        timer?.invalidate()
                        timer = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
            timer = nativeTimer
            RunLoop.main.add(nativeTimer, forMode: .common)
        }
        try Task.checkCancellation()
        return result
    }
}

@Suite(.serialized)
struct RecorderResponsivenessTests {
    @Test @MainActor func pausedRecorderBackgroundTracksStateAcrossBothStyles() async throws {
        let session = RecordingSession(phase: .recording)
        session.partialTranscript = "A retained transcript remains visible while paused."
        let recorder = Recorder()
        let assistant = AssistantSession()
        for height in [CGFloat(56), CGFloat(180)] {
            let views: [(String, AnyView, CGFloat)] = [
                ("mini", AnyView(MiniRecorderView(stateProvider: session,
                    liveTranscriptHeight: height, liveTranscriptWidth: 640, recorder: recorder,
                    assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                    onCancelTapped: {}, onAssistantFollowUp: { _ in })), 640),
                ("notch", AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                    assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                    liveTranscriptHeight: height, onRecordButtonTapped: {}, onCloseTapped: {},
                    onCancelTapped: {}, onAssistantFollowUp: { _ in })), MiniRecorderLayoutMetrics.liveTranscriptWidth)
            ]
            for (style, view, width) in views {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let host = NSHostingView(rootView: view.frame(width: width, height: 300))
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }
                // Reuse each host across transitions: a static paused rendering
                // alone would not prove that Resume restores the ordinary surface.
                for (name, state, microphoneOff) in [
                    ("recording", RecordingState.recording, false),
                    ("typing", .recording, true),
                    ("paused", .paused, false),
                    ("resumed", .recording, false)
                ] {
                    session.microphoneOff = microphoneOff
                    session.liveRecordingState = state
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    var painted = 0
                    var orange = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                  color.alphaComponent > 0.2 else { continue }
                            painted += 1
                            if color.redComponent > 0.35, color.greenComponent > 0.10,
                               color.greenComponent < 0.45, color.blueComponent < 0.12,
                               color.redComponent > color.greenComponent * 1.5 { orange += 1 }
                        }
                    }
                    #expect(painted > 100)
                    let orangeFraction = Double(orange) / Double(max(painted, 1))
                    #expect(state == .paused ? orangeFraction > 0.65 : orangeFraction < 0.08)
                    if let directory = ProcessInfo.processInfo.environment["VIPP_PAUSE_SNAPSHOT_DIR"] {
                        let folder = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let image = try #require(bitmap.representation(using: .png, properties: [:]))
                        try image.write(to: folder.appendingPathComponent("\(style)-\(Int(height))-\(name).png"))
                    }
                }
            }
        }
    }

    @Test @MainActor func recorderAppIconLayoutSnapshots() async throws {
        // Render the real views without starting capture or posting shortcuts.
        // These images let us inspect spacing after removing the secondary app icon.
        let session = RecordingSession(phase: .recording)
        let recorder = Recorder()
        let assistant = AssistantSession()
        for state in [RecordingState.recording, .paused, .transcribing] {
            session.liveRecordingState = state
            session.phase = state == .transcribing ? .transcribing : .recording
            let views: [(String, AnyView, CGFloat)] = [
                ("mini", AnyView(MiniRecorderView(stateProvider: session,
                    liveTranscriptHeight: 56, liveTranscriptWidth: 640, recorder: recorder,
                    assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                    onCancelTapped: {}, onAssistantFollowUp: { _ in })), 640),
                ("notch", AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                    assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                    liveTranscriptHeight: 56, onRecordButtonTapped: {}, onCloseTapped: {},
                    onCancelTapped: {}, onAssistantFollowUp: { _ in })), MiniRecorderLayoutMetrics.liveTranscriptWidth),
                ("pending", AnyView(TranscribingChip(session: session, style: .mini, onCancel: {})), 200)
            ]
            for (name, view, width) in views {
                // Fit the full live-context width: a compact 660pt notch host
                // clips the 1100pt recording layout. A non-key test panel gives
                // GeometryReader settled window dimensions before pixel capture.
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                let host = NSHostingView(rootView: view.frame(width: width, height: 160))
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try #require(bitmap.representation(using: .png, properties: [:]))
                try image.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("Recorder-single-app-\(name)-\(state).png"))
            }
        }
    }

    @Test func typingFinishDoesNotQueueMainActorWorkItAlreadyOwns() throws {
        let pipeline = try source("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift")
        #expect(pipeline.contains("private let archivePrompt: @MainActor (String, UUID) async throws -> AgentFlowPromptArchive.SavedPrompt"))
        let archiveStart = try #require(pipeline.range(of: "archivePrompt: @escaping @MainActor"))
        let archiveEnd = try #require(pipeline.range(of: "currentPromptRecipient:", range: archiveStart.upperBound..<pipeline.endIndex))
        let archive = pipeline[archiveStart.lowerBound..<archiveEnd.lowerBound]
        #expect(!archive.contains("await MainActor.run"))
        // Heavy scope/file work must still leave the UI actor.
        #expect(!archive.contains("CodexConversationContextReader"))
        #expect(!archive.contains("NSWorkspace"))
        #expect(!archive.contains("CodexConversationContextReader.selectionThreadRead"))
        #expect(!archive.contains("CodexConversationContextReader.readSelectionThreadIDs"))
        let scope = try source("VoiceInk/Transcription/Engine/CodexConversationContext.swift")
        #expect(scope.contains("await CodexSelectionLogWorker.shared.read"))
        #expect(archive.contains("await AgentFlowPromptArchive.save"))

        let paster = try source("VoiceInk/Paste/CursorPaster.swift")
        let directStart = try #require(paster.range(of: "static func pasteAtCursorAndWaitUntilPosted("))
        let directEnd = try #require(paster.range(of: "private static func performPasteSession(", range: directStart.upperBound..<paster.endIndex))
        let direct = paster[directStart.lowerBound..<directEnd.lowerBound]
        #expect(direct.contains("await performPasteSession"))
        #expect(!direct.contains("startPasteAtCursor("))
        #expect(!direct.contains("Task {"))
        // Both entry points retain the local typing-HUD veto; faster delivery
        // must never paste a previous result into a newer Agent Flow editor.
        let shared = paster[directEnd.lowerBound...]
        #expect(shared.contains("!RecorderTypingTextView.ownsKeyboard && requestedCanPost()"))
    }

    @Test @MainActor func finishedHUDDoesNotReadHiddenContextForVisibility() {
        let probe = FinishedHUDContextProbe()
        for state in [RecordingState.transcribing, .enhancing, .idle, .busy] {
            probe.recordingState = state
            #expect(!probe.showsLiveContext)
        }
        #expect(probe.referenceReads == 0)
        probe.recordingState = .recording
        #expect(probe.showsLiveContext && probe.referenceReads == 1)
    }

    @Test func finishLayoutSkipsTextMeasurementAndDoesNotFadeLoading() throws {
        let stacks = try source("VoiceInk/Views/Recorder/RecorderStackView.swift")
        for session in ["baseSession", "pillSession"] {
            let gate = try #require(stacks.range(of: "guard let \(session), \(session).showsLiveContext else"))
            let measured = try #require(stacks.range(of: "\(session).liveContextHeight(", range: gate.upperBound..<stacks.endIndex))
            #expect(gate.lowerBound < measured.lowerBound)
        }
        let mini = try source("VoiceInk/Views/Recorder/MiniRecorderView.swift")
        #expect(mini.contains(".animation(stateProvider.captureFinishRequested || stateProvider.recordingState.isProcessing ? nil : .easeInOut(duration: 0.3), value: hasLiveTranscript)"))
        let notch = try source("VoiceInk/Views/Recorder/NotchRecorderView.swift")
        #expect(notch.contains("if stateProvider.captureFinishRequested || stateProvider.recordingState.isProcessing { return nil }"))
        let components = try source("VoiceInk/Views/Recorder/RecorderComponents.swift")
        #expect(components.contains(".animation(currentState.isProcessing ? nil : .easeInOut(duration: 0.2), value: currentState)"))
    }

    @Test func stoppedRecoveryFormattingLeavesMainActorBeforeHardwareWait() throws {
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let stop = try #require(engine.range(of: "            RecorderTypingTextView.releaseKeyboardBeforeFinish()"))
        let end = try #require(engine.range(of: "            // ── RAPID-SESSION MEDIA OWNERSHIP", range: stop.upperBound..<engine.endIndex))
        let body = String(engine[stop.lowerBound..<end.lowerBound])
        let freeze = try #require(body.range(of: "let stoppedReferences = active.liveSelectionReferencesForDelivery"))
        let worker = try #require(body.range(of: "let recoveryDraft = Task.detached(priority: .userInitiated)"))
        let hardware = try #require(body.range(of: "await recorder.stopRecording("))
        let join = try #require(body.range(of: "active.recoverablePartialTranscript = await recoveryDraft.value"))
        #expect(freeze.lowerBound < worker.lowerBound && worker.lowerBound < hardware.lowerBound)
        #expect(hardware.lowerBound < join.lowerBound)
        #expect(body.contains("stoppedReferences, with: stoppedTranscript, includeTiming: true"))
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func miniFinishCollapsesOnFirstUpdateWithoutMovingBottomEdge(captureTail: Bool, assistantVisible: Bool) async throws {
        let screen = try #require(NSScreen.main)
        let session = RecordingSession()
        session.microphoneOff = true
        session.updateTypedInput(String(repeating: "Long typed draft with context ", count: 400))
        session.microphoneOff = !captureTail
        let panel = MiniRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 240))
        let assistant = AssistantSession()
        if assistantVisible {
            assistant.beginInitialResponse(transcript: "Previous context", provider: nil,
                modelName: nil, modeName: nil, modeEmoji: nil, promptName: nil)
            assistant.finishInitialResponse("Previous response", systemPrompt: nil)
        }
        let view = MiniRecorderView(stateProvider: session, liveTranscriptHeight: 180, liveTranscriptWidth: 640,
            recorder: Recorder(), assistantSession: assistant, onRecordButtonTapped: {},
            onCloseTapped: {}, onCancelTapped: {}, onAssistantFollowUp: { _ in })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setFrame(NSRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                              width: 640, height: 240), display: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        host.layoutSubtreeIfNeeded()
        let bottom = panel.frame.minY
        session.acknowledgeCaptureFinish()
        #expect(!session.showsAssistantContext(isVisible: assistant.isVisible))
        if captureTail {
            #expect(session.phase == .recording && session.recordingState == .recording)
        } else {
            session.phase = .transcribing
            session.liveRecordingState = .transcribing
        }
        // One display opportunity, well below the old 200/300 ms fade/collapse.
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        let oldEditorPixel = try #require(bitmap.colorAt(x: Int(40 * scaleX), y: Int(100 * scaleY)))
        #expect(oldEditorPixel.alphaComponent < 0.05)
        #expect(panel.frame.minY == bottom)
    }

    @Test @MainActor func miniRecorderHostedViewRendersFlushAtPhysicalBottom() async throws {
        let screen = try #require(NSScreen.main)
        let scale: CGFloat = 0.85
        let session = RecordingSession()
        let recorder = Recorder()
        let assistant = AssistantSession()
        let panel = MiniRecorderPanel(contentRect: .zero)
        // This live session lights the Recording Outline along the card's bottom edge.
        // RecorderCaptureOutlineTests covers that ring; a private suite turns it off
        // here so this geometry check still samples the black card body.
        let outlineSuiteName = "AgentFlowTests.MiniBottom.\(UUID().uuidString)"
        let outlineOff = try #require(UserDefaults(suiteName: outlineSuiteName))
        outlineOff.set(false, forKey: RecorderCaptureOutlinePreference.preferenceKey)
        defer { outlineOff.removePersistentDomain(forName: outlineSuiteName) }
        let view = MiniRecorderView(
            stateProvider: session, liveTranscriptHeight: 56, liveTranscriptWidth: 640,
            recorder: recorder, assistantSession: assistant,
            onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {},
            onAssistantFollowUp: { _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(RecorderPanelHeightSync(desiredHeight: 200, edge: .bottom, scale: scale))
            .defaultAppStorage(outlineOff)
        let host = ScaledRecorderHostingView(rootView: AnyView(view), scale: scale)
        panel.contentView = host
        defer { panel.orderOut(nil); panel.close() }
        panel.show(on: screen, scale: scale)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        #expect(panel.frame.minY == screen.frame.minY)
        #expect(abs(panel.frame.height - 200 * scale) <= 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // Native AppKit pixels, not inferred host geometry: the black capsule
        // must reach the host's bottom centre after SwiftUI's asynchronous resize.
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                y: bitmap.pixelsHigh - 1)?.usingColorSpace(.deviceRGB))
        #expect(pixel.alphaComponent > 0.95)
        #expect(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.1)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MiniRecorder-bottom.png"))
        let dragged = panel.frame.offsetBy(dx: 15, dy: 100)
        panel.wasDraggedByUser = true
        panel.setFrame(dragged, display: true)
        #expect(panel.frame.origin == dragged.origin)
    }

    @Test @MainActor func miniRecorderTouchesPhysicalBottomAcrossDocksOriginsAndScales() {
        for origin: CGFloat in [0, -900, 420] {
            let screen = NSRect(x: -1440, y: origin, width: 1440, height: 900)
            for dockHeight: CGFloat in [0, 80] {
                let visible = NSRect(x: screen.minX, y: origin + dockHeight,
                                     width: 1440, height: 875 - dockHeight)
                for scale: CGFloat in [0.5, 0.85, 1] {
                    let initial = MiniRecorderPanel.calculateWindowMetrics(
                        screenFrame: screen, visibleFrame: visible, scale: scale)
                    #expect(initial.minY == screen.minY)
                    #expect(initial.midX == visible.midX)
                    for contentHeight: CGFloat in [120, 700, 2_000] {
                        let grown = RecorderPanelHeightSync.resizedFrame(
                            initial, desiredHeight: contentHeight, edge: .bottom, scale: scale,
                            screenFrame: screen, visibleFrame: visible, wasDraggedByUser: false)
                        #expect(grown.minY == screen.minY)
                        #expect(grown.maxY <= visible.maxY - 12)
                        let dragged = initial.offsetBy(dx: 15, dy: 100)
                        let resizedDrag = RecorderPanelHeightSync.resizedFrame(
                            dragged, desiredHeight: contentHeight, edge: .bottom, scale: scale,
                            screenFrame: screen, visibleFrame: visible, wasDraggedByUser: true)
                        #expect(resizedDrag.origin == dragged.origin)
                    }
                }
            }
        }
    }

    @Test @MainActor func miniRecorderWarningReservationConvertsPhysicalBottomOnlyOnce() {
        let screenBottom: CGFloat = -900
        for dockHeight: CGFloat in [0, 80, 150] {
            for scale: CGFloat in [0.5, 0.85, 1] {
                let reserved = MiniRecorderLayoutMetrics.notificationBottomReservedHeight(
                    showsAssistant: false, showsRealtimeTranscript: true, sessionCount: 3,
                    realtimeTranscriptHeight: 200, scale: scale, screenBottomInset: dockHeight)
                let visible = NSRect(x: 0, y: screenBottom + dockHeight,
                                     width: 1440, height: 875 - dockHeight)
                let warning = NotificationManager.notificationOrigin(
                    screenRect: visible, notificationSize: NSSize(width: 500, height: 44),
                    bottomReservedHeight: reserved)
                let renderedTop = screenBottom + (200 + 1 + 40 + 92) * scale
                #expect(warning.y >= renderedTop + 16)
                #expect(reserved == max(0, (200 + 1 + 40 + 92) * scale - dockHeight))
            }
        }
    }

    @Test @MainActor func sharedEditorHeightMatchesOriginalLayoutAcrossTextAndGeometry() {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        let texts = ["", "one", "one\n", String(repeating: "long typed words ", count: 300),
            String(repeating: "👩🏽‍💻 e\u{301} العربية ", count: 80), String(repeating: "\n", count: 30)]
        for text in texts {
            session.updateTypedInput(text)
            for speech in ["Short speech.", String(repeating: "Spoken context grows too. ", count: 100)] {
                session.partialTranscript = speech
                for width: CGFloat in [320, 640, 1084] {
                    for cap: CGFloat in [80, 220, 660] {
                        let total = session.liveContextHeight(width: width, maxHeight: cap)
                        let original = MiniRecorderLayoutMetrics.typingHeight(text: text, width: width,
                            maxHeight: total - MiniRecorderLayoutMetrics.singleLineHeight)
                        #expect(provider.liveContextEditorHeight(width: width, contextHeight: total) == original)
                        #expect(session.liveContextHeight(width: width, maxHeight: cap) == total)
                    }
                }
            }
        }
    }

    @Test @MainActor func sharedEditorHeightRejectsStaleSnapshotsAndUnsupportedGeometry() throws {
        let session = RecordingSession()
        let provider: any RecorderStateProvider = session
        session.updateTypedInput(String(repeating: "long typing ", count: 200))
        let oldHeight = session.liveContextHeight(width: 640, maxHeight: 220)
        session.updateTypedInput("Short again")
        #expect(provider.liveContextEditorHeight(width: 640, contextHeight: oldHeight)
            == MiniRecorderLayoutMetrics.typingHeight(text: session.typedInput, width: 640,
                maxHeight: oldHeight - MiniRecorderLayoutMetrics.singleLineHeight))
        let current = session.liveContextHeight(width: 640, maxHeight: 220)
        #expect(provider.liveContextEditorHeight(width: 640, contextHeight: current)
            == MiniRecorderLayoutMetrics.typingHeight(text: session.typedInput, width: 640,
                maxHeight: current - MiniRecorderLayoutMetrics.singleLineHeight))
        session.updateTypedInput(String(repeating: "words wrap at a narrower width ", count: 4))
        let prepared = session.liveContextHeight(width: 640, maxHeight: 220)
        #expect(provider.liveContextEditorHeight(width: 180, contextHeight: prepared)
            == MiniRecorderLayoutMetrics.typingHeight(text: session.typedInput, width: 180,
                maxHeight: prepared - MiniRecorderLayoutMetrics.singleLineHeight))
        session.liveRecordingState = .transcribing
        session.phase = .transcribing
        #expect(provider.liveContextEditorHeight(width: 640, contextHeight: prepared) == 0)
        for file in ["MiniRecorderView.swift", "NotchRecorderView.swift"] {
            #expect(try source("VoiceInk/Views/Recorder/" + file)
                .contains("cachedEditorHeight: stateProvider.liveContextEditorHeight("))
        }
    }

    @Test @MainActor func cachedContextHeightTracksSpeechTypingGeometryAndShrink() throws {
        let session = RecordingSession()
        session.microphoneOff = true
        func check() {
            for width: CGFloat in [300, 640, 1100] {
                for limit: CGFloat in [180, 500] {
                    let expected = MiniRecorderLayoutMetrics.contextHeight(
                        parts: session.liveContextPreviewParts,
                        typedText: session.canTypeInHUD ? session.typedInput : nil,
                        width: width, maxHeight: limit)
                    // A repeated consumer must get the same exact geometry.
                    #expect(session.liveContextHeight(width: width, maxHeight: limit) == expected)
                    #expect(session.liveContextHeight(width: width, maxHeight: limit) == expected)
                }
            }
        }
        check()
        session.partialTranscript = String(repeating: "Growing speech and context. ", count: 200)
        check()
        session.updateTypedInput(String(repeating: "Typed words\n", count: 40))
        check()
        session.partialTranscript = "Short again."
        session.updateTypedInput("One line")
        check()
        session.recordLiveSelection(try #require(LiveSelectionReference("A newly accepted selection changes the shared preview.")))
        check()
        session.liveRecordingState = .transcribing
        session.phase = .transcribing
        check()
        // Cycling more geometries than the cache retains must preserve each size.
        for width in stride(from: CGFloat(300), through: 660, by: 10) {
            #expect(session.liveContextHeight(width: width, maxHeight: 500)
                == MiniRecorderLayoutMetrics.contextHeight(parts: session.liveContextPreviewParts,
                    typedText: nil, width: width, maxHeight: 500))
        }
    }

    @Test @MainActor func warningFollowsGrowingAndShrinkingRecorderWithoutReplacement() async throws {
        let screen = try #require(NSScreen.main)
        let placement = RecorderWarningPlacementProbe()
        let manager = NotificationManager()
        manager.setRecorderPlacementProvider(placement)
        manager.showNotification(title: "Recorder layout fixture", type: .error,
            playSound: false, dismissesAutomatically: false)
        let warning = try #require(NSApp.windows.first(where: { manager.isNotificationWindow($0) }))
        let panel = MiniRecorderPanel(contentRect: NSRect(
            x: screen.visibleFrame.midX - 200, y: screen.frame.minY, width: 400, height: 120))
        func content(_ height: CGFloat) -> some View {
            Color.clear.background(RecorderPanelHeightSync(
                desiredHeight: height + 12, edge: .bottom, scale: 1,
                onLayoutChange: { manager.recorderLayoutDidChange(on: $0) }))
        }
        let host = NSHostingView(rootView: content(placement.height))
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { manager.dismissNotification(); panel.orderOut(nil); panel.close() }
        for height: CGFloat in [40, 60, 220, 40] {
            placement.height = height
            host.rootView = content(height)
            host.layoutSubtreeIfNeeded()
            let origin = NotificationManager.notificationOrigin(screenRect: screen.visibleFrame,
                notificationSize: warning.frame.size, bottomReservedHeight: height)
            try await waitForCompletion { abs(warning.frame.minY - origin.y) < 1 }
            #expect(manager.isNotificationWindow(warning) && warning.isVisible)
            #expect(abs(warning.frame.minX - origin.x) < 1)
            // 40→60 changes the card envelope but not its minimum host height.
            if height <= 60 { #expect(panel.frame.height == 120) }
        }
    }

    @Test @MainActor func stoppedAssistantContextDoesNotReserveHiddenPanelHeight() throws {
        let session = RecordingSession()
        #expect(session.showsAssistantContext(isVisible: true))
        session.acknowledgeCaptureFinish()
        for scale: CGFloat in [0.5, 0.85, 1] {
            let height = MiniRecorderLayoutMetrics.notificationBottomReservedHeight(
                showsAssistant: session.showsAssistantContext(isVisible: true),
                showsRealtimeTranscript: session.showsLiveContext, sessionCount: 1,
                realtimeTranscriptHeight: 700, assistantHeight: 320, scale: scale)
            #expect(height == MiniRecorderLayoutMetrics.controlBarHeight * scale)
        }
        // A fresh/assistant-only card still shows the retained response normally.
        #expect(RecordingSession().showsAssistantContext(isVisible: true))
        let stacks = try source("VoiceInk/Views/Recorder/RecorderStackView.swift")
        #expect(stacks.contains("baseSession?.showsAssistantContext(isVisible:"))
        #expect(stacks.contains("pillSession?.showsAssistantContext(isVisible:"))
        #expect(stacks.components(separatedBy: "if showsAssistantContext {").count == 3)
        let manager = try source("VoiceInk/Transcription/Engine/RecorderUIManager.swift")
        #expect(manager.contains("baseSession?.showsAssistantContext(isVisible:"))
    }

    @Test @MainActor func disabledRecordingStartWarningDoesNotPresentNotification() {
        #expect(!FocusLockService.recordingStartInputCaptureEnabled)
        let windowNumbers = NSApp.windows.map(\.windowNumber)
        FocusLockService.shared.showRecordingStartInput(nil)
        #expect(NSApp.windows.map(\.windowNumber) == windowNumbers)
    }

    @Test func recordingStartWarningRequiresEnabledCaptureBeforeNotification() throws {
        let focus = try source("VoiceInk/Modes/FocusLockService.swift")
        let start = try #require(focus.range(of: "    func showRecordingStartInput(_ target: Target?) {"))
        let end = try #require(focus.range(of: "    func showPendingPasteInputUnavailable()", range: start.upperBound..<focus.endIndex))
        let body = String(focus[start.lowerBound..<end.lowerBound])
        let enabled = try #require(body.range(of: "guard Self.recordingStartInputCaptureEnabled, target == nil else { return }"))
        let notification = try #require(body.range(of: "NotificationManager.shared.showNotification("))
        #expect(enabled.lowerBound < notification.lowerBound)
        // Only this dormant feature's advisory is suppressed, not microphone
        // failures or an explicit second-chance paste-target failure.
        #expect(body.contains("Recording start input unavailable"))
        #expect(focus[end.lowerBound...].contains("Paste target unchanged — focus a text input and press Next Track again"))
    }

    @Test @MainActor func unusedRecordingStartInputCaptureReturnsNilWithoutReadingAX() {
        #expect(!FocusLockService.recordingStartInputCaptureEnabled)
        FocusLockService.shared.stageRecordingStartInputBeforeShortcutCompletion()
        #expect(FocusLockService.shared.captureRecordingStartInputSnapshot() == nil)
    }

    @Test func unusedRecordingStartCaptureGuardsEveryProductionRead() throws {
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        #expect(engine.contains("if FocusLockService.recordingStartInputCaptureEnabled {\n            focusedInput = FocusLockService.shared.captureRecordingStartInputSnapshot()"))
        #expect(engine.contains("if FocusLockService.recordingStartInputCaptureEnabled,\n               session.recordingStartFocusedInput == nil"))
        let manager = try source("VoiceInk/Shortcuts/RecordingShortcutManager.swift")
        let stage = try #require(manager.range(of: "            onModifierOnlySequenceProgress:"))
        let next = try #require(manager.range(of: "            onNextTrackKeyDown:", range: stage.upperBound..<manager.endIndex))
        let body = String(manager[stage.lowerBound..<next.lowerBound])
        let guardRange = try #require(body.range(of: "guard FocusLockService.recordingStartInputCaptureEnabled else"))
        let capture = try #require(body.range(of: ".stageRecordingStartInputBeforeShortcutCompletion("))
        #expect(guardRange.lowerBound < capture.lowerBound)
        let focus = try source("VoiceInk/Modes/FocusLockService.swift")
        let completed = try #require(focus.range(of: "    func captureRecordingStartInputSnapshot() -> Target? {"))
        let completedEnd = try #require(focus.range(of: "    private func captureAuditedOpenAIComposerAtRecordingStart(", range: completed.upperBound..<focus.endIndex))
        let completedBody = String(focus[completed.lowerBound..<completedEnd.lowerBound])
        let completedGuard = try #require(completedBody.range(of: "guard Self.recordingStartInputCaptureEnabled else"))
        let completedRead = try #require(completedBody.range(of: "captureFocusedInputSnapshot("))
        #expect(completedGuard.lowerBound < completedRead.lowerBound)
    }

    @Test func disabledRecordingTimeNextDoesNotCancelPrimaryOrUseMissingSavedInput() throws {
        let manager = try source("VoiceInk/Shortcuts/RecordingShortcutManager.swift")
        let start = try #require(manager.range(of: "            onNextTrackKeyDown:"))
        let end = try #require(manager.range(of: "            onPrimaryTypingFocus:", range: start.upperBound..<manager.endIndex))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        let disabled = try #require(body.range(of: "!FocusLockService.recordingStartInputCaptureEnabled"))
        let cancel = try #require(body.range(of: "cancelPendingPrimaryDecisions()"))
        let stop = try #require(body.range(of: "stopPasteDestination: .recordingStart"))
        #expect(disabled.lowerBound < cancel.lowerBound)
        #expect(disabled.lowerBound < stop.lowerBound)
        #expect(body.contains("unusedCaptureDisabled\")\n                        return true"))
        #expect(body.contains("retargetMostRecentPendingTranscriptionToFocusedInput()"))
    }

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
        #expect(ui.contains("let hasFeedback = engine.noPasteOutlineFeedback != nil"))
        #expect(ui.contains("guard showsAssistant || baseSession != nil || showsStartup || hasFeedback else { return nil }"))
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
            // AppKit's cache uses backing pixels: a Retina MacBook returns twice
            // as many pixels as view points. Sampling unscaled point coordinates
            // tests the black background instead of the centre dot on that host.
            let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            let black = try #require(bitmap.colorAt(
                x: Int(20 * scaleX), y: Int(CGFloat(height / 2) * scaleY)
            )?.usingColorSpace(.deviceRGB))
            #expect(black.alphaComponent > 0.99)
            #expect(black.redComponent < 0.01 && black.greenComponent < 0.01 && black.blueComponent < 0.01)
            let dots = try #require(bitmap.colorAt(
                x: Int(140 * scaleX), y: Int(CGFloat(height / 2) * scaleY)
            )?.usingColorSpace(.deviceRGB))
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

@MainActor private final class FinishedHUDContextProbe: RecorderStateProvider {
    var recordingState = RecordingState.transcribing
    var partialTranscript = ""
    var skipPostProcessing = false
    var pasteDestinationIndicatorTarget: FocusLockService.Target? { nil }
    var iconActionPulse: RecorderIconActionPulse? { nil }
    private(set) var referenceReads = 0
    var liveSelectionReferences: [LiveSelectionReference] {
        referenceReads += 1
        return [LiveSelectionReference("selected context")!]
    }
}

@MainActor private final class RecorderWarningPlacementProbe: NotificationRecorderPlacementProviding {
    var height: CGFloat = 40
    func notificationBottomReservedHeight(on screen: NSScreen) -> CGFloat? { height }
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
