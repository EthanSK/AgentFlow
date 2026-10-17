import AppKit
import ImageIO
import Testing
@testable import VoiceInkPlusPlus

@MainActor
struct TelegramSelectionImageTests {
    private let window = CGRect(x: -900, y: 100, width: 800, height: 700)
    private var gesture: LiveSelectionGesture {
        .init(mouseDown: CGPoint(x: -700, y: 300), mouseUp: CGPoint(x: -300, y: 400), displays: [window])
    }

    @Test func telegramImageFallbackRequiresConsentGestureAndNoAXText() {
        var resolution = LiveSelectionResolution()
        resolution.emptyHitTests = 2
        func allowed(_ enabled: Bool = true, _ bundle: String? = TelegramSelectionImageCapture.bundleID,
                     _ prior: Bool = false, _ g: LiveSelectionGesture? = nil,
                     _ r: LiveSelectionResolution? = nil) -> Bool {
            TelegramSelectionImageCapture.mayCapture(enabled: enabled, sourceBundleID: bundle,
                precedesSpeech: prior, gesture: g ?? gesture, resolution: r ?? resolution)
        }
        #expect(allowed())
        #expect(!allowed(false))
        #expect(!allowed(true, "com.openai.codex"))
        #expect(!allowed(true, nil))
        #expect(!allowed(true, TelegramSelectionImageCapture.bundleID, true))
        #expect(!TelegramSelectionImageCapture.mayCapture(enabled: true,
            sourceBundleID: TelegramSelectionImageCapture.bundleID, precedesSpeech: false,
            gesture: nil, resolution: resolution))
        for keyPath in [\LiveSelectionResolution.refusedSecure, \.examinedElements,
                        \.rejectedElsewhere, \.rejectedOutsideSourceWindow] {
            var rejected = resolution
            rejected[keyPath: keyPath] = 1
            #expect(!allowed(true, TelegramSelectionImageCapture.bundleID, false, gesture, rejected))
        }
        resolution.accessibilityTrusted = false
        #expect(!allowed())
        resolution.accessibilityTrusted = true
        resolution.budgetExhausted = true
        #expect(!allowed())
        resolution.budgetExhausted = false
        resolution.emptyHitTests = 1
        #expect(!allowed())
    }

    @Test func telegramImageCropIsGestureBoundedAcrossNegativeDisplayCoordinates() throws {
        let crop = try #require(TelegramSelectionImageCapture.cropRect(gesture: gesture, window: window))
        #expect(crop == CGRect(x: 152, y: 164, width: 496, height: 172))
        var outside = gesture
        outside = .init(mouseDown: outside.mouseDown, mouseUp: CGPoint(x: 900, y: 400), displays: [window])
        #expect(TelegramSelectionImageCapture.cropRect(gesture: outside, window: window) == nil)
        let click = LiveSelectionGesture(mouseDown: gesture.mouseDown, mouseUp: gesture.mouseDown, displays: [window])
        #expect(TelegramSelectionImageCapture.cropRect(gesture: click, window: window) == nil)
        var double = click
        double.clickCount = 2
        let small = try #require(TelegramSelectionImageCapture.cropRect(gesture: double, window: window))
        #expect(small.height == 96 && small.width <= 480)
        #expect(CGRect(origin: .zero, size: window.size).contains(small))
    }

    private func image(blank: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        if !blank {
            context.setFillColor(NSColor.cyan.cgColor)
            context.fill(CGRect(x: 32, y: 16, width: 64, height: 32))
        }
        return try #require(context.makeImage())
    }

    @Test func telegramImageStorageIsPrivateExclusiveAndRejectsBlankOrRedirectedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("images")
        let first = try TelegramSelectionImageCapture.save(image(), directory: directory)
        let second = try TelegramSelectionImageCapture.save(image(), directory: directory)
        #expect(first != second)
        #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(AgentFlowPromptViewer.screenshotPreview(path: first.path) != nil)
        #expect(throws: (any Error).self) { try TelegramSelectionImageCapture.save(image(blank: true), directory: directory) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(throws: (any Error).self) { try TelegramSelectionImageCapture.save(image(), directory: link) }
        TelegramSelectionImageCapture.discard(second)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func telegramImageTimelineViewerHistoryAndCopyKeepOneHonestImageReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try TelegramSelectionImageCapture.save(image(), directory: root)
        let reference = try #require(LiveSelectionReference(telegramSelectionImageURL: file))
            .anchored(after: "before").timed(at: Date(timeIntervalSince1970: 100))
        let timeline = LiveSelectionReference.interleaving([reference], with: "before after", includeTiming: true)
        let events = AgentFlowPromptViewer.events(timeline)
        #expect(events.map(\.tag) == ["speech", "app_selection_image", "speech"])
        #expect(events[1].attributes["scope"] == "gesture_area")
        #expect(events[1].attributes["exact_selection"] == "false")
        #expect(events[1].attributes["captured_at"] == "100.000")
        #expect(events[1].attributes["path"] == file.path)
        #expect(!timeline.contains("<local_screenshot") && !timeline.contains("<text>"))
        #expect(HistoryContextPresentation.hasFlowMarkers(timeline))
        #expect(HistoryContextPresentation.copyText(timeline, format: .plain) == "before\n\nafter")
        #expect(HistoryContextPresentation.copyText(timeline, format: .formatted) == timeline)
        #expect(LiveSelectionReference.previewParts([reference], with: "before after")
            .contains(.selection("Telegram — Selection image")))
        let html = AgentFlowPromptViewer.html(timeline)
        #expect(html.contains("<h2>Selection image</h2>"))
        #expect(html.contains("Highlighted area; nearby text may be included."))
        #expect(html.components(separatedBy: "<img ").count == 2)
        #expect(!html.contains("Preview unavailable"))
        let styled = LiveSelectionReference.interleaving([reference], with: "before after", presentation: .styledMath)
        let decoded = HistoryContextPresentation.document(styled).plainText
        #expect(AgentFlowPromptViewer.events(decoded).filter { $0.tag == "app_selection_image" }.count == 1)
        if let path = ProcessInfo.processInfo.environment["AGENTFLOW_TELEGRAM_IMAGE_FIXTURE_PATH"] {
            try Data(html.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
