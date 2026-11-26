// Proves the Recording Outline's accepted-context lap with synthetic sessions and
// isolated outline leaves only. Nothing here starts capture, reads a real selection,
// takes a screenshot, plays media, changes focus or touches Primary/Next delivery.
// File URLs are never opened; references only carry their paths. — Claude Opus 5.5
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderContextSweepTests {
    /// macOS's dark cyan and purple, fixed so the pure geometry checks do not
    /// depend on the test machine's appearance.
    private let blue = RecorderNeonSpectrum.Components(red: 0.39, green: 0.82, blue: 1.0)
    private let magenta = RecorderNeonSpectrum.Components(red: 0.75, green: 0.35, blue: 0.95)

    @Test func pulseMaskPreservesTheActualRainbowWhenItsClockDiffers() {
        let paint = RecorderContextSweepPaint(tint: blue,
            form: .lap(.init(head: 0, tail: 0, strength: 0)))
        for position in stride(from: 0.0, to: 1.0, by: 0.01) {
            let actual = position + 0.35
            #expect(paint.components(at: position, rainbowPosition: actual)
                == RecorderNeonSpectrum.components(at: actual))
        }
    }

    @Test @MainActor func acceptedHighlightsAndScreenshotsEachLaunchOneAcknowledgementOfTheirColour() throws {
        let session = RecordingSession()
        session.microphoneOff = true
        #expect(session.contextAcceptancePulse == nil)
        #expect(session.canTypeInHUD && !session.showsRecordingActivityOutline)

        let highlight = try #require(LiveSelectionReference("highlighted words"))
            .timed(at: Date(timeIntervalSince1970: 10)).identifiedForCapture(UUID())
        session.recordLiveSelection(highlight, spokenAnchor: "before")
        let first = try #require(session.contextAcceptancePulse)
        #expect(first.kind == .selection)
        #expect(session.showsRecordingActivityOutline)

        // The generic cards read the pulse through the protocol requirement, not a
        // statically dispatched extension default.
        func providerPulse<S: RecorderStateProvider>(_ provider: S) -> RecorderContextAcceptancePulse? {
            provider.contextAcceptancePulse
        }
        #expect(providerPulse(session) == first)

        // The same accepted gesture again is stored as before but relaunches nothing.
        session.recordLiveSelection(highlight, spokenAnchor: "before")
        #expect(session.contextAcceptancePulse == first)

        // Highlighting the same words again is a new gesture with its own lap.
        let again = try #require(LiveSelectionReference("highlighted words"))
            .timed(at: Date(timeIntervalSince1970: 11)).identifiedForCapture(UUID())
        session.recordLiveSelection(again)
        let second = try #require(session.contextAcceptancePulse)
        #expect(second.kind == .selection && second.id != first.id)

        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/Screenshot \(UUID().uuidString).png")))
            .timed(at: Date(timeIntervalSince1970: 12))
        session.recordLiveSelection(screenshot)
        let third = try #require(session.contextAcceptancePulse)
        #expect(third.kind == .screenshot && third.id != second.id)
        // The scan's baseline already prevents this; if the same file and time
        // arrived again, it still could not relaunch the lap.
        session.recordLiveSelection(screenshot)
        #expect(session.contextAcceptancePulse == third)

        // An approved selection image is a selection, so it is blue, not magenta.
        let image = try #require(LiveSelectionReference(codexSelectionImageURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/\(UUID().uuidString).png")))
            .timed(at: Date(timeIntervalSince1970: 13))
        session.recordLiveSelection(image)
        let fourth = try #require(session.contextAcceptancePulse)
        #expect(fourth.kind == .selection && fourth.id != third.id)
    }

    @Test @MainActor func typingTimingLabelsAttachedImagesRetryAndUnlitStatesNeverLaunchALap() throws {
        let session = RecordingSession()
        // Typed prose and the internal speech-timing marker are not captured context.
        session.recordLiveSelection(try #require(LiveSelectionReference(typedText: "typed note")))
        session.recordLiveSelection(.speechTiming(after: "words",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2)))
        #expect(session.contextAcceptancePulse == nil)

        // A highlight made before Start is still captured, without a lap.
        session.recordLiveSelection(try #require(LiveSelectionReference("read before start"))
            .identifiedForCapture(UUID()), precedesSpeech: true)
        #expect(session.liveSelectionReferences.first?.isSelection == true)
        #expect(session.contextAcceptancePulse == nil)

        // Pause and voice startup show no outline. Capture still
        // stores each highlight, but no lap can surface later as a stale fragment.
        for (state, microphoneOff) in [(RecordingState.paused, false), (.starting, false)] {
            session.liveRecordingState = state
            session.microphoneOff = microphoneOff
            let before = session.liveSelectionReferences.count
            session.recordLiveSelection(try #require(LiveSelectionReference("unlit highlight"))
                .identifiedForCapture(UUID()))
            #expect(session.liveSelectionReferences.count == before + 1, "\(state) off=\(microphoneOff)")
            #expect(session.contextAcceptancePulse == nil, "\(state) off=\(microphoneOff)")
        }
        session.microphoneOff = false
        session.liveRecordingState = .recording

        // A rejected event stores nothing and launches nothing.
        session.shouldCancel = true
        let count = session.liveSelectionReferences.count
        session.recordLiveSelection(try #require(LiveSelectionReference("after cancel")).identifiedForCapture(UUID()))
        #expect(session.liveSelectionReferences.count == count)
        #expect(session.contextAcceptancePulse == nil)
        session.shouldCancel = false

        // One real lap; its later labels and drag image belong to the same gesture.
        let textID = UUID()
        session.recordLiveSelection(try #require(LiveSelectionReference("drag text"))
            .identifiedForCapture(textID), spokenAnchor: "")
        let lap = try #require(session.contextAcceptancePulse)
        session.updateLiveSelectionLabels(captureID: textID,
            reference: try #require(LiveSelectionReference("label source")))
        let picture = try #require(LiveSelectionReference(codexSelectionImageURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/\(UUID().uuidString).png")))
        #expect(session.attachLiveSelectionImage(picture, after: textID, spokenAnchor: ""))
        #expect(session.contextAcceptancePulse == lap)

        // Microphone-off typing now has the rainbow, so a real accepted highlight
        // can answer with its colour too. Typing prose above still cannot launch it.
        // — GPT-6.1 Sol
        session.microphoneOff = true
        session.recordLiveSelection(try #require(LiveSelectionReference("typing highlight"))
            .identifiedForCapture(UUID()))
        #expect(session.contextAcceptancePulse?.id != lap.id)

        // Retry hydration restores old context into a transcribing session silently.
        let retry = RecordingSession(phase: .transcribing)
        retry.restoreLiveContextForRetry(session.liveSelectionReferences)
        #expect(!retry.liveSelectionReferences.isEmpty)
        #expect(retry.contextAcceptancePulse == nil)
    }

    @Test func lapLaunchesFromItsColourBandCirclesOnceAndLeavesTheRainbowUntouched() throws {
        let sweep = RecorderContextSweep.self
        let anchorStep = 1 / Double(RecorderNeonSpectrum.anchors.count)
        let blueOrigin = sweep.origin(nearest: blue)
        let magentaOrigin = sweep.origin(nearest: magenta)
        // Ethan's "where the blue currently is": between laser blue and neon cyan.
        // The screenshot lap starts between hot magenta and electric violet.
        #expect(blueOrigin > 2 * anchorStep && blueOrigin < 3 * anchorStep, "\(blueOrigin)")
        #expect(magentaOrigin > 0 && magentaOrigin < anchorStep, "\(magentaOrigin)")
        for (tint, origin) in [(blue, blueOrigin), (magenta, magentaOrigin)] {
            let best = sweep.squaredDistance(RecorderNeonSpectrum.components(at: origin), tint)
            for index in 0..<700 {
                let position = Double(index) / 700
                #expect(sweep.squaredDistance(RecorderNeonSpectrum.components(at: position), tint) >= best - 1e-3)
            }
        }

        // Nothing before the start or from the end: the plain rainbow, no timer to clear.
        let start = Date(timeIntervalSince1970: 1_000)
        let highlight = try #require(LiveSelectionReference("x"))
        let pulse = try #require(RecorderContextAcceptancePulse(accepting: highlight, at: start))
        #expect(sweep.acknowledgement(for: nil, at: start) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(-0.01)) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(sweep.duration)) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(0.5))?.kind == .selection)

        // Exactly one lap: head and tail each travel once, the tail never passes
        // the head, and the arc stretches to about half the border mid-lap.
        var previous = sweep.lap(atProgress: 0)
        #expect(previous.head == 0 && previous.tail == 0 && previous.strength == 0)
        for step in 1...200 {
            let lap = sweep.lap(atProgress: Double(step) / 200)
            #expect(lap.head >= previous.head && lap.tail >= previous.tail && lap.tail <= lap.head)
            #expect(lap.strength >= 0 && lap.strength <= 1)
            previous = lap
        }
        #expect(sweep.lap(atProgress: sweep.travelShare).head == 1)
        #expect(previous.head == 1 && previous.tail == 1 && previous.strength == 0)
        let middle = sweep.lap(atProgress: 0.5)
        #expect(middle.head - middle.tail > 0.4 && middle.head - middle.tail < 0.6)

        for (tint, origin) in [(blue, blueOrigin), (magenta, magentaOrigin)] {
            let paint = RecorderContextSweepPaint(tint: tint, form: .lap(middle))
            #expect(paint.origin == origin)
            // Mid-arc is the transcript colour, and the far side is the rainbow's own
            // colour at its own phase, bit for bit.
            let arcMiddle = origin + (middle.head + middle.tail) / 2
            #expect(sweep.squaredDistance(paint.components(at: arcMiddle), tint) < 1e-12)
            let farSide = arcMiddle + 0.5
            #expect(paint.components(at: farSide) == RecorderNeonSpectrum.components(at: farSide))
            // A white-hot spark rides the head.
            let head = paint.components(at: origin + middle.head)
            #expect(min(head.red, head.green, head.blue) > min(tint.red, tint.green, tint.blue) + 0.2)

            // Early on, only the stretch beside the launch band changes.
            let early = RecorderContextSweepPaint(tint: tint, form: .lap(sweep.lap(atProgress: 0.12)))
            for index in 0..<144 {
                let offset = Double(index) / 144
                guard offset > 0.2, offset < 0.8 else { continue }
                #expect(early.components(at: origin + offset) == RecorderNeonSpectrum.components(at: origin + offset))
            }

            // Launch and landing fade from and to nothing, so neither end jumps.
            for progress in [0.001, 0.999] {
                let edge = RecorderContextSweepPaint(tint: tint, form: .lap(sweep.lap(atProgress: progress)))
                for index in 0..<144 {
                    let position = Double(index) / 144
                    let actual = position + 0.35
                    let distance = sweep.squaredDistance(edge.components(at: position, rainbowPosition: actual),
                                                         RecorderNeonSpectrum.components(at: actual))
                    #expect(distance < 1e-4, "progress \(progress) position \(position)")
                }
            }
        }
    }

    @Test func extraCyclePreservesTheOriginalEntranceTravelAndExit() throws {
        let sweep = RecorderContextSweep.self
        #expect(sweep.cycleDuration == 1 && sweep.cycleCount == 2 && sweep.duration == 2)
        let start = Date(timeIntervalSince1970: 1_000)
        let reference = try #require(LiveSelectionReference("two animated cycles"))
        let pulse = try #require(RecorderContextAcceptancePulse(accepting: reference, at: start))
        for cycle in 0..<2 {
            for step in 0..<100 {
                let progress = Double(step) / 100
                let elapsed = Double(cycle) + progress
                let acknowledgement = try #require(sweep.acknowledgement(
                    for: pulse, at: start.addingTimeInterval(elapsed)))
                guard case .lap(let actual) = acknowledgement.form else {
                    Issue.record("Expected the original travelling lap"); return
                }
                // Original 1s curve, repeated unchanged, including its entrance
                // and tail. The extra cycle does not flatten the whole edge.
                // — GPT-6.1 Sol
                let expected = sweep.lap(atProgress: progress)
                #expect(abs(actual.head - expected.head) < 1e-5)
                #expect(abs(actual.tail - expected.tail) < 1e-5)
                #expect(abs(actual.strength - expected.strength) < 1e-5)
            }
        }
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(2)) == nil)
    }

    @Test func reduceMotionHoldsOneStillColourBrieflyAndAlwaysEnds() throws {
        let sweep = RecorderContextSweep.self
        let start = Date(timeIntervalSince1970: 2_000)
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/still.png")))
        let pulse = try #require(RecorderContextAcceptancePulse(accepting: screenshot, at: start))
        #expect(pulse.kind == .screenshot)
        #expect(sweep.stillDuration == 1.2)
        #expect(sweep.stillRemaining(of: pulse, at: start) == sweep.stillDuration)
        let partway = try #require(sweep.stillRemaining(of: pulse, at: start.addingTimeInterval(0.3)))
        // Date stores an absolute floating-point value; fractional intervals are
        // only as precise as that epoch's adjacent representable values.
        let precision = max(1e-9, abs(start.timeIntervalSinceReferenceDate).ulp * 2)
        #expect(abs(partway - (sweep.stillDuration - 0.3)) <= precision)
        #expect(sweep.stillRemaining(of: pulse, at: start.addingTimeInterval(sweep.stillDuration)) == nil)
        // A clock reading earlier than the start still yields a bounded hold.
        #expect(sweep.stillRemaining(of: pulse, at: start.addingTimeInterval(-5)) == sweep.stillDuration)

        // Still means one colour everywhere: no head, spark or travelling edge.
        let paint = RecorderContextSweepPaint(tint: magenta, form: .still)
        for index in 0..<72 {
            #expect(paint.components(at: Double(index) / 72) == magenta)
        }
    }

    @Test @MainActor func lapColoursAreTheTranscriptsSelectionBlueAndScreenshotMagenta() throws {
        #expect(RecorderContextColor.selection == Color.cyan)
        #expect(RecorderContextColor.screenshot == Color.purple)
        #expect(RecorderContextAcceptancePulse.Kind.selection.color == RecorderContextColor.selection)
        #expect(RecorderContextAcceptancePulse.Kind.screenshot.color == RecorderContextColor.screenshot)
        let transcript = try source("VoiceInk/Views/Recorder/RecorderComponents.swift")
        #expect(transcript.contains("waitingContext : RecorderContextColor.selection.opacity(0.8))"))
        #expect(transcript.contains("waitingContext : RecorderContextColor.screenshot.opacity(0.95))"))

        let sweep = RecorderContextSweep.self
        func cyclicDistance(_ a: Double, _ b: Double) -> Double { abs(RecorderCaptureOutlineTrace.wrapped(a - b)) }
        let anchorStep = 1 / Double(RecorderNeonSpectrum.anchors.count)
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let selection = sweep.components(of: RecorderContextColor.selection, in: environment)
            let screenshot = sweep.components(of: RecorderContextColor.screenshot, in: environment)
            #expect(selection.blue >= selection.green && selection.green > selection.red, "\(scheme) \(selection)")
            #expect(screenshot.red > screenshot.green + 0.2 && screenshot.blue > screenshot.green + 0.2,
                    "\(scheme) \(screenshot)")
            // Each lap launches from its own band: blue between laser blue and cyan,
            // magenta between hot magenta and violet.
            #expect(cyclicDistance(sweep.origin(nearest: selection), 2.5 * anchorStep) < anchorStep, "\(scheme)")
            #expect(cyclicDistance(sweep.origin(nearest: screenshot), 0.5 * anchorStep) < anchorStep, "\(scheme)")
        }
    }

    @Test func onlyTheGatedOutlineDrawsTheLapSoTheRecordingOutlineSwitchRemovesIt() throws {
        for name in ["MiniRecorderView", "NotchRecorderView"] {
            let card = try source("VoiceInk/Views/Recorder/\(name).swift")
            let gate = try #require(card.range(of: "captureOutlineEnabled && stateProvider.showsRecordingActivityOutline"))
            let lap = try #require(card.range(of: "acceptancePulse: stateProvider.contextAcceptancePulse"))
            #expect(gate.upperBound < lap.lowerBound, "\(name)")
            #expect(card.components(separatedBy: "contextAcceptancePulse").count == 2, "\(name)")
        }
        // The leaf adds no clock: the lap reads the existing 30 Hz timeline, and only
        // Reduce Motion's bounded hold uses a task keyed to the pulse.
        let outline = try source("VoiceInk/Views/Recorder/RecorderCaptureOutline.swift")
        #expect(outline.components(separatedBy: "TimelineView(").count == 2)
        #expect(!outline.contains("Timer"))
        #expect(outline.contains(".task(id: acceptancePulse?.id)"))
        // One launch site, inside the accepted-context boundary.
        let session = try source("VoiceInk/Transcription/Engine/RecordingSession.swift")
        #expect(session.components(separatedBy: "acknowledgeAcceptedContext(").count == 3)
        #expect(session.components(separatedBy: "contextAcceptancePulse = ").count == 2)
        let boundary = try #require(session.range(of: "func recordLiveSelection("))
        let call = try #require(session.range(of: "acknowledgeAcceptedContext(reference, precedesSpeech: precedesSpeech)"))
        let attach = try #require(session.range(of: "func attachLiveSelectionImage("))
        #expect(boundary.upperBound < call.lowerBound && call.upperBound < attach.lowerBound)
    }

    @Test @MainActor func lapPaintsTheBorderThenHandsBackTheSameRainbow() async throws {
        // Two isolated leaves side by side, one without a pulse. Comparing them at
        // the same moment separates the lap from the rainbow's own flow. — Claude Opus 5.5
        let size = CGSize(width: 500, height: 80)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/lap.png")))
        for reduced in [false, true] {
            // The moving lap starts just after mounting, so the first capture is mid-lap.
            let pulse = try #require(RecorderContextAcceptancePulse(
                accepting: screenshot, at: Date().addingTimeInterval(reduced ? 0 : 0.15)))
            let plain = OutlineLeafHost(shape: shape, size: size, origin: CGPoint(x: 0, y: 0),
                                        pulse: nil, reduced: reduced)
            let acknowledged = OutlineLeafHost(shape: shape, size: size, origin: CGPoint(x: 0, y: 120),
                                               pulse: pulse, reduced: reduced)
            defer { plain.close(); acknowledged.close() }
            let label = "Reduce Motion=\(reduced)"

            // Mid-lap for motion; well inside the still hold for Reduce Motion.
            try await Task.sleep(for: .milliseconds(reduced ? 250 : 500))
            let lapFrame = try acknowledged.capture()
            let during = try EdgeComparison(plain.capture(), lapFrame)
            #expect(during.edgePixels > 100, "\(label)")
            #expect(during.differingFraction > (reduced ? 0.4 : 0.1), "\(label): \(during.differingFraction)")
            if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let image = try #require(acknowledged.capture().representation(using: .png, properties: [:]))
                try image.write(to: folder.appendingPathComponent("context-lap-\(reduced ? "still" : "flow")-during.png"))
            }
            if reduced {
                // Still means still: no movement while the colour is held.
                let first = try acknowledged.capture()
                try await Task.sleep(for: .milliseconds(120))
                let held = try EdgeComparison(first, acknowledged.capture())
                #expect(held.differingFraction < 0.01, "\(label): \(held.differingFraction)")
            }

            // Observe the requested second animated cycle, then its natural end.
            // Reduce Motion retains its existing bounded static hold.
            // — GPT-6.1 Sol
            try await Task.sleep(for: .milliseconds(reduced ? 600 : 1_000))
            let lateFrame = try acknowledged.capture()
            let late = try EdgeComparison(plain.capture(), lateFrame)
            #expect(late.edgePixels > 100, "\(label)")
            #expect(late.differingFraction > (reduced ? 0.4 : 0.1), "\(label): extra cycle \(late.differingFraction)")
            if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                let data = try #require(lateFrame.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "context-lap-\(reduced ? "still" : "flow")-late-hold.png"))
            }
            try await Task.sleep(for: .milliseconds(reduced ? 700 : 800))
            let after = try EdgeComparison(plain.capture(), acknowledged.capture())
            #expect(after.edgePixels > 100, "\(label)")
            #expect(after.differingFraction < 0.01, "\(label): \(after.differingFraction)")

            if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try #require(lapFrame.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("context-lap-\(reduced ? "still" : "flow")-during.png"))
            }
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

/// One isolated outline leaf on a black card in its own non-activating panel.
/// Panels never overlap, so neither window is occluded and both clocks keep
/// running. — Claude Opus 5.5
@MainActor private final class OutlineLeafHost {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>

    init(shape: RoundedRectangle, size: CGSize, origin: CGPoint,
         pulse: RecorderContextAcceptancePulse?, reduced: Bool) {
        let root = RecorderCaptureOutline(shape: shape, acceptancePulse: pulse, reduceMotionForPreview: reduced)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .clipShape(shape)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: AnyView(root))
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func capture() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// Compares two renders of the same outline geometry. Only lit pixels count, so
/// the black interior shared by both cannot dilute the result. — Claude Opus 5.5
private struct EdgeComparison {
    var edgePixels = 0
    var differingPixels = 0

    var differingFraction: Double {
        edgePixels == 0 ? 0 : Double(differingPixels) / Double(edgePixels)
    }

    init(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws {
        try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh)
        for y in stride(from: 0, to: a.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let brightest = max(p.redComponent, p.greenComponent, p.blueComponent,
                                    q.redComponent, q.greenComponent, q.blueComponent)
                guard brightest > 0.25 else { continue }
                edgePixels += 1
                let difference = abs(p.redComponent - q.redComponent)
                    + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent)
                if difference > 0.25 { differingPixels += 1 }
            }
        }
    }
}
