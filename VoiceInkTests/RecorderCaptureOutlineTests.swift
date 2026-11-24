// Proves the Recording Outline's live-capture gate, saved-switch default, even
// colour sampling and rendered neon edge with synthetic sessions only. Nothing here
// starts microphone capture, playback, shortcuts or Primary/Next delivery.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderCaptureOutlineTests {
    @Test func olderBackupsOmitOutlineChoiceAndDisabledChoiceRoundTrips() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(GeneralBackup.self, from: Data("{}".utf8))
        #expect(old.recorderCaptureOutlineEnabled == nil)
        let disabled = try decoder.decode(GeneralBackup.self,
            from: Data("{\"recorderCaptureOutlineEnabled\":false}".utf8))
        let restored = try decoder.decode(GeneralBackup.self, from: JSONEncoder().encode(disabled))
        #expect(restored.recorderCaptureOutlineEnabled == false)
    }

    @Test @MainActor func outlineLightsOnlyWhileThisSessionsMicrophoneIsLive() {
        let session = RecordingSession()
        #expect(session.showsLiveCaptureOutline)

        session.liveRecordingState = .starting
        #expect(!session.showsLiveCaptureOutline)
        session.liveRecordingState = .recording

        // Microphone-off typing keeps the recording state but captures no audio.
        session.microphoneOff = true
        #expect(!session.showsLiveCaptureOutline)
        session.microphoneOff = false

        // Won't paste is a delivery choice; capture continues through its gesture
        // decision window and real stop tail, so the recording signal stays honest.
        session.completionDisposition = .clipboardOnly
        #expect(session.showsLiveCaptureOutline)
        session.completionDisposition = .normalDelivery

        for state in [RecordingState.paused, .transcribing, .enhancing, .idle, .busy] {
            session.liveRecordingState = state
            #expect(!session.showsLiveCaptureOutline, "\(state)")
        }
        session.liveRecordingState = .recording
        #expect(session.showsLiveCaptureOutline)
    }

    @Test @MainActor func traceSpreadsColourEvenlyAndFlowsClockwiseOnEveryCardShape() {
        let cases: [(String, Path, CGPoint)] = [
            ("compact mini", RoundedRectangle(cornerRadius: 20, style: .continuous)
                .path(in: CGRect(x: 0, y: 0, width: 324, height: 40)), CGPoint(x: 162, y: 20)),
            ("expanded mini", RoundedRectangle(cornerRadius: 14, style: .continuous)
                .path(in: CGRect(x: 0, y: 0, width: 1100, height: 260)), CGPoint(x: 550, y: 130)),
            ("active notch", NotchShape(topCornerRadius: 8, bottomCornerRadius: 16)
                .path(in: CGRect(x: 0, y: 0, width: 660, height: 38)), CGPoint(x: 330, y: 19)),
            ("live-text notch", NotchShape(topCornerRadius: 12, bottomCornerRadius: 22)
                .path(in: CGRect(x: 0, y: 0, width: 1100, height: 95)), CGPoint(x: 550, y: 47.5))
        ]
        let step = 1 / Double(RecorderCaptureOutlineTrace.sampleCount)
        for (name, path, center) in cases {
            let samples = RecorderCaptureOutlineTrace.trace(path, around: center)
            #expect(samples.count == RecorderCaptureOutlineTrace.sampleCount + 2, "\(name)")
            guard let first = samples.first, let last = samples.last else { continue }
            // Matching seam stops close the conic gradient without a visible break.
            #expect(first.angularLocation == 0 && last.angularLocation == 1, "\(name)")
            #expect(first.clockwiseFraction == last.clockwiseFraction, "\(name)")
            // Sorted by angle, neighbours are exactly one equal-length step apart
            // and advance clockwise, so colour is even along long and short edges.
            let interior = Array(samples.dropFirst().dropLast())
            for (earlier, later) in zip(interior, interior.dropFirst()) {
                #expect(earlier.angularLocation <= later.angularLocation, "\(name)")
                let advance = RecorderCaptureOutlineTrace.wrapped(
                    later.clockwiseFraction - earlier.clockwiseFraction
                )
                #expect(abs(advance - step) < 1e-9, "\(name)")
            }
        }
    }

    // Former neonSpectrumIsCyclicVividAndKeepsItsHueInTheHotCore: the hot core
    // was removed at Ethan's request; the single border keeps the same spectrum.
    @Test func rainbowSpectrumRemainsVividAndCyclic() {
        func channels(_ value: RecorderNeonSpectrum.Components) -> [Double] {
            [value.red, value.green, value.blue]
        }
        for index in 0..<420 {
            let position = Double(index) / 420
            let tube = channels(RecorderNeonSpectrum.components(at: position))
            let nextLap = channels(RecorderNeonSpectrum.components(at: position + 1))
            #expect(zip(tube, nextLap).allSatisfy { abs($0 - $1) < 1e-9 })
            let tubeChroma = tube.max()! - tube.min()!
            #expect(tubeChroma > 0.5, "position \(position)")
            #expect(tube.max()! > 0.85, "position \(position)")

        }
    }

    @Test @MainActor func miniAndNotchLightTheirEdgeOnlyForLiveCaptureAndTheSavedSwitch() async throws {
        // Private suites keep this independent of the installed app's real choice.
        let suitePrefix = "AgentFlowTests.RecordingOutline.\(UUID().uuidString)"
        let unsetDefaults = try #require(UserDefaults(suiteName: suitePrefix + ".unset"))
        let disabledDefaults = try #require(UserDefaults(suiteName: suitePrefix + ".off"))
        disabledDefaults.set(false, forKey: RecorderCaptureOutlinePreference.preferenceKey)
        defer {
            unsetDefaults.removePersistentDomain(forName: suitePrefix + ".unset")
            disabledDefaults.removePersistentDomain(forName: suitePrefix + ".off")
        }
        let recorder = Recorder()
        let assistant = AssistantSession()
        let inset = RecorderCaptureOutlineStyle.tubeInset
        let transcriptHeight: CGFloat = 56
        // A new session can type in the HUD, so both styles render their expanded
        // live-context card. Mini fills the 640pt host up from its bottom edge. The
        // Notch pill spans the 1,100pt host down from its top edge: 32pt notch, 6pt
        // row bonus, the transcript and its 1pt divider, with 12pt top flares.
        let notchPillHeight: CGFloat = 32 + 6 + transcriptHeight + 1
        let notchFlare: CGFloat = 12

        for style in ["mini", "notch"] {
            for (defaults, switchOn) in [(unsetDefaults, true), (disabledDefaults, false)] {
                let session = RecordingSession()
                let hostSize = CGSize(
                    width: style == "mini" ? 640 : MiniRecorderLayoutMetrics.liveTranscriptWidth,
                    height: 200
                )
                let card: AnyView = style == "mini"
                    ? AnyView(MiniRecorderView(stateProvider: session,
                        liveTranscriptHeight: transcriptHeight, liveTranscriptWidth: 640, recorder: recorder,
                        assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                    : AnyView(NotchRecorderView(stateProvider: session, recorder: recorder,
                        assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                        liveTranscriptHeight: transcriptHeight, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hostSize),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let host = NSHostingView(rootView: card
                    .frame(width: hostSize.width, height: hostSize.height)
                    .defaultAppStorage(defaults))
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }

                // Reuse one host across transitions, as the real mirrored panels do.
                let scenarios: [(String, RecordingState, Bool, RecordingCompletionDisposition)] = [
                    ("recording", .recording, false, .normalDelivery),
                    ("typing", .recording, true, .normalDelivery),
                    ("wont-paste", .recording, false, .clipboardOnly),
                    ("paused", .paused, false, .normalDelivery),
                    ("resumed", .recording, false, .normalDelivery)
                ]
                for (name, state, microphoneOff, disposition) in scenarios {
                    session.microphoneOff = microphoneOff
                    session.completionDisposition = disposition
                    session.liveRecordingState = state
                    host.layoutSubtreeIfNeeded()
                    // Let the real native card finish laying out before reading pixels.
                    try await Task.sleep(for: .milliseconds(500))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                        let folder = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let image = try #require(bitmap.representation(using: .png, properties: [:]))
                        try image.write(to: folder.appendingPathComponent(
                            "\(style)-\(switchOn ? "on" : "off")-\(name).png"))
                    }

                    // Each band lies on the tube's centre line, clear of every
                    // control, transcript line and corner curve.
                    var edge = EdgeBandReading()
                    var topOfNotch = EdgeBandReading()
                    if style == "mini" {
                        let bottom = hostSize.height - inset
                        edge.read(bitmap, hostSize: hostSize,
                                  x: 40...600, y: (bottom - 0.7)...(bottom + 0.7))
                        edge.read(bitmap, hostSize: hostSize,
                                  x: (inset - 0.4)...(inset + 0.6),
                                  y: (hostSize.height - 60)...(hostSize.height - 30))
                    } else {
                        let bottom = notchPillHeight - inset
                        edge.read(bitmap, hostSize: hostSize,
                                  x: 60...(hostSize.width - 60), y: (bottom - 0.7)...(bottom + 0.7))
                        let side = notchFlare + inset
                        edge.read(bitmap, hostSize: hostSize,
                                  x: (side - 0.4)...(side + 0.6), y: 42...68)
                        topOfNotch.read(bitmap, hostSize: hostSize, x: 300...800, y: 0.2...1.4)
                    }
                    let label = "\(style) switch=\(switchOn) \(name)"
                    // Every band sits on the opaque card, so a dark reading cannot
                    // come from sampling empty space beside it.
                    #expect(edge.sampled > 0 && edge.opaqueFraction > 0.9, "\(label)")

                    let lit = switchOn && (name == "recording" || name == "resumed" || name == "wont-paste")
                    if lit {
                        #expect(edge.saturatedFraction > 0.6, "\(label): \(edge.saturatedFraction)")
                        #expect(edge.hueBuckets.count >= 2, "\(label): \(edge.hueBuckets)")
                        if style == "notch" {
                            // The sharp U leaves the bezel edge unpainted.
                            #expect(topOfNotch.opaqueFraction > 0.9, "\(label)")
                            #expect(topOfNotch.saturatedFraction < 0.1, "\(label): \(topOfNotch.saturatedFraction)")
                        }
                    } else if name == "paused" {
                        // Only the existing dark orange Pause surface, never the rainbow.
                        #expect(edge.saturatedFraction > 0.6, "\(label): \(edge.saturatedFraction)")
                        #expect(edge.hueBuckets.count <= 1, "\(label): \(edge.hueBuckets)")
                    } else {
                        #expect(edge.saturatedFraction < 0.05, "\(label): \(edge.saturatedFraction)")
                    }
                }
            }
        }
    }

    @Test func bothStylesShareOneGateBeneathContentAndSettingsUsesTheSameKey() throws {
        for name in ["MiniRecorderView", "NotchRecorderView"] {
            let card = try source("VoiceInk/Views/Recorder/\(name).swift")
            #expect(card.contains("@AppStorage(RecorderCaptureOutlinePreference.preferenceKey)"))
            #expect(card.contains("captureOutlineEnabled && stateProvider.showsLiveCaptureOutline"))
            // Chained before the fill and the clip: above the card colour, beneath
            // every control and transcript line, and inside the card's silhouette.
            let outline = try #require(card.range(of: "RecorderCaptureOutline(shape:"))
            let fill = try #require(card.range(of: "RecorderPanelAppearance.pausedBackground"))
            let clip = try #require(card.range(of: ".clipShape("))
            #expect(outline.lowerBound < fill.lowerBound && fill.lowerBound < clip.lowerBound)
        }
        let outline = try source("VoiceInk/Views/Recorder/RecorderCaptureOutline.swift")
        #expect(outline.contains(".allowsHitTesting(false)"))
        #expect(outline.contains("paused: reduceMotion"))
        let settings = try source("VoiceInk/Views/Settings/SettingsView.swift")
        #expect(settings.contains("@AppStorage(RecorderCaptureOutlinePreference.preferenceKey)"))
        #expect(settings.contains("Toggle(\"Recording Outline\""))
    }

    @Test @MainActor func coloursActuallyMoveAndReduceMotionHoldsThemStill() async throws {
        // Render only the decorative leaf. No capture, session, meter, media or
        // focus-sensitive recorder action is involved. — GPT-6.1 Sol
        let size = CGSize(width: 500, height: 80)
        for reduced in [false, true] {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            let root = RecorderCaptureOutline(shape: shape, reduceMotionForPreview: reduced)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .clipShape(shape)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: root)
            panel.contentView = host
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.close() }

            var frames: [NSBitmapImageRep] = []
            for frame in 0..<2 {
                try await Task.sleep(for: .milliseconds(550))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                frames.append(bitmap)
                // Ethan asked for no gradient into the black interior. The old
                // blurred bloom painted these pixels; the thin border must not.
                let sx = CGFloat(bitmap.pixelsWide) / size.width
                let sy = CGFloat(bitmap.pixelsHigh) / size.height
                for x in stride(from: CGFloat(30), through: 470, by: 10) {
                    for y in [CGFloat(3), 5, 7] {
                        let c = try #require(bitmap.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.sRGB))
                        #expect(max(c.redComponent, c.greenComponent, c.blueComponent) < 0.015)
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: folder.appendingPathComponent("\(reduced ? "reduced-motion" : "flow")-frame-\(frame).png"))
                }
            }
            var changed = 0
            for y in stride(from: 0, to: frames[0].pixelsHigh, by: 2) {
                for x in stride(from: 0, to: frames[0].pixelsWide, by: 2) {
                    let a = try #require(frames[0].colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let b = try #require(frames[1].colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let difference = abs(a.redComponent - b.redComponent)
                        + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    if difference > 0.12 { changed += 1 }
                }
            }
            #expect(reduced ? changed < 8 : changed > 100,
                "Reduce Motion=\(reduced), changed sampled pixels=\(changed)")
        }
    }

    @Test @MainActor func compactExpandedAndFinishingPanelAppearance() async throws {
        // The regular session owns a typing editor from start. This presentation-
        // only fixture also exercises batch/compact layouts without that editor.
        let state = OutlineAppearanceState()
        let recorder = Recorder()
        let assistant = AssistantSession()
        for style in ["mini", "notch"] {
            for (name, expanded, phase) in [
                ("compact", false, RecordingState.recording),
                ("expanded", true, .recording),
                ("finishing", false, .transcribing)
            ] {
                state.showsRealtimeTranscriptHUD = expanded
                state.recordingState = phase
                let width = style == "mini" ? 640 : MiniRecorderLayoutMetrics.liveTranscriptWidth
                let card: AnyView = style == "mini"
                    ? AnyView(MiniRecorderView(stateProvider: state,
                        liveTranscriptHeight: 180, liveTranscriptWidth: 640, recorder: recorder,
                        assistantSession: assistant, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                    : AnyView(NotchRecorderView(stateProvider: state, recorder: recorder,
                        assistantSession: assistant, notchWidth: 180, notchHeight: 32,
                        liveTranscriptHeight: 180, onRecordButtonTapped: {}, onCloseTapped: {},
                        onCancelTapped: {}, onAssistantFollowUp: { _ in }))
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let host = NSHostingView(rootView: card.frame(width: width, height: 300))
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide >= Int(width))
                if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: folder.appendingPathComponent("\(style)-\(name)-appearance.png"))
                }
            }
        }
    }

    @Test func outlineFitsWholePixelsOnStandardAndRetinaDisplays() {
        for display: CGFloat in [1, 2] {
            for hudScale: CGFloat in [0.5, 0.85, 1] {
                let size = CGSize(width: 640, height: 101)
                let frame = CGRect(x: 0.3, y: 0.7, width: size.width * hudScale, height: size.height * hudScale)
                let pixels = RecorderCaptureOutlinePixels(localSize: size, frame: frame, displayScale: display)
                let density = display * hudScale
                #expect(abs(pixels.width * density - (pixels.width * density).rounded()) < 1e-9)
                let path = pixels.aligned(Rectangle().path(in: pixels.bounds.insetBy(
                    dx: pixels.width / 2, dy: pixels.width / 2)))
                let physical = path.boundingRect.applying(CGAffineTransform(scaleX: density, y: density))
                    .offsetBy(dx: frame.minX * display, dy: frame.minY * display)
                let half = pixels.width * density / 2
                for edge in [physical.minX - half, physical.minY - half,
                             physical.maxX + half, physical.maxY + half] {
                    #expect(abs(edge - edge.rounded()) < 1e-9)
                }
                #expect(physical.minX - half >= frame.minX * display - 1e-9)
                #expect(physical.maxX + half <= frame.maxX * display + 1e-9)
            }
        }
    }

    @Test @MainActor func scaledOutlinePaintsEveryStraightEdgeEvenly() async throws {
        for scale: CGFloat in [0.5, 0.85, 1] {
            for style in ["mini", "notch"] {
                let sourceSize = CGSize(width: 640, height: 101)
                let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
                let outline: AnyView = style == "mini"
                    ? AnyView(RecorderCaptureOutline(shape: RoundedRectangle(cornerRadius: 14),
                        reduceMotionForPreview: true))
                    : AnyView(RecorderCaptureOutline(shape: NotchShape(topCornerRadius: 12, bottomCornerRadius: 22),
                        omitsTopEdge: true, reduceMotionForPreview: true))
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                let host = ScaledRecorderHostingView(rootView: AnyView(outline
                    .frame(width: sourceSize.width - 0.6, height: sourceSize.height - 0.6)
                    .padding(0.3)), scale: scale)
                panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let sx = CGFloat(bitmap.pixelsWide) / size.width
                let sy = CGFloat(bitmap.pixelsHigh) / size.height
                func alpha(x: Int, y: Int) -> CGFloat {
                    bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                }
                let middleX = bitmap.pixelsWide / 2
                let middleY = bitmap.pixelsHigh / 2
                let sideInset = Int((style == "notch" ? 12 : 0) * scale * sx)
                let band = max(4, Int(4 * sx))
                let left = (sideInset..<(sideInset + band)).map { alpha(x: $0, y: middleY) }.max() ?? 0
                let right = ((bitmap.pixelsWide - sideInset - band)..<(bitmap.pixelsWide - sideInset))
                    .map { alpha(x: $0, y: middleY) }.max() ?? 0
                let bottom = ((bitmap.pixelsHigh - Int(4 * sy))..<bitmap.pixelsHigh)
                    .map { alpha(x: middleX, y: $0) }.max() ?? 0
                let top = (0..<Int(4 * sy)).map { alpha(x: middleX, y: $0) }.max() ?? 0
                let edges = style == "mini" ? [left, right, top, bottom] : [left, right, bottom]
                #expect((edges.min() ?? 0) > 0.9, "\(style) scale=\(scale) edges=\(edges)")
                if let directory = ProcessInfo.processInfo.environment["VIPP_OUTLINE_SNAPSHOT_DIR"] {
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(style)-scaled-\(scale).png"))
                }
            }
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor private final class OutlineAppearanceState: ObservableObject, RecorderStateProvider {
    @Published var recordingState = RecordingState.recording
    @Published var showsRealtimeTranscriptHUD = false
    let partialTranscript = "The flowing rainbow stays around the panel while the transcript grows.\nControls and text remain clear inside the neon edge."
    var skipPostProcessing = false
    let pasteDestinationIndicatorTarget: FocusLockService.Target? = nil
    let iconActionPulse: RecorderIconActionPulse? = nil
}

/// Counts opaque and vivid pixels plus their hue sextants inside a thin band of a
/// rendered recorder card, so tests can tell the rainbow tube from black glass and
/// from the single-hue Pause surface. — Claude Opus 5.5
private struct EdgeBandReading {
    var sampled = 0
    var opaque = 0
    var saturated = 0
    var hueBuckets = Set<Int>()

    var opaqueFraction: Double {
        sampled == 0 ? 0 : Double(opaque) / Double(sampled)
    }

    var saturatedFraction: Double {
        sampled == 0 ? 0 : Double(saturated) / Double(sampled)
    }

    /// Reads every backing-pixel row whose centre lies in `y` (points, top-left
    /// origin), stepping two pixels across `x`. — Claude Opus 5.5
    mutating func read(
        _ bitmap: NSBitmapImageRep, hostSize: CGSize,
        x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>
    ) {
        let scaleX = CGFloat(bitmap.pixelsWide) / hostSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hostSize.height
        let firstRow = max(0, Int((y.lowerBound * scaleY - 0.5).rounded(.up)))
        let lastRow = min(bitmap.pixelsHigh - 1, Int((y.upperBound * scaleY - 0.5).rounded(.down)))
        let firstColumn = max(0, Int(x.lowerBound * scaleX))
        let lastColumn = min(bitmap.pixelsWide - 1, Int(x.upperBound * scaleX))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }
        for row in firstRow...lastRow {
            for column in stride(from: firstColumn, through: lastColumn, by: 2) {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                sampled += 1
                if color.alphaComponent > 0.9 { opaque += 1 }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let brightest = max(red, green, blue)
                let chroma = brightest - min(red, green, blue)
                guard chroma > 0.2, brightest > 0.35 else { continue }
                saturated += 1
                var sextant: Double
                if brightest == red {
                    sextant = (green - blue) / chroma
                } else if brightest == green {
                    sextant = (blue - red) / chroma + 2
                } else {
                    sextant = (red - green) / chroma + 4
                }
                if sextant < 0 { sextant += 6 }
                hueBuckets.insert(Int(sextant) % 6)
            }
        }
    }
}
