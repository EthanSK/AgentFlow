import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

/// Provider-internal GPT Live turn ownership. Offline only: these prove correlation,
/// assembly and fail-closed gates, not real API behavior or recognition quality.
struct OpenAITranscriptionTurnTests {
    private typealias Reducer = OpenAITranscriptionTurnReducer

    // MARK: - Legacy single commit

    @Test func legacyOneTurnKeepsTheExistingSingleCommitContract() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        // Live deltas legitimately arrive before the committed event.
        #expect(reducer.apply(.delta(itemID: "item-a", text: "hello ")).partial == "hello ")
        #expect(reducer.apply(.delta(itemID: "item-a", text: "world")).partial == "hello world")
        #expect(reducer.planFinalCommit() == .commitTurn(index: 0))
        #expect(reducer.apply(.committed(itemID: "item-a")) == .init())
        let completed = reducer.apply(.completed(itemID: "item-a", transcript: "Hello world."))
        #expect(completed.finalText == "Hello world.")
        #expect(completed.partial == nil)
        #expect(completed.newFailure == nil)
        #expect(reducer.finalEmitted)
        #expect(reducer.turnCount == 1)
        // Nothing may follow the one final, including a late error.
        #expect(reducer.apply(.completed(itemID: "item-a", transcript: "again")) == .init())
        #expect(reducer.apply(.serverError) == .init())
        #expect(reducer.failure == nil)
    }

    @Test func legacyCommitStillRecoversSameItemDeltasAndCommitsAnEmptyRecording() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        #expect(reducer.planFinalCommit() == .commitTurn(index: 0))
        _ = reducer.apply(.committed(itemID: "item-a"))
        #expect(reducer.apply(.delta(itemID: "item-a", text: "recover this")).partial == "recover this")
        let completed = reducer.apply(.completed(itemID: "item-a", transcript: ""))
        #expect(completed.finalText == "recover this")
        #expect(completed.completion?.source == .sameItemDelta)

        // Without earlier turns Stop always sends the legacy commit, even with no audio.
        var empty = Reducer()
        #expect(empty.planFinalCommit() == .commitTurn(index: 0))
    }

    // MARK: - Multiple owned turns

    @Test func threeTurnsJoinInCommitOrderWithAHUDThatKeepsEarlierWords() {
        var reducer = Reducer()
        var partials: [String] = []

        reducer.noteAudioAppended()
        if let partial = reducer.apply(.delta(itemID: "a", text: "cedar")).partial { partials.append(partial) }
        #expect(reducer.planContextBoundary() == .commitTurn(index: 0))
        #expect(!reducer.hasUncommittedAudio)
        #expect(reducer.apply(.committed(itemID: "a")) == .init())
        let first = reducer.apply(.completed(itemID: "a", transcript: "Cedar one."))
        #expect(first.completedTurnIndex == 0)
        #expect(first.finalText == nil) // intermediate turns never become a final
        if let partial = first.partial { partials.append(partial) }
        #expect(reducer.isTurnComplete(0))

        reducer.noteAudioAppended()
        if let partial = reducer.apply(.delta(itemID: "b", text: "maple")).partial { partials.append(partial) }
        #expect(reducer.planContextBoundary() == .commitTurn(index: 1))
        _ = reducer.apply(.committed(itemID: "b"))
        let second = reducer.apply(.completed(itemID: "b", transcript: "Maple two."))
        #expect(second.finalText == nil)
        if let partial = second.partial { partials.append(partial) }

        reducer.noteAudioAppended()
        if let partial = reducer.apply(.delta(itemID: "c", text: "willow")).partial { partials.append(partial) }
        #expect(reducer.planFinalCommit() == .commitTurn(index: 2))
        _ = reducer.apply(.committed(itemID: "c"))
        let final = reducer.apply(.completed(itemID: "c", transcript: "Willow three."))

        #expect(final.finalText == "Cedar one. Maple two. Willow three.")
        #expect(partials == [
            "cedar",
            "Cedar one.",
            "Cedar one. maple",
            "Cedar one. Maple two.",
            "Cedar one. Maple two. willow",
        ])
        #expect(partials.dropFirst().allSatisfy { $0.hasPrefix("Cedar one.") })
    }

    @Test func zeroAudioBoundariesNeverCommitAndStopReusesCommittedTurns() {
        var reducer = Reducer()
        // A startup update before any audio has nothing to preserve.
        #expect(reducer.planContextBoundary() == .noAudio)
        #expect(reducer.turnCount == 0)

        reducer.noteAudioAppended()
        #expect(reducer.planContextBoundary() == .commitTurn(index: 0))
        _ = reducer.apply(.committed(itemID: "a"))
        _ = reducer.apply(.completed(itemID: "a", transcript: "Only turn."))
        #expect(reducer.planContextBoundary() == .noAudio)

        // Stop with nothing appended since the last commit sends no empty commit.
        guard case .noNewAudio(let output) = reducer.planFinalCommit() else {
            Issue.record("Stop must not commit an empty buffer after an owned turn")
            return
        }
        #expect(output.finalText == "Only turn.")
        #expect(reducer.turnCount == 1)
    }

    @Test func stopDuringAnOwnedBoundaryFinishesThatTurnAndStartsNoOther() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        #expect(reducer.planContextBoundary() == .commitTurn(index: 0))
        guard case .noNewAudio(let pending) = reducer.planFinalCommit() else {
            Issue.record("Stop during a boundary must reuse the owned turn")
            return
        }
        #expect(pending.finalText == nil)
        #expect(reducer.planContextBoundary() == .unavailable)
        _ = reducer.apply(.committed(itemID: "a"))
        #expect(reducer.apply(.completed(itemID: "a", transcript: "Owned turn.")).finalText == "Owned turn.")
    }

    @Test func emptyIntermediateTurnsAreValidButAWhollyEmptyFinalUsesTheFallback() {
        var reducer = Reducer()
        reducer.noteAudioAppended(containsPossibleSpeech: false)
        _ = reducer.planContextBoundary()
        _ = reducer.apply(.committed(itemID: "quiet"))
        let quiet = reducer.apply(.completed(itemID: "quiet", transcript: ""))
        #expect(quiet.newFailure == nil)
        #expect(quiet.completedTurnIndex == 0)
        reducer.noteAudioAppended()
        _ = reducer.apply(.delta(itemID: "speech", text: "spoken"))
        _ = reducer.planFinalCommit()
        _ = reducer.apply(.committed(itemID: "speech"))
        #expect(reducer.apply(.completed(itemID: "speech", transcript: "Spoken.")).finalText == "Spoken.")

        var silent = Reducer()
        silent.noteAudioAppended(containsPossibleSpeech: false)
        _ = silent.planContextBoundary()
        _ = silent.apply(.committed(itemID: "a"))
        _ = silent.apply(.completed(itemID: "a", transcript: " "))
        silent.noteAudioAppended(containsPossibleSpeech: false)
        _ = silent.planFinalCommit()
        _ = silent.apply(.committed(itemID: "b"))
        let empty = silent.apply(.completed(itemID: "b", transcript: nil))
        #expect(empty.finalText == "")
        #expect(StreamingFinalTextDisposition.resolve(empty.finalText ?? "unexpected") == .useBatchFallback)
    }

    @Test func anEmptyAudibleTurnCannotBeHiddenByOtherNonemptyTurns() {
        var intermediate = Reducer()
        intermediate.noteAudioAppended()
        _ = intermediate.planContextBoundary()
        _ = intermediate.apply(.committed(itemID: "speech"))
        let failure = intermediate.apply(.completed(itemID: "speech", transcript: ""))
        #expect(failure.newFailure == .emptyAudibleTurn)
        #expect(intermediate.planFinalCommit() == .unavailable)

        var final = Reducer()
        final.noteAudioAppended()
        _ = final.planContextBoundary()
        _ = final.apply(.committed(itemID: "first"))
        _ = final.apply(.completed(itemID: "first", transcript: "Earlier words."))
        final.noteAudioAppended()
        _ = final.planFinalCommit()
        _ = final.apply(.committed(itemID: "last"))
        let empty = final.apply(.completed(itemID: "last", transcript: nil))
        #expect(empty.newFailure == .emptyAudibleTurn)
        #expect(empty.finalText == "")
    }

    @Test func shortFinalTurnUsesOnlyEnoughNetworkSilenceToMeetTheMinimum() {
        let minimum = Int(Double(OpenAITranscriptionConfiguration.realtimeSampleRate) * 0.12) * 2
        #expect(OpenAIStreamingProvider.finalTurnPaddingBytes(audioBytes: 0) == 0)
        #expect(OpenAIStreamingProvider.finalTurnPaddingBytes(audioBytes: 480) + 480 == minimum)
        #expect(OpenAIStreamingProvider.finalTurnPaddingBytes(audioBytes: minimum) == 0)
        #expect(OpenAIStreamingProvider.finalTurnPaddingBytes(audioBytes: minimum * 2) == 0)
    }

    @Test func lateDeltaAfterCompletionCannotChangeTheAuthoritativeText() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        _ = reducer.planContextBoundary()
        _ = reducer.apply(.committed(itemID: "a"))
        _ = reducer.apply(.completed(itemID: "a", transcript: "Exact."))
        #expect(reducer.apply(.delta(itemID: "a", text: "garbage")) == .init())
        #expect(reducer.composedPartial == "Exact.")
        _ = reducer.planFinalCommit()
        #expect(reducer.failure == nil)
    }

    // MARK: - Fail-closed identity

    @Test func earlyForeignAndDuplicateCompletionsFailClosed() {
        var early = Reducer()
        early.noteAudioAppended()
        _ = early.apply(.delta(itemID: "a", text: "live"))
        let earlyOutput = early.apply(.completed(itemID: "a", transcript: "Before any commit."))
        #expect(earlyOutput.newFailure == .earlyCompletion)
        #expect(earlyOutput.finalText == nil) // Stop has not been requested
        #expect(early.planFinalCommit() == .unavailable)

        var foreign = Reducer()
        foreign.noteAudioAppended()
        _ = foreign.planFinalCommit()
        _ = foreign.apply(.committed(itemID: "a"))
        let foreignOutput = foreign.apply(.completed(itemID: "z", transcript: "Someone else's item."))
        #expect(foreignOutput.newFailure == .unknownCompletion)
        #expect(foreignOutput.finalText == "") // wakes Stop; the WAV fallback owns the result
        #expect(foreign.apply(.completed(itemID: "a", transcript: "Plausible.")) == .init())

        var duplicate = Reducer()
        duplicate.noteAudioAppended()
        _ = duplicate.planContextBoundary()
        _ = duplicate.apply(.committed(itemID: "a"))
        _ = duplicate.apply(.completed(itemID: "a", transcript: "First."))
        #expect(duplicate.apply(.completed(itemID: "a", transcript: "Second.")).newFailure == .duplicateCompletion)
    }

    @Test func missingItemIdentifiersFailClosed() {
        let events: [Reducer.ServerEvent] = [
            .delta(itemID: nil, text: "words"),
            .delta(itemID: "", text: "words"),
            .committed(itemID: nil),
            .completed(itemID: nil, transcript: "words"),
        ]
        for event in events {
            var reducer = Reducer()
            reducer.noteAudioAppended()
            _ = reducer.planFinalCommit()
            #expect(reducer.apply(event).newFailure == .missingItemID)
        }
    }

    @Test func unexpectedDuplicateAndMismatchedCommitsFailClosed() {
        var unrequested = Reducer()
        #expect(unrequested.apply(.committed(itemID: "a")).newFailure == .unexpectedCommit)

        var duplicate = Reducer()
        duplicate.noteAudioAppended()
        _ = duplicate.planFinalCommit()
        _ = duplicate.apply(.committed(itemID: "a"))
        #expect(duplicate.apply(.committed(itemID: "a")).newFailure == .duplicateCommit)

        var extra = Reducer()
        extra.noteAudioAppended()
        _ = extra.planContextBoundary()
        _ = extra.apply(.committed(itemID: "a"))
        #expect(extra.apply(.committed(itemID: "b")).newFailure == .unexpectedCommit)

        var mismatched = Reducer()
        mismatched.noteAudioAppended()
        _ = mismatched.apply(.delta(itemID: "live", text: "attributed words"))
        _ = mismatched.planFinalCommit()
        let output = mismatched.apply(.committed(itemID: "other"))
        #expect(output.newFailure == .mismatchedCommit)
        #expect(output.finalText == "")
    }

    @Test func ambiguousLiveItemsFailClosed() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        _ = reducer.apply(.delta(itemID: "a", text: "one"))
        #expect(reducer.apply(.delta(itemID: "b", text: "two")).newFailure == .ambiguousDelta)
    }

    @Test func unexpectedClearFailedItemsAndTransportErrorsFailClosed() {
        let cases: [(Reducer.ServerEvent, Reducer.Failure)] = [
            (.cleared, .unexpectedClear),
            (.itemFailed, .itemFailed),
            (.serverError, .serverError),
            (.connectionLost, .connectionLost),
        ]
        for (event, failure) in cases {
            var reducer = Reducer()
            reducer.noteAudioAppended()
            #expect(reducer.apply(event).newFailure == failure)
            #expect(reducer.planContextBoundary() == .unavailable)
        }
    }

    // MARK: - Failure and lifecycle gates

    @Test func failureAfterStopEmitsOneEmptyFinalAndNoPlausibleText() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        _ = reducer.planFinalCommit()
        _ = reducer.apply(.committed(itemID: "a"))
        _ = reducer.apply(.delta(itemID: "a", text: "plausible but incomplete"))
        let failed = reducer.apply(.serverError)
        #expect(failed.newFailure == .serverError)
        #expect(failed.finalText == "")
        #expect(reducer.apply(.completed(itemID: "a", transcript: "late text")) == .init())
        #expect(reducer.recordFailure(.operationTimedOut) == .init())
        #expect(StreamingFinalTextDisposition.resolve(failed.finalText ?? "unexpected") == .useBatchFallback)
    }

    @Test func failureBeforeStopEmitsNoFinalAndBlocksEveryLaterOperation() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        let failed = reducer.apply(.connectionLost)
        #expect(failed.newFailure == .connectionLost)
        #expect(failed.finalText == nil)
        #expect(reducer.planContextBoundary() == .unavailable)
        #expect(reducer.planFinalCommit() == .unavailable)
        // Only the first failure surfaces.
        #expect(reducer.recordFailure(.sendFailed) == .init())
    }

    @Test func overlappingBoundariesFailClosed() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        #expect(reducer.planContextBoundary() == .commitTurn(index: 0))
        reducer.noteAudioAppended()
        guard case .overlap(let output) = reducer.planContextBoundary() else {
            Issue.record("A second outstanding boundary must not be correlated")
            return
        }
        #expect(output.newFailure == .operationOverlap)
    }

    @Test func closeEmitsNoFinalAndIgnoresLaterEvents() {
        var reducer = Reducer()
        reducer.noteAudioAppended()
        _ = reducer.planFinalCommit()
        _ = reducer.apply(.committed(itemID: "a"))
        reducer.close()
        #expect(reducer.apply(.completed(itemID: "a", transcript: "text")) == .init())
        #expect(reducer.apply(.serverError) == .init())
        #expect(reducer.recordFailure(.operationInterrupted) == .init())
        #expect(!reducer.finalEmitted)
    }

    // MARK: - Provider integration without a socket

    @MainActor private func makeProvider() throws -> (OpenAIStreamingProvider, ModelContainer) {
        let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return (OpenAIStreamingProvider(modelContext: ModelContext(container)), container)
    }

    @Test @MainActor func providerKeepsIntermediateTurnsPrivateAndHUDPartialsMonotonic() async throws {
        let (provider, container) = try makeProvider()
        _ = container
        #expect(provider.supportsLiveContextUpdates) // qualified quiet-boundary path
        var events = provider.transcriptionEvents.makeAsyncIterator()

        provider.recordAppendedAudio()
        provider.handleServerEvent(["type": "conversation.item.input_audio_transcription.delta",
                                    "item_id": "item-a", "delta": "one"])
        guard case .partial(let live)? = await events.next() else { Issue.record("Missing live partial"); return }
        #expect(live == "one")
        #expect(provider.beginContextBoundary() == .commitTurn(index: 0))
        provider.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "item-a"])
        provider.handleServerEvent(["type": "conversation.item.input_audio_transcription.completed",
                                    "item_id": "item-a", "transcript": "One."])
        // The intermediate turn surfaces only as HUD text, never as a final.
        guard case .partial(let completed)? = await events.next() else {
            Issue.record("An intermediate turn must not emit .committed")
            return
        }
        #expect(completed == "One.")
        provider.recordAppendedAudio()
        provider.handleServerEvent(["type": "conversation.item.input_audio_transcription.delta",
                                    "item_id": "item-b", "delta": "two"])
        guard case .partial(let combined)? = await events.next() else { Issue.record("Missing combined partial"); return }
        #expect(combined == "One. two")

        await provider.disconnect()
        if let unexpected = await events.next() {
            Issue.record("Disconnect must emit no final: \(unexpected)")
        }
    }

    @Test @MainActor func providerFailureEmitsOneFixedErrorAndBlocksSendsAndCommit() async throws {
        let (provider, container) = try makeProvider()
        _ = container
        var events = provider.transcriptionEvents.makeAsyncIterator()
        provider.handleServerEvent(["type": "error", "error": ["message": "echoed private hint AC-42"]])
        guard case .error(let error)? = await events.next() else { Issue.record("Missing error event"); return }
        #expect(!String(describing: error).contains("AC-42"))
        provider.handleServerEvent(["type": "error"]) // later errors do not repeat

        do {
            try await provider.sendAudioChunk(Data([0, 0, 0, 0]))
            Issue.record("A failed recording must not append more audio")
        } catch StreamingTranscriptionError.serverError(let message) {
            #expect(message == OpenAIStreamingProvider.unusableSessionMessage)
        }
        do {
            try await provider.commit()
            Issue.record("A failed recording must not commit a plausible truncated final")
        } catch StreamingTranscriptionError.serverError(let message) {
            #expect(message == OpenAIStreamingProvider.unusableSessionMessage)
        }
        provider.handleServerEvent(["type": "conversation.item.input_audio_transcription.completed",
                                    "item_id": "item-a", "transcript": "late text"])
        await provider.disconnect()
        if let unexpected = await events.next() {
            Issue.record("No further event may follow the first failure: \(unexpected)")
        }
    }

    @Test @MainActor func boundaryWaitsResolveOnCompletionFailureDisconnectCancelAndTimeout() async throws {
        let clock = ContinuousClock()

        let (completedProvider, c1) = try makeProvider()
        _ = c1
        completedProvider.recordAppendedAudio()
        #expect(completedProvider.beginContextBoundary() == .commitTurn(index: 0))
        let completion = Task {
            await completedProvider.waitForTurnOperation(.turnCompletion(0), timeoutNanoseconds: 5_000_000_000)
        }
        completedProvider.handleServerEvent(["type": "input_audio_buffer.committed", "item_id": "item-a"])
        completedProvider.handleServerEvent(["type": "conversation.item.input_audio_transcription.completed",
                                             "item_id": "item-a", "transcript": "Done."])
        #expect(await completion.value == .satisfied)

        let (failingProvider, c2) = try makeProvider()
        _ = c2
        failingProvider.recordAppendedAudio()
        _ = failingProvider.beginContextBoundary()
        let failingStart = clock.now
        let failing = Task {
            await failingProvider.waitForTurnOperation(.turnCompletion(0), timeoutNanoseconds: 5_000_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        failingProvider.handleServerEvent(["type": "input_audio_buffer.cleared"])
        #expect(await failing.value == .failed)
        #expect(failingStart.duration(to: clock.now) < .seconds(2))

        let (closingProvider, c3) = try makeProvider()
        _ = c3
        closingProvider.recordAppendedAudio()
        _ = closingProvider.beginContextBoundary()
        let closing = Task {
            await closingProvider.waitForTurnOperation(.turnCompletion(0), timeoutNanoseconds: 5_000_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await closingProvider.disconnect()
        #expect(await closing.value == .cancelled)

        let (cancelledProvider, c4) = try makeProvider()
        _ = c4
        cancelledProvider.recordAppendedAudio()
        _ = cancelledProvider.beginContextBoundary()
        let cancelled = Task {
            await cancelledProvider.waitForTurnOperation(.turnCompletion(0), timeoutNanoseconds: 5_000_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        #expect(await cancelled.value == .cancelled)

        let (slowProvider, c5) = try makeProvider()
        _ = c5
        slowProvider.recordAppendedAudio()
        _ = slowProvider.beginContextBoundary()
        #expect(await slowProvider.waitForTurnOperation(.turnCompletion(0), timeoutNanoseconds: 50_000_000) == .timedOut)
    }

    @Test @MainActor func unsolicitedSessionUpdatesCannotAcknowledgeAContextUpdate() async throws {
        let (provider, container) = try makeProvider()
        _ = container
        // session.updated carries no event ID; only an update this provider is
        // awaiting may consume one, so stray acknowledgements are ignored.
        provider.handleServerEvent(["type": "session.updated"])
        let waiting = Task {
            await provider.waitForTurnOperation(.acknowledgement, timeoutNanoseconds: 100_000_000)
        }
        provider.handleServerEvent(["type": "session.updated"])
        #expect(await waiting.value == .timedOut)
    }

    // MARK: - Source guards

    @Test func onlyStopFlushesTheResamplerAndOnlyOneFinalEmissionExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Streaming/OpenAIStreamingProvider.swift"),
            encoding: .utf8
        )
        #expect(source.components(separatedBy: "resampler.flush()").count - 1 == 1)
        let update = try #require(source.range(of: "func updateTranscriptionContext("))
        let commit = try #require(source.range(of: "func commit() async throws"))
        let disconnect = try #require(source.range(of: "func disconnect() async", range: commit.upperBound..<source.endIndex))
        let flush = try #require(source.range(of: "resampler.flush()"))
        #expect(update.upperBound < commit.lowerBound)
        #expect(commit.upperBound <= flush.lowerBound && flush.upperBound <= disconnect.lowerBound)
        let updateBody = source[update.lowerBound..<commit.lowerBound]
        #expect(!updateBody.contains("flush"))
        #expect(updateBody.contains("sendCommitMessage(over: task)"))
        #expect(updateBody.contains(".turnCompletion(index)"))
        #expect(updateBody.contains(".acknowledgement"))
        #expect(source.components(separatedBy: "eventsContinuation?.yield(.committed(").count - 1 == 1)
        #expect(source.components(separatedBy: "\"type\": \"input_audio_buffer.commit\"").count - 1 == 1)
    }
}
