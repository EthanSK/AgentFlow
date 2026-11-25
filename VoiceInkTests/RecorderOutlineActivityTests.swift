// Exercises Ethan's shared typing/recognised-speech "charge" with synthetic text
// and controlled dates. No microphone, shortcuts, media or delivery. — GPT-6.1 Sol
import Foundation
import Testing
@testable import VoiceInkPlusPlus

struct RecorderOutlineActivityTests {
    private let start = Date(timeIntervalSinceReferenceDate: 12_345)

    @Test func idleIsSlowAndSustainedFasterInputBuildsMoreSpeedWithoutACap() {
        var fast = RecorderOutlineActivity(at: start)
        var slow = fast
        #expect(fast.speed(at: start) == RecorderOutlineActivity.idleSpeed)
        for index in 0..<1_000 {
            fast.addText(units: 1, at: start.addingTimeInterval(Double(index) / 10))
            slow.addText(units: 1, at: start.addingTimeInterval(Double(index) * 2))
        }
        // The gentler gain and speed easing put this near791x, versus the
        // original940x target. Keep a strong long-chain assertion. — GPT-6.1 Sol
        #expect(fast.speed(at: start.addingTimeInterval(99.9)) > 780)
        #expect(slow.speed(at: start.addingTimeInterval(1_998)) < 1)
    }

    @Test func aPauseEasesToIdleAndTheNextBurstStartsWithoutAPhaseJump() {
        var activity = RecorderOutlineActivity(at: start)
        activity.addText(units: 20, at: start)
        #expect(activity.speed(at: start) == RecorderOutlineActivity.idleSpeed)
        let charged = activity.speed(at: start.addingTimeInterval(0.8))
        #expect(activity.speed(at: start.addingTimeInterval(0.5)) < charged)
        #expect(activity.speed(at: start.addingTimeInterval(2)) < charged)
        #expect(abs(activity.speed(at: start.addingTimeInterval(20)) - RecorderOutlineActivity.idleSpeed) < 0.000_001)
        let next = start.addingTimeInterval(2)
        let phase = activity.phase(at: next)
        activity.addText(units: 3, at: next)
        #expect(activity.phase(at: next) == phase)
        #expect(activity.phase(at: next.addingTimeInterval(86_400)).isFinite)
    }

    @Test func phaseDerivativeMatchesSpeedThroughTheDecayAndFramesDoNotMutateIt() {
        var activity = RecorderOutlineActivity(at: start)
        activity.addText(units: 24, at: start)
        let copy = activity
        for elapsed in [0.1, 0.7, 0.9, 1.5, 4, 20] {
            let date = start.addingTimeInterval(elapsed)
            let delta = RecorderCaptureOutlineTrace.wrapped(
                activity.phase(at: date.addingTimeInterval(0.0001)) - activity.phase(at: date))
            #expect(abs(delta * RecorderCaptureOutlineStyle.lapDuration / 0.0001 - activity.speed(at: date)) < 0.001)
        }
        #expect(activity == copy)
    }

    @Test func aLargePasteIsOneBoundedBurstButSuccessiveBurstsKeepAdding() {
        var paste = RecorderOutlineActivity(at: start)
        var burst = paste
        paste.addText(units: 1_000_000, at: start)
        burst.addText(units: 32, at: start)
        #expect(paste == burst)
        let before = paste.speed(at: start.addingTimeInterval(0.5))
        paste.addText(units: 32, at: start)
        #expect(paste.speed(at: start) == RecorderOutlineActivity.idleSpeed)
        #expect(paste.speed(at: start.addingTimeInterval(0.5)) > before)
        let original = paste
        paste.addText(units: 0, at: start)
        #expect(paste == original)
    }

    @Test @MainActor func typingAndRecognisedSpeechShareMomentumWhileDuplicatesAndRevisionsDoNotCharge() throws {
        let typed = RecordingSession()
        typed.microphoneOff = true
        let voice = RecordingSession()
        let date = Date().addingTimeInterval(1)
        let probe = date.addingTimeInterval(0.5)
        typed.updateTypedInput("hello", at: date)
        voice.recordSpeechActivity("hello", at: date)
        voice.partialTranscript = "hello"
        let provider: any RecorderStateProvider = voice
        #expect(try #require(typed.outlineActivity).speed(at: probe) > RecorderOutlineActivity.idleSpeed)
        #expect(try #require(typed.outlineActivity).speed(at: probe)
            == #require(provider.outlineActivity).speed(at: probe))
        let previous = voice.outlineActivity
        voice.recordSpeechActivity("hello", at: date)
        voice.recordSpeechActivity("hi", at: date)
        voice.partialTranscript = "hi"
        voice.recordSpeechActivity("hello", at: date)
        #expect(voice.outlineActivity == previous)
        voice.partialTranscript = "hello"
        voice.recordSpeechActivity("hello there", at: date)
        typed.updateTypedInput("hello there", at: date)
        #expect(try #require(typed.outlineActivity).speed(at: probe)
            == #require(voice.outlineActivity).speed(at: probe))
        voice.flushSpeechTiming()
    }

    @Test func textBurstsEaseInWithoutResettingColourOrVisibleSpeed() {
        var activity = RecorderOutlineActivity(at: start)
        activity.addText(units: 32, at: start)
        #expect(activity.speed(at: start) == RecorderOutlineActivity.idleSpeed)
        #expect(activity.speed(at: start.addingTimeInterval(0.05))
            < activity.speed(at: start.addingTimeInterval(0.2)))
        let next = start.addingTimeInterval(0.2)
        let speed = activity.speed(at: next)
        let phase = activity.phase(at: next)
        activity.addText(units: 32, at: next)
        #expect(activity.phase(at: next) == phase)
        #expect(activity.speed(at: next) == speed)
        #expect(activity.speed(at: next.addingTimeInterval(0.2)) > speed)
        #expect(abs(activity.speed(at: next.addingTimeInterval(0.8001))
            - activity.speed(at: next.addingTimeInterval(0.7999))) < 0.002)
    }

    @Test func enteringLoadingKeepsAccumulatedInputSpeedInsteadOfResettingIt() {
        var activity = RecorderOutlineActivity(at: start)
        for index in 0..<30 {
            activity.addText(units: 10, at: start.addingTimeInterval(Double(index) / 10))
        }
        let boundary = start.addingTimeInterval(3)
        let speed = activity.speed(at: boundary)
        #expect(speed > RecorderCaptureOutlineStyle.initialProcessingSpeed)
        let interval = 0.0001
        let initial = RecorderCaptureOutlineStyle.flowPhase(at: boundary, isProcessing: true,
            processingStartedAt: boundary, activity: activity)
        let next = RecorderCaptureOutlineStyle.flowPhase(at: boundary.addingTimeInterval(interval),
            isProcessing: true, processingStartedAt: boundary, activity: activity)
        let rate = -RecorderCaptureOutlineTrace.wrapped(next - initial)
            * RecorderCaptureOutlineStyle.lapDuration / interval
        #expect(abs(rate - speed) < 0.002)
    }

    @Test @MainActor func internalClearsSilenceAndBlockedEditsDoNotChargeOrChangeDelivery() throws {
        let session = RecordingSession()
        let date = Date().addingTimeInterval(1)
        let initial = session.outlineActivity
        session.recordSpeechActivity(" \n", at: date)
        session.partialTranscript = ""
        #expect(session.outlineActivity == initial)
        session.updateTypedInput("hello", at: date)
        let charged = session.outlineActivity
        session.updateTypedInput("hello", at: date)
        session.endTypingRun()
        #expect(session.outlineActivity == charged)
        session.phase = .transcribing
        session.updateTypedInput("blocked", at: date)
        session.recordSpeechActivity("blocked", at: date)
        #expect(session.outlineActivity == charged)
        #expect(session.completionDisposition == .normalDelivery)
        #expect(session.autoSendDisposition == .configured)
        #expect(session.outlineProcessingStartedAt == nil)
    }

    @Test @MainActor func tailKeepsTheLivePhaseAndLoadingReversesFromItsExactColour() throws {
        let session = RecordingSession()
        let date = Date().addingTimeInterval(1)
        session.updateTypedInput("chain", at: date)
        let activity = try #require(session.outlineActivity)
        session.acknowledgeCaptureFinish()
        #expect(session.outlineActivity == activity && session.outlineProcessingStartedAt == nil)
        #expect(session.recordingState == .recording && !session.microphoneOff)
        let style = RecorderCaptureOutlineStyle.self
        #expect(style.flowPhase(at: date, activity: activity)
            == style.flowPhase(at: date, isProcessing: true, processingStartedAt: date, activity: activity))
        let later = date.addingTimeInterval(0.1)
        #expect(RecorderCaptureOutlineTrace.wrapped(style.flowPhase(at: later, isProcessing: true,
            processingStartedAt: date, activity: activity) - activity.phase(at: date)) < 0)
        session.liveRecordingState = .paused
        #expect(try #require(session.outlineActivity).speed(at: Date()) == RecorderOutlineActivity.idleSpeed)
        #expect(!session.showsRecordingActivityOutline)
    }
}
