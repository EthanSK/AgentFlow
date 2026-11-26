// Proves the Recording Outline's accepted-context acknowledgement with synthetic
// sessions and isolated outline leaves only. Nothing here starts capture, reads a
// real selection, takes a screenshot, plays media, changes focus or touches
// Primary/Next delivery. File URLs are never opened; references only carry their
// paths. — Claude Opus 5.5
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
            form: .lap(.init(head: 0, tail: 0, strength: 0, spark: 1)))
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

    /// The entrance: the colour grows clockwise out of its own rainbow band, with a
    /// spark on its head, and the rainbow ahead of it is untouched. — Claude Opus 5.5
    @Test func colourGrowsFromItsBandRoundTheWholeOutlineAndLandsThere() throws {
        let sweep = RecorderContextSweep.self
        let anchorStep = 1 / Double(RecorderNeonSpectrum.anchors.count)
        let blueOrigin = sweep.origin(nearest: blue)
        let magentaOrigin = sweep.origin(nearest: magenta)
        // Ethan's "where the blue currently is": between laser blue and neon cyan.
        // The screenshot colour starts between hot magenta and electric violet.
        #expect(blueOrigin > 2 * anchorStep && blueOrigin < 3 * anchorStep, "\(blueOrigin)")
        #expect(magentaOrigin > 0 && magentaOrigin < anchorStep, "\(magentaOrigin)")
        for (tint, origin) in [(blue, blueOrigin), (magenta, magentaOrigin)] {
            let best = sweep.squaredDistance(RecorderNeonSpectrum.components(at: origin), tint)
            for index in 0..<700 {
                let position = Double(index) / 700
                #expect(sweep.squaredDistance(RecorderNeonSpectrum.components(at: position), tint) >= best - 1e-3)
            }
        }

        // Nothing before the start or from the end: the plain rainbow, no clock to clear.
        let start = Date(timeIntervalSince1970: 1_000)
        let highlight = try #require(LiveSelectionReference("x"))
        let pulse = try #require(RecorderContextAcceptancePulse(accepting: highlight, at: start))
        #expect(pulse.replaced == nil)
        #expect(sweep.acknowledgement(for: nil, at: start) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(-0.01)) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(sweep.duration)) == nil)
        #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(0.5))?.kind == .selection)
        #expect(sweep.duration == sweep.entranceDuration + sweep.holdDuration + sweep.exitDuration)

        // One continuous curve: the head goes round once and closes the ring, the
        // whole stroke holds, then the tail goes round once. Neither edge reverses
        // or restarts, and the tail never passes the head.
        let exitStarts = sweep.entranceDuration + sweep.holdDuration
        var previous = sweep.lap(atElapsed: 0)
        #expect(previous.head == 0 && previous.tail == 0 && previous.strength == 0 && previous.spark == 1)
        for step in 1...520 {
            // Sample the exact endpoint, not a multiply/divide rounding below it.
            // The production Date deadline is checked separately. — GPT-6.1 Sol
            let elapsed = step == 520 ? sweep.duration : sweep.duration * Double(step) / 520
            let lap = sweep.lap(atElapsed: elapsed)
            #expect(lap.head >= previous.head && lap.tail >= previous.tail && lap.tail <= lap.head, "\(elapsed)")
            #expect(lap.strength >= 0 && lap.strength <= 1, "\(elapsed)")
            #expect(lap.spark >= 0 && lap.spark <= previous.spark, "\(elapsed)")
            if elapsed >= sweep.entranceDuration { #expect(lap.head == 1, "\(elapsed)") }
            if elapsed <= exitStarts { #expect(lap.tail == 0, "\(elapsed)") }
            previous = lap
        }
        #expect(previous.head == 1 && abs(previous.tail - 1) < 1e-9)
        #expect(previous.strength == 0 && previous.spark == 0)
        let halfway = sweep.lap(atElapsed: sweep.entranceDuration / 2)
        #expect(abs(halfway.head - 0.5) < 1e-12 && halfway.tail == 0 && halfway.strength == 1)

        for (tint, origin) in [(blue, blueOrigin), (magenta, magentaOrigin)] {
            let paint = RecorderContextSweepPaint(tint: tint, form: .lap(halfway))
            #expect(paint.origin == origin)
            // Inside the growing arc: the transcript colour, at most lightened by its
            // flowing sheen. Never a rainbow colour.
            for offset in stride(from: 0.06, through: 0.44, by: 0.02) {
                let shade = try #require(whiteness(of: paint.components(at: origin + offset), over: tint),
                                         "\(offset)")
                #expect(shade <= sweep.sheenWhiteness + 1e-9, "\(offset)")
            }
            // Ahead of the head and its spark, and before the launch band's soft
            // trailing edge, the rainbow is untouched, bit for bit.
            for offset in stride(from: 0.56, through: 0.88, by: 0.02) {
                #expect(paint.components(at: origin + offset)
                    == RecorderNeonSpectrum.components(at: origin + offset), "\(offset)")
            }
            // A white-hot spark rides the head.
            let head = paint.components(at: origin + halfway.head)
            #expect(min(head.red, head.green, head.blue) > min(tint.red, tint.green, tint.blue) + 0.2)

            // Early on, only the stretch beside the launch band changes.
            let early = RecorderContextSweepPaint(tint: tint,
                form: .lap(sweep.lap(atElapsed: 0.12 * sweep.entranceDuration)))
            for index in 0..<144 {
                let offset = Double(index) / 144
                guard offset > 0.2, offset < 0.8 else { continue }
                #expect(early.components(at: origin + offset) == RecorderNeonSpectrum.components(at: origin + offset))
            }

            // Launch and landing fade from and to nothing, so neither end jumps.
            for elapsed in [0.001, sweep.duration - 0.001] {
                let edge = RecorderContextSweepPaint(tint: tint, form: .lap(sweep.lap(atElapsed: elapsed)))
                for index in 0..<144 {
                    let position = Double(index) / 144
                    let actual = position + 0.35
                    let distance = sweep.squaredDistance(edge.components(at: position, rainbowPosition: actual),
                                                         RecorderNeonSpectrum.components(at: actual))
                    #expect(distance < 1e-4, "elapsed \(elapsed) position \(position)")
                }
            }
        }
    }

    /// Formerly wholeStrokeHoldsTheContextColourForOverASecondWithoutARainbowGap:
    /// Ethan approved the fill/hold/exit, then requested half its full-colour hold.
    /// Measured from the production paint's actual output
    /// colours every 2 ms: a stop shows rainbow only if its painted colour changes
    /// when the rainbow beneath it does. The rejected two-lap replay fails here,
    /// because the rainbow came back between its cycles. — Claude Opus 5.5; GPT-6.1 Sol
    @Test func wholeStrokeHoldsTheContextColourContinuouslyWithoutARainbowGap() throws {
        let sweep = RecorderContextSweep.self
        let start = Date(timeIntervalSince1970: 3_000)
        let exitStarts = sweep.entranceDuration + sweep.holdDuration
        let positions = (0..<72).map { Double($0) / 72 }
        let step = 0.002
        let samples = Int((sweep.duration / step).rounded(.up))
        let whiteLimit = max(sweep.sparkWhiteness, sweep.sheenWhiteness) + 1e-9
        let references = [
            try #require(LiveSelectionReference("whole stroke")),
            try #require(LiveSelectionReference(screenshotURL: URL(
                fileURLWithPath: "/tmp/AgentFlowTests/whole-stroke.png")))
        ]
        for (reference, tint) in zip(references, [blue, magenta]) {
            let pulse = try #require(RecorderContextAcceptancePulse(accepting: reference, at: start))
            let label = "\(pulse.kind)"
            var previous = [Double](repeating: 1, count: positions.count)
            var becameOpaque = [Bool](repeating: false, count: positions.count)
            var regressions: [String] = []
            var coveredTimes: [Double] = []
            var runStart: Double?
            var longestRun = 0.0
            var partialEntrance = false
            var partialExit = false
            for sample in 0..<samples {
                let elapsed = Double(sample) * step
                guard elapsed < sweep.duration else { break }
                let shown = try #require(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(elapsed)))
                let paint = RecorderContextSweepPaint(tint: tint, form: shown.form)
                let shares = positions.map { rainbowShare(paint, at: $0) }
                // Once ink fully covers a stop, no rainbow can return before exit.
                // Before that, the moving white spark can vary a soft edge's tiny
                // remaining rainbow share without being a reset. The native trace
                // exposed that distinction. Found and fixed by GPT-6.1 Sol.
                for index in positions.indices where regressions.count < 5 {
                    let regressed = elapsed <= exitStarts
                        ? becameOpaque[index] && shares[index] > 1e-7
                        : shares[index] < previous[index] - 1e-7
                    if regressed {
                        regressions.append("t=\(elapsed) p=\(positions[index]) \(previous[index])->\(shares[index])")
                    }
                    if shares[index] == 0 { becameOpaque[index] = true }
                }
                previous = shares
                let covered = shares.allSatisfy { $0 == 0 } && positions.allSatisfy { position in
                    whiteness(of: paint.components(at: position), over: tint).map { $0 <= whiteLimit } ?? false
                }
                if covered {
                    coveredTimes.append(elapsed)
                    let began = runStart ?? elapsed
                    runStart = began
                    longestRun = max(longestRun, elapsed - began)
                } else {
                    runStart = nil
                }
                let coloured = shares.filter { $0 < 0.01 }.count
                let rainbow = shares.filter { $0 > 0.99 }.count
                if coloured > 10 && rainbow > 10 {
                    if elapsed < sweep.entranceDuration { partialEntrance = true }
                    if elapsed > exitStarts { partialExit = true }
                }
            }
            #expect(regressions.isEmpty, "\(label): \(regressions)")
            #expect(longestRun >= 0.58 && longestRun < 0.8,
                    "\(label): shortened whole-stroke colour lasted \(longestRun)s")
            // Feathered edges may finish coverage slightly before the head closes
            // and keep it slightly into exit. Require the entire nominal hold,
            // one uninterrupted run, and genuine partial entrance/exit frames;
            // do not require unfeathered timing. Found and fixed by GPT-6.1 Sol.
            let first = try #require(coveredTimes.first)
            let last = try #require(coveredTimes.last)
            #expect(abs(longestRun - (last - first)) < 1e-9, "\(label): one run only")
            #expect(first > 0 && first <= sweep.entranceDuration + step
                && last >= exitStarts - step && last < sweep.duration, "\(label) \(first)...\(last)")
            #expect(partialEntrance && partialExit, "\(label)")
            #expect(sweep.acknowledgement(for: pulse, at: start.addingTimeInterval(sweep.duration)) == nil)

            // The held colour is exactly the transcript colour at its launch band
            // and only gently lighter at its sheen.
            let settledShown = try #require(sweep.acknowledgement(for: pulse,
                at: start.addingTimeInterval(sweep.entranceDuration + 0.5)))
            let settled = RecorderContextSweepPaint(tint: tint, form: settledShown.form)
            #expect(settled.components(at: settled.origin) == tint, "\(label)")
            let peak = try #require(whiteness(of: settled.components(at: settled.origin + 0.5), over: tint))
            #expect(abs(peak - sweep.sheenWhiteness) < 1e-9, "\(label)")

            // It still travels: the lighter band rides the rainbow's own flow round
            // the border, measured where the outline actually draws each stop.
            func brightestPlace(at elapsed: Double) throws -> Double {
                let date = start.addingTimeInterval(elapsed)
                let shown = try #require(sweep.acknowledgement(for: pulse, at: date))
                let paint = RecorderContextSweepPaint(tint: tint, form: shown.form)
                let phase = RecorderCaptureOutlineStyle.flowPhase(at: date)
                var best = (place: 0.0, shade: -1.0)
                for index in 0..<720 {
                    let place = Double(index) / 720
                    let colour = paint.components(at: place - phase, rainbowPosition: place - phase)
                    let shade = try #require(whiteness(of: colour, over: tint), "\(place)")
                    if shade > best.shade { best = (place, shade) }
                }
                return best.place
            }
            // Sample the settled sheen inside the shortened hold, before exit.
            // The old fixed 1.0s offset belonged to the former 1.2s hold. — GPT-6.1 Sol
            let earlierTime = sweep.entranceDuration + sweep.holdDuration * 0.55
            let laterTime = sweep.entranceDuration + sweep.holdDuration * 0.95
            let earlier = try brightestPlace(at: earlierTime)
            let later = try brightestPlace(at: laterTime)
            let travelled = (later - earlier) - (later - earlier).rounded(.down)
            #expect(abs(travelled - (laterTime - earlierTime) / RecorderCaptureOutlineStyle.lapDuration) < 0.01,
                    "\(label) \(travelled)")
        }
    }

    /// Ethan often highlights again while the blue is still showing. The newer
    /// gesture still replaces the older one at once, but its entrance paints over
    /// the older colour instead of first dropping back to the rainbow. — Claude Opus 5.5
    @Test func aSecondContextPaintsOverTheFirstWithoutARainbowGap() throws {
        let sweep = RecorderContextSweep.self
        let start = Date(timeIntervalSince1970: 4_000)
        let exitStarts = sweep.entranceDuration + sweep.holdDuration
        let positions = (0..<72).map { Double($0) / 72 }
        let highlight = try #require(LiveSelectionReference("first highlight"))
        let first = try #require(RecorderContextAcceptancePulse(accepting: highlight, at: start))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/second.png")))

        // Nothing to carry from no pulse, a finished one, or one still invisible.
        #expect(first.replacing(nil).replaced == nil)
        let afterwards = try #require(RecorderContextAcceptancePulse(accepting: screenshot,
            at: start.addingTimeInterval(sweep.duration + 0.1)))
        #expect(afterwards.replacing(first).replaced == nil)
        let simultaneous = try #require(RecorderContextAcceptancePulse(accepting: screenshot, at: start))
        #expect(simultaneous.replacing(first).replaced == nil)

        let handover = start.addingTimeInterval(sweep.entranceDuration + 0.5)
        let anotherHighlight = try #require(LiveSelectionReference("second highlight"))
        for (reference, tint) in [(screenshot, magenta), (anotherHighlight, blue)] {
            let second = try #require(RecorderContextAcceptancePulse(accepting: reference, at: handover))
                .replacing(first)
            let label = "\(second.kind) over selection"
            let carried = try #require(second.replaced)
            #expect(carried.kind == .selection)
            #expect(carried.lap == RecorderContextSweep.Lap(head: 1, tail: 0, strength: 1, spark: 0))
            #expect(second.id != first.id)

            // The handover frame, and a frame stamped a moment earlier, show the
            // first colour exactly as it was. No jump, no rainbow flash.
            let before = try #require(sweep.acknowledgement(for: first, at: handover))
            let beforePaint = RecorderContextSweepPaint(tint: blue, form: before.form)
            for frame in [handover, handover.addingTimeInterval(-0.01)] {
                let shown = try #require(sweep.acknowledgement(for: second, at: frame))
                let shownPaint = paint(for: shown, tint: tint)
                for position in positions {
                    #expect(shownPaint.components(at: position, rainbowPosition: position + 0.35)
                        == beforePaint.components(at: position, rainbowPosition: position + 0.35), "\(label)")
                }
            }

            // Through the new entrance and hold, every stop shows one of the two
            // context colours. The rainbow returns only with the new exit.
            var leaks: [String] = []
            for sample in 0...Int((exitStarts / 0.005).rounded(.down)) {
                let elapsed = Double(sample) * 0.005
                let shown = try #require(sweep.acknowledgement(for: second, at: handover.addingTimeInterval(elapsed)))
                let shownPaint = paint(for: shown, tint: tint)
                for position in positions where leaks.count < 5 && rainbowShare(shownPaint, at: position) != 0 {
                    leaks.append("t=\(elapsed) p=\(position)")
                }
            }
            #expect(leaks.isEmpty, "\(label): \(leaks)")

            // The second gesture is still visibly acknowledged: its spark travels
            // round over the first colour, which remains ahead of the new head.
            let middle = try #require(sweep.acknowledgement(for: second,
                at: handover.addingTimeInterval(sweep.entranceDuration / 2)))
            #expect(middle.underlay?.kind == .selection)
            let middlePaint = paint(for: middle, tint: tint)
            let spark = middlePaint.components(at: middlePaint.origin + 0.5)
            #expect(min(spark.red, spark.green, spark.blue) > min(tint.red, tint.green, tint.blue) + 0.2, "\(label)")
            #expect(whiteness(of: middlePaint.components(at: middlePaint.origin + 0.7), over: blue) != nil, "\(label)")

            // The new exit reveals the rainbow itself, never the replaced colour.
            let leaving = try #require(sweep.acknowledgement(for: second,
                at: handover.addingTimeInterval(exitStarts + sweep.exitDuration / 2)))
            #expect(leaving.underlay == nil)
            let leavingPaint = paint(for: leaving, tint: tint)
            for offset in stride(from: 0.06, through: 0.38, by: 0.02) {
                let position = leavingPaint.origin + offset
                #expect(leavingPaint.components(at: position) == RecorderNeonSpectrum.components(at: position),
                        "\(label) \(offset)")
            }
        }
    }

    /// Keep an already filled border coloured through several rapid replacements,
    /// including a replacement whose own entrance has barely begun. A two-event
    /// check alone misses losing the older fully coloured background. — GPT-6.1 Sol
    @Test func repeatedContextsKeepTheAlreadyColouredBackground() throws {
        let start = Date(timeIntervalSinceReferenceDate: 12_345.125)
        let highlight = try #require(LiveSelectionReference("rapid context"))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/rapid-context.png")))
        for alternating in [false, true] {
            var previous = try #require(RecorderContextAcceptancePulse(accepting: highlight, at: start))
            for index in 0..<6 {
                let reference = alternating && index.isMultiple(of: 2) ? screenshot : highlight
                let date = start.addingTimeInterval(1.2 + Double(max(0, index - 1)) * 0.1)
                let pulse = try #require(RecorderContextAcceptancePulse(accepting: reference, at: date))
                    .replacing(previous)
                let shown = try #require(RecorderContextSweep.acknowledgement(for: pulse, at: date))
                let painted = paint(for: shown, tint: reference.isScreenshot ? magenta : blue)
                let leaks = (0..<72).filter { rainbowShare(painted, at: Double($0) / 72) > 1e-9 }
                #expect(leaks.isEmpty, "replacement \(index), mixed=\(alternating), leaked stops=\(leaks.count)")
                previous = pulse
            }
        }
    }

    /// Fractional animation lifetimes expire at the Date deadline itself, even
    /// when subtracting two Date values rounds the elapsed interval down.
    /// Uses the same representable-deadline contract as Reduce Motion. — GPT-6.1 Sol
    @Test func acknowledgementExpiresAtItsRepresentableDeadline() throws {
        let reference = try #require(LiveSelectionReference("deadline"))
        for start in [Date(timeIntervalSinceReferenceDate: 100),
                      Date(timeIntervalSinceReferenceDate: 12_345.125), Date()] {
            let pulse = try #require(RecorderContextAcceptancePulse(accepting: reference, at: start))
            let deadline = start.addingTimeInterval(RecorderContextSweep.duration)
            #expect(RecorderContextSweep.acknowledgement(for: pulse, at: deadline) == nil)
            #expect(RecorderContextSweep.underlay(freezing: pulse, at: deadline) == nil)
            #expect(RecorderContextSweep.acknowledgement(for: pulse,
                at: deadline.addingTimeInterval(-0.001)) != nil)
        }
    }

    @Test func reduceMotionHoldsOneStillColourBrieflyAndAlwaysEnds() throws {
        let sweep = RecorderContextSweep.self
        let start = Date(timeIntervalSince1970: 2_000)
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/still.png")))
        let pulse = try #require(RecorderContextAcceptancePulse(accepting: screenshot, at: start))
        #expect(pulse.kind == .screenshot)
        #expect(sweep.stillDuration == 0.6 && sweep.stillDuration == sweep.holdDuration)
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
            // Each colour launches from its own band: blue between laser blue and
            // cyan, magenta between hot magenta and violet.
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
        // The leaf adds no clock: the acknowledgement reads the existing 30 Hz
        // timeline, and only Reduce Motion's bounded hold uses a task keyed to the pulse.
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

    /// The real outline leaf on the real clock, beside an identical leaf without a
    /// pulse. Comparing them at the same moment separates the acknowledgement from
    /// the rainbow's own flow. — Claude Opus 5.5
    @Test @MainActor func lapPaintsTheBorderThenHandsBackTheSameRainbow() async throws {
        let size = CGSize(width: 500, height: 80)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/lap.png")))
        let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"]
        for reduced in [false, true] {
            // The moving acknowledgement starts just after mounting, so the first
            // capture lands in its entrance.
            let pulse = try #require(RecorderContextAcceptancePulse(
                accepting: screenshot, at: Date().addingTimeInterval(reduced ? 0 : 0.15)))
            let plain = OutlineLeafHost(shape: shape, size: size, origin: CGPoint(x: 0, y: 0),
                                        pulse: nil, reduced: reduced)
            let acknowledged = OutlineLeafHost(shape: shape, size: size, origin: CGPoint(x: 0, y: 120),
                                               pulse: pulse, reduced: reduced)
            defer { plain.close(); acknowledged.close() }
            let label = "Reduce Motion=\(reduced)"
            func save(_ frame: NSBitmapImageRep, _ name: String) throws {
                guard let directory else { return }
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try #require(frame.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent(
                    "context-lap-\(reduced ? "still" : "flow")-\(name).png"))
            }

            // About 0.35s in: the entrance for motion; inside the still hold otherwise.
            try await Task.sleep(for: .milliseconds(reduced ? 250 : 500))
            let entranceFrame = try acknowledged.capture()
            let during = try EdgeComparison(plain.capture(), entranceFrame)
            #expect(during.edgePixels > 100, "\(label)")
            #expect(during.differingFraction > (reduced ? 0.4 : 0.1), "\(label): \(during.differingFraction)")
            try save(entranceFrame, "during")
            if reduced {
                // Still means still: no movement while the colour is held.
                let first = try acknowledged.capture()
                try await Task.sleep(for: .milliseconds(120))
                let held = try EdgeComparison(first, acknowledged.capture())
                #expect(held.differingFraction < 0.01, "\(label): \(held.differingFraction)")
            }

            // About 0.95s in: the whole stroke holds the screenshot colour. Only the
            // rainbow's own near-magenta stretch can still match the plain leaf.
            try await Task.sleep(for: .milliseconds(reduced ? 50 : 600))
            let holdFrame = try acknowledged.capture()
            let hold = try EdgeComparison(plain.capture(), holdFrame)
            #expect(hold.edgePixels > 100, "\(label)")
            #expect(hold.differingFraction > (reduced ? 0.4 : 0.5), "\(label): hold \(hold.differingFraction)")
            try save(holdFrame, "hold")

            // After the 2s acknowledgement (0.6s still hold): the same rainbow.
            try await Task.sleep(for: .milliseconds(reduced ? 700 : 1_600))
            let after = try EdgeComparison(plain.capture(), acknowledged.capture())
            #expect(after.edgePixels > 100, "\(label)")
            #expect(after.differingFraction < 0.01, "\(label): \(after.differingFraction)")
        }
    }

    /// The real outline leaf at exact frame times on the Mini and Notch silhouettes,
    /// for both colours: a travelling entrance, the entire visible stroke in the
    /// context colour at five moments across the shortened hold, a travelling exit,
    /// then pixel-identical rainbow. A screenshot replacing a held highlight never
    /// shows the rainbow either. With VIPP_OUTLINE_SNAPSHOT_DIR set it also exports
    /// a 0.1s frame sequence and a contact sheet for visual review. — Claude Opus 5.5; GPT-6.1 Sol
    @Test(arguments: [false, true]) @MainActor
    func nativeFramesFillTheWholeStrokeHoldItThenReturnTheRainbow(notch: Bool) async throws {
        enum Check { case sequence, partial, full, restored }
        let sweep = RecorderContextSweep.self
        let entrance = sweep.entranceDuration
        let exitStarts = entrance + sweep.holdDuration
        let size = CGSize(width: 500, height: 80)
        let shapeName = notch ? "notch" : "mini"
        let start = Date(timeIntervalSinceReferenceDate: 12_345.125)
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        let selectionTint = sweep.components(of: RecorderContextColor.selection, in: environment)
        let screenshotTint = sweep.components(of: RecorderContextColor.screenshot, in: environment)
        let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"]
        let folder = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let host = ControlledOutlineHost(notch: notch, size: size)
        defer { host.close() }
        let highlight = try #require(LiveSelectionReference("native fill"))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(
            fileURLWithPath: "/tmp/AgentFlowTests/native-fill.png")))

        for (reference, tint, name) in [(highlight, selectionTint, "selection"),
                                        (screenshot, screenshotTint, "screenshot")] {
            let pulse = try #require(RecorderContextAcceptancePulse(accepting: reference, at: start))
            let label = "\(shapeName) \(name)"
            let after = sweep.duration + 0.05
            let plain = try await host.render(nil, at: start.addingTimeInterval(after))
            let plainReading = ContextPixelReading(plain, tints: [tint])
            #expect(plainReading.lit > 300, "\(label)")
            // The classifier really separates the rainbow from the context colour.
            #expect(plainReading.contextFraction < 0.4, "\(label) plain \(plainReading.contextFraction)")

            var frames: [(name: String, elapsed: Double, check: Check)] = [
                ("entrance", entrance / 2, .partial),
                ("exit", exitStarts + sweep.exitDuration / 2, .partial),
                ("after", after, .restored)
            ]
            frames += [entrance + 0.02, entrance + sweep.holdDuration * 0.25,
                       entrance + sweep.holdDuration * 0.5, entrance + sweep.holdDuration * 0.75,
                       exitStarts - 0.02]
                .map { (name: "hold", elapsed: $0, check: Check.full) }
            if folder != nil {
                frames += stride(from: 0.0, through: sweep.duration, by: 0.1)
                    .map { (name: "sequence", elapsed: $0, check: Check.sequence) }
            }
            frames.sort { $0.elapsed < $1.elapsed }

            var sheet: [NSBitmapImageRep] = []
            for (index, frame) in frames.enumerated() {
                let bitmap = try await host.render(pulse, at: start.addingTimeInterval(frame.elapsed))
                let reading = ContextPixelReading(bitmap, tints: [tint])
                let moment = "\(label) \(frame.name) t=\(frame.elapsed)"
                // The black interior stays black: no glow or gradient into the panel.
                let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
                #expect(max(middle.redComponent, middle.greenComponent, middle.blueComponent) < 0.02, "\(moment)")
                switch frame.check {
                case .full:
                    // Every visible stop is the context colour; the stroke keeps its width.
                    #expect(reading.contextFraction >= 0.97, "\(moment): \(reading.contextFraction)")
                    #expect(abs(reading.lit - plainReading.lit) * 7 <= plainReading.lit,
                            "\(moment): lit \(reading.lit) vs \(plainReading.lit)")
                case .partial:
                    // Animated: both the colour and the rainbow are visible. The
                    // Notch hides its top run, so only loose visible shares apply;
                    // the exact curve is proven by the paint tests above.
                    #expect(reading.contextFraction > 0.05 && reading.contextFraction < 0.95,
                            "\(moment): \(reading.contextFraction)")
                case .restored:
                    let comparison = try EdgeComparison(plain, bitmap)
                    #expect(comparison.differingFraction < 0.01, "\(moment): \(comparison.differingFraction)")
                case .sequence:
                    break
                }
                sheet.append(bitmap)
                if let folder {
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: folder.appendingPathComponent(String(format: "context-fill-%@-%@-%02ld-%@-%.2fs.png",
                        shapeName, name, index, frame.name, frame.elapsed)))
                }
            }

            if reference.isScreenshot {
                // A screenshot accepted while the highlight's blue is held paints its
                // magenta over that blue. No visible stop returns to the rainbow.
                let earlier = try #require(RecorderContextAcceptancePulse(accepting: highlight,
                    at: start.addingTimeInterval(-(entrance + 0.5))))
                let over = pulse.replacing(earlier)
                #expect(over.replaced?.kind == .selection)
                for (step, elapsed) in [("handover", 0.0), ("painting-over", entrance / 2),
                                        ("replaced-hold", entrance + 0.6)] {
                    let bitmap = try await host.render(over, at: start.addingTimeInterval(elapsed))
                    let reading = ContextPixelReading(bitmap, tints: [selectionTint, screenshotTint])
                    let moment = "\(label) \(step)"
                    switch step {
                    case "handover":
                        #expect(reading.fraction(of: 0) >= 0.97, "\(moment): blue \(reading.fraction(of: 0))")
                    case "painting-over":
                        #expect(reading.contextFraction >= 0.9, "\(moment): \(reading.contextFraction)")
                        #expect(reading.fraction(of: 0) > 0.1 && reading.fraction(of: 1) > 0.1,
                                "\(moment): blue \(reading.fraction(of: 0)) magenta \(reading.fraction(of: 1))")
                    default:
                        #expect(reading.fraction(of: 1) >= 0.97, "\(moment): magenta \(reading.fraction(of: 1))")
                    }
                    sheet.append(bitmap)
                    if let folder {
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: folder.appendingPathComponent(
                            "context-fill-\(shapeName)-replacement-\(step).png"))
                    }
                }
            }

            if let folder, let contact = contactSheet(sheet),
               let data = contact.representation(using: .png, properties: [:]) {
                try data.write(to: folder.appendingPathComponent("context-fill-\(shapeName)-\(name)-sheet.png"))
            }
        }
    }

    // MARK: - Helpers

    /// How much of the rainbow still shows at `position`, 0...1, taken from the
    /// paint's actual output: the same stop is painted over two different rainbow
    /// colours, and the share of that difference that survives is the rainbow's.
    /// Zero means the stop shows only the context colour. — Claude Opus 5.5
    private func rainbowShare(_ paint: RecorderContextSweepPaint, at position: Double) -> Double {
        let one = position + 0.31
        let other = position + 0.63
        let painted = RecorderContextSweep.squaredDistance(paint.components(at: position, rainbowPosition: one),
                                                           paint.components(at: position, rainbowPosition: other))
        let rainbow = RecorderContextSweep.squaredDistance(RecorderNeonSpectrum.components(at: one),
                                                           RecorderNeonSpectrum.components(at: other))
        return (painted / rainbow).squareRoot()
    }

    /// The amount of white mixed into `tint` to give `colour`, or nil when `colour`
    /// is not on that line: it then contains some other, rainbow colour. — Claude Opus 5.5
    private func whiteness(of colour: RecorderNeonSpectrum.Components,
                           over tint: RecorderNeonSpectrum.Components) -> Double? {
        let channels = [(colour.red, tint.red), (colour.green, tint.green), (colour.blue, tint.blue)]
        guard let room = channels.min(by: { $0.1 < $1.1 }), room.1 < 1 else { return nil }
        let amount = (room.0 - room.1) / (1 - room.1)
        let expected = RecorderContextSweepPaint.mix(tint, .init(red: 1, green: 1, blue: 1), amount)
        guard amount > -1e-9, RecorderContextSweep.squaredDistance(expected, colour) < 1e-18 else { return nil }
        return max(0, amount)
    }

    /// The outline's own paint for `shown`, resolving any replaced colour with these
    /// fixed test colours, exactly as the leaf builds it. — Claude Opus 5.5
    private func paint(for shown: RecorderContextSweep.Acknowledgement,
                       tint: RecorderNeonSpectrum.Components) -> RecorderContextSweepPaint {
        RecorderContextSweepPaint(tint: tint, form: shown.form, underlay: shown.underlay.map { older in
            RecorderContextSweepPaint.Layer(tint: older.kind == .selection ? blue : magenta, lap: older.lap,
                backgroundTint: older.backgroundKind.map { $0 == .selection ? blue : magenta })
        })
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

/// The real outline leaf drawn at exact frame times, on the Mini's rounded card or
/// the Notch's open U, each clipped by its own silhouette like the real cards. Dark
/// appearance fixes the system colours the classifier compares. — Claude Opus 5.5
@MainActor private final class ControlledOutlineHost {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private let notch: Bool
    private let size: CGSize

    init(notch: Bool, size: CGSize) {
        self.notch = notch
        self.size = size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AnyView(Color.black))
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func render(_ pulse: RecorderContextAcceptancePulse?, at date: Date) async throws -> NSBitmapImageRep {
        host.rootView = view(pulse, at: date)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func view(_ pulse: RecorderContextAcceptancePulse?, at date: Date) -> AnyView {
        if notch {
            let shape = NotchShape(topCornerRadius: 8, bottomCornerRadius: 16)
            return AnyView(RecorderCaptureOutline(shape: shape, omitsTopEdge: true, acceptancePulse: pulse,
                                                  reduceMotionForPreview: false, frameDateForPreview: date)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .clipShape(shape)
                .environment(\.colorScheme, .dark))
        }
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return AnyView(RecorderCaptureOutline(shape: shape, acceptancePulse: pulse,
                                              reduceMotionForPreview: false, frameDateForPreview: date)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .clipShape(shape)
            .environment(\.colorScheme, .dark))
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

/// Classifies a rendered outline's lit pixels. A pixel is context-coloured when it
/// lies on one of the context colours' lines toward white, the only colours a
/// covered stop may show, after scaling its brightest channel to 1 so antialiased
/// edges still count. Every other lit pixel shows a rainbow colour. — Claude Opus 5.5
private struct ContextPixelReading {
    var lit = 0
    var nearest: [Int]

    var contextFraction: Double {
        lit == 0 ? 0 : Double(nearest.reduce(0, +)) / Double(lit)
    }

    func fraction(of index: Int) -> Double {
        lit == 0 ? 0 : Double(nearest[index]) / Double(lit)
    }

    init(_ bitmap: NSBitmapImageRep, tints: [RecorderNeonSpectrum.Components]) {
        nearest = Array(repeating: 0, count: tints.count)
        let lines: [[[Double]]] = tints.map { tint in
            stride(from: 0.0, through: 0.6, by: 0.02).map { amount in
                Self.scaled([tint.red + (1 - tint.red) * amount,
                             tint.green + (1 - tint.green) * amount,
                             tint.blue + (1 - tint.blue) * amount])
            }
        }
        for y in 0..<bitmap.pixelsHigh {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let rgb = [Double(colour.redComponent), Double(colour.greenComponent), Double(colour.blueComponent)]
                guard (rgb.max() ?? 0) > 0.3 else { continue }
                lit += 1
                let shade = Self.scaled(rgb)
                var best = (index: -1, distance: Double.infinity)
                for (index, line) in lines.enumerated() {
                    for point in line {
                        let distance = zip(shade, point).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                        if distance < best.distance { best = (index, distance) }
                    }
                }
                if best.index >= 0, best.distance < 0.12 * 0.12 { nearest[best.index] += 1 }
            }
        }
    }

    static func scaled(_ rgb: [Double]) -> [Double] {
        let peak = max(rgb.max() ?? 0, 1e-6)
        return rgb.map { $0 / peak }
    }
}

/// Stacks rendered frames top to bottom for visual review. Inspection only:
/// nothing asserts on it. — Claude Opus 5.5
@MainActor private func contactSheet(_ frames: [NSBitmapImageRep]) -> NSBitmapImageRep? {
    guard let width = frames.map(\.pixelsWide).max(), width > 0 else { return nil }
    let gap = 6
    let height = frames.reduce(0) { $0 + $1.pixelsHigh } + gap * max(0, frames.count - 1)
    guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: sheet) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor(white: 0.3, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    var top = height
    for frame in frames {
        top -= frame.pixelsHigh
        _ = frame.draw(in: NSRect(x: 0, y: top, width: frame.pixelsWide, height: frame.pixelsHigh))
        top -= gap
    }
    return sheet
}
