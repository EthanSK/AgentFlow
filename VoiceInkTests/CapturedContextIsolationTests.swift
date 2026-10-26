import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

private final class FrozenContextProvider: ContextualStreamingTranscriptionProvider, @unchecked Sendable {
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let lock = NSLock()
    private var contexts: [TranscriptionRequestContext] = []
    private var commits = 0

    init() {
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
    }

    var recordedContexts: [TranscriptionRequestContext] { lock.withLock { contexts } }
    var commitCount: Int { lock.withLock { commits } }
    func connect(model: any TranscriptionModel, language: String?, context: TranscriptionRequestContext) async throws {
        lock.withLock { contexts.append(context) }
        continuation.yield(.sessionStarted)
    }
    func sendAudioChunk(_ data: Data) async throws {}
    func commit() async throws {
        lock.withLock { commits += 1 }
        continuation.yield(.committed(text: "my spoken words"))
    }
    func disconnect() async { continuation.finish() }
}

struct CapturedContextIsolationTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test @MainActor func capturedSelectionAndScreenshotStayInFinalReferencesWithoutChangingRecognition() async throws {
        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let provider = FrozenContextProvider()
        let service = StreamingTranscriptionService(modelContext: ModelContext(container),
            providerFactory: { _ in provider })
        let context = TranscriptionRequestContext(language: "en", prompt: "original guidance", vocabulary: ["Realivy"])
        let model = CloudModel(name: OpenAITranscriptionConfiguration.liveModelName,
            displayName: "Offline test", description: "No network", provider: .openAI,
            speed: 1, accuracy: 1, isMultilingual: true, supportsStreaming: true, supportedLanguages: ["en": "English"])
        let session = RecordingSession(phase: .recording)
        session.transcriptionConfiguration = TranscriptionRuntimeConfiguration(
            mode: nil, model: model, language: "en", isRealtimeEnabled: true, requestContext: context)
        let selected = try #require(LiveSelectionReference("a highlighted phrase"))
        let screenshot = try #require(LiveSelectionReference(screenshotURL: URL(fileURLWithPath: "/tmp/never-read-context.png")))
        session.recordLiveSelection(selected)
        try await service.startStreaming(model: model, context: context)
        session.recordLiveSelection(screenshot)
        service.sendAudioChunk(Data(repeating: 0, count: 640))
        let final = try await service.stopAndGetFinalText()
        #expect(final == "my spoken words")
        let contexts = provider.recordedContexts
        #expect(contexts.count == 1)
        let connected = try #require(contexts.first)
        #expect(connected.language == context.language)
        #expect(connected.prompt == context.prompt)
        #expect(connected.promptWithRecentContext == context.promptWithRecentContext)
        #expect(connected.vocabulary == context.vocabulary)
        #expect(provider.commitCount == 1)
        #expect(session.transcriptionConfiguration?.requestContext.openAITranscriptionPrompt == "original guidance")
        #expect(session.transcriptionConfiguration?.requestContext.vocabulary == ["Realivy"])
        #expect(session.liveSelectionReferencesForDelivery.contains { $0.isSelection })
        #expect(session.liveSelectionReferencesForDelivery.count >= 2)
    }

    @Test func recognitionHasNoCapturedReferenceOrMidRecordingUpdateRoute() throws {
        let files = ["VoiceInk/Transcription/Engine/TranscriptionService.swift",
                     "VoiceInk/Transcription/Engine/TranscriptionSession.swift",
                     "VoiceInk/Transcription/Engine/RecordingSession.swift",
                     "VoiceInk/Transcription/Streaming/StreamingTranscriptionService.swift",
                     "VoiceInk/Transcription/Streaming/OpenAIStreamingProvider.swift",
                     "VoiceInk/Transcription/Streaming/StreamingTranscriptionProvider.swift"]
        for path in files {
            let text = try source(path)
            for retired in ["LiveTranscriptionContext", "withLiveReference", "updateRecognitionReference",
                            "updateTranscriptionContext", "LiveContextStreamingTranscriptionProvider"] {
                #expect(!text.contains(retired), "Retired recognition hook in \(path): \(retired)")
            }
        }
        let provider = try source("VoiceInk/Transcription/Streaming/OpenAIStreamingProvider.swift")
        #expect(provider.components(separatedBy: "\"type\": \"input_audio_buffer.commit\"").count - 1 == 1)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceInk/Transcription/Engine/LiveTranscriptionContext.swift").path))
    }
}
