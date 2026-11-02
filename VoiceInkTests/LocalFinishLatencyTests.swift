// Guards the build-476 local finish path: the WAV duration read overlaps provider
// finalization instead of following it, avoidable UI-actor work (recipient
// Info.plist reads, per-finish regex compilation) stays removed, and the new
// stop/queue/stage receipts remain numeric and allowlisted. No microphone,
// shortcut, clipboard, provider or delivery transport is exercised here.
import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct LocalFinishLatencyTests {
    // MARK: WAV duration overlaps the provider

    @Test func finishedWAVDurationStartsBeforeTheProviderResultAndIsAwaitedAfterIt() throws {
        let pipeline = try source("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift")
        let start = try #require(pipeline.range(
            of: "let audioDurationTask: Task<TimeInterval, Never>? = hasCapturedAudio"))
        let worker = try #require(pipeline.range(
            of: "? Task.detached(priority: .userInitiated) { await AudioFileMetadata.duration(for: audioURL) }",
            range: start.upperBound..<pipeline.endIndex))
        let provider = try #require(pipeline.range(
            of: "text = try await session.transcribe(audioURL: audioURL)",
            range: worker.upperBound..<pipeline.endIndex))
        let join = try #require(pipeline.range(
            of: "let actualDuration = if let audioDurationTask {\n                await audioDurationTask.value",
            range: provider.upperBound..<pipeline.endIndex))
        #expect(start.lowerBound < worker.lowerBound)
        #expect(worker.lowerBound < provider.lowerBound)
        #expect(provider.lowerBound < join.lowerBound)
        // After the provider returns, nothing may reopen the asset on the UI actor;
        // the only other direct read is the typing-only cancel fallback, which is
        // declared before the provider call and keeps build 470's no-empty-WAV rule.
        let afterProvider = pipeline[provider.upperBound...]
        #expect(!afterProvider.contains("await AudioFileMetadata.duration(for: audioURL)"))
        #expect(pipeline.components(separatedBy: "AudioFileMetadata.duration(for: audioURL)").count - 1 == 2)
        // Typing-only sessions still never start a read (hasCapturedAudio gate).
        #expect(pipeline.contains("if !hasCapturedAudio {"))
        #expect(pipeline.contains("} else { TimeInterval.zero }"))
    }

    @Test @MainActor func completedVoiceFinishStillRecordsTheDurationFromTheOverlappedRead() async throws {
        let fixture = try PipelineFixture(wavSeconds: 0.5)
        defer { fixture.remove() }
        let audio = LatencyTestAudioSession(text: "hello from the finished recording")
        let output = LatencyTestDelivery()
        let record = try await fixture.run(session: audio, delivery: output, shouldCancel: { false })
        #expect(audio.transcriptionCalls == 1)
        #expect(record.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        // The History row still receives the real file duration; only its place in
        // the schedule moved. AVFoundation reports the 16 kHz fixture as 0.5 s.
        #expect(abs(record.duration - 0.5) < 0.02)
        #expect(output.messages == ["hello from the finished recording"])
        #expect(output.routes == [.primaryCurrentInput])
        #expect(output.keys == [.none])
    }

    @Test @MainActor func canceledVoiceFinishReusesTheOverlappedDurationWithoutDelivering() async throws {
        let fixture = try PipelineFixture(wavSeconds: 0.5)
        defer { fixture.remove() }
        let audio = LatencyTestAudioSession(text: "never requested")
        let output = LatencyTestDelivery()
        let record = try await fixture.run(session: audio, delivery: output, shouldCancel: { true })
        #expect(audio.transcriptionCalls == 0)
        #expect(record.transcriptionStatus == TranscriptionStatus.canceled.rawValue)
        #expect(abs(record.duration - 0.5) < 0.02)
        #expect(output.messages.isEmpty && output.routes.isEmpty)
    }

    // MARK: Avoidable UI-actor work stays removed

    @Test @MainActor func recipientClassificationReadsNoRecipientBundleMetadata() throws {
        // Runtime: whatever is frontmost on the test host, no version/build is read.
        let recipient = AgentFlowPromptPreview.Recipient.current()
        #expect(recipient.version == nil && recipient.build == nil)
        // Source: the finish-path getter must not load another app's Info.plist.
        let archive = try source("VoiceInk/Paste/AgentFlowPromptArchive.swift")
        let start = try #require(archive.range(of: "@MainActor static func current() -> Self {"))
        let end = try #require(archive.range(of: "var supportsLocalFilePrompt: Bool {",
                                             range: start.upperBound..<archive.endIndex))
        let body = archive[start.lowerBound..<end.lowerBound]
        #expect(!body.contains("infoDictionary"))
        #expect(!body.contains("Bundle(url:"))
        #expect(body.contains("NSWorkspace.shared.frontmostApplication"))
        // The classifier still ignores version/build, so the removed read changed
        // nothing about which hosts receive compact file prompts.
        for name in ["Codex.app", "ChatGPT.app"] {
            #expect(AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: "com.openai.codex",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name)"), version: nil, build: nil))
        }
        #expect(!AgentFlowPromptPreview.supportsLocalFilePrompt(bundleID: "com.google.Chrome", bundleURL: nil))
    }

    @Test func presentationAndFilterExpressionsCompileOnceWithUnchangedOutput() throws {
        let archive = try source("VoiceInk/Paste/AgentFlowPromptArchive.swift")
        #expect(archive.contains("static let fragmentExpression = try! NSRegularExpression(pattern: fragmentPattern)"))
        #expect(archive.components(separatedBy: "NSRegularExpression(pattern: fragmentPattern)").count - 1 == 1)
        #expect(!archive.contains("NSRegularExpression(pattern: AgentFlowPromptViewer.fragmentPattern)"))
        let events = try #require(archive.range(of: "static func events(_ source: String) -> [Event] {"))
        let eventsEnd = try #require(archive.range(of: "private final class Fragment", range: events.upperBound..<archive.endIndex))
        #expect(archive[events.lowerBound..<eventsEnd.lowerBound].contains("let expression = fragmentExpression"))
        let map = try #require(archive.range(of: "private static func mapTimeline("))
        let mapEnd = try #require(archive.range(of: "struct Recipient {", range: map.upperBound..<archive.endIndex))
        #expect(archive[map.lowerBound..<mapEnd.lowerBound].contains("let expression = AgentFlowPromptViewer.fragmentExpression"))

        let filter = try source("VoiceInk/Transcription/Processing/TranscriptionOutputFilter.swift")
        let filterBody = try #require(filter.range(of: "static func filter(_ text: String) -> String {"))
        #expect(!filter[filterBody.lowerBound...].contains("NSRegularExpression(pattern:"))
        #expect(!filter[filterBody.lowerBound...].contains("options: .regularExpression"))
        #expect(filter.contains("CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive)"))

        // Same observable behavior as the former per-call construction.
        let sample = "<speech start_at=\"1.000\">alpha</speech>\n" +
            "<codex_selection source=\"Code\"><text>  exact &amp; quote  </text></codex_selection>\n" +
            "<typed_text>bravo</typed_text>"
        let parsed = AgentFlowPromptViewer.events(sample)
        #expect(parsed.map(\.tag) == ["speech", "codex_selection", "typed_text"])
        #expect(parsed[1].text == "  exact & quote  ")
        #expect(AgentFlowPromptPreview.compactTimeline(sample)
            == "<speech start_at=\"1.000\">alpha</speech>\n<codex_selection source=\"Code\"><text>  exact &amp; quote  </text></codex_selection>\n<typed_text>bravo</typed_text>")
        let filterSample = "[noise] alpha  (aside) <tag a=\"1\">x</tag> bravo"
        // Compare the old algorithm using the same saved filler list. Tests must
        // not overwrite that setting or assume the user's list excludes a word.
        #expect(TranscriptionOutputFilter.filter(filterSample)
            == uncachedOutputFilter(filterSample, fillerWords: FillerWordManager.shared.fillerWords))
        #expect(TranscriptionOutputFilter.filter("  ") == "")
    }

    @Test @MainActor func dictionaryExpressionsAreReusedWithoutStaleRulesOrUnboundedGrowth() throws {
        let pattern = "(?<![a-zA-Z0-9])latency(?![a-zA-Z0-9])"
        let first = try #require(CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive))
        let second = try #require(CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive))
        let sensitive = try #require(CompiledExpressionCache.expression(for: pattern, options: []))
        #expect(first === second)
        #expect(first !== sensitive)
        #expect(CompiledExpressionCache.expression(for: "(unbalanced", options: []) == nil)

        // Rules edit through SwiftData; the cache keys compiled patterns by text, so
        // a changed original or replacement takes effect on the very next finish.
        let schema = Schema([WordReplacement.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let rule = WordReplacement(originalText: "latency", replacementText: "delay")
        context.insert(rule)
        try context.save()
        let input = "Local latency, local latency."
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context) == "Local delay, local delay.")
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context) == "Local delay, local delay.")
        rule.replacementText = "wait"
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context) == "Local wait, local wait.")
        rule.originalText = "local"
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context) == "wait latency, wait latency.")
        rule.isEnabled = false
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context) == input)

        // The cap is a memory bound: filling past it clears rather than growing.
        for index in 0...(CompiledExpressionCache.capacity + 8) {
            _ = CompiledExpressionCache.expression(for: "bounded-\(index)", options: [])
        }
        #expect(CompiledExpressionCache.count <= CompiledExpressionCache.capacity)
        #expect(CompiledExpressionCache.count > 0)
    }

    @Test func cachedExpressionPreparationBenchmarkPreservesMatches() throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let patterns = (0..<120).map { "(?<![a-zA-Z0-9])benchmark\(token)variant\($0)(?![a-zA-Z0-9])" }
        let input = "benchmark\(token)variant0 and benchmark\(token)variant119"
        let range = NSRange(input.startIndex..., in: input)
        // Warm one bounded dictionary-sized set. Measure exactly the same
        // expression preparation + matching work with and without reuse.
        for pattern in patterns { _ = CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive) }
        let coldStarted = ContinuousClock.now
        var coldMatches = 0
        for _ in 0..<25 {
            for pattern in patterns {
                let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                coldMatches += expression.numberOfMatches(in: input, range: range)
            }
        }
        let coldMs = PipelineStageTimings.milliseconds(from: coldStarted, to: ContinuousClock.now)
        let cachedStarted = ContinuousClock.now
        var cachedMatches = 0
        for _ in 0..<25 {
            for pattern in patterns {
                let expression = try #require(CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive))
                cachedMatches += expression.numberOfMatches(in: input, range: range)
            }
        }
        let cachedMs = PipelineStageTimings.milliseconds(from: cachedStarted, to: ContinuousClock.now)
        #expect(coldMatches == 50 && cachedMatches == coldMatches)
        // A benchmark receipt, never a hardware-independent timing assertion or
        // a claim about total Stop-to-paste latency.
        print("LOCAL_FINISH_BENCH expressions=120 iterations=25 uncachedMs=\(coldMs) cachedMs=\(cachedMs) matches=\(cachedMatches)")
    }

    // MARK: Numeric stage receipts

    @Test func finishStageReceiptsAreNumericAndSurviveTheTraceAllowlist() throws {
        var timings = PipelineStageTimings()
        let start = ContinuousClock.now
        timings.add("sampleMs", since: start)
        timings.add("secondMs", since: start)
        #expect(timings.description.range(of: #"^sampleMs=\d+\.\d secondMs=\d+\.\d$"#, options: .regularExpression) != nil)
        let later = start.advanced(by: .milliseconds(1_250))
        #expect(abs(PipelineStageTimings.milliseconds(from: start, to: later) - 1_250) < 0.001)

        let pipeline = try source("VoiceInk/Transcription/Engine/TranscriptionPipeline.swift")
        let stagesLog = try #require(pipeline.range(of: "vippLog.info(\"pipeline: local stages "))
        let deliverLog = try #require(pipeline.range(of: "vippLog.info(\"pipeline: about to DELIVER",
                                                     range: stagesLog.upperBound..<pipeline.endIndex))
        // The receipt sits immediately before the delivery boundary and renders only
        // the stage description plus the already-allowlisted job lineage: exactly
        // two interpolations, neither of which can carry transcript text.
        #expect(stagesLog.lowerBound < deliverLog.lowerBound)
        let stagesLine = pipeline[stagesLog.lowerBound...].prefix { !$0.isNewline }
        #expect(stagesLine.contains("\\(stageTimings.description, privacy: .public) \\(jobIdentity.logDescription, privacy: .public)"))
        #expect(stagesLine.components(separatedBy: "\\(").count - 1 == 2)
        for stage in ["completionPolicyWaitMs", "triggerWordMs", "modeResolveMs", "paragraphFormatMs",
                      "wordReplacementMs", "audioMetadataWaitMs", "enhancementMs", "archiveMs",
                      "pasteTargetMs", "leaseWaitMs", "typingCommitMs", "presentationMs", "totalMs"] {
            #expect(pipeline.contains("stageTimings.add(\"\(stage)\""))
        }
        // The deliberate gesture wait is measured, not removed: the policy freeze
        // still precedes every Mode effect, exactly as before.
        let providerStamp = try #require(pipeline.range(of: "let providerResultAt = ContinuousClock.now"))
        let freeze = try #require(pipeline.range(of: "let completionPolicyNow = await completionPolicy()",
                                                 range: providerStamp.upperBound..<pipeline.endIndex))
        let filter = try #require(pipeline.range(of: "text = TranscriptionOutputFilter.filter(text)",
                                                 range: freeze.upperBound..<pipeline.endIndex))
        #expect(providerStamp.lowerBound < freeze.lowerBound && freeze.lowerBound < filter.lowerBound)

        let engine = try source("VoiceInk/Transcription/Engine/VoiceInkEngine.swift")
        let stopReceipt = try #require(engine.range(of: "vippLog.info(\"toggleRecord: stop stages stopPrepMs="))
        let stopLine = engine[stopReceipt.lowerBound...].prefix { !$0.isNewline }
        for key in ["stopPrepMs=", "micTransitionMs=", "hardwareStopMs=", "recoveryJoinMs=", "historySaveMs=", "enqueueMs=", "session="] {
            #expect(stopLine.contains(key))
        }
        #expect(stopLine.contains("format: .fixed(precision: 1), privacy: .public"))
        #expect(!stopLine.contains("partialTranscript") && !stopLine.contains("recoverablePartialTranscript"))
        let enqueueStamp = try #require(engine.range(of: "let enqueuedAt = ContinuousClock.now"))
        let enqueueCall = try #require(engine.range(of: "transcriptionJobQueue.enqueue(", range: enqueueStamp.upperBound..<engine.endIndex))
        let queueWait = try #require(engine.range(of: "let queueWaitMs = PipelineStageTimings.milliseconds(from: enqueuedAt, to: ContinuousClock.now)",
                                                  range: enqueueCall.upperBound..<engine.endIndex))
        #expect(engine[queueWait.upperBound...].contains("await self.runPipeline(for: job, queueWaitMs: queueWaitMs)"))
        #expect(engine.contains("intentional previous-job/reset"))
        #expect(engine.contains("cannot alone"))
        #expect(engine.contains("vippLog.info(\"pipeline run START queueWaitMs=\\(queueWaitMs, format: .fixed(precision: 1), privacy: .public) \\(job.identity.logDescription, privacy: .public)\")"))

        // The privacy trace keeps these receipts because their prefixes are allowlisted.
        let trace = try source(".agents/skills/learnings/scripts/live-delivery-trace.sh")
        for prefix in ["*'pipeline: local stages'*", "*'pipeline run START'*", "*'toggleRecord:'*"] {
            #expect(trace.contains(prefix))
        }
        let filterTest = try source(".agents/skills/learnings/scripts/test-live-delivery-trace-filter.js")
        #expect(filterTest.contains("pipeline: local stages completionPolicyWaitMs="))
        #expect(filterTest.contains("toggleRecord: stop stages stopPrepMs="))
        #expect(filterTest.contains("pipeline run START queueWaitMs="))
    }

    // MARK: Fixtures

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func uncachedOutputFilter(_ text: String, fillerWords: [String]) -> String {
        var value = text
        let patterns = [#"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#, #"\[.*?\]"#, #"\(.*?\)"#, #"\{.*?\}"#]
        for pattern in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            value = expression.stringByReplacingMatches(in: value,
                range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        for filler in fillerWords {
            let expression = try! NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b[,.]?", options: .caseInsensitive)
            value = expression.stringByReplacingMatches(in: value,
                range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        return value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct FixtureError: Error {}

    /// Minimal real-pipeline host: in-memory SwiftData, a closed synthetic WAV, a
    /// scripted provider session and a recording delivery sink. Raw/skip output
    /// keeps the paste deterministic regardless of the test host's frontmost app.
    @MainActor
    private final class PipelineFixture {
        let directory: URL
        let audioURL: URL
        let context: ModelContext
        let registry: TranscriptionServiceRegistry

        init(wavSeconds: Double) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalFinishLatency-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            audioURL = directory.appendingPathComponent("finished.wav")
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
                throw FixtureError()
            }
            let frames = AVAudioFrameCount(wavSeconds * 16_000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw FixtureError()
            }
            buffer.frameLength = frames
            var file: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file?.write(from: buffer)
            file = nil // Close before the pipeline reads it, exactly like the stop path.
            let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            context = ModelContext(container)
            registry = TranscriptionServiceRegistry(modelProvider: LatencyTestModelProvider(),
                modelsDirectory: URL(fileURLWithPath: "/tmp"), modelContext: context)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func run(session: LatencyTestAudioSession, delivery: LatencyTestDelivery,
                 shouldCancel: @escaping () -> Bool) async throws -> Transcription {
            let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry,
                enhancementService: nil, delivery: delivery,
                archivePrompt: { _, _ in .init(url: URL(fileURLWithPath: "/tmp/local-finish-latency-unused.md"), rainbowStartIndex: 0) },
                currentPromptRecipient: { .init(bundleID: "com.google.Chrome", bundleURL: nil) })
            let record = Transcription(text: "", duration: 0)
            context.insert(record)
            let model = NativeAppleModel(name: "unused", displayName: "Unused", description: "Test only",
                isMultilingualModel: false, supportedLanguages: [:])
            await pipeline.run(transcription: record, audioURL: audioURL,
                transcriptionConfiguration: .init(mode: nil, model: model, language: "en",
                    isRealtimeEnabled: false, requestContext: .init(language: "en", prompt: nil)),
                jobIdentity: .init(generation: 1, enqueueSequence: 1, recordingSessionID: UUID(),
                    transcriptionID: record.id, audioURL: audioURL),
                formattingConfiguration: { .init(mode: nil, isTextFormattingEnabled: false) },
                session: session, hasCapturedAudio: true,
                enhancementConfiguration: { nil },
                pasteTarget: { .init(destination: .primaryCurrentInput, focusedInput: nil) },
                outputConfiguration: { .init(mode: nil, outputMode: .paste, autoSendKey: .none, customCommand: nil) },
                skipPostProcessing: { true },
                onStateChange: { _ in }, shouldCancel: shouldCancel, isDeliveryAuthorized: { true },
                onCancel: {}, onDismiss: {})
            return record
        }
    }
}

@MainActor private final class LatencyTestModelProvider: WhisperModelProvider {
    var isModelLoaded: Bool { false }
    var whisperContext: WhisperContext? { nil }
    var loadedWhisperModel: WhisperModelFile? { nil }
    var availableModels: [WhisperModelFile] { [] }
}

@MainActor private final class LatencyTestAudioSession: TranscriptionSession {
    private let text: String
    private(set) var transcriptionCalls = 0
    init(text: String) { self.text = text }
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? { nil }
    func transcribe(audioURL: URL) async throws -> String {
        transcriptionCalls += 1
        return text
    }
    func cancel() {}
}

@MainActor private final class LatencyTestDelivery: TranscriptionDelivering {
    private(set) var messages: [String] = []
    private(set) var routes: [RecordingPasteDestination] = []
    private(set) var keys: [AutoSendKey] = []
    func deliver(_ request: TranscriptionDelivery.Request, actions: TranscriptionDelivery.Actions) async {
        if let text = request.text { messages.append(text) }
        routes.append(request.pasteTarget.destination)
        keys.append(request.output.autoSendKey)
    }
}
