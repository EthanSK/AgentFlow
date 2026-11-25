// Finite native performance diagnostic for the actual recorder cards, without capture,
// media controls or user settings. Timing is evidence, not a shared-runner pass/fail
// threshold. Set VIPP_RECORDER_PERFORMANCE_DIR for the opt-in measurement. — GPT-6.1 Sol
import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderPerformanceMeasurementTests {
    @Test @MainActor func measureThreeRecorderCardsWithLongDraftWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VIPP_RECORDER_PERFORMANCE_DIR"] else { return }
        let suiteName = "AgentFlowTests.Performance.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        settings.set(false, forKey: RecorderCaptureOutlinePreference.preferenceKey)
        let session = RecordingSession(phase: .recording)
        session.liveRecordingState = .recording
        session.partialTranscript = String(repeating: "Measured microphone feedback. ", count: 20)
        let recorder = Recorder()
        let assistant = AssistantSession()
        var panels: [NSPanel] = []
        var hosts: [NSView] = []
        for index in 0..<3 {
            let width: CGFloat = index == 2 ? MiniRecorderLayoutMetrics.liveTranscriptWidth : 640
            let card: AnyView = index == 2
                ? AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                    assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                    liveTranscriptHeight: 180, onRecordButtonTapped: {}, onCloseTapped: {},
                    onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                : AnyView(MiniRecorderView(stateProvider: session, liveTranscriptHeight: 180,
                    liveTranscriptWidth: width, recorder: recorder, assistantSession: assistant,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {},
                    onAssistantFollowUp: { _ in }))
            let panel = NSPanel(contentRect: NSRect(x: 20, y: CGFloat(20 + index * 300), width: width, height: 280),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let host = NSHostingView(rootView: card.frame(width: width, height: 280).defaultAppStorage(settings))
            panel.contentView = host
            panel.orderFrontRegardless()
            panels.append(panel)
            hosts.append(host)
        }
        defer { for panel in panels { panel.orderOut(nil); panel.close() } }
        var reports: [[String: Any]] = []
        for (name, waveform, outline, longDraft) in [
            ("still-baseline", false, false, false),
            ("waveform", true, false, false),
            ("waveform-and-outline", true, true, false),
            ("long-draft-baseline", false, false, true),
            ("long-draft-waveform", true, false, true),
            ("long-growing-draft", true, true, true)
        ] {
            settings.set(outline, forKey: RecorderCaptureOutlinePreference.preferenceKey)
            session.partialTranscript = String(repeating: "Measured microphone feedback. ", count: longDraft ? 2_500 : 20)
            recorder.audioMeter = .silent
            for host in hosts { host.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(800))
            var history = MicrophoneLevelHistory()
            var intervals: [Double] = []
            var previous = ProcessInfo.processInfo.systemUptime
            let started = previous
            let cpuStarted = cpuSeconds()
            for tick in 0..<180 {
                // Match the coalescing recorder cadence: never replay missed ticks in a burst.
                try await Task.sleep(for: .milliseconds(33))
                let now = ProcessInfo.processInfo.systemUptime
                intervals.append((now - previous) * 1_000)
                previous = now
                if waveform {
                    history.append(MicrophoneLevelWindow(duration: 0.033, rmsDecibels: tick % 20 < 8 ? -65 : -25))
                    recorder.audioMeter = history.meter
                }
                if longDraft && tick.isMultiple(of: 6) { session.partialTranscript += " spoken" }
                for host in hosts { host.layoutSubtreeIfNeeded() }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let cpu = cpuSeconds() - cpuStarted
            let sorted = intervals.sorted()
            let report: [String: Any] = ["scenario": name, "panels": panels.count,
                "ticks": intervals.count, "seconds": elapsed, "cpuPercentOfOneCore": 100 * cpu / elapsed,
                "tickP50Milliseconds": sorted[sorted.count / 2],
                "tickP95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "tickMaxMilliseconds": sorted.last!, "draftCharacters": session.partialTranscript.count]
            reports.append(report)
            print("Recorder performance: \(report)")
            #expect(intervals.count == 180)
            #expect(history.meter.levels.count == 16)
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["configuration": ProcessInfo.processInfo.environment["VIPP_RECORDER_PERFORMANCE_CONFIGURATION"] ?? "Debug native test host",
            "limits": "Synthetic microphone levels, three real hosted cards; no hardware capture, API/provider or physical playback timing. CPU includes the test host's other work. No fixed performance gate on a shared runner.",
            "outlineGeometry": measureOutlineGeometry(),
            "scenarios": reports], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("recorder-performance.json"))
    }

    @Test @MainActor func measureGrowingTextLayoutWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VIPP_RECORDER_RESIZE_PERFORMANCE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession(phase: .recording)
        session.liveRecordingState = .recording
        var measurements: [[String: Any]] = []
        for count in [500, 5_000, 20_000, 75_000] {
            let text = String(repeating: "Measured growing text. ", count: count / 23 + 1)
            for typed in [false, true] {
                session.partialTranscript = typed ? "Speech before typing." : text
                session.updateTypedInput(typed ? text : "")
                for width: CGFloat in [640, 1100] {
                    let coldStart = ProcessInfo.processInfo.systemUptime
                    let expected = session.liveContextHeight(width: width, maxHeight: 220)
                    let coldMs = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
                    var cached: [Double] = []
                    var uncached: [Double] = []
                    for iteration in 0..<11 {
                        // Alternate ordering. Timings are diagnostic, not a flaky
                        // shared-runner pass threshold. — GPT-6.1 Sol
                        for useCache in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                            let start = ProcessInfo.processInfo.systemUptime
                            for _ in 0..<3 {
                                let height = useCache
                                    ? session.liveContextHeight(width: width, maxHeight: 220)
                                    : MiniRecorderLayoutMetrics.contextHeight(parts: session.liveContextPreviewParts,
                                        typedText: session.typedInput, width: width, maxHeight: 220)
                                #expect(height == expected)
                            }
                            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                            if useCache { cached.append(elapsed) } else { uncached.append(elapsed) }
                        }
                    }
                    cached.sort(); uncached.sort()
                    measurements.append(["characters": text.count, "typed": typed, "width": width,
                        "coldMilliseconds": coldMs, "reads": 3,
                        "cachedP50Milliseconds": cached[5], "uncachedP50Milliseconds": uncached[5]])
                }
            }
        }
        let suite = "AgentFlowTests.Resize.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(false, forKey: RecorderCaptureOutlinePreference.preferenceKey)
        let recorder = Recorder()
        let assistant = AssistantSession()
        var panels: [NSPanel] = []
        var hosts: [NSView] = []
        for index in 0..<3 {
            let width: CGFloat = index == 0 ? 640 : 1100
            let panel = MiniRecorderPanel(contentRect: NSRect(x: CGFloat(index * 30), y: 0, width: width, height: 120))
            let host = NSHostingView(rootView: RecorderGrowingLayoutProbe(
                session: session, recorder: recorder, assistant: assistant,
                width: width, notch: index == 2).defaultAppStorage(settings))
            panel.contentView = host
            panel.orderFrontRegardless()
            panels.append(panel); hosts.append(host)
        }
        defer { for panel in panels { panel.orderOut(nil); panel.close() } }
        var frames: [[String: Any]] = []
        for count in [500, 5_000, 20_000, 75_000] {
            for typed in [false, true] {
                for growing in [false, true] {
                    session.microphoneOff = typed
                    session.partialTranscript = typed ? "Speech before typing." : String(repeating: "Growing spoken words. ", count: count / 22 + 1)
                    session.updateTypedInput(typed ? String(repeating: "Growing typed words. ", count: count / 21 + 1) : "")
                    var intervals: [Double] = []
                    var previous = ProcessInfo.processInfo.systemUptime
                    let cpuStart = cpuSeconds()
                    let start = previous
                    for tick in 0..<30 {
                        // The existing provider-cadence diagnostic yields instead
                        // of replaying missed ticks; no production wait is added.
                        // Fixed and growing controls share this cadence. — GPT-6.1 Sol
                        try await Task.sleep(for: .milliseconds(33))
                        if growing && tick.isMultiple(of: 3) {
                            if typed { session.updateTypedInput(session.typedInput + " word") }
                            else { session.partialTranscript += " word" }
                        }
                        for host in hosts { host.layoutSubtreeIfNeeded() }
                        let now = ProcessInfo.processInfo.systemUptime
                        intervals.append((now - previous) * 1_000); previous = now
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    let cpu = cpuSeconds() - cpuStart
                    intervals.sort()
                    frames.append(["startingCharacters": count, "typed": typed, "growing": growing,
                        "cpuPercentOfOneCore": 100 * cpu / elapsed,
                        "intervalP50Milliseconds": intervals[15], "intervalP95Milliseconds": intervals[27],
                        "panels": 3, "ticks": intervals.count])
                    #expect(intervals.count == 30)
                }
            }
        }
        let report: [String: Any] = ["configuration": "Debug native test host",
            "limits": "Synthetic growing speech/typing in three real recorder cards with actual height measurement and host sync. No microphone, provider, physical multi-display or GPU timing. Interval includes the33ms cadence and shared-host scheduling. Not a performance pass threshold.",
            "geometry": measurements, "hostedCards": frames]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("recorder-resize-performance.json"))
        print("Recorder growing-text diagnostic completed: \(measurements.count) geometry and \(frames.count) hosted scenarios")
    }

    // Time the actual cache-miss path during shape changes separately from GPU
    // compositing. Covers three cards at both HUD-scale extremes and Retina geometry;
    // keeps today's path sampler and appearance intact. — GPT-6.1 Sol
    private func measureOutlineGeometry() -> [[String: Any]] {
        var results: [[String: Any]] = []
        for scale: CGFloat in [0.5, 1] {
            for resizing in [false, true] {
                let traces = (0..<3).map { _ in RecorderCaptureOutlineTrace() }
                var times: [Double] = []
                var count = 0
                for frame in 0..<240 {
                    let started = ProcessInfo.processInfo.systemUptime
                    let fraction = resizing ? CGFloat(frame % 60) / 59 : 1
                    let size = CGSize(width: 324 + 776 * fraction, height: 40 + 280 * fraction)
                    let pixels = RecorderCaptureOutlinePixels(localSize: size,
                        frame: CGRect(x: 0.3, y: 0.7, width: size.width * scale, height: size.height * scale),
                        displayScale: 2)
                    let bounds = CGRect(origin: .zero, size: pixels.bounds.size)
                    let center = CGPoint(x: bounds.midX, y: bounds.midY)
                    for index in 0..<3 {
                        let rect = bounds.insetBy(dx: pixels.width / 2, dy: pixels.width / 2)
                        let path = index == 2
                            ? NotchShape(topCornerRadius: 8 + 4 * fraction, bottomCornerRadius: 16 + 6 * fraction).path(in: rect)
                            : RoundedRectangle(cornerRadius: 20 - 6 * fraction, style: .continuous).path(in: rect)
                        let aligned = pixels.aligned(path)
                        let samples = traces[index].samples(along: aligned, around: center)
                        let gradient = Gradient(stops: samples.map {
                            Gradient.Stop(color: RecorderNeonSpectrum.color(at: $0.clockwiseFraction - Double(frame) / 240),
                                          location: $0.angularLocation)
                        })
                        if index == 2 { _ = pixels.aligned(path, omittingTopEdge: true) }
                        count += gradient.stops.count
                    }
                    times.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                }
                let sorted = times.sorted()
                #expect(count == 240 * 3 * (RecorderCaptureOutlineTrace.sampleCount + 2))
                results.append(["scenario": resizing ? "resizing" : "cached", "hudScale": scale,
                    "panels": 3, "frames": times.count, "p95MillisecondsForThreeCards": sorted[227],
                    "maxMillisecondsForThreeCards": sorted.last!])
            }
        }
        return results
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

/// Exercise the actual card and host-height sync without an engine, capture or
/// notification lifecycle; each panel owns its normal session observation.
/// The cached measurement is the production stack's shared entry. — GPT-6.1 Sol
@MainActor private struct RecorderGrowingLayoutProbe: View {
    @ObservedObject var session: RecordingSession
    let recorder: Recorder
    let assistant: AssistantSession
    let width: CGFloat
    let notch: Bool
    var body: some View {
        let height = session.liveContextHeight(width: notch ? width - 16 : width, maxHeight: 220)
        Group {
            if notch {
                NotchRecorderView(stateProvider: session, recorder: recorder, assistantSession: assistant,
                    notchWidth: 180, notchHeight: 32, liveTranscriptHeight: height,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {}, onAssistantFollowUp: { _ in })
            } else {
                MiniRecorderView(stateProvider: session, liveTranscriptHeight: height,
                    liveTranscriptWidth: width, recorder: recorder, assistantSession: assistant,
                    onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {}, onAssistantFollowUp: { _ in })
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: notch ? .top : .bottom)
        .background(RecorderPanelHeightSync(desiredHeight: height + 52,
            edge: notch ? .top : .bottom, scale: 1, onLayoutChange: { _ in }))
    }
}
