import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct LiveTranscriptionBoundaryTests {
    private func tone(_ sample: Int16, seconds: Double) -> Data {
        let bits = UInt16(bitPattern: sample)
        let pair = [UInt8(bits & 255), UInt8(bits >> 8)]
        return Data(Array(repeating: pair, count: Int(16_000 * seconds)).joined())
    }

    @Test func continuousSpeechAndAudibleMusicNeverCreateABoundary() {
        for sample in [Int16(4_000), 100, 26] {
            var policy = LiveTranscriptionBoundaryPolicy()
            policy.didSend(tone(sample, seconds: 15), at: 15)
            #expect(!policy.canApplyContext(at: 15))
        }
    }

    @Test func startupOrOneFullyAnalysedQuietSecondAfterThreeSecondsIsEligible() {
        var policy = LiveTranscriptionBoundaryPolicy()
        #expect(policy.canApplyContext(at: 0))
        policy.didSend(tone(4_000, seconds: 2), at: 2)
        policy.didSend(tone(0, seconds: 0.98), at: 2.98)
        #expect(!policy.canApplyContext(at: 2.98))
        policy.didSend(tone(0, seconds: 0.02), at: 3)
        #expect(policy.canApplyContext(at: 3))
        policy.didSend(tone(4_000, seconds: 0.02), at: 3.02)
        #expect(!policy.canApplyContext(at: 3.02))
    }

    @Test func anUnanalysedOnsetOrMalformedPCMDoesNotAuthorizeACut() {
        var policy = LiveTranscriptionBoundaryPolicy()
        policy.didSend(tone(0, seconds: 3), at: 3)
        #expect(policy.canApplyContext(at: 3))
        policy.didSend(Data([255, 127]), at: 3.001)
        #expect(!policy.canApplyContext(at: 3.001))
        policy.didSend(tone(0, seconds: 0.02), at: 3.021)
        #expect(!policy.canApplyContext(at: 3.021))
        policy.didSend(Data([0]), at: 4)
        policy.didSend(tone(0, seconds: 5), at: 9)
        #expect(!policy.canApplyContext(at: 9))
    }

    @Test func boundariesAreRateAndCountBoundedWithoutDroppingAudio() {
        var policy = LiveTranscriptionBoundaryPolicy()
        policy.didSend(tone(0, seconds: 3), at: 3)
        for index in 0..<10 {
            let time = 3 + Double(index * 10)
            if index > 0 { policy.didSend(tone(0, seconds: 1), at: time) }
            #expect(policy.canApplyContext(at: time))
            policy.didApplyContext(at: time)
            #expect(!policy.canApplyContext(at: time + 9.9))
        }
        #expect(!policy.canApplyContext(at: 1_000))
    }

    @Test func aNewTurnCannotReuseThePreviousTurnsQuietEvidence() {
        var policy = LiveTranscriptionBoundaryPolicy()
        policy.didSend(tone(0, seconds: 3), at: 3)
        policy.didApplyContext(at: 3)
        policy.didSend(tone(0, seconds: 0.02), at: 14)
        #expect(!policy.canApplyContext(at: 14))
        policy.didSend(tone(0, seconds: 0.98), at: 15)
        #expect(policy.canApplyContext(at: 15))
    }

    @Test func appliedHintsSurviveExpiryAndStartupSeedingDoesNotOverwriteNewerOffers() {
        let base = TranscriptionRequestContext(language: "en", prompt: "topic", vocabulary: [])
        let newer = base.withLiveReference("newer")
        let buffer = LiveTranscriptionContextBuffer()
        buffer.offer(newer, at: 0)
        buffer.markApplied(base)
        #expect(buffer.take(at: 1) == newer)
        // Revert while a different update is in flight must survive its ack.
        buffer.offer(base, at: 2)
        buffer.markApplied(newer)
        #expect(buffer.take(at: 3) == base)
        buffer.markApplied(base)
        #expect(buffer.take(maximumAge: 120, at: 1_000) == nil)
        buffer.offer(base, at: 1_001)
        #expect(buffer.take(at: 1_001) == nil)
        buffer.offer(newer, at: 1_002)
        #expect(buffer.take(maximumAge: 120, at: 1_123) == nil)
        buffer.offer(newer, at: 1_124)
        #expect(buffer.take(at: 1_124) == newer)
    }

    @Test func possibleAudioEvidenceIncludesAShortUnfinishedOnset() {
        var observer = RealtimeSilenceSleepGate(configuration: .gptLiveDefault, startedAt: 0)
        _ = observer.process(tone(0, seconds: 1), at: 0)
        #expect(!observer.hasPossibleActivity)
        _ = observer.process(tone(4_000, seconds: 0.01), at: 0)
        #expect(observer.hasPossibleActivity)
    }

    @Test func staleOrStoppedHintsNeverMakeAnotherTurn() {
        let context = TranscriptionRequestContext(language: "en", prompt: "topic", vocabulary: [])
        let stale = LiveTranscriptionContextBuffer()
        stale.offer(context, at: 0)
        #expect(stale.take(maximumAge: LiveTranscriptionBoundaryPolicy.maximumHintAge, at: 121) == nil)
        stale.offer(context, at: 122)
        #expect(stale.take(maximumAge: 120, at: 122) == context)
        let stopped = LiveTranscriptionContextBuffer()
        stopped.offer(context, at: 0)
        stopped.finish(discard: true)
        #expect(stopped.take() == nil)
    }
}
