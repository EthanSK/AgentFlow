import Foundation
import SwiftData
import os

/// Reconciles one OpenAI realtime transcription item without letting a later empty
/// completion erase text the same item already emitted as deltas.
///
/// OpenAI's live-transcription contract uses `item_id` to pair delta and completed
/// events. Keep that boundary in this state object so text from concurrent or later
/// items can never be combined merely because their events arrived close together.
struct OpenAITranscriptAccumulator {
    enum CompletionSource: String, Equatable {
        case completed
        case sameItemDelta
        case empty
    }

    struct Resolution: Equatable {
        let text: String
        let source: CompletionSource

        /// Deliberately excludes transcript contents and item identifiers. This is the
        /// only metadata permitted in the managed seven-day delivery trace.
        var privacySafeLogMetadata: String {
            "source=\(source.rawValue) chars=\(text.count)"
        }
    }

    private var partialsByItemID: [String: String] = [:]

    mutating func reset(keepingCapacity: Bool) {
        partialsByItemID.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func append(delta: String, itemID: String) -> String {
        let cumulative = partialsByItemID[itemID, default: ""] + delta
        partialsByItemID[itemID] = cumulative
        return cumulative
    }

    mutating func complete(
        itemID: String,
        completedTranscript: String?
    ) -> Resolution {
        let sameItemDelta = partialsByItemID.removeValue(forKey: itemID) ?? ""
        if let completedTranscript,
           !completedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Resolution(text: completedTranscript, source: .completed)
        }
        if !sameItemDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Resolution(text: sameItemDelta, source: .sameItemDelta)
        }
        return Resolution(text: "", source: .empty)
    }
}

/// Privacy-safe summary of a completed event's optional `usage` object. Only numeric
/// billing fields and a known usage type are kept, so a per-session log can compare the
/// provider's billed duration with the audio actually appended (for example while the
/// optional silence sleep withholds quiet audio). It never includes transcript text,
/// item identifiers, prompts, or any other string the server echoes.
enum OpenAIRealtimeUsageSummary {
    static func describe(_ usage: Any?) -> String? {
        guard let usage = usage as? [String: Any] else { return nil }
        var fields: [String] = []
        if let type = usage["type"] as? String {
            fields.append("type=\(["duration", "tokens"].contains(type) ? type : "other")")
        }
        for key in ["seconds", "input_tokens", "output_tokens", "total_tokens"] {
            if let number = usage[key] as? NSNumber {
                fields.append("\(key)=\(number.stringValue)")
            }
        }
        return fields.isEmpty ? "present=unrecognized" : fields.joined(separator: " ")
    }
}

/// Incremental 16 kHz PCM16 to 24 kHz PCM16 conversion for OpenAI Realtime.
/// The phase and preceding sample survive audio callback boundaries so chunking cannot
/// introduce discontinuities or subtly change the submitted recording.
struct OpenAIRealtimePCMResampler {
    private var inputSamples: [Int16] = []
    private var nextSourcePosition = 0.0
    private var pendingByte: UInt8?

    mutating func convert(_ data: Data) -> Data {
        appendSamples(from: data)
        return makeOutput(flushing: false)
    }

    mutating func flush() -> Data {
        guard !inputSamples.isEmpty else {
            pendingByte = nil
            return Data()
        }
        return makeOutput(flushing: true)
    }

    private mutating func appendSamples(from data: Data) {
        var bytes = Array(data)
        if let pendingByte {
            bytes.insert(pendingByte, at: 0)
            self.pendingByte = nil
        }
        if bytes.count.isMultiple(of: 2) == false {
            pendingByte = bytes.removeLast()
        }

        var index = 0
        while index + 1 < bytes.count {
            let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            inputSamples.append(Int16(bitPattern: bits))
            index += 2
        }
    }

    private mutating func makeOutput(flushing: Bool) -> Data {
        if flushing, let last = inputSamples.last {
            inputSamples.append(last)
        }

        var output: [Int16] = []
        output.reserveCapacity(Int(Double(inputSamples.count) * 1.5) + 2)

        while nextSourcePosition + 1 < Double(inputSamples.count) {
            let lowerIndex = Int(nextSourcePosition)
            let fraction = nextSourcePosition - Double(lowerIndex)
            let lower = Double(inputSamples[lowerIndex])
            let upper = Double(inputSamples[lowerIndex + 1])
            let interpolated = lower + ((upper - lower) * fraction)
            output.append(Int16(clamping: Int(interpolated.rounded())))
            nextSourcePosition += 2.0 / 3.0
        }

        if flushing {
            inputSamples.removeAll(keepingCapacity: false)
            nextSourcePosition = 0
            pendingByte = nil
        } else {
            let removable = min(Int(nextSourcePosition), max(0, inputSamples.count - 1))
            if removable > 0 {
                inputSamples.removeFirst(removable)
                nextSourcePosition -= Double(removable)
            }
        }

        var data = Data(capacity: output.count * MemoryLayout<Int16>.size)
        for sample in output {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Dedicated WebSocket adapter for OpenAI's transcription session. Realtime deltas remain
/// recorder-HUD preview only; only the completed event enters the existing one-shot final
/// delivery pipeline selected by Primary or Next.
final class OpenAIStreamingProvider: LiveContextStreamingTranscriptionProvider, @unchecked Sendable {
    // Held experiment, with no user-default escape hatch. The 2026-10-25 real API
    // accepted both complete and transcription-only session.update payloads but
    // returned only the audio appended after the latest update. Identical control
    // recordings without updates retained all three spoken markers. Startup context
    // remains valid; do not enable mid-recording updates from schema/ack tests alone.
    let supportsLiveContextUpdates = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var transcriptAccumulator = OpenAITranscriptAccumulator()
    private var resampler = OpenAIRealtimePCMResampler()
    private let modelContext: ModelContext
    private let stateLock = NSLock()
    private var didCommitStorage = false
    private var didSignalFinalStorage = false
    private let contextAcknowledgements: AsyncStream<Void>
    private let contextAcknowledgement: AsyncStream<Void>.Continuation
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "OpenAIStreamingProvider"
    )

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
        let acknowledgements = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        contextAcknowledgements = acknowledgements.stream
        contextAcknowledgement = acknowledgements.continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        eventsContinuation?.finish()
        contextAcknowledgement.finish()
    }

    func connect(
        model: any TranscriptionModel,
        language: String?,
        context: TranscriptionRequestContext
    ) async throws {
        guard model.name == OpenAITranscriptionConfiguration.liveModelName else {
            throw StreamingTranscriptionError.serverError(
                "Unsupported OpenAI streaming model: \(model.name)"
            )
        }
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "OpenAI"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        // Transcription sessions use an intent-scoped Realtime connection. Putting
        // gpt-live-transcribe in the URL makes it the session model and is rejected;
        // the model belongs only in audio.input.transcription.model below.
        let url = OpenAITranscriptionConfiguration.realtimeWebSocketURL

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        transcriptAccumulator.reset(keepingCapacity: true)
        resampler = OpenAIRealtimePCMResampler()
        setDidCommit(false)
        resetFinalSignal()
        task.resume()

        // Both halves start with this recording's own prompt and frozen Vocabulary.
        // Only references available at prepare can enter the live startup request.
        // Later captures stay in the final message and completed-WAV fallback context;
        // mid-recording network updates are held by supportsLiveContextUpdates.
        // The fallback uses original guidance if startup/a context update fails;
        // partial transcripts never generate hints, retries or destination mutations.
        // Send initial guidance here, never on every audio chunk or partial transcript.
        // Fresh recording sessions also prevent implicit context carry-over between tasks.
        // Research: .agents/skills/learnings/references/openai-transcription-quality.md.
        let sessionUpdate = OpenAITranscriptionConfiguration.realtimeSessionUpdate(
            language: language,
            prompt: context.openAITranscriptionPrompt,
            customVocabulary: context.customVocabulary(orLiveFetch: customDictionaryTerms)
        )
        try await sendJSON(sessionUpdate, over: task)
        try await waitForSessionReady(from: task)

        eventsContinuation?.yield(.sessionStarted)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }
        let converted = resampler.convert(data)
        guard !converted.isEmpty else { return }
        try await sendAudio(converted, over: task)
    }

    func updateTranscriptionContext(_ context: TranscriptionRequestContext) async throws {
        // Enforce the hold here too, so a direct caller cannot bypass the sender's
        // capability check and silently discard already buffered speech.
        guard supportsLiveContextUpdates else {
            throw StreamingTranscriptionError.serverError("OpenAI mid-recording context updates are unavailable")
        }
        guard let task = webSocketTask, !didCommit, !Task.isCancelled else {
            throw StreamingTranscriptionError.notConnected
        }
        let update = OpenAITranscriptionConfiguration.realtimeContextUpdate(
            language: context.language,
            prompt: context.openAITranscriptionPrompt,
            customVocabulary: context.customVocabulary(orLiveFetch: customDictionaryTerms)
        )
        try await sendJSON(update, over: task)
        let acknowledged = await StreamingTranscriptionService.waitForSendLoopCompletion(
            contextAcknowledgements, timeoutNanoseconds: 2_000_000_000
        )
        guard acknowledged, !Task.isCancelled else {
            throw StreamingTranscriptionError.timeout
        }
    }

    func commit() async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        let tail = resampler.flush()
        if !tail.isEmpty {
            try await sendAudio(tail, over: task)
        }
        setDidCommit(true)
        try await sendJSON(["type": "input_audio_buffer.commit"], over: task)
    }

    func disconnect() async {
        contextAcknowledgement.finish()
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        transcriptAccumulator.reset(keepingCapacity: false)
        setDidCommit(false)
        resetFinalSignal()
        eventsContinuation?.finish()
    }

    private func waitForSessionReady(from task: URLSessionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw StreamingTranscriptionError.connectionFailed("OpenAI provider was released")
                }
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do {
                        message = try await task.receive()
                    } catch {
                        throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
                    }
                    guard let json = self.decodeMessage(message) else { continue }

                    switch json["type"] as? String {
                    case "session.updated":
                        return
                    case "error":
                        // An initial reference hint can already be present here. Never
                        // expose a server error's echoed private request in local logs.
                        throw StreamingTranscriptionError.serverError("OpenAI realtime transcription request failed")
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw StreamingTranscriptionError.timeout
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if let json = decodeMessage(message) {
                    handleMessage(json)
                }
            } catch {
                contextAcknowledgement.finish()
                if !Task.isCancelled {
                    eventsContinuation?.yield(
                        .error(StreamingTranscriptionError.connectionFailed(error.localizedDescription))
                    )
                    signalEmptyFinalAfterCommitIfNeeded()
                }
                break
            }
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "session.updated":
            contextAcknowledgement.yield()

        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
            let itemID = (json["item_id"] as? String) ?? "active"
            let cumulative = transcriptAccumulator.append(
                delta: delta,
                itemID: itemID
            )
            eventsContinuation?.yield(.partial(text: cumulative))

        case "conversation.item.input_audio_transcription.completed":
            let itemID = (json["item_id"] as? String) ?? "active"
            let resolution = transcriptAccumulator.complete(
                itemID: itemID,
                completedTranscript: json["transcript"] as? String
            )
            if resolution.source == .sameItemDelta {
                logger.notice(
                    "OpenAI completion recovered same-item delta \(resolution.privacySafeLogMetadata, privacy: .public)"
                )
            }
            if let usage = OpenAIRealtimeUsageSummary.describe(json["usage"]) {
                logger.notice("OpenAI completion usage \(usage, privacy: .public)")
            }
            // Still exactly one final per recording. The optional silence sleep pauses
            // appends only; it never commits, so this one completion covers every byte
            // sent before Stop's single commit.
            yieldFinalOnce(resolution.text)

        case "conversation.item.input_audio_transcription.failed", "error":
            contextAcknowledgement.finish()
            eventsContinuation?.yield(
                // Provider errors can echo private prompt text. Keep a fixed message
                // on the live event/log path; the complete WAV remains authoritative.
                .error(StreamingTranscriptionError.serverError("OpenAI realtime transcription request failed"))
            )
            signalEmptyFinalAfterCommitIfNeeded()

        default:
            break
        }
    }

    private func signalEmptyFinalAfterCommitIfNeeded() {
        if didCommit {
            yieldFinalOnce("")
        }
    }

    private func yieldFinalOnce(_ text: String) {
        stateLock.lock()
        let shouldYield = !didSignalFinalStorage
        didSignalFinalStorage = true
        stateLock.unlock()
        if shouldYield {
            eventsContinuation?.yield(.committed(text: text))
        }
    }

    private func sendAudio(_ data: Data, over task: URLSessionWebSocketTask) async throws {
        try await sendJSON(
            [
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ],
            over: task
        )
    }

    private func sendJSON(_ object: [String: Any], over task: URLSessionWebSocketTask) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StreamingTranscriptionError.serverError("Invalid OpenAI Realtime request")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StreamingTranscriptionError.serverError("Could not encode OpenAI Realtime request")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        }
    }

    private func decodeMessage(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return nil }
            data = textData
        case .data(let binaryData):
            data = binaryData
        @unknown default:
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func customDictionaryTerms() -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        return OpenAIKeywordSelection.selected(from: vocabularyWords.map(\.word))
    }

    private var didCommit: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didCommitStorage
    }

    private func setDidCommit(_ value: Bool) {
        stateLock.lock()
        didCommitStorage = value
        stateLock.unlock()
    }

    private func resetFinalSignal() {
        stateLock.lock()
        didSignalFinalStorage = false
        stateLock.unlock()
    }
}
