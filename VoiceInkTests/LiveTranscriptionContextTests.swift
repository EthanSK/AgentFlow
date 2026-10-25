import Foundation
import CoreText
import ImageIO
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

private final class ReferenceHintTestProvider: LiveContextStreamingTranscriptionProvider, @unchecked Sendable {
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let output: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let lock = NSLock()
    private var recorded: [String] = []
    private var contexts: [TranscriptionRequestContext] = []
    let rejectsUpdates: Bool
    let rejectsConnection: Bool
    let acknowledgement: (@Sendable () async -> Void)?
    var snapshot: [String] { lock.withLock { recorded } }
    var contextSnapshot: [TranscriptionRequestContext] { lock.withLock { contexts } }

    init(rejectsUpdates: Bool = false, rejectsConnection: Bool = false,
         acknowledgement: (@Sendable () async -> Void)? = nil) {
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        output = pair.continuation
        self.rejectsUpdates = rejectsUpdates
        self.rejectsConnection = rejectsConnection
        self.acknowledgement = acknowledgement
    }

    func connect(model: any TranscriptionModel, language: String?, context: TranscriptionRequestContext) async throws {
        lock.withLock { recorded.append("connect"); contexts.append(context) }
        if rejectsConnection { throw StreamingTranscriptionError.serverError("Synthetic startup rejection") }
        output.yield(.sessionStarted)
    }
    func updateTranscriptionContext(_ context: TranscriptionRequestContext) async throws {
        lock.withLock { recorded.append("context"); contexts.append(context) }
        if rejectsUpdates { throw StreamingTranscriptionError.serverError("Synthetic rejected hint") }
        await acknowledgement?()
    }
    func sendAudioChunk(_ data: Data) async throws { lock.withLock { recorded.append("audio") } }
    func commit() async throws {
        lock.withLock { recorded.append("commit") }
        output.yield(.committed(text: "spoken words only"))
    }
    func disconnect() async { output.finish() }
}

private final class ReferenceHintFallback: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranscriptionRequestContext] = []
    var contexts: [TranscriptionRequestContext] { lock.withLock { values } }
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        lock.withLock { values.append(context) }
        return "spoken words only"
    }
}

private actor ReferenceHintOCRGate {
    private var result: CheckedContinuation<String?, Never>?
    private(set) var started = false
    func read() async -> String? {
        started = true
        return await withCheckedContinuation { result = $0 }
    }
    func complete(_ text: String) { result?.resume(returning: text); result = nil }
}

struct LiveTranscriptionContextTests {
    private let base = TranscriptionRequestContext(language: "en", prompt: "A design conversation.", vocabulary: ["Scarlett", "AC-42"])

    @MainActor private func model(provider: ModelProvider = .openAI) -> CloudModel {
        CloudModel(name: OpenAITranscriptionConfiguration.liveModelName,
                   displayName: "Offline transcription", description: "Offline only",
                   provider: provider, speed: 1, accuracy: 1, isMultilingual: true,
                   supportsStreaming: true, supportedLanguages: ["en": "English"])
    }

    @MainActor private func harness(_ provider: ReferenceHintTestProvider) throws
        -> (StreamingTranscriptionService, ModelContainer) {
        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return (StreamingTranscriptionService(modelContext: ModelContext(container), providerFactory: { _ in provider }), container)
    }

    @Test func hintsAreBoundedDataAndNeverBecomeVocabularyOrLegacyPrompt() throws {
        let reference = "Account \"AC-42\" \\ dashboard\n" + String(repeating: "specialized terminology ", count: 50)
        let context = base.withLiveReference(reference)
        let prompt = try #require(context.openAITranscriptionPrompt)
        #expect(context.prompt == base.prompt)
        #expect(context.vocabulary == base.vocabulary)
        #expect(context.language == base.language)
        #expect(context.liveReferenceText!.count <= 320)
        #expect(prompt.count <= OpenAITranscriptionConfiguration.promptCharacterLimit)
        #expect(prompt.hasPrefix(base.prompt! + "\n\nCurrent reference: "))
        let encoded = String(prompt.split(separator: "\n").last!.dropFirst("Current reference: ".count))
        #expect(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)) == context.liveReferenceText)
        #expect(context.withLiveReference("new topic").openAITranscriptionPrompt?.contains("specialized") == false)
    }

    @Test func fullStaticPromptWinsAndEscapedHintsFitWithoutSlicingJSON() throws {
        let full = TranscriptionRequestContext(language: "en", prompt: String(repeating: "x", count: 992), vocabulary: [])
        #expect(full.withLiveReference("new topic").openAITranscriptionPrompt == full.prompt)
        let escaped = base.withLiveReference(String(repeating: "\"\\ ", count: 100))
        #expect(escaped.openAITranscriptionPrompt!.count <= 992)
        #expect(escaped.openAITranscriptionPrompt!.hasSuffix("\""))
        #expect(base.withLiveReference("\n \t").openAITranscriptionPrompt == base.openAITranscriptionPrompt)
    }

    @Test func nonLatinTextAndJoinedEmojiFitAConservativeWireBudget() throws {
        for reference in [String(repeating: "你好世界", count: 100),
                          String(repeating: "👩🏽‍💻", count: 400),
                          "https://example.test/" + String(repeating: "identifier", count: 60)] {
            let context = base.withLiveReference(reference)
            #expect(context.liveReferenceText?.isEmpty == false)
            let prompt = try #require(context.openAITranscriptionPrompt)
            #expect(prompt.contains("Current reference: "))
            #expect(prompt.utf8.count <= 992)
            let encoded = String(prompt.split(separator: "\n").last!.dropFirst("Current reference: ".count))
            #expect(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)).isEmpty == false)
        }
    }

    @Test func originalSelectionIsSeparateFromTypedProseTimingAndImages() throws {
        let reference = try #require(LiveSelectionReference("unabridged selected source"))
        guard case .text(let text) = reference.recognitionSource else { Issue.record("Missing source text"); return }
        #expect(text == "unabridged selected source")
        #expect(text != reference.preview)
        #expect(LiveSelectionReference(typedText: "authored words")?.recognitionSource == nil)
        #expect(LiveSelectionReference.speechTiming(after: "spoken", startedAt: Date(), endedAt: Date()).recognitionSource == nil)
        let url = URL(fileURLWithPath: "/tmp/explicit-capture.png")
        let screenshot = try #require(LiveSelectionReference(screenshotURL: url))
        guard case .image(let image) = screenshot.recognitionSource else { Issue.record("Missing captured image"); return }
        #expect(image == url)
    }

    @Test func OCRReadsOnlyTheSuppliedSavedImageAndHandlesMissingFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("captured.png")
        let graphics = try #require(CGContext(data: nil, width: 900, height: 160,
            bitsPerComponent: 8, bytesPerRow: 900 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        graphics.setFillColor(CGColor(gray: 1, alpha: 1))
        graphics.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
        graphics.textPosition = CGPoint(x: 30, y: 55)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Scarlett AC-42", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 58, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        CTLineDraw(line, graphics)
        let image = try #require(graphics.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let text = await LiveTranscriptionContext.imageText(url)
        #expect(text?.contains("Scarlett") == true)
        #expect(text?.contains("AC-42") == true)
        #expect(await LiveTranscriptionContext.imageText(folder.appendingPathComponent("missing.png")) == nil)
    }

    @Test func latestHintCoalescesAndStopDrainsButCancelDiscards() {
        let buffer = LiveTranscriptionContextBuffer()
        buffer.offer(base.withLiveReference("first"))
        buffer.offer(base.withLiveReference("latest"))
        buffer.finish()
        buffer.offer(base.withLiveReference("too late"))
        #expect(buffer.take()?.liveReferenceText == "latest")
        #expect(buffer.take() == nil)
        let canceled = LiveTranscriptionContextBuffer()
        canceled.offer(base.withLiveReference("discarded"))
        canceled.finish(discard: true)
        #expect(canceled.take() == nil)
        let deduped = LiveTranscriptionContextBuffer()
        deduped.offer(base.withLiveReference("same"))
        _ = deduped.take()
        deduped.offer(base.withLiveReference("same"))
        #expect(deduped.take() == nil)
    }

    @Test func clearingAHintIsAnExplicitEmptyPromptAndDoesNotResetSessionSettings() throws {
        let update = OpenAITranscriptionConfiguration.realtimeContextUpdate(prompt: nil)
        let session = try #require(update["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["prompt"] as? String == "")
        #expect(Set(transcription.keys) == ["prompt"])
        #expect(Set(input.keys) == ["transcription"])
        #expect(session["type"] as? String == "transcription")
    }

    @Test @MainActor func lateScreenshotOCRCannotReplaceNewerSelectionOrSurviveStop() async throws {
        for stop in [false, true] {
            let gate = ReferenceHintOCRGate()
            var hints: [String?] = []
            let capture = LiveTranscriptionReferenceCapture(imageText: { _ in await gate.read() }, onHint: { hints.append($0) })
            capture.accept(.image(URL(fileURLWithPath: "/tmp/captured.png")))
            while !(await gate.started) { await Task.yield() }
            if stop { capture.finish() } else { capture.accept(.text("new selection")) }
            await gate.complete("obsolete screenshot text")
            for _ in 0..<10 { await Task.yield() }
            #expect(hints == (stop ? [] : ["new selection"]))
            capture.finish()
            capture.accept(.text("after stop"))
            #expect(hints == (stop ? [] : ["new selection"]))
        }
    }

    @Test @MainActor func serialSenderCoalescesHintsBeforeAudioAndCommitsOnlyOnce() async throws {
        let provider = ReferenceHintTestProvider()
        let (service, container) = try harness(provider)
        _ = container
        service.updateTranscriptionContext(base.withLiveReference("obsolete"))
        service.updateTranscriptionContext(base.withLiveReference("AC-42 account"))
        service.sendAudioChunk(Data([1, 2]))
        try await service.startStreaming(model: model(), context: base)
        let result = try await service.stopAndGetFinalText()
        #expect(provider.snapshot == ["connect", "context", "audio", "commit"])
        #expect(result == "spoken words only")
        #expect(!result.contains("AC-42"))
        #expect(service.audioWasComplete)
        #expect(provider.contextSnapshot.last?.vocabulary == base.vocabulary)
    }

    @Test @MainActor func noFollowingAudioStillDrainsTheLastContextBeforeCommit() async throws {
        let provider = ReferenceHintTestProvider()
        let (service, container) = try harness(provider)
        _ = container
        try await service.startStreaming(model: model(), context: base)
        service.updateTranscriptionContext(base.withLiveReference("final highlight"))
        _ = try await service.stopAndGetFinalText()
        #expect(provider.snapshot == ["connect", "context", "commit"])
        service.updateTranscriptionContext(base.withLiveReference("after final"))
        #expect(provider.contextSnapshot.last?.liveReferenceText == "final highlight")
    }

    @Test @MainActor func audioAndCommitWaitForTheContextAcknowledgement() async throws {
        let gate = ReferenceHintOCRGate()
        let provider = ReferenceHintTestProvider(acknowledgement: { _ = await gate.read() })
        let (service, container) = try harness(provider)
        _ = container
        try await service.startStreaming(model: model(), context: base)
        service.updateTranscriptionContext(base.withLiveReference("pending acknowledgement"))
        service.sendAudioChunk(Data([1, 2]))
        while !(await gate.started) { await Task.yield() }
        let stopping = Task { @MainActor in try await service.stopAndGetFinalText() }
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.snapshot == ["connect", "context"])
        await gate.complete("acknowledged")
        #expect(try await stopping.value == "spoken words only")
        #expect(provider.snapshot == ["connect", "context", "audio", "commit"])
    }

    @Test @MainActor func rejectedHintUsesTheCompleteWAVWithOriginalGuidanceOnce() async throws {
        let provider = ReferenceHintTestProvider(rejectsUpdates: true)
        let (service, container) = try harness(provider)
        _ = container
        let fallback = ReferenceHintFallback()
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: fallback)
        let config = TranscriptionRuntimeConfiguration(mode: nil, model: model(), language: "en", isRealtimeEnabled: true, requestContext: base)
        let audio = try #require(try await session.prepare(configuration: config))
        session.updateRecognitionReference("current selection")
        audio(Data([1, 2]))
        let result = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/existing-recording.wav"))
        #expect(result == "spoken words only")
        #expect(provider.snapshot == ["connect", "context", "audio"])
        #expect(!service.audioWasComplete)
        #expect(fallback.contexts.count == 1)
        #expect(fallback.contexts.first == base)
        #expect(provider.contextSnapshot.last?.liveReferenceText == "current selection")
        session.updateRecognitionReference("new recording must not leak")
        #expect(fallback.contexts.first?.liveReferenceText == nil)
    }

    @Test @MainActor func initialHintAndFileFallbackRemainRecordingOwnedAcrossOverlap() async throws {
        let provider = ReferenceHintTestProvider()
        let (service, container) = try harness(provider)
        _ = container
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: ReferenceHintFallback())
        session.updateRecognitionReference("initial selected term")
        let config = TranscriptionRuntimeConfiguration(mode: nil, model: model(), language: "en", isRealtimeEnabled: true, requestContext: base)
        _ = try await session.prepare(configuration: config)
        _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/recording-a.wav"))
        #expect(provider.snapshot == ["connect", "commit"])
        #expect(provider.contextSnapshot.first?.liveReferenceText == "initial selected term")
        let a = RecordingSession(), b = RecordingSession()
        a.transcriptionConfiguration = config
        b.transcriptionConfiguration = config
        a.recordLiveSelection(try #require(LiveSelectionReference("recording A term")))
        b.recordLiveSelection(try #require(LiveSelectionReference("recording B term")))
        a.recordLiveSelection(try #require(LiveSelectionReference("late initial")), precedesSpeech: true)
        a.endLiveSelectionCapture()
        a.recordLiveSelection(try #require(LiveSelectionReference("after stop")))
        #expect(a.transcriptionConfigurationWithLiveReference?.requestContext.liveReferenceText == "recording A term")
        #expect(b.transcriptionConfigurationWithLiveReference?.requestContext.liveReferenceText == "recording B term")
        #expect(a.transcriptionConfiguration?.requestContext == base)
    }

    @Test @MainActor func otherProvidersKeepTheOriginalRequestAndReceiveNoLiveHint() async throws {
        let provider = ReferenceHintTestProvider()
        let (service, container) = try harness(provider)
        _ = container
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: ReferenceHintFallback())
        session.updateRecognitionReference("before model selection")
        _ = try await session.prepare(configuration: TranscriptionRuntimeConfiguration(mode: nil,
            model: model(provider: .soniox), language: "en", isRealtimeEnabled: true, requestContext: base))
        session.updateRecognitionReference("later captured selection")
        _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/non-openai.wav"))
        #expect(provider.snapshot == ["connect", "commit"])
        #expect(provider.contextSnapshot == [base])
    }

    @Test @MainActor func rejectedInitialHintCannotPoisonCompletedAudioFallback() async throws {
        let provider = ReferenceHintTestProvider(rejectsConnection: true)
        let (service, container) = try harness(provider)
        _ = container
        let fallback = ReferenceHintFallback()
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: fallback)
        session.updateRecognitionReference("initial reference")
        _ = try await session.prepare(configuration: TranscriptionRuntimeConfiguration(mode: nil,
            model: model(), language: "en", isRealtimeEnabled: true, requestContext: base))
        #expect(try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/recording.wav")) == "spoken words only")
        #expect(provider.contextSnapshot.first?.liveReferenceText == "initial reference")
        #expect(fallback.contexts == [base])
        #expect(provider.snapshot == ["connect"])
    }

    @Test @MainActor func recordingStartSelectionReplaysThroughItsAttachedStreamingSession() async throws {
        let provider = ReferenceHintTestProvider()
        let (service, container) = try harness(provider)
        _ = container
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: ReferenceHintFallback())
        let recording = RecordingSession()
        let config = TranscriptionRuntimeConfiguration(mode: nil, model: model(), language: "en",
            isRealtimeEnabled: true, requestContext: base)
        recording.transcriptionConfiguration = config
        recording.recordLiveSelection(try #require(LiveSelectionReference("preparation-time selection")))
        recording.transcriptionSession = session
        _ = try await session.prepare(configuration: config)
        recording.endLiveSelectionCapture()
        _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/tmp/recording.wav"))
        #expect(provider.contextSnapshot.first == recording.transcriptionConfigurationWithLiveReference?.requestContext)
        #expect(provider.contextSnapshot.first?.liveReferenceText == "preparation-time selection")
        #expect(provider.snapshot == ["connect", "commit"])
    }
}
