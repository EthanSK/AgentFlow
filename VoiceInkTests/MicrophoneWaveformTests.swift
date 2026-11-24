// Proves the recorder waveform draws measured microphone loudness rather than an
// animation. Pure tests feed known energy windows through the same model Recorder uses;
// source guards pin the audio-thread and meter-tick wiring; hosted renders draw the real
// Mini and Notch cards from injected meters at every supported HUD size. No microphone,
// shortcut, media, focus or delivery action runs. Ethan reported the old waveform as
// "just like a random animation" on 2026-11-24. — Claude Opus 5.5
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct MicrophoneWaveformTests {
    // MARK: Measured sound → history

    @Test func barsFollowTheOrderSoundWasCaptured() {
        var history = MicrophoneLevelHistory()
        feed(&history, -70, seconds: 0.5)
        feed(&history, -24, seconds: 0.3)
        feed(&history, -70, seconds: 0.4)
        feed(&history, -15, seconds: 0.2)
        let speech = MicrophoneLevelScale.displayLevel(forDecibels: -24)
        let loud = MicrophoneLevelScale.displayLevel(forDecibels: -15)
        let meter = history.meter
        // Oldest first: one untouched starting slice, then each 100 ms of captured audio
        // exactly where and as loud as it happened. The slice still filling is empty.
        var expected: [Float] = [0]
        expected += zeros(5)
        expected += Array(repeating: speech, count: 3)
        expected += zeros(4)
        expected += Array(repeating: loud, count: 2)
        expected += [0]
        #expect(meter.levels == expected)
        #expect(meter.currentSliceProgress == 0)
        #expect(loud > speech && speech > 0)
    }

    @Test func silenceStaysFlatAndPublishesNothingNew() {
        var history = MicrophoneLevelHistory()
        #expect(history.meter == .silent)
        // A quiet room and a muted interface both read as silence, however long.
        feed(&history, -70, seconds: 2)
        feed(&history, MicrophoneLevelAccumulator.silenceDecibels, seconds: 1)
        #expect(history.meter == .silent)
        #expect(history.meter.isSilent)
        // Consecutive silent ticks compare equal, so Recorder skips republishing and the
        // mirrored panels draw nothing new while Ethan is quiet.
        let before = history.meter
        let appended = history.append(window(-65, seconds: 0.033))
        #expect(appended)
        #expect(history.meter == before)
    }

    @Test func sameSteadyInputGivesSameBarHeights() {
        var history = MicrophoneLevelHistory()
        // 33 ms reads straddle slice boundaries, as the real tick does.
        feed(&history, -30, seconds: 3.01, readEvery: 0.033)
        let level = MicrophoneLevelScale.displayLevel(forDecibels: -30)
        #expect(history.meter.levels == Array(repeating: level, count: 16))
        // The old clock-driven ripple gave a steady tone fifteen different heights.
        let heights = Set(AudioVisualizerLayout.bars(for: history.meter, slidesWithCapturedAudio: true)
            .map(\.frame.height))
        #expect(heights.count == 1)
    }

    @Test func speechShowsOnTheFirstTickAfterStart() throws {
        var history = MicrophoneLevelHistory()
        let appended = history.append(window(-20, seconds: 0.033))
        #expect(appended)
        let meter = history.meter
        #expect(meter.levels.last == MicrophoneLevelScale.displayLevel(forDecibels: -20))
        #expect(abs(meter.currentSliceProgress - 0.33) < 1e-9)
        // The slice still being captured is already drawn at the right edge.
        let newest = try #require(AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: true).last)
        #expect(newest.frame.height > AudioVisualizerLayout.minimumBarHeight)
        #expect(newest.frame.maxX <= AudioVisualizerLayout.width)
    }

    @Test func shortUtteranceScrollsAwayLeavingExactSilence() {
        var history = MicrophoneLevelHistory()
        feed(&history, -70, seconds: 1)
        feed(&history, -20, seconds: 0.15)
        // The second speech slice ends after 50 ms of quiet; then 14 quiet slices push the
        // first speech slice out, leaving only the second.
        feed(&history, -70, seconds: 0.05 + 1.4)
        #expect(!history.meter.isSilent)
        #expect(history.completedLevels.first == MicrophoneLevelScale.displayLevel(forDecibels: -20))
        feed(&history, -70, seconds: 0.1)
        #expect(history.meter == .silent)
    }

    @Test func slideDistanceFollowsCapturedAudioTimeNotTicks() {
        var history = MicrophoneLevelHistory()
        history.append(window(-20, seconds: 0.03))
        #expect(abs(history.meter.currentSliceProgress - 0.3) < 1e-9)
        history.append(window(-20, seconds: 0.03))
        #expect(abs(history.meter.currentSliceProgress - 0.6) < 1e-9)
        // One read that crosses a boundary finishes that slice and starts the next.
        history.append(window(-20, seconds: 0.05))
        #expect(abs(history.meter.currentSliceProgress - 0.1) < 1e-9)
        #expect(history.completedLevels.last == MicrophoneLevelScale.displayLevel(forDecibels: -20))
    }

    @Test func noCapturedAudioMeansNoMotion() {
        var history = MicrophoneLevelHistory()
        feed(&history, -20, seconds: 0.25)
        let before = history
        // A stalled device or closing capture delivers no frames: hold the last frame.
        let rejected: [MicrophoneLevelWindow] = [
            .empty,
            MicrophoneLevelWindow(duration: .nan, rmsDecibels: -20),
            MicrophoneLevelWindow(duration: -1, rmsDecibels: -20),
            MicrophoneLevelWindow(duration: .infinity, rmsDecibels: -20)
        ]
        for window in rejected {
            let appended = history.append(window)
            #expect(!appended)
        }
        #expect(history == before)
    }

    @Test func historyMemoryIsFixedHoweverLongTheRecording() {
        var history = MicrophoneLevelHistory()
        // One hour of 100 ms reads.
        for index in 0..<36_000 {
            history.append(window(index.isMultiple(of: 7) ? -20 : -70, seconds: 0.1))
        }
        #expect(history.completedLevels.count == MicrophoneLevelHistory.completedSliceCount)
        #expect(history.meter.levels.count == MicrophoneLevelHistory.completedSliceCount + 1)
        // One hour-long read (a stall) still touches only one history's worth of slices.
        history.append(window(-20, seconds: 3_600))
        let level = MicrophoneLevelScale.displayLevel(forDecibels: -20)
        #expect(history.completedLevels == Array(repeating: level, count: MicrophoneLevelHistory.completedSliceCount))
        #expect(history.meter.levels.count == MicrophoneLevelHistory.completedSliceCount + 1)
    }

    @Test func aCoalescedReadKeepsTheCapturedFractionalSlicePhase() {
        var history = MicrophoneLevelHistory()
        history.append(window(-20, seconds: 0.037))
        history.append(window(-20, seconds: 3_600.041))
        #expect(abs(history.meter.currentSliceProgress - 0.78) < 1e-7)
        #expect(history.completedLevels.count == MicrophoneLevelHistory.completedSliceCount)
    }

    // MARK: Loudness scale and audio-thread accumulation

    @Test func scaleIsLinearInDecibelsWithAFlatQuietFloor() {
        let scale = MicrophoneLevelScale.self
        #expect(scale.displayLevel(forDecibels: MicrophoneLevelAccumulator.silenceDecibels) == 0)
        #expect(scale.displayLevel(forDecibels: -58) == 0) // a typical quiet room
        #expect(scale.displayLevel(forDecibels: scale.silenceFloorDecibels) == 0)
        #expect(scale.displayLevel(forDecibels: scale.fullScaleDecibels) == 1)
        #expect(scale.displayLevel(forDecibels: 0) == 1)
        #expect(scale.displayLevel(forDecibels: .nan) == 0)
        #expect(scale.displayLevel(forDecibels: .infinity) == 1)
        let midpoint = (scale.silenceFloorDecibels + scale.fullScaleDecibels) / 2
        #expect(abs(scale.displayLevel(forDecibels: midpoint) - 0.5) < 1e-5)
        // Stronger input always draws stronger, in equal steps: no hidden boost curve.
        var previous: Float = -1
        var steps: [Float] = []
        for decibels in stride(from: scale.silenceFloorDecibels + 6, through: scale.fullScaleDecibels, by: 6) {
            let level = scale.displayLevel(forDecibels: decibels)
            #expect(level > previous)
            if previous >= 0 { steps.append(level - previous) }
            previous = level
        }
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) < 1e-5)
    }

    @Test func accumulatorMeasuresEveryCapturedBufferNotOnlyTheLatest() {
        var accumulator = MicrophoneLevelAccumulator()
        #expect(accumulator.window == .empty)
        // 10 ms of a 0.1-amplitude signal, then 10 ms of digital silence. The old meter kept
        // only the newest buffer, so this tick would have read as silence.
        accumulator.addBuffer(squareSum: 480 * 0.01, frameCount: 480, sampleRate: 48_000)
        accumulator.addBuffer(squareSum: 0, frameCount: 480, sampleRate: 48_000)
        let window = accumulator.window
        #expect(abs(window.duration - 0.02) < 1e-12)
        // Energy-weighted RMS: sqrt(4.8 / 960) ≈ 0.0707, or −23.01 dBFS.
        #expect(abs(window.rmsDecibels - -23.0103) < 0.01)
        // A device switch can change the callback rate mid-window; time stays exact.
        accumulator.addBuffer(squareSum: 0, frameCount: 441, sampleRate: 44_100)
        #expect(abs(accumulator.window.duration - 0.03) < 1e-12)
        // Malformed buffers add neither energy nor time.
        let valid = accumulator.window
        accumulator.addBuffer(squareSum: .nan, frameCount: 480, sampleRate: 48_000)
        accumulator.addBuffer(squareSum: -1, frameCount: 480, sampleRate: 48_000)
        accumulator.addBuffer(squareSum: 1, frameCount: 0, sampleRate: 48_000)
        accumulator.addBuffer(squareSum: 1, frameCount: 480, sampleRate: 0)
        accumulator.addBuffer(squareSum: 1, frameCount: 480, sampleRate: .infinity)
        accumulator.addBuffer(squareSum: 1, frameCount: 480, sampleRate: .leastNonzeroMagnitude)
        #expect(accumulator.window == valid)
    }

    @Test func levelWindowReplayKeepsTimeAndRelativeHeights() throws {
        let reference = try replayReference()
        var history = MicrophoneLevelHistory()
        var minimum: Float = 1
        var maximum: Float = 0
        for (index, sample) in reference.samples.enumerated() {
            let end = index + 1 < reference.samples.count ? reference.samples[index + 1].at : reference.seconds
            let duration = end - sample.at
            #expect(duration > 0 && duration.isFinite)
            history.append(window(sample.rmsDb, seconds: duration))
            let expected = MicrophoneLevelScale.displayLevel(forDecibels: sample.rmsDb)
            minimum = min(minimum, expected)
            maximum = max(maximum, expected)
            // A read can finish a slice. Its sound must remain in the current or
            // immediately preceding slot, never disappear at that boundary. — GPT-6.1 Sol
            #expect((history.meter.levels.suffix(2).max() ?? 0) + 1e-6 >= expected)
            #expect(history.meter.levels.count == MicrophoneLevelHistory.completedSliceCount + 1)
            #expect(history.meter.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        }
        #expect(maximum - minimum > 0.3)
        let phase = reference.seconds.truncatingRemainder(dividingBy: MicrophoneLevelHistory.sliceDuration)
            / MicrophoneLevelHistory.sliceDuration
        let error = abs(history.meter.currentSliceProgress - phase)
        #expect(min(error, abs(error - 1)) < 1e-5)
        if ProcessInfo.processInfo.environment["VIPP_WAVEFORM_REPLAY_FILE"] != nil {
            print("Measured input envelope replay passed: \(reference.samples.count) windows, \(reference.seconds) seconds")
        }
    }

    // MARK: Drawing

    @Test func drawingDependsOnlyOnTheMeasuredMeter() async throws {
        let meter = AudioMeter(levels: (0...15).map { Float($0 % 4) / 3 }, currentSliceProgress: 0.4)
        let first = AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: true)
        // The old ripple advanced about one radian every 125 ms of wall-clock time.
        try await Task.sleep(for: .milliseconds(150))
        #expect(AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: true) == first)
    }

    @Test func louderSlicesDrawTallerBrighterBarsAndSilenceDrawsDots() throws {
        let silent = AudioVisualizerLayout.bars(for: .silent, slidesWithCapturedAudio: true)
        #expect(silent.count == AudioVisualizerLayout.barCount)
        #expect(silent.allSatisfy { $0.frame.height == AudioVisualizerLayout.minimumBarHeight })
        #expect(silent.allSatisfy { $0.opacity <= AudioVisualizerLayout.quietOpacity })

        var previous: AudioVisualizerLayout.Bar?
        for level: Float in [0, 0.25, 0.5, 1] {
            let meter = AudioMeter(levels: Array(repeating: level, count: 16), currentSliceProgress: 0)
            let newest = try #require(AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: true).last)
            if let previous {
                #expect(newest.frame.height > previous.frame.height)
                #expect(newest.opacity > previous.opacity)
            }
            previous = newest
        }
        #expect(previous?.frame.height == AudioVisualizerLayout.height)
    }

    @Test func newestSoundIsOnTheRightAndOldestOnTheLeft() {
        let newestOnly = AudioVisualizerLayout.bars(for: meter(loudAges: [0]), slidesWithCapturedAudio: false)
        #expect(newestOnly.last?.frame.height == AudioVisualizerLayout.height)
        #expect(newestOnly.dropLast().allSatisfy { $0.frame.height == AudioVisualizerLayout.minimumBarHeight })
        // Age 14 is the oldest slice still on screen when bars do not slide.
        let oldestOnly = AudioVisualizerLayout.bars(for: meter(loudAges: [14]), slidesWithCapturedAudio: false)
        #expect(oldestOnly.first?.frame.height == AudioVisualizerLayout.height)
        #expect(oldestOnly.first?.frame.minX == 0)
        // Every bar stays in the unchanged 73 × 28 pt slot, centred vertically.
        #expect(AudioVisualizerLayout.width == 73 && AudioVisualizerLayout.height == 28)
        for bar in newestOnly + oldestOnly {
            #expect(bar.frame.minY >= 0 && bar.frame.maxY <= AudioVisualizerLayout.height)
            #expect(abs(bar.frame.midY - AudioVisualizerLayout.height / 2) < 1e-9)
            #expect(bar.frame.maxX > 0 && bar.frame.minX < AudioVisualizerLayout.width)
        }
    }

    @Test func reduceMotionStepsWholeBarsInsteadOfSliding() {
        let pitch = AudioVisualizerLayout.barPitch
        let meter = AudioMeter(levels: (0...15).map { Float($0) / 15 }, currentSliceProgress: 0.6)
        let stepped = AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: false)
        let sliding = AudioVisualizerLayout.bars(for: meter, slidesWithCapturedAudio: true)
        for bar in stepped {
            let slot = bar.frame.minX / pitch
            #expect(abs(slot - slot.rounded()) < 1e-9)
        }
        let edge = AudioVisualizerLayout.width - AudioVisualizerLayout.barWidth
        #expect(stepped.last?.frame.minX == edge)
        #expect(abs((sliding.last?.frame.minX ?? 0) - (edge - 0.6 * pitch)) < 1e-9)
        // The same slices keep the same heights either way; only position differs.
        #expect(stepped.last?.frame.height == sliding.last?.frame.height)
    }

    // MARK: Production wiring

    @Test func waveformCodeHasNoClockRandomnessOrRipple() throws {
        let file = try source("VoiceInk/Views/Recorder/AudioVisualizerView.swift")
        let start = try #require(file.range(of: "struct AudioVisualizer: View {"))
        let end = try #require(file.range(of: "struct StaticVisualizer: View {", range: start.upperBound..<file.endIndex))
        let code = file[start.lowerBound..<end.lowerBound]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in ["sin(", "cos(", "pow(", "Date(", "TimelineView", "timeIntervalSince",
                          "random", "withAnimation", ".animation(", "Timer", "phases"] {
            #expect(!code.contains(forbidden), "AudioVisualizer must not use \(forbidden)")
        }
        #expect(code.contains("AudioVisualizerLayout.bars("))
        #expect(code.contains("reduceMotionForPreview ?? systemReduceMotion"))
    }

    @Test func meterTickDrainsCapturedEnergyIntoOneBoundedHistory() throws {
        let recorder = try source("VoiceInk/Recorder.swift")
        let tick = try body(of: "    private func updateAudioMeter() {", in: recorder, until: "    // MARK: - Cleanup")
        #expect(tick.contains("recorder.drainMeterWindow()"))
        #expect(tick.contains("guard levelHistory.append(window) else { return }"))
        #expect(tick.contains("if meter != audioMeter"))
        #expect(!tick.contains("averagePower") && !tick.contains("* 0.6"))
        // One authoritative history: its declaration plus the reset, nothing per panel.
        #expect(recorder.components(separatedBy: "MicrophoneLevelHistory()").count - 1 == 2)

        let timer = try body(of: "    private func startAudioMeterTimer() {", in: recorder,
                             until: "    private func stopAudioMeter() {")
        let reset = try #require(timer.range(of: "resetAudioMeter()"))
        let resume = try #require(timer.range(of: "timer.resume()"))
        #expect(reset.lowerBound < resume.lowerBound)
        #expect(timer.contains("repeating: .milliseconds(33)"))
        let stopOldClock = try #require(timer.range(of: "stopAudioMeter()"))
        #expect(stopOldClock.lowerBound < reset.lowerBound)
        let resetBody = try body(of: "    private func resetAudioMeter() {", in: recorder,
                             until: "    private func scheduleCaptureRefresh(")
        let successorGuard = try #require(resetBody.range(of: "guard audioMeterUpdateTimer == nil else { return }"))
        let historyClear = try #require(resetBody.range(of: "levelHistory = MicrophoneLevelHistory()"))
        #expect(successorGuard.lowerBound < historyClear.lowerBound)

        // Pause closes the waveform before the hardware gate and clears it after; paused
        // audio is neither drawn nor joined to the resumed run.
        let pause = try body(of: "    func pauseRecording() async throws {", in: recorder,
                             until: "    func resumeRecording() async throws {")
        let stopMeter = try #require(pause.range(of: "stopAudioMeter()"))
        let hardwarePause = try #require(pause.range(of: "try currentRecorder.pauseRecording()"))
        let clear = try #require(pause.range(of: "resetAudioMeter()"))
        #expect(stopMeter.lowerBound < hardwarePause.lowerBound && hardwarePause.lowerBound < clear.lowerBound)

        // Microphone-off typing never starts the meter, so its waveform stays flat.
        let typingStart = try body(of: "        if initiallyPaused {", in: recorder,
                                   until: "        let currentDeviceID = deviceManager.getCurrentDevice()")
        #expect(typingStart.contains("return nil"))
        #expect(!typingStart.contains("startAudioMeterTimer()"))
        #expect(typingStart.contains("stopAudioMeter()") && typingStart.contains("resetAudioMeter()"))
    }

    @Test func audioThreadOnlyAddsScalarsUnderTheExistingMeterLock() throws {
        let core = try source("VoiceInk/CoreAudioRecorder.swift")
        let meters = try body(of: "    private func calculateMeters(", in: core,
                              until: "    private func convertAndWriteToFile(")
        let lock = try #require(meters.range(of: "meterLock.lock()"))
        let add = try #require(meters.range(of: "pendingMeterEnergy.addBuffer("))
        let unlock = try #require(meters.range(of: "meterLock.unlock()"))
        #expect(lock.lowerBound < add.lowerBound && add.lowerBound < unlock.lowerBound)
        for forbidden in ["DispatchQueue", "logger.", "Task", "NotificationCenter", ".append(", "print("] {
            #expect(!meters.contains(forbidden), "The real-time callback must not use \(forbidden)")
        }
        let reset = try body(of: "    private func resetMeters() {", in: core, until: "    // MARK: - Input Callback")
        #expect(reset.contains("pendingMeterEnergy = MicrophoneLevelAccumulator()"))
        // Only the main-queue tick drains it.
        #expect(try source("VoiceInk/Recorder.swift").components(separatedBy: ".drainMeterWindow()").count - 1 == 1)
    }

    @Test func mirroredPanelsShareTheOneObservedMeter() throws {
        let components = try source("VoiceInk/Views/Recorder/RecorderComponents.swift")
        #expect(components.components(separatedBy: "AudioVisualizer(audioMeter: recorder.audioMeter").count - 1 == 1)
        for file in ["MiniRecorderView.swift", "NotchRecorderView.swift", "RecorderStackView.swift"] {
            let card = try source("VoiceInk/Views/Recorder/" + file)
            // Cards pass the recorder through; only RecorderStatusDisplay observes it.
            #expect(!card.contains("@ObservedObject var recorder"), "\(file)")
            #expect(!card.contains("audioMeter"), "\(file)")
        }
    }

    // MARK: Native renders

    @Test @MainActor func visualizerPaintsDotsForSilenceAndFullBarsForLoudSound() async throws {
        let size = CGSize(width: AudioVisualizerLayout.width, height: AudioVisualizerLayout.height)
        let loud = meter(loudAges: Set(0...15))
        func render(_ meter: AudioMeter, isActive: Bool = true,
                    reduceMotion: Bool = true) async throws -> NSBitmapImageRep {
            let root = AudioVisualizer(audioMeter: meter, color: .white, isActive: isActive,
                                       reduceMotionForPreview: reduceMotion)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: root)
            panel.contentView = host
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }

        let silentImage = try await render(.silent)
        let loudImage = try await render(loud)
        let silent = paintedExtent(silentImage, pointHeight: size.height)
        let full = paintedExtent(loudImage, pointHeight: size.height)
        // Silent dots stay in the 4 pt centre band (plus antialiasing); loud bars fill the slot.
        #expect(silent.count > 0)
        #expect(silent.minY >= 11 && silent.maxY <= 17, "silent rows \(silent.minY)...\(silent.maxY)")
        #expect(full.maxY - full.minY >= 26, "loud rows \(full.minY)...\(full.maxY)")
        #expect(full.count > silent.count * 4)
        // An inactive waveform ignores the meter entirely.
        let inactive = try await render(loud, isActive: false)
        #expect(changedRegion(silentImage, inactive, hostSize: size).count == 0)

        // Sliding moves the newest bar left by the captured fraction of its slice; Reduce
        // Motion keeps it on the right-hand slot.
        let partial = AudioMeter(levels: zeros(15) + [1], currentSliceProgress: 0.6)
        let stepped = paintedExtent(try await render(partial, reduceMotion: true), pointHeight: size.height)
        let slid = paintedExtent(try await render(partial, reduceMotion: false), pointHeight: size.height)
        let shift = stepped.maxX - slid.maxX
        #expect(shift > 2 && shift < 4, "slide shift \(shift) pt")
    }

    @Test @MainActor func miniAndNotchCardsDrawInjectedMeterNewestOnTheRightAtEveryScale() async throws {
        // The Recording Outline flows with the wall clock. A private suite turns it off so
        // the only pixels that can differ between renders belong to the waveform.
        let suiteName = "AgentFlowTests.Waveform.\(UUID().uuidString)"
        let outlineOff = try #require(UserDefaults(suiteName: suiteName))
        outlineOff.set(false, forKey: RecorderCaptureOutlinePreference.preferenceKey)
        defer { outlineOff.removePersistentDomain(forName: suiteName) }
        let recorder = Recorder()
        let assistant = AssistantSession()
        let state = WaveformCardState()

        for style in ["mini", "notch"] {
            for scale: CGFloat in [0.5, 0.85, 1] {
                let sourceSize = CGSize(
                    width: style == "mini" ? 640 : MiniRecorderLayoutMetrics.liveTranscriptWidth,
                    height: 160
                )
                let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
                let card: AnyView = style == "mini"
                    ? AnyView(MiniRecorderView(stateProvider: state,
                        liveTranscriptHeight: 56, liveTranscriptWidth: 640, recorder: recorder,
                        assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                    : AnyView(NotchRecorderView(stateProvider: state, recorder: recorder,
                        assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                        liveTranscriptHeight: 56, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let host = ScaledRecorderHostingView(rootView: AnyView(card
                    .frame(width: sourceSize.width, height: sourceSize.height)
                    .defaultAppStorage(outlineOff)), scale: scale)
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }
                // Let the Notch's expand spring and the first layout settle before the
                // baseline, so later differences can only come from the meter.
                recorder.audioMeter = .silent
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(700))

                // One host is reused across meters, as the real mirrored panels are, so
                // this also proves the card follows Recorder's published meter.
                func render(_ name: String, _ meter: AudioMeter) async throws -> NSBitmapImageRep {
                    recorder.audioMeter = meter
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let directory = ProcessInfo.processInfo.environment["VIPP_WAVEFORM_SNAPSHOT_DIR"] {
                        let folder = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: folder.appendingPathComponent("\(style)-\(scale)-\(name).png"))
                    }
                    return bitmap
                }

                let silent = try await render("silent", .silent)
                let loud = try await render("loud", meter(loudAges: Set(0...15)))
                let newest = try await render("newest", meter(loudAges: [0, 1, 2, 3]))
                let earlier = try await render("earlier", meter(loudAges: [6, 7, 8]))
                let silentAgain = try await render("silent-again", .silent)
                // Optional private envelope data is transported only for this finite
                // native diagnostic. Public CI uses the synthetic cases above; no
                // recording content or private input trace enters the repository.
                // — GPT-6.1 Sol
                if ProcessInfo.processInfo.environment["VIPP_WAVEFORM_REPLAY_FILE"] != nil {
                    let reference = try replayReference()
                    let indices = Set([reference.samples.count / 4, reference.samples.count / 2,
                                       reference.samples.count * 3 / 4, reference.samples.count - 1])
                    var replay = MicrophoneLevelHistory()
                    for (index, sample) in reference.samples.enumerated() {
                        let end = index + 1 < reference.samples.count ? reference.samples[index + 1].at : reference.seconds
                        replay.append(window(sample.rmsDb, seconds: end - sample.at))
                        if indices.contains(index) { _ = try await render("reference-\(index)", replay.meter) }
                    }
                }
                let label = "\(style) scale=\(scale)"

                // After loud sound, silence redraws exactly the original quiet card: no
                // leftover bars, and nothing else on the card moved between renders.
                #expect(changedRegion(silent, silentAgain, hostSize: size).count == 0, "\(label)")

                // Measure in recorder points, before the HUD scale.
                let everything = changedRegion(silent, loud, hostSize: size).scaled(by: 1 / scale)
                let recent = changedRegion(silent, newest, hostSize: size).scaled(by: 1 / scale)
                let past = changedRegion(silent, earlier, hostSize: size).scaled(by: 1 / scale)
                #expect(everything.count > 0 && recent.count > 0 && past.count > 0, "\(label)")
                // Only the 73 × 28 pt waveform slot changes; the card and controls do not.
                #expect(everything.width <= AudioVisualizerLayout.width + 3, "\(label) width \(everything.width)")
                #expect(everything.width >= 45, "\(label) width \(everything.width)")
                #expect(everything.height <= AudioVisualizerLayout.height + 2, "\(label) height \(everything.height)")
                #expect(everything.height >= 18, "\(label) height \(everything.height)")
                // Newest sound sits at the right edge; sound from 0.6–0.9 s ago sits left of it.
                #expect(recent.minX > everything.midX, "\(label) recent \(recent.minX) mid \(everything.midX)")
                #expect(abs(recent.maxX - everything.maxX) <= 2, "\(label)")
                #expect(past.maxX < recent.minX, "\(label) past \(past.maxX) recent \(recent.minX)")
            }
        }
        recorder.audioMeter = .silent
    }

    // MARK: Helpers

    /// Uses an optional measured, content-free envelope for the private Mini replay;
    /// ordinary public tests exercise the same path with explicit synthetic levels.
    /// The supplied file is bounded and never copied into a public fixture. — GPT-6.1 Sol
    private func replayReference() throws -> WaveformReplayReference {
        if let file = ProcessInfo.processInfo.environment["VIPP_WAVEFORM_REPLAY_FILE"] {
            let url = URL(fileURLWithPath: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file)
            let bytes = try #require((attributes[.size] as? NSNumber)?.intValue)
            #expect(bytes > 0 && bytes < 512_000)
            let reference = try JSONDecoder().decode(WaveformReplayReference.self, from: Data(contentsOf: url))
            #expect(reference.samples.count > 3 && reference.samples.count < 10_000)
            return reference
        }
        let samples = (0..<80).map { index in
            WaveformReplayReference.Sample(at: Double(index) * 0.03,
                rmsDb: index % 20 < 8 ? -70 : (index % 20 < 14 ? -34 : -15))
        }
        return WaveformReplayReference(seconds: 2.4, samples: samples)
    }


    private func window(_ decibels: Float, seconds: TimeInterval) -> MicrophoneLevelWindow {
        MicrophoneLevelWindow(duration: seconds, rmsDecibels: decibels)
    }

    /// Feeds steady sound in meter-tick-sized reads. — Claude Opus 5.5
    private func feed(_ history: inout MicrophoneLevelHistory, _ decibels: Float,
                      seconds: TimeInterval, readEvery read: TimeInterval = 0.05) {
        var remaining = seconds
        while remaining > 1e-9 {
            let step = min(read, remaining)
            history.append(window(decibels, seconds: step))
            remaining -= step
        }
    }

    private func zeros(_ count: Int) -> [Float] {
        Array(repeating: 0, count: count)
    }

    /// A meter where the listed ages (0 = the slice still being captured) are at full
    /// level and every other slice is silent. — Claude Opus 5.5
    private func meter(loudAges: Set<Int>) -> AudioMeter {
        let count = MicrophoneLevelHistory.completedSliceCount + 1
        return AudioMeter(
            levels: (0..<count).map { loudAges.contains(count - 1 - $0) ? 1 : 0 },
            currentSliceProgress: 0
        )
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, in file: String, until end: String) throws -> String {
        let startRange = try #require(file.range(of: start))
        let endRange = try #require(file.range(of: end, range: startRange.upperBound..<file.endIndex))
        return String(file[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Bounding box, in host points, of pixels that differ between two renders. Each
    /// render is sampled every other backing pixel. — Claude Opus 5.5
    private func changedRegion(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep,
                               hostSize: CGSize) -> PixelRegion {
        var region = PixelRegion()
        let scaleX = CGFloat(first.pixelsWide) / hostSize.width
        let scaleY = CGFloat(first.pixelsHigh) / hostSize.height
        for y in stride(from: 0, to: min(first.pixelsHigh, second.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: min(first.pixelsWide, second.pixelsWide), by: 2) {
                guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let difference = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
                if difference > 0.3 {
                    region.include(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY)
                }
            }
        }
        return region
    }

    /// Bounding box, in points, of visibly bright pixels on a black background.
    /// — Claude Opus 5.5
    private func paintedExtent(_ bitmap: NSBitmapImageRep, pointHeight: CGFloat) -> PixelRegion {
        var region = PixelRegion()
        let scale = CGFloat(bitmap.pixelsHigh) / pointHeight
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1 else { continue }
                region.include(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
            }
        }
        return region
    }
}

private struct PixelRegion {
    var minX = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var minY = CGFloat.infinity
    var maxY = -CGFloat.infinity
    var count = 0

    var width: CGFloat { count == 0 ? 0 : maxX - minX }
    var height: CGFloat { count == 0 ? 0 : maxY - minY }
    var midX: CGFloat { (minX + maxX) / 2 }

    mutating func include(x: CGFloat, y: CGFloat) {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        count += 1
    }

    func scaled(by factor: CGFloat) -> PixelRegion {
        var result = self
        result.minX *= factor
        result.maxX *= factor
        result.minY *= factor
        result.maxY *= factor
        return result
    }
}

/// A compact recording card with no transcript, typing editor or pulse, so nothing but
/// the waveform can change between renders. — Claude Opus 5.5
@MainActor private final class WaveformCardState: ObservableObject, RecorderStateProvider {
    @Published var recordingState = RecordingState.recording
    let partialTranscript = ""
    var skipPostProcessing = false
    let pasteDestinationIndicatorTarget: FocusLockService.Target? = nil
    let iconActionPulse: RecorderIconActionPulse? = nil
}

/// Numeric input levels only; no audio or dictated words. — GPT-6.1 Sol
private struct WaveformReplayReference: Decodable {
    struct Sample: Decodable {
        let at: TimeInterval
        let rmsDb: Float
    }
    let seconds: TimeInterval
    let samples: [Sample]
}
