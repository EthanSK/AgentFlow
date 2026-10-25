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

    /// Live text already received for one item, without completing it.
    func partial(for itemID: String) -> String? {
        partialsByItemID[itemID]
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

/// Provider-private ownership of every audio turn VoiceInk++ commits in one GPT Live
/// recording.
///
/// WHY: the 2026-10-25 real API kept only the audio appended after a mid-recording
/// session.update, while a phrase-boundary commit before the update preserved every
/// spoken marker. A recording may therefore become several committed turns. That is
/// safe only when each server item is bound to the exact commit VoiceInk++ sent and the
/// user's single Stop still produces exactly one final text. Anything that cannot be
/// correlated (an early, foreign, duplicate or id-less item, an unrequested commit or
/// clear, a failed item, a server/socket error) fails closed: realtime is abandoned and
/// the complete WAV fallback owns the result. Never guess which turn a text belongs to.
///
/// Pure and not thread-safe; `OpenAIStreamingProvider` serializes it with `stateLock`.
/// It never sees audio bytes, prompts, destinations or Primary/Next routing.
struct OpenAITranscriptionTurnReducer {
    enum Failure: String, Equatable, Sendable {
        case missingItemID
        case ambiguousDelta
        case unexpectedCommit
        case duplicateCommit
        case mismatchedCommit
        case earlyCompletion
        case unknownCompletion
        case duplicateCompletion
        case unexpectedClear
        case itemFailed
        case serverError
        case connectionLost
        case sendFailed
        case operationOverlap
        case operationTimedOut
        case operationInterrupted
        case emptyAudibleTurn
    }

    enum ServerEvent: Equatable {
        case delta(itemID: String?, text: String)
        case committed(itemID: String?)
        case completed(itemID: String?, transcript: String?)
        case cleared
        case itemFailed
        case serverError
        case connectionLost
    }

    /// Effects for the provider to publish after releasing its lock.
    struct Output: Equatable {
        /// Recorder-HUD text only: ordered completed turns plus live text. Never delivered.
        var partial: String?
        /// The one final for this recording. Empty text after a failure wakes Stop's wait
        /// and selects the existing complete-WAV fallback.
        var finalText: String?
        /// Set only the first time this recording's realtime path fails.
        var newFailure: Failure?
        /// A committed turn completed; a waiting boundary operation may continue.
        var completedTurnIndex: Int?
        /// Counts-only completion metadata for the existing same-item recovery log.
        var completion: OpenAITranscriptAccumulator.Resolution?
    }

    enum BoundaryDecision: Equatable {
        /// Send one commit WITHOUT flushing the resampler; this turn owns the next
        /// server committed item.
        case commitTurn(index: Int)
        /// Nothing was appended since the previous commit, so an update cannot drop audio.
        case noAudio
        /// Failed, closed, or Stop already requested: no new boundary may start.
        case unavailable
        /// A second boundary while one turn is still outstanding breaks the serial
        /// sender contract. Fail closed instead of correlating two pending turns.
        case overlap(Output)
    }

    enum FinalDecision: Equatable {
        /// Flush the resampler tail and send Stop's commit for this turn.
        case commitTurn(index: Int)
        /// Every appended byte is already committed; the final assembles from existing
        /// turns, immediately when they are complete or when the last one completes.
        case noNewAudio(Output)
        case unavailable
    }

    private struct Turn: Equatable {
        var itemID: String?
        var text: String?
        var requiresText: Bool
    }

    private(set) var failure: Failure?
    private(set) var finalCommitRequested = false
    private(set) var finalEmitted = false
    private(set) var isClosed = false
    private(set) var hasUncommittedAudio = false
    private var turns: [Turn] = []
    /// The live item receiving deltas before its committed event. The serial sender
    /// blocks audio during a boundary, so at most one such item can be legitimate.
    private var currentItemID: String?
    private var accumulator = OpenAITranscriptAccumulator()
    private var lastPartial: String?
    private var currentTurnRequiresText = false

    var turnCount: Int { turns.count }

    func isTurnComplete(_ index: Int) -> Bool {
        turns.indices.contains(index) && turns[index].text != nil
    }

    var hasOutstandingTurn: Bool {
        turns.contains { $0.text == nil }
    }

    mutating func noteAudioAppended(containsPossibleSpeech: Bool = true) {
        guard failure == nil, !isClosed, !finalCommitRequested else { return }
        hasUncommittedAudio = true
        currentTurnRequiresText = currentTurnRequiresText || containsPossibleSpeech
    }

    mutating func planContextBoundary() -> BoundaryDecision {
        guard failure == nil, !isClosed, !finalCommitRequested else { return .unavailable }
        guard !hasOutstandingTurn else { return .overlap(fail(.operationOverlap)) }
        guard hasUncommittedAudio else { return .noAudio }
        turns.append(Turn(requiresText: currentTurnRequiresText))
        hasUncommittedAudio = false
        currentTurnRequiresText = false
        return .commitTurn(index: turns.count - 1)
    }

    mutating func planFinalCommit() -> FinalDecision {
        guard failure == nil, !isClosed, !finalCommitRequested else { return .unavailable }
        finalCommitRequested = true
        // With no earlier turn this is the unchanged legacy single commit, even for an
        // empty recording (the server's own empty-buffer error still fails closed).
        if turns.isEmpty || hasUncommittedAudio {
            turns.append(Turn(requiresText: currentTurnRequiresText))
            hasUncommittedAudio = false
            currentTurnRequiresText = false
            return .commitTurn(index: turns.count - 1)
        }
        var output = Output()
        output.finalText = assembleIfReady()
        return .noNewAudio(output)
    }

    mutating func recordFailure(_ reason: Failure) -> Output {
        fail(reason)
    }

    /// Cancel/disconnect: no final, no fallback signal; waits resolve as cancelled.
    mutating func close() {
        isClosed = true
    }

    mutating func apply(_ event: ServerEvent) -> Output {
        guard failure == nil, !isClosed, !finalEmitted else { return Output() }
        switch event {
        case .delta(let itemID, let text):
            guard !text.isEmpty else { return Output() }
            guard let itemID, !itemID.isEmpty else { return fail(.missingItemID) }
            if let index = turns.firstIndex(where: { $0.itemID == itemID }) {
                // A late delta after completion cannot change the authoritative text.
                guard turns[index].text == nil else { return Output() }
            } else if let currentItemID, currentItemID != itemID {
                return fail(.ambiguousDelta)
            } else {
                currentItemID = itemID
            }
            _ = accumulator.append(delta: text, itemID: itemID)
            var output = Output()
            output.partial = partialIfChanged()
            return output

        case .committed(let itemID):
            guard let itemID, !itemID.isEmpty else { return fail(.missingItemID) }
            guard !turns.contains(where: { $0.itemID == itemID }) else { return fail(.duplicateCommit) }
            guard let index = turns.firstIndex(where: { $0.itemID == nil }) else {
                return fail(.unexpectedCommit)
            }
            // Live text for another item cannot be attributed to the audio this commit
            // created; delivering it, or dropping it, would both be a guess.
            if let currentItemID, currentItemID != itemID { return fail(.mismatchedCommit) }
            currentItemID = nil
            turns[index].itemID = itemID
            return Output()

        case .completed(let itemID, let transcript):
            guard let itemID, !itemID.isEmpty else { return fail(.missingItemID) }
            guard let index = turns.firstIndex(where: { $0.itemID == itemID }) else {
                return fail(itemID == currentItemID ? .earlyCompletion : .unknownCompletion)
            }
            guard turns[index].text == nil else { return fail(.duplicateCompletion) }
            let resolution = accumulator.complete(itemID: itemID, completedTranscript: transcript)
            // Quiet trailing audio does not prove the WHOLE turn was quiet. Losing
            // an audible empty turn beside a nonempty sibling would otherwise pass
            // the final nonempty-text check and silently omit earlier speech.
            if turns[index].requiresText && resolution.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fail(.emptyAudibleTurn)
            }
            // An intermediate empty turn is valid (a quiet boundary); a wholly empty
            // final still reaches the existing empty-final fallback in the service.
            turns[index].text = resolution.text
            var output = Output()
            output.completedTurnIndex = index
            output.completion = resolution
            if let finalText = assembleIfReady() {
                output.finalText = finalText
            } else {
                output.partial = partialIfChanged()
            }
            return output

        case .cleared:
            return fail(.unexpectedClear)
        case .itemFailed:
            return fail(.itemFailed)
        case .serverError:
            return fail(.serverError)
        case .connectionLost:
            return fail(.connectionLost)
        }
    }

    /// Completed turns first, then live text, in commit order. One turn returns the
    /// legacy cumulative string unchanged; later turns can never erase earlier words.
    var composedPartial: String {
        var parts: [String] = []
        for turn in turns {
            if let text = turn.text {
                parts.append(text)
            } else if let itemID = turn.itemID, let partial = accumulator.partial(for: itemID) {
                parts.append(partial)
            }
        }
        if let currentItemID, let partial = accumulator.partial(for: currentItemID) {
            parts.append(partial)
        }
        return Self.join(parts)
    }

    private mutating func partialIfChanged() -> String? {
        let text = composedPartial
        guard !text.isEmpty, text != lastPartial else { return nil }
        lastPartial = text
        return text
    }

    private mutating func assembleIfReady() -> String? {
        guard finalCommitRequested, !finalEmitted, failure == nil, !turns.isEmpty,
              turns.allSatisfy({ $0.text != nil }) else { return nil }
        finalEmitted = true
        return Self.join(turns.compactMap(\.text))
    }

    private mutating func fail(_ reason: Failure) -> Output {
        guard failure == nil, !isClosed else { return Output() }
        failure = reason
        var output = Output()
        output.newFailure = reason
        if finalCommitRequested, !finalEmitted {
            finalEmitted = true
            output.finalText = ""
        }
        return output
    }

    private static func join(_ texts: [String]) -> String {
        let nonEmpty = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if nonEmpty.count == 1 { return nonEmpty[0] }
        return nonEmpty
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
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
/// recorder-HUD preview only; only the one assembled final enters the existing one-shot
/// delivery pipeline selected by Primary or Next.
///
/// A recording may contain several provider-owned turns: a mid-recording context update
/// first commits the audio already appended (at a quiet boundary chosen by the sender),
/// waits for that exact item to complete, and only then changes the prompt. Intermediate
/// turns never emit `.committed`; their text stays private until Stop's final turn
/// completes, when every turn is joined in commit order and emitted exactly once.
final class OpenAIStreamingProvider: LiveContextStreamingTranscriptionProvider, @unchecked Sendable {
    // Updates run only before audio or at the sender's fully analysed quiet gap.
    // Raw session.update over uncommitted audio lost earlier words in real probes;
    // this adapter first completes the owned turn, then changes the hint. Three
    // quiet-gap wire probes and the native-adapter probe preserved all markers.
    // Acknowledgement/schema tests alone never qualify this path.
    let supportsLiveContextUpdates = true

    /// Bounds for one sender-owned boundary operation. A miss fails closed: realtime is
    /// abandoned and the complete WAV remains authoritative.
    static let intermediateTurnTimeoutNanoseconds: UInt64 = 2_000_000_000
    static let contextAcknowledgementTimeoutNanoseconds: UInt64 = 2_000_000_000

    enum TurnWait: Equatable, Sendable {
        case turnCompletion(Int)
        case acknowledgement
    }

    enum TurnWaitResult: Equatable, Sendable {
        case satisfied
        case failed
        case timedOut
        case cancelled
    }

    private enum AcknowledgementState {
        case idle
        case awaiting
        case received
    }

    // Fixed strings only: server errors can echo private prompt/hint text.
    static let unusableSessionMessage = "OpenAI realtime transcription is unavailable for this recording"
    private static let serverFailureMessage = "OpenAI realtime transcription request failed"
    private static let integrityFailureMessage = "OpenAI realtime transcription integrity check failed"

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var resampler = OpenAIRealtimePCMResampler()
    private var audioEvidence = RealtimeSilenceSleepGate(configuration: .gptLiveDefault, startedAt: 0)
    private var currentTurnAudioBytes = 0
    private let modelContext: ModelContext
    private let stateLock = NSLock()
    // Every field below is guarded by stateLock.
    private var turns = OpenAITranscriptionTurnReducer()
    private var didSignalFinalStorage = false
    private var acknowledgementState = AcknowledgementState.idle
    private var waitSequence: UInt64 = 0
    private var activeWait: (token: UInt64, kind: TurnWait)?
    private var activeWaitContinuation: CheckedContinuation<TurnWaitResult, Never>?
    private var earlyWaitResult: TurnWaitResult?
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
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        eventsContinuation?.finish()
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
        resampler = OpenAIRealtimePCMResampler()
        audioEvidence = RealtimeSilenceSleepGate(configuration: .gptLiveDefault, startedAt: 0)
        currentTurnAudioBytes = 0
        withState {
            turns = OpenAITranscriptionTurnReducer()
            didSignalFinalStorage = false
            acknowledgementState = .idle
        }
        task.resume()

        // Both halves start with this recording's own prompt and frozen Vocabulary.
        // Only references available at prepare can enter the live startup request.
        // Later captures stay in final references/fallback context and may update
        // this socket only through the quiet-boundary operation below.
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
        // A failed recording must not keep appending audio that no final can own;
        // throwing records the chunk as dropped, so Stop takes the complete WAV.
        try throwIfUnusable()
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }
        _ = audioEvidence.process(data, at: 0)
        let converted = resampler.convert(data)
        guard !converted.isEmpty else { return }
        do {
            try await sendAudio(converted, over: task)
        } catch {
            publish(withState { turns.recordFailure(.sendFailed) })
            throw error
        }
        currentTurnAudioBytes += converted.count
        recordAppendedAudio(containsPossibleSpeech: audioEvidence.hasPossibleActivity)
    }

    /// Mid-recording prompt change for the serial audio sender only.
    ///
    /// The sender calls this before any audio or at a conservative quiet boundary,
    /// never mid-word. Appended audio is committed first WITHOUT flushing the
    /// resampler, that exact item must commit and complete, and only then is the
    /// prompt changed: the real API kept only post-update audio when updates ran
    /// over uncommitted speech. An acknowledgement alone never proves audio survived.
    func updateTranscriptionContext(_ context: TranscriptionRequestContext) async throws {
        // The serial sender owns acoustic-boundary eligibility. This second
        // capability boundary prevents a disabled adapter from doing network work.
        guard supportsLiveContextUpdates else {
            throw StreamingTranscriptionError.serverError("OpenAI mid-recording context updates are unavailable")
        }
        try throwIfUnusable()
        guard let task = webSocketTask, !Task.isCancelled else {
            throw StreamingTranscriptionError.notConnected
        }

        switch beginContextBoundary() {
        case .unavailable:
            try throwIfUnusable()
            throw StreamingTranscriptionError.notConnected
        case .overlap(let output):
            publish(output)
            throw StreamingTranscriptionError.serverError(Self.unusableSessionMessage)
        case .noAudio:
            break
        case .commitTurn(let index):
            do {
                try await sendCommitMessage(over: task)
            } catch {
                publish(withState { turns.recordFailure(.sendFailed) })
                throw error
            }
            try await requireOperation(
                .turnCompletion(index),
                timeoutNanoseconds: Self.intermediateTurnTimeoutNanoseconds
            )
            currentTurnAudioBytes = 0
        }

        withState { acknowledgementState = .awaiting }
        defer { withState { acknowledgementState = .idle } }
        let update = OpenAITranscriptionConfiguration.realtimeContextUpdate(
            language: context.language,
            prompt: context.openAITranscriptionPrompt,
            customVocabulary: context.customVocabulary(orLiveFetch: customDictionaryTerms)
        )
        do {
            try await sendJSON(update, over: task)
        } catch {
            publish(withState { turns.recordFailure(.sendFailed) })
            throw error
        }
        try await requireOperation(
            .acknowledgement,
            timeoutNanoseconds: Self.contextAcknowledgementTimeoutNanoseconds
        )
    }

    /// Stop's single user-visible commit, and the only path that drains the resampler tail.
    func commit() async throws {
        try throwIfUnusable()
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        switch withState({ turns.planFinalCommit() }) {
        case .unavailable:
            try throwIfUnusable()
            throw StreamingTranscriptionError.notConnected
        case .noNewAudio(let output):
            // Every appended byte already belongs to a committed turn. Committing an
            // empty buffer would be rejected; the final assembles from those turns.
            publish(output)
        case .commitTurn(let index):
            do {
                let tail = resampler.flush()
                if !tail.isEmpty {
                    try await sendAudio(tail, over: task)
                    currentTurnAudioBytes += tail.count
                }
                // Stop may follow an intermediate boundary by only one callback.
                // Satisfy the server's 100ms minimum with network-only zero PCM;
                // the original WAV and every captured speech sample stay unchanged.
                if index > 0 {
                    let count = Self.finalTurnPaddingBytes(audioBytes: currentTurnAudioBytes)
                    if count > 0 { try await sendAudio(Data(repeating: 0, count: count), over: task) }
                }
                try await sendCommitMessage(over: task)
            } catch {
                publish(withState { turns.recordFailure(.sendFailed) })
                throw error
            }
        }
    }

    func disconnect() async {
        // Cancel and cleanup emit no final: a waiting boundary returns cancelled.
        withState { turns.close() }
        reevaluateWait()
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        eventsContinuation?.finish()
    }

    // MARK: - Turn ownership (sender-serialized; internal for focused tests)

    /// Records converted audio that reached the socket for the current turn.
    func recordAppendedAudio(containsPossibleSpeech: Bool = true) {
        withState { turns.noteAudioAppended(containsPossibleSpeech: containsPossibleSpeech) }
    }

    /// Plans one context boundary. At most one may be outstanding.
    func beginContextBoundary() -> OpenAITranscriptionTurnReducer.BoundaryDecision {
        let decision = withState { turns.planContextBoundary() }
        if case .commitTurn = decision { audioEvidence.resetActivityEvidence() }
        return decision
    }

    static func finalTurnPaddingBytes(audioBytes: Int) -> Int {
        let minimum = Int(Double(OpenAITranscriptionConfiguration.realtimeSampleRate) * 0.12) * 2
        return audioBytes > 0 ? max(0, minimum - audioBytes) : 0
    }

    /// Server-event entry point used by the receive loop. Never logs text or item IDs.
    func handleServerEvent(_ json: [String: Any]) {
        let event: OpenAITranscriptionTurnReducer.ServerEvent
        switch json["type"] as? String {
        case "session.updated":
            // No event ID is echoed, so only the single update this provider is
            // awaiting may consume an acknowledgement; anything else is ignored.
            withState {
                if acknowledgementState == .awaiting { acknowledgementState = .received }
            }
            reevaluateWait()
            return

        case "input_audio_buffer.committed":
            event = .committed(itemID: json["item_id"] as? String)

        case "input_audio_buffer.cleared":
            event = .cleared

        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
            event = .delta(itemID: json["item_id"] as? String, text: delta)

        case "conversation.item.input_audio_transcription.completed":
            if let usage = OpenAIRealtimeUsageSummary.describe(json["usage"]) {
                logger.notice("OpenAI completion usage \(usage, privacy: .public)")
            }
            event = .completed(
                itemID: json["item_id"] as? String,
                transcript: json["transcript"] as? String
            )

        case "conversation.item.input_audio_transcription.failed":
            event = .itemFailed

        case "error":
            event = .serverError

        default:
            return
        }
        publish(withState { turns.apply(event) })
    }

    /// Waits for one sender-owned operation. Failure, cancel, disconnect or timeout
    /// resolve it promptly; no wait can outlive its bounded timeout.
    func waitForTurnOperation(_ kind: TurnWait, timeoutNanoseconds: UInt64) async -> TurnWaitResult {
        let token: UInt64 = withState {
            waitSequence &+= 1
            activeWait = (waitSequence, kind)
            activeWaitContinuation = nil
            earlyWaitResult = nil
            return waitSequence
        }
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.finishWait(token: token, with: .timedOut)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TurnWaitResult, Never>) in
                stateLock.lock()
                let immediate: TurnWaitResult?
                if activeWait?.token != token {
                    immediate = .cancelled
                } else if let earlyWaitResult {
                    immediate = earlyWaitResult
                } else if Task.isCancelled {
                    immediate = .cancelled
                } else {
                    immediate = readyResult(for: kind)
                }
                if let immediate {
                    activeWait = nil
                    earlyWaitResult = nil
                    stateLock.unlock()
                    continuation.resume(returning: immediate)
                } else {
                    activeWaitContinuation = continuation
                    stateLock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.finishWait(token: token, with: .cancelled)
        }
    }

    private func requireOperation(_ kind: TurnWait, timeoutNanoseconds: UInt64) async throws {
        switch await waitForTurnOperation(kind, timeoutNanoseconds: timeoutNanoseconds) {
        case .satisfied:
            return
        case .failed:
            throw StreamingTranscriptionError.serverError(Self.unusableSessionMessage)
        case .timedOut:
            publish(withState { turns.recordFailure(.operationTimedOut) })
            throw StreamingTranscriptionError.timeout
        case .cancelled:
            // A boundary left half-finished cannot prove which audio survived.
            publish(withState { turns.recordFailure(.operationInterrupted) })
            throw CancellationError()
        }
    }

    /// Caller holds stateLock.
    private func readyResult(for kind: TurnWait) -> TurnWaitResult? {
        if turns.isClosed { return .cancelled }
        if turns.failure != nil { return .failed }
        switch kind {
        case .turnCompletion(let index):
            return turns.isTurnComplete(index) ? .satisfied : nil
        case .acknowledgement:
            return acknowledgementState == .received ? .satisfied : nil
        }
    }

    private func finishWait(token: UInt64, with result: TurnWaitResult) {
        stateLock.lock()
        guard let active = activeWait, active.token == token else {
            stateLock.unlock()
            return
        }
        guard let continuation = activeWaitContinuation else {
            // The wait has not installed its continuation yet; it will see this result.
            if earlyWaitResult == nil { earlyWaitResult = result }
            stateLock.unlock()
            return
        }
        activeWait = nil
        activeWaitContinuation = nil
        earlyWaitResult = nil
        stateLock.unlock()
        continuation.resume(returning: result)
    }

    /// Re-evaluates the installed wait after turn, acknowledgement or lifecycle state changed.
    private func reevaluateWait() {
        stateLock.lock()
        guard let active = activeWait,
              let continuation = activeWaitContinuation,
              let result = readyResult(for: active.kind) else {
            stateLock.unlock()
            return
        }
        activeWait = nil
        activeWaitContinuation = nil
        earlyWaitResult = nil
        stateLock.unlock()
        continuation.resume(returning: result)
    }

    /// Publishes reducer effects outside the lock: one error on the first failure,
    /// HUD partials, and the single final (empty after a failure following Stop).
    private func publish(
        _ output: OpenAITranscriptionTurnReducer.Output,
        surfacedError: StreamingTranscriptionError? = nil
    ) {
        if let resolution = output.completion, resolution.source == .sameItemDelta {
            logger.notice(
                "OpenAI completion recovered same-item delta \(resolution.privacySafeLogMetadata, privacy: .public)"
            )
        }
        if let failure = output.newFailure {
            // Reason only; never transcript text, prompts or item identifiers.
            logger.warning("OpenAI realtime turn failed closed reason=\(failure.rawValue, privacy: .public)")
            eventsContinuation?.yield(.error(surfacedError ?? Self.error(for: failure)))
        }
        if let partial = output.partial {
            eventsContinuation?.yield(.partial(text: partial))
        }
        if let finalText = output.finalText {
            yieldFinalOnce(finalText)
        }
        reevaluateWait()
    }

    private static func error(for failure: OpenAITranscriptionTurnReducer.Failure) -> StreamingTranscriptionError {
        switch failure {
        case .serverError, .itemFailed:
            return .serverError(serverFailureMessage)
        case .connectionLost, .sendFailed:
            return .connectionFailed("OpenAI realtime connection was lost")
        default:
            return .serverError(integrityFailureMessage)
        }
    }

    private func throwIfUnusable() throws {
        let (failed, closed) = withState { (turns.failure != nil, turns.isClosed) }
        if failed { throw StreamingTranscriptionError.serverError(Self.unusableSessionMessage) }
        if closed { throw StreamingTranscriptionError.notConnected }
    }

    private func sendCommitMessage(over task: URLSessionWebSocketTask) async throws {
        try await sendJSON(["type": "input_audio_buffer.commit"], over: task)
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
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
                    handleServerEvent(json)
                }
            } catch {
                if !Task.isCancelled {
                    // A lost socket fails closed: pending waits end, later sends and
                    // Stop's commit throw, and after Stop one empty final wakes the
                    // service so it takes the complete WAV without a ten-second stall.
                    publish(
                        withState { turns.apply(.connectionLost) },
                        surfacedError: .connectionFailed(error.localizedDescription)
                    )
                }
                break
            }
        }
    }

    /// The only `.committed` emission. Intermediate turns never reach it; the reducer
    /// supplies either the assembled final or, after a failure following Stop, "".
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
}
