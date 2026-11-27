// Offline integration checks for realtime gating, startup and completed-file recovery. — GPT-6.1 Sol
import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

/// Offline provider: the production gate, queue, consumer and Stop path still run.
/// No microphone, preferences, credentials, network or delivery surface is touched.
private final class SilenceSleepTestProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var commits = 0
    private let errorOnCommit: Bool
    private let committedText: String
    private let connectOperation: (@Sendable () async throws -> Void)?

    init(errorOnCommit: Bool = false, committedText: String = "alpha beta",
         connectOperation: (@Sendable () async throws -> Void)? = nil) {
        let pair = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = pair.stream
        continuation = pair.continuation
        self.errorOnCommit = errorOnCommit
        self.committedText = committedText
        self.connectOperation = connectOperation
    }

    var sent: [Data] { lock.withLock { chunks } }
    var commitCount: Int { lock.withLock { commits } }
    func emit(_ event: StreamingTranscriptionEvent) { continuation.yield(event) }
    func connect(model: any TranscriptionModel, language: String?) async throws {
        try await connectOperation?()
        emit(.sessionStarted)
    }
    func sendAudioChunk(_ data: Data) async throws { lock.withLock { chunks.append(data) } }
    func commit() async throws {
        lock.withLock { commits += 1 }
        if errorOnCommit { emit(.error(StreamingTranscriptionError.serverError("Synthetic failure"))) }
        emit(.committed(text: committedText))
    }
    func disconnect() async { continuation.finish() }
}

private final class SilenceSleepTestStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    private let onWake: (() -> Void)?
    init(onWake: (() -> Void)? = nil) { self.onWake = onWake }
    func append(_ value: Bool) {
        lock.withLock { values.append(value) }
        if !value { onWake?() }
    }
    var snapshot: [Bool] { lock.withLock { values } }
}

struct RealtimeSilenceSleepIntegrationTests {
    @Test @MainActor func backgroundRealtimeConnectFailureReportsOnceAndKeepsFileFallback() async throws {
        let provider = SilenceSleepTestProvider(connectOperation: { throw URLError(.notConnectedToInternet) })
        let run = try harness(provider: provider, enabled: false)
        var warnings = 0
        let fallback = StartupFailureTestFallback()
        let session = StreamingTranscriptionSession(streamingService: run.service,
            fallbackService: fallback, onRealtimeStartupFailure: { warnings += 1 })
        let configuration = TranscriptionRuntimeConfiguration(mode: nil, model: model(), language: "en", isRealtimeEnabled: true,
            requestContext: .init(language: "en", prompt: "frozen prompt"))
        let callback = try await session.prepare(configuration: configuration)
        #expect(callback != nil)
        let audio = URL(fileURLWithPath: "/offline-fixture.wav")
        let result = try await session.transcribe(audioURL: audio)
        #expect(warnings == 1 && result == "recovered speech")
        #expect(await fallback.audioURLs == [audio])
        #expect(await fallback.prompts == ["frozen prompt"])
        #expect(try await session.transcribe(audioURL: audio) == result)
        #expect(warnings == 1)
        #expect(await fallback.audioURLs.count == 1)
    }

    @Test @MainActor func cancelledRealtimeConnectDoesNotReportAnOfflineWarning() async throws {
        let provider = SilenceSleepTestProvider(connectOperation: { throw CancellationError() })
        let run = try harness(provider: provider, enabled: false)
        var warnings = 0
        let session = StreamingTranscriptionSession(streamingService: run.service,
            fallbackService: StartupFailureTestFallback(), onRealtimeStartupFailure: { warnings += 1 })
        _ = try await session.prepare(configuration: .init(mode: nil, model: model(), language: "en", isRealtimeEnabled: true,
            requestContext: .init(language: "en", prompt: nil)))
        _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/offline-fixture.wav"))
        #expect(warnings == 0)
    }

    @Test func backgroundRealtimeWarningRequiresTheExactLiveRecording() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "onRealtimeStartupFailure: { [weak self, weak session] in"))
        let end = try #require(source.range(of: "session.transcriptionSession = streamingSession", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let effect = try #require(body.range(of: "session.showsRealtimeTranscriptHUD = false"))
        for guardText in ["self.activeRecordingSession === session", "session.startID == startID",
                          "session.liveRecordingState.isRecordingOrPaused", "!session.shouldCancel"] {
            #expect(try #require(body.range(of: guardText)).lowerBound < effect.lowerBound)
        }
        #expect(body.contains(".completedFileFallback(.providerPreparationFailed)"))
        for forbidden in ["stopRecording", "cancelRecording", "removeSession", "paste", "Task.sleep"] {
            #expect(!body.contains(forbidden))
        }
    }

    private func pcm(_ sample: Int16, count: Int = 320) -> Data {
        var data = Data()
        for _ in 0..<count {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private var shortConfiguration: RealtimeSilenceSleepGate.Configuration {
        var configuration = RealtimeSilenceSleepGate.Configuration.gptLiveDefault
        configuration.trailingQuietSeconds = 0.04
        configuration.activityHoldSeconds = 0
        configuration.prerollSeconds = 0.02
        return configuration
    }

    @MainActor private func model() -> CloudModel {
        CloudModel(name: OpenAITranscriptionConfiguration.liveModelName,
            displayName: "Offline live model", description: "No API calls",
            provider: .openAI, speed: 1, accuracy: 1, isMultilingual: true,
            supportsStreaming: true, supportedLanguages: ["en": "English"])
    }

    @MainActor private func harness(
        provider: SilenceSleepTestProvider,
        enabled: Bool = true,
        states: SilenceSleepTestStates = SilenceSleepTestStates(),
        onPartial: ((String) -> Void)? = nil
    ) throws -> (service: StreamingTranscriptionService, container: ModelContainer) {
        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return (StreamingTranscriptionService(modelContext: ModelContext(container),
            onPartialTranscript: onPartial,
            silenceSleepConfiguration: enabled ? shortConfiguration : nil,
            onSilenceSleepChange: { sleeping, _ in states.append(sleeping) },
            providerFactory: { _ in provider }), container)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func emptyRealtimeFinalIsCleanOnlyWithoutPartialsOrErrors(
        sendsPartial: Bool, sendsError: Bool
    ) async throws {
        let provider = SilenceSleepTestProvider(errorOnCommit: sendsError, committedText: "")
        // Even with silence sleep disabled, a synthetic empty event emitted by a
        // provider error must not be mistaken for a successful empty final.
        let run = try harness(provider: provider, enabled: false)
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        run.service.sendAudioChunk(pcm(0))
        if sendsPartial { provider.emit(.partial(text: "earlier words")) }
        let result = try await run.service.stopAndGetFinalText()
        #expect(result.isEmpty)
        #expect(run.service.completedEmptyWithoutPartials == (!sendsPartial && !sendsError))
    }

    @Test @MainActor func emptyRealtimeFallbackKeepsAQuickRecovery() async throws {
        let result = try await StreamingTranscriptionSession.finishEmptyRealtimeFallback {
            "missed speech recovered"
        }
        #expect(result == "missed speech recovered")
    }

    @Test @MainActor func stalledEmptyRealtimeFallbackCancelsTheUpload() async {
        let startsAndCancels = SilenceSleepTestStates()
        do {
            _ = try await StreamingTranscriptionSession.finishEmptyRealtimeFallback(limit: .milliseconds(40)) {
                startsAndCancels.append(true)
                defer { startsAndCancels.append(Task.isCancelled) }
                try await Task.sleep(for: .seconds(30))
                return "too late"
            }
            Issue.record("The stalled fallback must throw a timeout.")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(startsAndCancels.snapshot == [true, true])
    }

    @Test @MainActor func sleepingAtStopFlushesTheQueueAndReturnsOneCompleteRealtimeFinal() async throws {
        let provider = SilenceSleepTestProvider()
        let states = SilenceSleepTestStates()
        let run = try harness(provider: provider, states: states)
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        let head = pcm(12_000)
        run.service.sendAudioChunk(head)
        for _ in 0..<50 { run.service.sendAudioChunk(pcm(0)) }
        #expect(states.snapshot.last == true)
        let text = try await run.service.stopAndGetFinalText()
        #expect(text == "alpha beta")
        #expect(run.service.audioWasComplete)
        #expect(provider.commitCount == 1)
        #expect(provider.sent.first == head)
        #expect(provider.sent.count < 51)
        #expect(provider.sent.count == 4) // head, two trailing chunks, and Stop's held chunk
        #expect(provider.sent.last == pcm(0)) // held lead-in was flushed before commit
        #expect(states.snapshot.last == false)
    }

    @Test @MainActor func anIdleSocketErrorClearsSleepAndForcesTheCompleteWAVPathBeforeCommit() async throws {
        let provider = SilenceSleepTestProvider()
        let (wake, didWake) = AsyncStream.makeStream(of: Void.self)
        let states = SilenceSleepTestStates(onWake: { didWake.yield() })
        let run = try harness(provider: provider, states: states)
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        run.service.sendAudioChunk(pcm(12_000))
        for _ in 0..<50 { run.service.sendAudioChunk(pcm(0)) }
        #expect(states.snapshot.last == true)
        provider.emit(.error(StreamingTranscriptionError.connectionFailed("Synthetic idle close")))
        let received = await StreamingTranscriptionService.waitForSendLoopCompletion(wake,
            timeoutNanoseconds: 1_000_000_000)
        #expect(received)
        #expect(states.snapshot.last == false)
        do {
            _ = try await run.service.stopAndGetFinalText()
            Issue.record("An idle socket failure must reject the realtime final")
        } catch StreamingTranscriptionError.incompleteAudio {
            #expect(!run.service.audioWasComplete)
        }
        #expect(provider.commitCount == 0)
        didWake.finish()
    }

    @Test(arguments: [true, false]) @MainActor
    func providerErrorAfterDrainRejectsOnlyTheGatedRealtimeFinal(enabled: Bool) async throws {
        let provider = SilenceSleepTestProvider(errorOnCommit: true)
        let run = try harness(provider: provider, enabled: enabled)
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        run.service.sendAudioChunk(pcm(12_000))
        do {
            let text = try await run.service.stopAndGetFinalText()
            #expect(!enabled)
            #expect(text == "alpha beta")
            #expect(run.service.audioWasComplete)
        } catch StreamingTranscriptionError.incompleteAudio {
            #expect(enabled)
            #expect(!run.service.audioWasComplete)
        }
        #expect(provider.commitCount == 1)
    }

    @Test @MainActor func aLateProviderWordWakesTheSleepingProductionStream() async throws {
        let provider = SilenceSleepTestProvider()
        let states = SilenceSleepTestStates()
        let (ack, acknowledged) = AsyncStream.makeStream(of: Void.self)
        let run = try harness(provider: provider, states: states,
            onPartial: { _ in acknowledged.yield() })
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        for _ in 0..<50 { run.service.sendAudioChunk(pcm(0)) }
        #expect(states.snapshot.last == true)
        provider.emit(.partial(text: "late word"))
        let received = await StreamingTranscriptionService.waitForSendLoopCompletion(ack,
            timeoutNanoseconds: 1_000_000_000)
        #expect(received)
        run.service.sendAudioChunk(pcm(0))
        #expect(states.snapshot.last == false)
        let finalText = try await run.service.stopAndGetFinalText()
        #expect(finalText == "alpha beta")
        #expect(run.service.audioWasComplete)
        #expect(provider.commitCount == 1)
        acknowledged.finish()
    }

    @Test @MainActor func startupReplayThroughTheGatePreservesBothEdgesAndResamplerAlignment() async throws {
        let provider = SilenceSleepTestProvider()
        let run = try harness(provider: provider)
        let router = RecordingStartupAudioRouter()
        let head = pcm(12_000), tail = pcm(-10_000)
        router.receive(head)
        for _ in 0..<50 { router.receive(pcm(0)) }
        let activation = router.activate { run.service.sendAudioChunk($0) }
        #expect(activation == .connected(replayedChunks: 51, replayedBytes: 51 * 640))
        try await run.service.startStreaming(model: model(), context: .init(language: "en", prompt: nil))
        router.receive(tail)
        let finalText = try await run.service.stopAndGetFinalText()
        #expect(finalText == "alpha beta")
        #expect(run.service.audioWasComplete)
        let sent = provider.sent
        #expect(sent.first == head && sent.last == tail)
        #expect(sent.filter { $0 == head }.count == 1)
        #expect(sent.filter { $0 == tail }.count == 1)
        #expect(sent.count < 52)
        #expect(sent.count == 5) // the tail woke and replayed held quiet before Stop

        var chunkedResampler = OpenAIRealtimePCMResampler(), joinedResampler = OpenAIRealtimePCMResampler()
        var chunked = Data(), joinedInput = Data()
        for part in sent {
            chunked.append(chunkedResampler.convert(part))
            joinedInput.append(part)
        }
        chunked.append(chunkedResampler.flush())
        var joined = joinedResampler.convert(joinedInput)
        joined.append(joinedResampler.flush())
        #expect(chunked == joined)
        let first = Int16(bitPattern: UInt16(chunked[0]) | (UInt16(chunked[1]) << 8))
        let last = Int16(bitPattern: UInt16(chunked[chunked.count - 2]) | (UInt16(chunked[chunked.count - 1]) << 8))
        #expect(first == 12_000 && last == -10_000) // original PCM sample grid survived omission
    }

    @Test func concurrentActivitySmokeKeepsEveryChunkAccountedFor() {
        // Exercises concurrent callers and accounting; this is not a substitute for TSan.
        let lock = NSLock()
        var sent = 0, withheld = 0
        let controller = RealtimeSilenceSleepController(configuration: shortConfiguration,
            forward: { _ in lock.withLock { sent += 1 } },
            withhold: { _ in lock.withLock { withheld += 1 } },
            onSleepingChange: { _, _ in })
        let quiet = pcm(0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<400 { controller.receive(quiet) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<400 { controller.noteSessionActivity() }
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 2) == .success)
        controller.finish()
        #expect(lock.withLock { sent + withheld } == 400)
    }
}

/// A completed-file double that never reads a WAV or calls a provider. — GPT-6.1 Sol
private actor StartupFailureTestFallback: TranscriptionService {
    var audioURLs: [URL] = []
    var prompts: [String?] = []
    func transcribe(audioURL: URL, model: any TranscriptionModel,
                    context: TranscriptionRequestContext) async throws -> String {
        audioURLs.append(audioURL)
        prompts.append(context.prompt)
        return "recovered speech"
    }
}
