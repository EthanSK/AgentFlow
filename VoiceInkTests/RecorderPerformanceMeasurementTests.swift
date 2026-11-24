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
