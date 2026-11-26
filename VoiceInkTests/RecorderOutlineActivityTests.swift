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
        let charged = activity.speed(at: start.addingTimeInterval(0.2))
        #expect(activity.speed(at: start.addingTimeInterval(0.1)) < charged)
        #expect(activity.speed(at: start.addingTimeInterval(0.5)) < charged)
        #expect(activity.speed(at: start.addingTimeInterval(2)) < charged)
        #expect(abs(activity.speed(at: start.addingTimeInterval(20)) - RecorderOutlineActivity.idleSpeed) < 0.000_001)
        let next = start.addingTimeInterval(2)
        let phase = activity.phase(at: next)
        activity.addText(units: 3, at: next)
        #expect(activity.phase(at: next) == phase)
        #expect(activity.phase(at: next.addingTimeInterval(86_400)).isFinite)
    }

    @Test func shortGapsCoastAndResumedTypingKeepsItsSpeedPhaseAndCharge() {
        var activity = RecorderOutlineActivity(at: start)
        for index in 0..<20 {
            activity.addText(units: 4, at: start.addingTimeInterval(Double(index) / 10))
        }
        let lastKey = start.addingTimeInterval(1.9)
        let brake = lastKey.addingTimeInterval(0.2)
        #expect(activity.speed(at: brake) > activity.speed(at: lastKey.addingTimeInterval(0.1)))
        let initial = activity.speed(at: brake) - RecorderOutlineActivity.idleSpeed
        let quiet = lastKey.addingTimeInterval(0.5)
        let remaining = activity.speed(at: quiet) - RecorderOutlineActivity.idleSpeed
        #expect(remaining > initial * 0.50 && remaining < initial * 0.57)
        #expect(activity.speed(at: quiet) > RecorderOutlineActivity.idleSpeed)
        let speed = activity.speed(at: quiet)
        let phase = activity.phase(at: quiet)
        activity.addText(units: 1, at: quiet)
        #expect(activity.speed(at: quiet) == speed)
        #expect(activity.phase(at: quiet) == phase)
        #expect(activity.speed(at: quiet.addingTimeInterval(0.1)) > speed)
        var fresh = RecorderOutlineActivity(at: quiet)
        fresh.addText(units: 1, at: quiet)
        #expect(activity.speed(at: quiet.addingTimeInterval(0.1))
            > fresh.speed(at: quiet.addingTimeInterval(0.1)))
    }

    @Test func slowerContinuousTypingStillBuildsAnUncappedChainWhileItCoastsBetweenKeys() {
        var activity = RecorderOutlineActivity(at: start)
        for index in 0..<1_000 {
            activity.addText(units: 1, at: start.addingTimeInterval(Double(index) / 3))
        }
        // Three characters per second is a continuous chain under the existing
        // 800 ms allowance, even though 200 ms visual braking starts between its keys.
        // A shared 200 ms charge deadline would plateau below 1x here.
        // Found and fixed by GPT-6.1 Sol.
        #expect(activity.speed(at: start.addingTimeInterval(999.0 / 3)) > 250)
    }

    @Test func brakingBeginsQuicklyAndNearlyMatchesBuildUpWithoutPhaseJumps() {
        var activity = RecorderOutlineActivity(at: start)
        activity.addText(units: 32, at: start)
        let brake = start.addingTimeInterval(0.2)
        let before = activity.speed(at: brake.addingTimeInterval(-0.000_001))
        let at = activity.speed(at: brake)
        let after = activity.speed(at: brake.addingTimeInterval(0.000_001))
        #expect(abs(at - before) < 0.0001 && abs(after - at) < 0.0001)
        #expect(activity.speed(at: brake.addingTimeInterval(0.01)) < at)
        let momentum = at - RecorderOutlineActivity.idleSpeed
        let firstRise = activity.speed(at: start.addingTimeInterval(0.1)) - RecorderOutlineActivity.idleSpeed
        let riseRetention = (momentum - firstRise) / firstRise
        let fallRetention = (activity.speed(at: brake.addingTimeInterval(0.1))
            - RecorderOutlineActivity.idleSpeed) / momentum
        // Compare the actual visible easing rates; don't merely repeat the two
        // implementation constants. Ethan wants them nearly matched. — GPT-6.1 Sol
        let relativeBrakingRate = log(fallRetention) / log(riseRetention)
        #expect(relativeBrakingRate > 1 && relativeBrakingRate < 1.1)
        let halfSecond = activity.speed(at: brake.addingTimeInterval(0.5)) - RecorderOutlineActivity.idleSpeed
        #expect(halfSecond / momentum > 0.33 && halfSecond / momentum < 0.37)
        let oneSecond = activity.speed(at: brake.addingTimeInterval(1)) - RecorderOutlineActivity.idleSpeed
        #expect(oneSecond > momentum * 0.10 && oneSecond < momentum * 0.15)
        let twoSeconds = activity.speed(at: brake.addingTimeInterval(2)) - RecorderOutlineActivity.idleSpeed
        #expect(twoSeconds > momentum * 0.014 && twoSeconds < momentum * 0.016)
        let phaseBefore = activity.phase(at: brake.addingTimeInterval(-0.000_001))
        let phaseAfter = activity.phase(at: brake.addingTimeInterval(0.000_001))
        #expect(abs(RecorderCaptureOutlineTrace.wrapped(phaseAfter - phaseBefore)) < 0.0001)
    }

    @Test func resumingALongChargedCoastNeverMakesNewTypingSlowItDown() {
        var activity = RecorderOutlineActivity(at: start)
        for index in 0..<2_000 {
            activity.addText(units: 1, at: start.addingTimeInterval(Double(index) / 10))
        }
        let resume = start.addingTimeInterval(199.9 + 3)
        let speed = activity.speed(at: resume)
        let phase = activity.phase(at: resume)
        #expect(speed > RecorderOutlineActivity.idleSpeed)
        activity.addText(units: 1, at: resume)
        #expect(activity.speed(at: resume) == speed)
        #expect(activity.phase(at: resume) == phase)
        #expect(activity.speed(at: resume.addingTimeInterval(0.1)) > speed)
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

    @Test @MainActor func recognisedSpeechAndTypingCoastAndResumeThroughTheSameMotion() throws {
        let typed = RecordingSession()
        typed.microphoneOff = true
        let voice = RecordingSession()
        defer { voice.flushSpeechTiming() }
        let start = Date().addingTimeInterval(1)
        var text = ""
        for index in 0..<20 {
            text += "word "
            let date = start.addingTimeInterval(Double(index) / 10)
            typed.updateTypedInput(text, at: date)
            voice.recordSpeechActivity(text, at: date)
            voice.partialTranscript = text
        }
        let last = start.addingTimeInterval(1.9)
        let typedActivity = try #require(typed.outlineActivity)
        let speechActivity = try #require(voice.outlineActivity)
        let peak = speechActivity.speed(at: last.addingTimeInterval(0.2))
        for quiet in [0.0, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 20.0] {
            let date = last.addingTimeInterval(quiet)
            #expect(typedActivity.speed(at: date) == speechActivity.speed(at: date))
            #expect(abs(RecorderCaptureOutlineTrace.wrapped(
                typedActivity.phase(at: date) - speechActivity.phase(at: date))) < 1e-6)
        }
        let resume = last.addingTimeInterval(0.5)
        let before = speechActivity.speed(at: resume)
        #expect(before > RecorderOutlineActivity.idleSpeed && before < peak)
        text += "resumed"
        typed.updateTypedInput(text, at: resume)
        voice.recordSpeechActivity(text, at: resume)
        voice.partialTranscript = text
        let resumedTyping = try #require(typed.outlineActivity)
        let resumedSpeech = try #require(voice.outlineActivity)
        #expect(resumedSpeech.speed(at: resume) == before)
        #expect(resumedSpeech.speed(at: resume.addingTimeInterval(0.1)) > before)
        #expect(resumedTyping.speed(at: resume.addingTimeInterval(0.1))
            == resumedSpeech.speed(at: resume.addingTimeInterval(0.1)))
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
