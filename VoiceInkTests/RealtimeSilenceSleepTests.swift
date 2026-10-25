import Foundation
import AppKit
import SwiftUI
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

/// Plain test-owned destination: no recorder shortcut dispatch or app activation.
private final class SilenceSleepTypingTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// GPT Live silence sleep: network-stream omission during clearly quiet recording.
/// These fixtures use synthetic PCM only. They prove the local gate's decisions and
/// accounting; they do not prove OpenAI billing, idle-socket survival, or recognition
/// across a gap — those need the separate synthetic provider probe.
struct RealtimeSilenceSleepTests {
    /// Exercise native window/event dispatch with the actual SwiftUI HUD roots,
    /// rather than infer typing safety from a gate-only unit test. These windows
    /// belong to the Mini test host; no system input or live user app is targeted.
    @Test @MainActor func sleepWakeRepaintsPreserveExactTypingAndReleasedFocusInBothHUDStyles() async throws {
        func editor(in view: NSView) -> RecorderTypingTextView? {
            if let found = view as? RecorderTypingTextView { return found }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func settle(_ windows: [NSWindow]) async throws {
            for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let authored = "one key becomes one character"
        // Exercise RecordingSession's real focus controller and its real gates.
        // Refuse an unsuitable fixture environment instead of replacing that
        // wiring or changing the Mini user's preferences/mouse state.
        try #require(RecorderTypingFocus.automaticReturnEnabled(in: .standard))
        try #require(NSEvent.pressedMouseButtons == 0)
        for mini in [true, false] {
            for microphoneOff in [false, true] {
                for driveSleepChanges in [false, true] {
                    let session = RecordingSession()
                    session.microphoneOff = microphoneOff
                    session.showsRealtimeTranscriptHUD = true
                    let activity = ActivityCountingSession()
                    session.transcriptionSession = activity
                    var configuration = Self.fixtureConfiguration
                    configuration.trailingQuietSeconds = 0.04
                    configuration.activityHoldSeconds = 0
                    configuration.prerollSeconds = 0.02
                    let controller = RealtimeSilenceSleepController(configuration: configuration,
                        forward: { _ in }, withhold: { _ in },
                        onSleepingChange: { [weak session] sleeping, generation in
                            Task { @MainActor in
                                session?.applyRealtimeStreamSleeping(sleeping, generation: generation)
                            }
                        })
                    if driveSleepChanges { activity.onActivity = { controller.noteSessionActivity() } }
                    let recorder = Recorder()
                    let assistant = AssistantSession()
                    var panels: [NSPanel] = []
                    for offset in [0, 30] {
                        let frame = NSRect(x: 100 + offset, y: 100, width: 940, height: 220)
                        let panel: NSPanel = mini ? MiniRecorderPanel(contentRect: frame)
                            : NotchRecorderPanel(contentRect: frame)
                        let root: AnyView
                        if mini {
                            root = AnyView(MiniRecorderView(stateProvider: session,
                                liveTranscriptHeight: 120, liveTranscriptWidth: 900, recorder: recorder,
                                assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                                onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                        } else {
                            root = AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                                assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                                liveTranscriptHeight: 120, liveTranscriptWidth: 900,
                                onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {},
                                onAssistantFollowUp: { _ in }))
                        }
                        panel.contentView = NSHostingView(rootView: root.frame(width: 940, height: 220))
                        panel.orderFrontRegardless()
                        panels.append(panel)
                    }
                    // The test host can be inactive. A normal activating NSWindow
                    // cannot establish key ownership there; use a test-owned
                    // nonactivating panel with an ordinary, non-recorder editor.
                    let outside = SilenceSleepTypingTestPanel(contentRect: NSRect(x: 200, y: 200, width: 400, height: 100),
                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                    outside.isReleasedWhenClosed = false
                    let outsideEditor = NSTextView(frame: outside.contentView!.bounds)
                    outsideEditor.isRichText = false
                    outside.contentView = outsideEditor
                    defer {
                        session.typingFocus.disable(releaseKeyboard: false)
                        for panel in panels { panel.orderOut(nil); panel.close() }
                        outside.orderOut(nil)
                        outside.close()
                    }
                    try await settle(panels)
                    let active = try #require(editor(in: panels[0].contentView!))
                    let mirror = try #require(editor(in: panels[1].contentView!))
                    #expect(active !== mirror)
                    session.typingFocus.enable(active)
                    panels[0].makeKey()
                    #expect(panels[0].makeFirstResponder(active))
                    var expectedSleeping = false
                    func repaint() async throws {
                        if driveSleepChanges {
                            expectedSleeping.toggle()
                            let sleep = expectedSleeping
                            // Exercise the actual background-audio -> controller ->
                            // MainActor presentation hop. Short test timings force
                            // repeated transitions; the real ten-second policy has
                            // its own deterministic audio/wall-clock regression.
                            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                                DispatchQueue.global(qos: .userInitiated).async {
                                    if sleep {
                                        controller.receive(Data(count: 1_280))
                                        controller.receive(Data(count: 1_280))
                                    } else {
                                        controller.receive(TestPCM.data(Array(repeating: Int16(10_000), count: 320)))
                                    }
                                    done.resume()
                                }
                            }
                        }
                        // Read only the test-owned views while they redraw. This is
                        // bounded AppKit inspection, not a CUA/physical-key receipt.
                        _ = active.accessibilityValue()
                        _ = panels[0].accessibilityTitle()
                        try await settle(panels)
                        #expect(session.realtimeStreamSleeping == expectedSleeping)
                        #expect(session.showsRealtimeStreamSleepingBadge == (expectedSleeping && !microphoneOff))
                        #expect(editor(in: panels[0].contentView!) === active)
                        #expect(editor(in: panels[1].contentView!) === mirror)
                    }
                    func type(_ character: Character, in window: NSWindow) throws {
                        try #require(NSApp.keyWindow === window && window.isKeyWindow)
                        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: String(character),
                            charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
                        NSApp.sendEvent(event)
                    }
                    var expected = ""
                    for character in authored {
                        try await repaint()
                        try type(character, in: panels[0])
                        expected.append(character)
                        try await settle(panels)
                        #expect(active.string == expected)
                        #expect(mirror.string == expected)
                        #expect(session.typedInput == expected)
                        #expect(activity.activityCount == expected.count)
                        #expect(session.liveSelectionReferences.filter(\.isTypedText).isEmpty)
                        #expect(NSApp.keyWindow === panels[0] && panels[0].firstResponder === active)
                    }
                    outside.makeKeyAndOrderFront(nil)
                    #expect(outside.makeFirstResponder(outsideEditor))
                    try await settle(panels + [outside])
                    try #require(NSApp.keyWindow === outside && outside.firstResponder === outsideEditor)
                    for character in "outside" {
                        try await repaint()
                        try type(character, in: outside)
                        #expect(NSApp.keyWindow === outside && outside.firstResponder === outsideEditor)
                    }
                    #expect(outsideEditor.string == "outside")
                    #expect(session.typedInput.isEmpty && active.string.isEmpty && mirror.string.isEmpty)
                    let runs = session.liveSelectionReferences.filter(\.isTypedText)
                    #expect(runs.count == 1)
                    #expect(runs.first?.preview == authored)
                    #expect(activity.activityCount == authored.count)
                    // Give even the full production retry lifetime a chance to
                    // run. Sleep changes alone must not reclaim the keyboard.
                    try await Task.sleep(nanoseconds: 2_200_000_000)
                    #expect(NSApp.keyWindow === outside && outside.firstResponder === outsideEditor)
                    #expect(outsideEditor.string == "outside" && session.typedInput.isEmpty)
                    #expect(session.liveSelectionReferences.filter(\.isTypedText) == runs)
                    // Positive control: accepted context really does return focus
                    // for microphone-off typing. Speech mode leaves it outside.
                    session.recordLiveSelection(try #require(LiveSelectionReference("test-owned selected context")))
                    for _ in 0..<110 {
                        if microphoneOff, NSApp.keyWindow === panels[0], panels[0].firstResponder === active { break }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    if microphoneOff {
                        #expect(NSApp.keyWindow === panels[0] && panels[0].firstResponder === active)
                    } else {
                        #expect(NSApp.keyWindow === outside && outside.firstResponder === outsideEditor)
                    }
                    #expect(outsideEditor.string == "outside")
                    #expect(session.liveSelectionReferences.filter(\.isTypedText) == runs)
                }
            }
        }
    }
    // Algorithm scenarios keep their original short fixture timings. The separate
    // production-policy test below pins Ethan's ten-second setting and both gates.
    private static var fixtureConfiguration: RealtimeSilenceSleepGate.Configuration {
        var configuration = RealtimeSilenceSleepGate.Configuration.gptLiveDefault
        configuration.trailingQuietSeconds = 5
        configuration.activityHoldSeconds = 5
        return configuration
    }

    // MARK: - Synthetic 16 kHz mono PCM16

    private enum TestPCM {
        static let sampleRate = 16_000

        static func peak(forRMSDBFS dbfs: Double) -> Double {
            pow(10, dbfs / 20) * 32_768
        }

        /// Deterministic uniform noise with the requested RMS (uniform RMS = peak/√3).
        /// Every chunk differs, so order/duplication checks can compare chunk bytes.
        static func noise(seconds: Double, dbfs: Double, seed: inout UInt64) -> [Int16] {
            let count = Int((seconds * Double(sampleRate)).rounded())
            let amplitude = peak(forRMSDBFS: dbfs) * 3.0.squareRoot()
            var samples: [Int16] = []
            samples.reserveCapacity(count)
            for _ in 0..<count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Double(seed >> 11) / Double(UInt64(1) << 53)
                samples.append(Int16(clamping: Int((((unit * 2) - 1) * amplitude).rounded())))
            }
            return samples
        }

        /// Sine tone with the requested RMS (sine RMS = peak/√2), starting at `offset`.
        static func tone(seconds: Double, dbfs: Double, frequency: Double = 220, offset: Int = 0) -> [Int16] {
            let count = Int((seconds * Double(sampleRate)).rounded())
            let amplitude = peak(forRMSDBFS: dbfs) * 2.0.squareRoot()
            return (0..<count).map { index in
                let phase = 2 * Double.pi * frequency * Double(index + offset) / Double(sampleRate)
                return Int16(clamping: Int((sin(phase) * amplitude).rounded()))
            }
        }

        static func mix(_ first: [Int16], _ second: [Int16]) -> [Int16] {
            zip(first, second).map { Int16(clamping: Int($0) + Int($1)) }
        }

        static func data<S: Sequence>(_ samples: S) -> Data where S.Element == Int16 {
            var data = Data()
            for sample in samples {
                var littleEndian = sample.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        static func chunks(_ samples: [Int16], samplesPerChunk: Int) -> [Data] {
            stride(from: 0, to: samples.count, by: samplesPerChunk).map { start in
                data(samples[start..<min(start + samplesPerChunk, samples.count)])
            }
        }

        static func rmsDBFS(_ chunk: Data) -> Double {
            let samples = chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int16] in
                stride(from: 0, to: raw.count - 1, by: 2).map {
                    Int16(bitPattern: UInt16(raw[$0]) | (UInt16(raw[$0 + 1]) << 8))
                }
            }
            guard !samples.isEmpty else { return -120 }
            let meanSquare = samples.reduce(0.0) {
                let value = Double($1) / 32_768
                return $0 + value * value
            } / Double(samples.count)
            return meanSquare > 0 ? 10 * log10(meanSquare) : -120
        }
    }

    /// Drives the pure gate with real-time pacing derived from sample counts, so the
    /// wall clock equals captured audio time unless a test deliberately skews it.
    private struct GateRun {
        var gate: RealtimeSilenceSleepGate
        private(set) var samplesFed = 0
        private(set) var input: [Data] = []
        private(set) var sent: [Data] = []
        private(set) var withheld: [Data] = []
        private(set) var transitions: [(sleeping: Bool, atAudioSeconds: Double)] = []
        private(set) var wallClockOffset: Double = 0

        init(configuration: RealtimeSilenceSleepGate.Configuration = RealtimeSilenceSleepTests.fixtureConfiguration) {
            gate = RealtimeSilenceSleepGate(configuration: configuration, startedAt: 0)
        }

        var audioSeconds: Double { Double(samplesFed) / Double(TestPCM.sampleRate) }
        var now: Double { audioSeconds + wallClockOffset }
        var sentSeconds: Double { Double(sent.reduce(0) { $0 + $1.count }) / 32_000 }
        var withheldSeconds: Double { Double(withheld.reduce(0) { $0 + $1.count }) / 32_000 }

        mutating func feed(_ samples: [Int16], samplesPerChunk: Int = 320) {
            for chunk in TestPCM.chunks(samples, samplesPerChunk: samplesPerChunk) {
                feedChunk(chunk)
            }
        }

        mutating func feedChunk(_ chunk: Data, arrivingAt arrival: Double? = nil) {
            input.append(chunk)
            samplesFed += chunk.count / 2
            apply(gate.process(chunk, at: arrival ?? now))
        }

        mutating func noteActivity() { gate.noteActivity(at: now) }
        mutating func finish() { apply(gate.finish()) }
        mutating func discard() { apply(gate.discard()) }

        /// Manual Pause: AUHAL stops, so no chunks arrive while wall-clock time passes.
        mutating func passWallClockWithoutAudio(_ seconds: Double) {
            wallClockOffset += seconds
        }

        private mutating func apply(_ actions: [RealtimeSilenceSleepGate.Action]) {
            for action in actions {
                switch action {
                case .send(let chunk): sent.append(chunk)
                case .withhold(let chunk): withheld.append(chunk)
                case .sleepingChanged(let sleeping): transitions.append((sleeping, audioSeconds))
                }
            }
        }

        /// Every emitted chunk corresponds to exactly one input chunk, in capture order;
        /// anything not yet emitted is only the still-held newest preroll.
        func emitsEachInputChunkOnceInOrder() -> Bool {
            var sentIndex = 0
            var withheldIndex = 0
            var inputIndex = 0
            while inputIndex < input.count {
                let chunk = input[inputIndex]
                if sentIndex < sent.count, sent[sentIndex] == chunk {
                    sentIndex += 1
                } else if withheldIndex < withheld.count, withheld[withheldIndex] == chunk {
                    withheldIndex += 1
                } else {
                    break
                }
                inputIndex += 1
            }
            return sentIndex == sent.count && withheldIndex == withheld.count
        }
    }

    // MARK: - Entering quiet

    @Test func productionPolicyWaitsTenSecondsForBothQuietAndRecentActivity() throws {
        let configuration = RealtimeSilenceSleepGate.Configuration.gptLiveDefault
        #expect(configuration.trailingQuietSeconds == 10)
        #expect(configuration.activityHoldSeconds == 10)
        #expect(configuration.prerollSeconds == 0.75)
        var seed: UInt64 = 103

        var quiet = GateRun(configuration: configuration)
        quiet.feed(TestPCM.noise(seconds: 9.9, dbfs: -70, seed: &seed))
        #expect(!quiet.gate.isSleeping)
        #expect(quiet.withheld.isEmpty)
        quiet.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        let quietSleep = try #require(quiet.transitions.first)
        #expect(quietSleep.atAudioSeconds >= 10 && quietSleep.atAudioSeconds <= 10.04)

        var active = GateRun(configuration: configuration)
        active.feed(TestPCM.noise(seconds: 9.9, dbfs: -70, seed: &seed))
        active.noteActivity()
        active.feed(TestPCM.noise(seconds: 9.9, dbfs: -70, seed: &seed))
        #expect(!active.gate.isSleeping)
        #expect(active.withheld.isEmpty)
        active.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        let activitySleep = try #require(active.transitions.first)
        #expect(activitySleep.atAudioSeconds >= 19.9 && activitySleep.atAudioSeconds <= 19.94)
    }

    @Test func quietRoomSleepsOnlyAfterTheTrailingPeriodAndSessionHold() throws {
        var seed: UInt64 = 1
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 4.9, dbfs: -70, seed: &seed))
        #expect(!run.gate.isSleeping)
        #expect(run.transitions.isEmpty)

        run.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        #expect(run.gate.isSleeping)
        let sleep = try #require(run.transitions.first)
        #expect(sleep.sleeping)
        #expect(sleep.atAudioSeconds >= 5.0 && sleep.atAudioSeconds <= 5.04)
        // The whole trailing period streamed before any audio was held back.
        #expect(run.sentSeconds >= 5.0)
        #expect(run.withheld.isEmpty)
        #expect(run.emitsEachInputChunkOnceInOrder())
    }

    @Test func speechThenSilenceKeepsAFullTrailingPeriodBeforeSleeping() throws {
        var seed: UInt64 = 2
        var run = GateRun()
        let bed = TestPCM.noise(seconds: 2, dbfs: -72, seed: &seed)
        run.feed(TestPCM.mix(TestPCM.tone(seconds: 2, dbfs: -28), bed))
        run.feed(TestPCM.noise(seconds: 6, dbfs: -72, seed: &seed))

        let sleep = try #require(run.transitions.first)
        // Five seconds of audio after the last audible frame, never earlier.
        #expect(sleep.atAudioSeconds >= 7.0 && sleep.atAudioSeconds <= 7.06)
        #expect(run.sentSeconds >= 7.0)
    }

    @Test func naturalDictationPausesNeverSleep() {
        var seed: UInt64 = 3
        var run = GateRun()
        for _ in 0..<6 {
            let bed = TestPCM.noise(seconds: 2, dbfs: -72, seed: &seed)
            run.feed(TestPCM.mix(TestPCM.tone(seconds: 2, dbfs: -30), bed))
            run.feed(TestPCM.noise(seconds: 3.5, dbfs: -72, seed: &seed))
        }
        #expect(run.transitions.isEmpty)
        #expect(run.withheld.isEmpty)
        #expect(run.sent.count == run.input.count)
    }

    // MARK: - Waking

    @Test func wakeSendsPrerollThenOnsetExactlyOnceInCaptureOrder() throws {
        var seed: UInt64 = 4
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 8, dbfs: -70, seed: &seed))
        #expect(run.gate.isSleeping)
        let onsetIndex = run.input.count

        let bed = TestPCM.noise(seconds: 1, dbfs: -70, seed: &seed)
        run.feed(TestPCM.mix(TestPCM.tone(seconds: 1, dbfs: -30), bed))
        #expect(!run.gate.isSleeping)
        #expect(run.transitions.map { $0.sleeping } == [true, false])

        // The newest ≥0.75 s of quiet before the onset (38 × 20 ms chunks) streamed as
        // preroll; the chunk before that run was intentionally withheld.
        let prerollChunks = 38
        for chunk in run.input[(onsetIndex - prerollChunks)..<onsetIndex] {
            #expect(run.sent.contains(chunk))
        }
        #expect(run.withheld.contains(run.input[onsetIndex - prerollChunks - 1]))

        // Every audible chunk streamed; only quiet audio was withheld.
        for chunk in run.input where TestPCM.rmsDBFS(chunk) > -60 {
            #expect(run.sent.contains(chunk))
        }
        for chunk in run.withheld {
            #expect(TestPCM.rmsDBFS(chunk) < -60)
        }
        #expect(run.emitsEachInputChunkOnceInOrder())
        run.finish()
        #expect(run.sent.count + run.withheld.count == run.input.count)
        #expect(abs(run.withheldSeconds - 2.24) < 0.03)
    }

    @Test func softSpeechBelowTheCeilingStillWakesAgainstAQuietFloor() {
        var seed: UInt64 = 5
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 7, dbfs: -88, seed: &seed))
        #expect(run.gate.isSleeping)
        // −78 dBFS is quieter than the −65 dBFS ceiling but above floor + margin.
        let bed = TestPCM.noise(seconds: 0.5, dbfs: -88, seed: &seed)
        run.feed(TestPCM.mix(TestPCM.tone(seconds: 0.5, dbfs: -78), bed))
        #expect(!run.gate.isSleeping)
    }

    @Test func lowGainMicrophoneWakesOnSoftSpeechThroughTheRelativeMargin() {
        var seed: UInt64 = 6
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 6, dbfs: -88, seed: &seed))
        #expect(run.gate.isSleeping)
        #expect(run.gate.activityThresholdDBFS < -70)
        let bed = TestPCM.noise(seconds: 0.5, dbfs: -88, seed: &seed)
        run.feed(TestPCM.mix(TestPCM.tone(seconds: 0.5, dbfs: -72), bed))
        #expect(!run.gate.isSleeping)
    }

    @Test func onsetSplitAcrossAnalysisFrameBoundariesStillWakesWithItsFirstBytes() throws {
        var seed: UInt64 = 7
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 6.5, dbfs: -70, seed: &seed), samplesPerChunk: 173)
        #expect(run.gate.isSleeping)

        let bed = TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed)
        let onset = TestPCM.data(TestPCM.mix(TestPCM.tone(seconds: 0.2, dbfs: -30), bed))
        // Whole PCM16 samples, but fewer than one analysis frame in the first chunk.
        let firstPart = onset.prefix(100)
        let secondPart = onset.dropFirst(100)
        run.feedChunk(Data(firstPart))
        run.feedChunk(Data(secondPart))

        #expect(!run.gate.isSleeping)
        #expect(run.sent.contains(Data(firstPart)))
        #expect(run.sent.contains(Data(secondPart)))
        run.finish()
        #expect(run.emitsEachInputChunkOnceInOrder())
        let inputBytes = run.input.reduce(0) { $0 + $1.count }
        let emittedBytes = run.sent.reduce(0) { $0 + $1.count } + run.withheld.reduce(0) { $0 + $1.count }
        #expect(inputBytes == emittedBytes)
    }

    // MARK: - Background sound and noise floors (fail open)

    @Test func audibleBackgroundMusicKeepsTheStreamAwake() {
        var seed: UInt64 = 8
        var run = GateRun()
        let seconds = 20.0
        let music = TestPCM.mix(
            TestPCM.tone(seconds: seconds, dbfs: -44, frequency: 196),
            TestPCM.tone(seconds: seconds, dbfs: -48, frequency: 330)
        )
        run.feed(TestPCM.mix(music, TestPCM.noise(seconds: seconds, dbfs: -72, seed: &seed)))
        #expect(run.transitions.isEmpty)
        #expect(run.withheld.isEmpty)
    }

    @Test func quietDynamicMusicBelowTheCeilingStillFailsOpen() {
        var seed: UInt64 = 9
        var configuration = RealtimeSilenceSleepGate.Configuration.gptLiveDefault
        configuration.initialNoiseFloorDBFS = -90
        var run = GateRun(configuration: configuration)
        // Soft phrases every second rise well above the learned floor; no five-second
        // quiet run ever forms, so nothing is withheld.
        for second in 0..<20 {
            // Every phrase stays below the actual −65 dBFS ceiling. Only the floor-relative
            // threshold can keep these very quiet musical phrases streaming.
            let loud = TestPCM.tone(seconds: 0.5, dbfs: -78, offset: second * 16_000)
            let soft = TestPCM.tone(seconds: 0.5, dbfs: -94, offset: second * 16_000 + 8_000)
            let bed = TestPCM.noise(seconds: 1, dbfs: -100, seed: &seed)
            run.feed(TestPCM.mix(loud + soft, bed))
        }
        #expect(run.transitions.isEmpty)
        #expect(run.withheld.isEmpty)
    }

    @Test func audibleRoomNoiseKeepsStreamingRatherThanRaisingTheSpeechThreshold() {
        var seed: UInt64 = 10
        var run = GateRun()
        // Noise louder than the ceiling must fail open. Learning it as silence could
        // discard intelligible soft speech mixed into that same background.
        run.feed(TestPCM.noise(seconds: 7, dbfs: -56, seed: &seed))
        #expect(run.transitions.isEmpty)
        #expect(run.withheld.isEmpty)

        let bed = TestPCM.noise(seconds: 0.5, dbfs: -56, seed: &seed)
        run.feed(TestPCM.mix(TestPCM.tone(seconds: 0.5, dbfs: -35), bed))
        #expect(!run.gate.isSleeping)
    }

    @Test func softVoiceMixedWithQuietBackgroundToneIsNeverWithheld() {
        var run = GateRun()
        // Production API regression: intelligible speech at −62 dBFS over a
        // −60 dBFS tone was recognized from the full audio, but the initial
        // −50 dBFS / 9 dB detector omitted it. Stay awake for this background.
        let background = TestPCM.tone(seconds: 18, dbfs: -60, frequency: 440)
        var voice = [Int16](repeating: 0, count: background.count)
        let phrase = TestPCM.tone(seconds: 2.5, dbfs: -62, frequency: 173)
        voice.replaceSubrange(192_000..<(192_000 + phrase.count), with: phrase)
        run.feed(TestPCM.mix(background, voice))
        run.finish()
        #expect(run.withheld.isEmpty)
        #expect(run.sent == run.input)
    }

    @Test func sustainedSoftVoiceDoesNotBecomeTheLearnedNoiseFloor() {
        var seed: UInt64 = 101
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 7, dbfs: -88, seed: &seed))
        #expect(run.gate.isSleeping)
        let onsetIndex = run.input.count
        run.feed(TestPCM.mix(
            TestPCM.tone(seconds: 15, dbfs: -72),
            TestPCM.noise(seconds: 15, dbfs: -88, seed: &seed)
        ))
        run.finish()
        #expect(run.transitions.map(\.sleeping) == [true, false])
        for chunk in run.input[onsetIndex...] { #expect(run.sent.contains(chunk)) }
    }

    @Test func oddPCMChunkDisablesOmissionWithoutMisaligningLaterAudio() {
        var seed: UInt64 = 102
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 7, dbfs: -70, seed: &seed))
        #expect(run.gate.isSleeping)
        run.feedChunk(Data([0x01]))
        #expect(run.gate.phase == .finished)
        let sentAfterOdd = run.sent.count
        run.feed(TestPCM.noise(seconds: 8, dbfs: -70, seed: &seed))
        #expect(run.sent.count == sentAfterOdd + 400)
        #expect(run.sent.count + run.withheld.count == run.input.count)
    }

    // MARK: - Session activity

    @Test func sessionActivityHoldsTheStreamAwakeAndWakesItOnTheNextChunk() throws {
        var seed: UInt64 = 11
        var run = GateRun()
        run.feed(TestPCM.noise(seconds: 3, dbfs: -70, seed: &seed))
        run.noteActivity() // typing at 3 s
        run.feed(TestPCM.noise(seconds: 4, dbfs: -70, seed: &seed))
        run.noteActivity() // a selection at 7 s
        run.feed(TestPCM.noise(seconds: 4.9, dbfs: -70, seed: &seed))
        #expect(!run.gate.isSleeping) // quiet audio alone is not enough
        run.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        let firstSleep = try #require(run.transitions.first)
        #expect(firstSleep.atAudioSeconds >= 12.0 && firstSleep.atAudioSeconds <= 12.04)

        run.feed(TestPCM.noise(seconds: 1.9, dbfs: -70, seed: &seed))
        let heldBeforeWake = run.input.count
        run.noteActivity() // a late provider word or typing while asleep
        #expect(run.gate.isSleeping) // applied on the audio path, in order
        run.feed(TestPCM.noise(seconds: 0.02, dbfs: -70, seed: &seed))
        #expect(!run.gate.isSleeping)
        #expect(run.sent.contains(run.input[heldBeforeWake - 1]))
        #expect(run.sent.last == run.input.last)

        // The next sleep needs a fresh trailing period and the activity hold.
        run.feed(TestPCM.noise(seconds: 6, dbfs: -70, seed: &seed))
        let secondSleep = try #require(run.transitions.last)
        #expect(secondSleep.sleeping)
        #expect(secondSleep.atAudioSeconds >= 19.0 && secondSleep.atAudioSeconds <= 19.06)
        #expect(run.emitsEachInputChunkOnceInOrder())
    }

    // MARK: - Startup, pause, stop, cancel

    @Test func startupReplayBurstIsMeasuredInAudioTimeNotArrivalTime() throws {
        var seed: UInt64 = 12
        var early = GateRun()
        // Four seconds buffered before the socket connected arrive in one burst.
        for chunk in TestPCM.chunks(TestPCM.noise(seconds: 4, dbfs: -70, seed: &seed), samplesPerChunk: 320) {
            early.feedChunk(chunk, arrivingAt: 0)
        }
        #expect(!early.gate.isSleeping)
        early.feed(TestPCM.noise(seconds: 0.9, dbfs: -70, seed: &seed))
        #expect(!early.gate.isSleeping)
        early.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        #expect(early.gate.isSleeping)

        // A slow handshake replays ten quiet seconds at once after the hold expired.
        var late = GateRun()
        for chunk in TestPCM.chunks(TestPCM.noise(seconds: 10, dbfs: -70, seed: &seed), samplesPerChunk: 320) {
            late.feedChunk(chunk, arrivingAt: 6)
        }
        let sleep = try #require(late.transitions.first)
        #expect(sleep.atAudioSeconds >= 5.0 && sleep.atAudioSeconds <= 5.04)
        #expect(abs(late.withheldSeconds - 4.24) < 0.03)
        #expect(late.emitsEachInputChunkOnceInOrder())
    }

    @Test func manualPauseGapNeitherSleepsNorWakesTheStream() {
        var seed: UInt64 = 13
        // Awake at pause: a long wall-clock pause does not count as trailing quiet.
        var awake = GateRun()
        awake.feed(TestPCM.noise(seconds: 3, dbfs: -70, seed: &seed))
        awake.passWallClockWithoutAudio(60)
        awake.feed(TestPCM.noise(seconds: 1.9, dbfs: -70, seed: &seed))
        #expect(!awake.gate.isSleeping)
        awake.feed(TestPCM.noise(seconds: 0.2, dbfs: -70, seed: &seed))
        #expect(awake.gate.isSleeping)

        // Asleep at pause: no chunks means no transition and no burst on resume.
        var asleep = GateRun()
        asleep.feed(TestPCM.noise(seconds: 6, dbfs: -70, seed: &seed))
        let transitionsAtPause = asleep.transitions.count
        let sentAtPause = asleep.sent.count
        asleep.passWallClockWithoutAudio(120)
        #expect(asleep.gate.isSleeping)
        asleep.feed(TestPCM.noise(seconds: 1, dbfs: -70, seed: &seed))
        #expect(asleep.gate.isSleeping)
        #expect(asleep.transitions.count == transitionsAtPause)
        #expect(asleep.sent.count == sentAtPause)
        let bed = TestPCM.noise(seconds: 0.3, dbfs: -70, seed: &seed)
        asleep.feed(TestPCM.mix(TestPCM.tone(seconds: 0.3, dbfs: -32), bed))
        #expect(!asleep.gate.isSleeping)
        #expect(asleep.emitsEachInputChunkOnceInOrder())
    }

    @Test func stopFlushesHeldPrerollWhileCancelWithholdsIt() {
        var seed: UInt64 = 14
        var stopped = GateRun()
        stopped.feed(TestPCM.noise(seconds: 5.5, dbfs: -70, seed: &seed))
        #expect(stopped.gate.isSleeping)
        let held = Array(stopped.input.suffix(from: stopped.sent.count))
        #expect(!held.isEmpty)
        stopped.finish()
        #expect(!stopped.gate.isSleeping)
        #expect(stopped.transitions.last?.sleeping == false)
        #expect(Array(stopped.sent.suffix(held.count)) == held)
        #expect(stopped.sent.count + stopped.withheld.count == stopped.input.count)
        // After Stop, late chunks pass straight through; the gate never withholds again.
        let late = TestPCM.data(TestPCM.noise(seconds: 0.02, dbfs: -70, seed: &seed))
        let lateActions = stopped.gate.process(late, at: 99)
        #expect(lateActions == [.send(late)])

        var canceled = GateRun()
        canceled.feed(TestPCM.noise(seconds: 5.5, dbfs: -70, seed: &seed))
        let sentBeforeCancel = canceled.sent.count
        canceled.discard()
        #expect(canceled.sent.count == sentBeforeCancel)
        #expect(canceled.sent.count + canceled.withheld.count == canceled.input.count)
        #expect(canceled.transitions.last?.sleeping == false)
    }

    // MARK: - Controller and session isolation

    private final class ManualClock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private final class ControllerSink: @unchecked Sendable {
        var sent: [Data] = []
        var withheld: [Data] = []
        var changes: [(sleeping: Bool, generation: UInt64)] = []
    }

    private func makeController(
        clock: ManualClock,
        sink: ControllerSink
    ) -> RealtimeSilenceSleepController {
        RealtimeSilenceSleepController(
            configuration: Self.fixtureConfiguration,
            clock: { clock.now },
            forward: { sink.sent.append($0) },
            withhold: { sink.withheld.append($0) },
            onSleepingChange: { sink.changes.append(($0, $1)) }
        )
    }

    private func feed(
        _ samples: [Int16],
        to controller: RealtimeSilenceSleepController,
        clock: ManualClock
    ) {
        for chunk in TestPCM.chunks(samples, samplesPerChunk: 320) {
            clock.now += Double(chunk.count / 2) / Double(TestPCM.sampleRate)
            controller.receive(chunk)
        }
    }

    @Test func controllersIsolateRecordingsAndPublishOrderedGenerations() {
        var seed: UInt64 = 15
        let clockA = ManualClock()
        let clockB = ManualClock()
        let sinkA = ControllerSink()
        let sinkB = ControllerSink()
        let recordingA = makeController(clock: clockA, sink: sinkA)
        let recordingB = makeController(clock: clockB, sink: sinkB)

        feed(TestPCM.noise(seconds: 3, dbfs: -70, seed: &seed), to: recordingB, clock: clockB)
        recordingB.noteSessionActivity() // B's typing must not affect A
        feed(TestPCM.noise(seconds: 6, dbfs: -70, seed: &seed), to: recordingA, clock: clockA)
        feed(TestPCM.noise(seconds: 3, dbfs: -70, seed: &seed), to: recordingB, clock: clockB)

        #expect(recordingA.isSleeping)
        #expect(!recordingB.isSleeping) // B's hold runs until 8 s
        #expect(sinkA.changes.map { $0.sleeping } == [true])
        #expect(sinkB.changes.isEmpty)

        recordingA.noteSessionActivity()
        feed(TestPCM.noise(seconds: 0.02, dbfs: -70, seed: &seed), to: recordingA, clock: clockA)
        #expect(!recordingA.isSleeping)
        #expect(sinkA.changes.map { $0.generation } == [1, 2])
        #expect(!recordingB.isSleeping)

        let summary = recordingA.summarySnapshot
        #expect(summary.sleeps == 1)
        #expect(summary.withheldChunks == sinkA.withheld.count)
        #expect(summary.withheldBytes == sinkA.withheld.reduce(0) { $0 + $1.count })
        #expect(sinkB.withheld.isEmpty)
    }

    @Test @MainActor func recordingSessionShowsSleepOnlyWhileRecordingAndIgnoresStaleUpdates() {
        let session = RecordingSession()
        session.applyRealtimeStreamSleeping(true, generation: 2)
        #expect(session.realtimeStreamSleeping)
        #expect(session.showsRealtimeStreamSleepingBadge)
        session.microphoneOff = true
        #expect(!session.showsRealtimeStreamSleepingBadge)
        session.microphoneOff = false
        #expect(session.showsRealtimeStreamSleepingBadge)
        session.applyRealtimeStreamSleeping(false, generation: 1) // late, out of order
        #expect(session.realtimeStreamSleeping)
        session.applyRealtimeStreamSleeping(false, generation: 3)
        #expect(!session.realtimeStreamSleeping)
        session.applyRealtimeStreamSleeping(true, generation: 4)
        #expect(session.realtimeStreamSleeping)
        session.phase = .transcribing
        #expect(!session.realtimeStreamSleeping)
        session.applyRealtimeStreamSleeping(true, generation: 5)
        #expect(!session.realtimeStreamSleeping)
    }

    @MainActor
    private final class ActivityCountingSession: TranscriptionSession {
        var activityCount = 0
        var onActivity: (() -> Void)?
        func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? { nil }
        func transcribe(audioURL: URL) async throws -> String { "" }
        func cancel() {}
        func noteSessionActivity() { activityCount += 1; onActivity?() }
    }

    @Test @MainActor func typingAndSelectionsReportActivityOnlyToTheirOwnRecording() throws {
        let recordingA = RecordingSession()
        let recordingB = RecordingSession()
        let streamA = ActivityCountingSession()
        let streamB = ActivityCountingSession()
        recordingA.transcriptionSession = streamA
        recordingB.transcriptionSession = streamB

        recordingA.updateTypedInput("typed during a quiet moment")
        #expect(streamA.activityCount == 1)
        recordingA.recordLiveSelection(try #require(LiveSelectionReference("selected during a quiet moment")))
        #expect(streamA.activityCount >= 2)
        #expect(streamB.activityCount == 0)
    }

    // MARK: - Accounting, policy, usage

    @Test func metricsSeparateWithheldSilenceFromRealLoss() {
        let withheldOnly = StreamingAudioMetricsSnapshot(
            receivedChunks: 10, receivedBytes: 40, sentChunks: 6, sentBytes: 24,
            droppedChunks: 0, droppedBytes: 0, drainTimedOut: false,
            withheldChunks: 4, withheldBytes: 16
        )
        let withheldAndDropped = StreamingAudioMetricsSnapshot(
            receivedChunks: 10, receivedBytes: 40, sentChunks: 5, sentBytes: 20,
            droppedChunks: 1, droppedBytes: 4, drainTimedOut: false,
            withheldChunks: 4, withheldBytes: 16
        )
        let unaccounted = StreamingAudioMetricsSnapshot(
            receivedChunks: 10, receivedBytes: 40, sentChunks: 6, sentBytes: 24,
            droppedChunks: 0, droppedBytes: 0, drainTimedOut: false,
            withheldChunks: 3, withheldBytes: 12
        )
        let providerFailed = StreamingAudioMetricsSnapshot(
            receivedChunks: 2, receivedBytes: 8, sentChunks: 2, sentBytes: 8,
            droppedChunks: 0, droppedBytes: 0, drainTimedOut: false,
            providerFailureReported: true
        )
        let ungated = StreamingAudioMetricsSnapshot(
            receivedChunks: 2, receivedBytes: 8, sentChunks: 2, sentBytes: 8,
            droppedChunks: 0, droppedBytes: 0, drainTimedOut: false
        )

        #expect(withheldOnly.isComplete) // intentional omission is not a paid retry
        #expect(!withheldAndDropped.isComplete) // real loss still forces the WAV
        #expect(!unaccounted.isComplete)
        #expect(!providerFailed.isComplete)
        #expect(ungated.isComplete)
    }

    @Test @MainActor func silenceSleepIsOptInForGPTLiveTranscribeOnly() throws {
        #expect(RealtimeSilenceSleepPolicy.defaultEnabled == false)
        let suiteName = "RealtimeSilenceSleepTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!RealtimeSilenceSleepPolicy.isEnabled(in: defaults))
        defaults.set(true, forKey: RealtimeSilenceSleepPolicy.userDefaultsKey)
        #expect(RealtimeSilenceSleepPolicy.isEnabled(in: defaults))

        func model(_ name: String, _ provider: ModelProvider) -> CloudModel {
            CloudModel(
                name: name, displayName: name, description: "Offline test only",
                provider: provider, speed: 1, accuracy: 1, isMultilingual: true,
                supportsStreaming: true, supportedLanguages: ["en": "English"]
            )
        }
        let live = model(OpenAITranscriptionConfiguration.liveModelName, .openAI)
        #expect(RealtimeSilenceSleepPolicy.configuration(for: live, isEnabled: true) == .gptLiveDefault)
        #expect(RealtimeSilenceSleepPolicy.configuration(for: live, isEnabled: false) == nil)
        let completedAudio = model(OpenAITranscriptionConfiguration.completedAudioModelName, .openAI)
        #expect(RealtimeSilenceSleepPolicy.configuration(for: completedAudio, isEnabled: true) == nil)
        let otherProvider = model(OpenAITranscriptionConfiguration.liveModelName, .assemblyAI)
        #expect(RealtimeSilenceSleepPolicy.configuration(for: otherProvider, isEnabled: true) == nil)
    }

    @Test func usageSummaryKeepsOnlyNumericBillingFields() {
        let duration: [String: Any] = ["type": "duration", "seconds": 3]
        let tokens: [String: Any] = [
            "type": "tokens", "input_tokens": 12, "output_tokens": 4, "total_tokens": 16,
        ]
        let unknownType: [String: Any] = ["type": "spoken words echoed", "seconds": 1.5]
        let textOnly: [String: Any] = ["note": "transcript text"]

        #expect(OpenAIRealtimeUsageSummary.describe(nil) == nil)
        #expect(OpenAIRealtimeUsageSummary.describe(duration) == "type=duration seconds=3")
        #expect(
            OpenAIRealtimeUsageSummary.describe(tokens)
                == "type=tokens input_tokens=12 output_tokens=4 total_tokens=16"
        )
        // Unknown strings are never echoed into the log.
        #expect(OpenAIRealtimeUsageSummary.describe(unknownType) == "type=other seconds=1.5")
        #expect(OpenAIRealtimeUsageSummary.describe(textOnly) == "present=unrecognized")
    }

    // MARK: - Structural guards

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func silenceSleepNeverCommitsDeliversPausesOrGatesTheCaptureSinks() throws {
        let gate = try source("VoiceInk/Transcription/Streaming/RealtimeSilenceSleep.swift")
        for forbidden in [
            "sendJSON", "commit()", ".deliver(", "CursorPaster", "FocusLockService",
            "pauseRecording(", "resumeRecording(", "ExtAudioFileWrite", "AXSelectedText",
        ] {
            #expect(!gate.contains(forbidden), "silence sleep must not reference \(forbidden)")
        }

        // Sleep/wake never commits. The only explicit network commit helper is
        // called by Stop and the owned captured-hint boundary, never by this gate.
        let provider = try source("VoiceInk/Transcription/Streaming/OpenAIStreamingProvider.swift")
        #expect(provider.components(separatedBy: "\"type\": \"input_audio_buffer.commit\"").count - 1 == 1)
        #expect(provider.components(separatedBy: "try await sendCommitMessage(over: task)").count - 1 == 2)
        let updateBody = try #require(provider.range(of: "func updateTranscriptionContext(_ context:"))
        let stopBody = try #require(provider.range(of: "func commit() async throws", range: updateBody.upperBound..<provider.endIndex))
        let boundaryBody = String(provider[updateBody.lowerBound..<stopBody.lowerBound])
        let ownedCommit = try #require(boundaryBody.range(of: "try await sendCommitMessage(over: task)"))
        let completeWait = try #require(boundaryBody.range(of: ".turnCompletion(index)"))
        let changeHint = try #require(boundaryBody.range(of: "OpenAITranscriptionConfiguration.realtimeContextUpdate"))
        #expect(ownedCommit.lowerBound < completeWait.lowerBound && completeWait.lowerBound < changeHint.lowerBound)
        #expect(provider.contains("private func yieldFinalOnce"))

        let service = try source("VoiceInk/Transcription/Streaming/StreamingTranscriptionService.swift")
        #expect(service.components(separatedBy: "provider.commit()").count - 1 == 1)
        let stop = try #require(service.range(of: "func stopAndGetFinalText()"))
        let flush = try #require(service.range(of: "silenceSleep?.finish()", range: stop.upperBound..<service.endIndex))
        let drain = try #require(service.range(of: "await drainRemainingChunks()", range: stop.upperBound..<service.endIndex))
        let commit = try #require(service.range(of: "try await provider.commit()", range: stop.upperBound..<service.endIndex))
        #expect(flush.lowerBound < drain.lowerBound)
        #expect(drain.lowerBound < commit.lowerBound)

        // The WAV write and realtime callback stay together in the recorder; omission
        // happens only downstream, and manual Pause remains the sole capture gate.
        let recorder = try source("VoiceInk/CoreAudioRecorder.swift")
        #expect(!recorder.contains("RealtimeSilenceSleep"))
        let wavWrite = try #require(recorder.range(of: "let writeStatus = ExtAudioFileWrite("))
        let realtimeCallback = try #require(recorder.range(of: "audioChunk(Data(bytes: outputBuffer"))
        #expect(wavWrite.lowerBound < realtimeCallback.lowerBound)
        let recorderWrapper = try source("VoiceInk/Recorder.swift")
        #expect(!recorderWrapper.contains("RealtimeSilenceSleep"))
        #expect(!recorderWrapper.contains("silenceSleep"))

        // The engine only forwards presentation state; it never acts on sleep changes.
        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        #expect(engine.components(separatedBy: "applyRealtimeStreamSleeping").count - 1 == 1)
        let mini = try source("VoiceInk/Views/Recorder/MiniRecorderView.swift")
        let notch = try source("VoiceInk/Views/Recorder/NotchRecorderView.swift")
        #expect(mini.contains("realtimeStreamSleeping: stateProvider.showsRealtimeStreamSleepingBadge"))
        #expect(notch.contains("realtimeStreamSleeping: stateProvider.showsRealtimeStreamSleepingBadge"))
    }
}
