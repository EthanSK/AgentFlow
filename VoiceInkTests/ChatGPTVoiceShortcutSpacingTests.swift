import Foundation
import Testing
@testable import VoiceInkPlusPlus

// Virtual time and fake transports exercise ordering without a real Voice call. — GPT-6.1 Sol
private final class ShortcutTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

private actor ShortcutTestGap {
    private let clock: ShortcutTestClock
    private var waits: [TimeInterval] = []
    private var heldNumbers: Set<Int> = []
    private var pending: (seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)?
    init(clock: ShortcutTestClock) { self.clock = clock }
    func hold(_ number: Int) { heldNumbers.insert(number) }
    func count() -> Int { waits.count }
    func isWaiting() -> Bool { pending != nil }
    func durations() -> [TimeInterval] { waits }
    func wait(_ seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            waits.append(seconds)
            if heldNumbers.remove(waits.count) != nil {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { pending = (seconds, continuation) }
                }
            } else {
                clock.advance(seconds)
            }
        }, onCancel: { Task { await self.cancel() } })
    }
    func release() {
        guard let pending else { return }
        self.pending = nil
        clock.advance(pending.seconds)
        pending.continuation.resume()
    }
    private func cancel() {
        pending?.continuation.resume(throwing: CancellationError())
        pending = nil
    }
}

private actor ShortcutTestTransport: ChatGPTVoiceMuteTransport, ChatGPTVoiceSpeakerTransport {
    struct Post: Equatable, Sendable { let command: String; let at: TimeInterval }
    private let clock: ShortcutTestClock
    private var call: ChatGPTVoiceCall?
    private var inputRunning = true
    private var posts: [Post] = []
    private var nextSpeakerIsStart = true
    private var allowsMicrophone = true
    private var microphoneMuted = false
    private var controlsReadable = true
    init(clock: ShortcutTestClock) {
        self.clock = clock
        call = .init(applicationPID: 42, sessionID: UUID())
    }
    func snapshot() -> ChatGPTVoiceInputSnapshot? {
        .init(applicationPID: 42, isInputRunning: inputRunning,
              microphoneState: controlsReadable ? (microphoneMuted ? .muted : .listening) : nil,
              call: inputRunning ? call : nil)
    }
    func postMicrophoneToggle(from before: ChatGPTVoiceInputSnapshot,
                              toward target: ChatGPTVoiceMicrophoneState,
                              using authority: ChatGPTVoiceShortcutAuthority) -> Date? {
        guard allowsMicrophone, inputRunning, before.call == call, call != nil,
              controlsReadable, microphoneMuted != (target == .muted) else { return nil }
        posts.append(.init(command: target == .muted ? "mic mute" : "mic restore", at: clock.now()))
        microphoneMuted = target == .muted
        return Date()
    }
    func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) -> ChatGPTVoiceMicrophoneState? {
        return self.call == call ? (microphoneMuted ? .muted : .listening) : nil
    }
    func activeSpeakerCall() -> ChatGPTVoiceCall? { inputRunning ? call : nil }
    func postSpeakerToggle(for call: ChatGPTVoiceCall, fromMuted: Bool) -> Date? {
        guard inputRunning, self.call == call, controlsReadable, fromMuted == !nextSpeakerIsStart else { return nil }
        posts.append(.init(command: nextSpeakerIsStart ? "speaker mute" : "speaker restore", at: clock.now()))
        nextSpeakerIsStart.toggle()
        return Date()
    }
    func recorded() -> [Post] { posts }
    func replaceCall() { call = .init(applicationPID: 42, sessionID: UUID()) }
    func endCall() { inputRunning = false; call = nil }
    func refuseMicrophone() { allowsMicrophone = false }
    func setStates(microphone: Bool, speaker: Bool, readable: Bool = true) {
        microphoneMuted = microphone; nextSpeakerIsStart = !speaker; controlsReadable = readable
    }
    func states() -> [Bool] { [microphoneMuted, !nextSpeakerIsStart] }
}

private struct ShortcutTestHarness {
    let clock: ShortcutTestClock
    let gap: ShortcutTestGap
    let transport: ShortcutTestTransport
    let coordinator: ChatGPTVoiceCaptureMuteCoordinator
    init(speakerEnabled: Bool = true) {
        let clock = ShortcutTestClock()
        let gap = ShortcutTestGap(clock: clock)
        let transport = ShortcutTestTransport(clock: clock)
        self.clock = clock
        self.gap = gap
        self.transport = transport
        coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport,
            speaker: .init(transport: transport, automaticControlEnabled: speakerEnabled),
            shortcutUptime: { clock.now() }, waitForShortcutGap: { try await gap.wait($0) })
    }
}

private func eventually(_ predicate: () async -> Bool) async -> Bool {
    // A yield count exhausted in 22ms under the hosted full suite. Give the
    // required actor work a real deadline and suspend between observations;
    // success stays immediate and virtual shortcut timing is unchanged. — GPT-6.1 Sol
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if await predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch { return false }
    }
    return await predicate()
}

struct ChatGPTVoiceShortcutSpacingTests {
    @Test func eachPreMutedControlRemainsExactlyAsItStarted() async {
        for microphone in [false, true] {
            for speaker in [false, true] {
                let h = ShortcutTestHarness()
                await h.transport.setStates(microphone: microphone, speaker: speaker)
                let lease = await h.coordinator.prepareForCapture()
                #expect(await h.transport.states() == [true, true])
                await h.coordinator.releaseCapture(lease)
                await h.coordinator.waitForPendingTransitionsForTesting()
                #expect(await h.transport.states() == [microphone, speaker])
                let posts = await h.transport.recorded().map(\.command)
                #expect(posts.filter { $0.hasPrefix("mic") }.count == (microphone ? 0 : 2))
                #expect(posts.filter { $0.hasPrefix("speaker") }.count == (speaker ? 0 : 2))
            }
        }
    }

    @Test func unreadablePanelNeverPostsEitherControl() async {
        let h = ShortcutTestHarness()
        await h.transport.setStates(microphone: false, speaker: true, readable: false)
        let lease = await h.coordinator.prepareForCapture()
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().isEmpty)
        #expect(await h.transport.states() == [false, true])
        #expect(await h.gap.count() == 0)
    }

    @Test func newerExternalUnmutePreventsBothInverseToggles() async {
        let h = ShortcutTestHarness()
        let lease = await h.coordinator.prepareForCapture()
        await h.transport.setStates(microphone: false, speaker: false)
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute"])
        #expect(await h.transport.states() == [false, false])
    }

    @Test func readableBoundariesPostOnceWithThreeHundredMilliseconds() async throws {
        let h = ShortcutTestHarness()
        let lease = await h.coordinator.prepareForCapture()
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        let posts = await h.transport.recorded()
        #expect(posts.map(\.command) == ["speaker mute", "mic mute", "speaker restore", "mic restore"])
        let startGap = try #require(posts.count == 4 ? posts[1].at - posts[0].at : nil)
        let stopGap = posts[3].at - posts[2].at
        #expect(abs(startGap - 0.3) < 0.000_001)
        #expect(abs(stopGap - 0.3) < 0.000_001)
        #expect(await h.gap.count() == 2)
    }

    @Test func disabledSpeakerAddsNoGapToExistingMicrophonePair() async {
        let h = ShortcutTestHarness(speakerEnabled: false)
        let lease = await h.coordinator.prepareForCapture()
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["mic mute", "mic restore"])
        #expect(await h.gap.count() == 0)
    }

    @Test func failedMicrophonePostDoesNotInventInverseOrRetry() async {
        let h = ShortcutTestHarness()
        await h.transport.refuseMicrophone()
        let lease = await h.coordinator.prepareForCapture()
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "speaker restore"])
    }

    @Test func cancelledStartSkipsDelayedMicrophoneAndBalancesSpeakerOnce() async throws {
        let h = ShortcutTestHarness()
        await h.gap.hold(1)
        let start = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.gap.isWaiting() })
        start.cancel()
        let lease = await start.value
        // Explicit recorder cleanup and the cancellation cleanup may both arrive.
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "speaker restore"])
        #expect(await h.coordinator.stateForTesting().ownedMutedApplicationPID == nil)
    }

    @Test func callReplacementDuringStartGapNeverTogglesReplacement() async throws {
        let h = ShortcutTestHarness()
        await h.gap.hold(1)
        let start = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.gap.isWaiting() })
        await h.transport.replaceCall()
        await h.gap.release()
        let lease = await start.value
        await h.coordinator.releaseCapture(lease)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute"])
    }

    @Test func callEndingDuringStopGapSkipsDelayedInverse() async throws {
        let h = ShortcutTestHarness()
        let lease = await h.coordinator.prepareForCapture()
        await h.gap.hold(2)
        await h.coordinator.releaseCapture(lease)
        try #require(await eventually { await h.gap.isWaiting() })
        await h.transport.endCall()
        await h.gap.release()
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore"])
    }

    @Test func supersedingStartDuringGapPostsOnlyOneMicrophoneMute() async throws {
        let h = ShortcutTestHarness()
        await h.gap.hold(1)
        let firstStart = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.gap.isWaiting() })
        let secondStart = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.coordinator.hasQueuedLocalCaptureForTesting() })
        await h.gap.release()
        let first = await firstStart.value
        let second = await secondStart.value
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute"])
        await h.coordinator.releaseCapture(first)
        await h.coordinator.releaseCapture(second)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore", "mic restore"])
    }

    @Test func replacementDuringStopGapCannotReceiveOldCallsInverse() async throws {
        let h = ShortcutTestHarness()
        let lease = await h.coordinator.prepareForCapture()
        await h.gap.hold(2)
        await h.coordinator.releaseCapture(lease)
        try #require(await eventually { await h.gap.isWaiting() })
        await h.transport.replaceCall()
        await h.gap.release()
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore"])
        #expect(await h.coordinator.stateForTesting().ownedMutedApplicationPID == nil)
    }

    @Test func cancelledReplacementBeforeApplyingBalancesInheritedSpeaker() async throws {
        let h = ShortcutTestHarness()
        await h.gap.hold(1)
        let firstStart = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.gap.isWaiting() })
        let replacement = Task { await h.coordinator.prepareForCapture() }
        try #require(await eventually { await h.coordinator.hasQueuedLocalCaptureForTesting() })
        replacement.cancel()
        try #require(await eventually { !(await h.coordinator.hasQueuedLocalCaptureForTesting()) })
        await h.gap.release()
        let first = await firstStart.value
        let second = await replacement.value
        await h.coordinator.releaseCapture(first)
        await h.coordinator.releaseCapture(second)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "speaker restore"])
        #expect(!(await h.coordinator.stateForTesting().captureActive))
    }

    @Test func newLocalCaptureDuringStopGapInheritsMicrophoneWithoutExtraToggle() async throws {
        let h = ShortcutTestHarness()
        let first = await h.coordinator.prepareForCapture()
        await h.gap.hold(2)
        await h.coordinator.releaseCapture(first)
        try #require(await eventually { await h.gap.isWaiting() })
        let secondStart = Task { await h.coordinator.prepareForCapture() }
        // A snapshot-free actor barrier proves the new intent was accepted before release.
        try #require(await eventually { await h.coordinator.hasQueuedLocalCaptureForTesting() })
        await h.gap.release()
        let second = await secondStart.value
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore", "speaker mute"])
        await h.coordinator.releaseCapture(first)
        await h.coordinator.releaseCapture(second)
        await h.coordinator.waitForPendingTransitionsForTesting()
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore", "speaker mute", "speaker restore", "mic restore"])
    }

    @Test func pendingPairedAcquireDuringStopGapHoldsMicrophoneUntilFinalOwnerEnds() async throws {
        let h = ShortcutTestHarness()
        let local = await h.coordinator.prepareForCapture()
        await h.gap.hold(2)
        await h.coordinator.releaseCapture(local)
        try #require(await eventually { await h.gap.isWaiting() })
        let source = "11111111-1111-4111-8111-111111111111"
        let session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
        let acquire = Task { await h.coordinator.handlePairedRequest(.init(
            operation: .acquire, source: source, sequence: 1, session: session)) }
        try #require(await eventually { await h.coordinator.pendingPairedOwnerCountForTesting() == 1 })
        await h.gap.release()
        _ = await acquire.value
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore"])
        _ = await h.coordinator.handlePairedRequest(.init(
            operation: .release, source: source, sequence: 2, session: session))
        #expect(await h.transport.recorded().map(\.command) == ["speaker mute", "mic mute", "speaker restore", "mic restore"])
    }
}

struct ChatGPTVoiceMicrophoneStateReadingTests {
    @Test func boundedReaderDefaultsOnAndPreservesExplicitOptOut() throws {
        let name = "VoiceMicrophoneReaderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ChatGPTVoiceMicrophoneStateReading.isEnabled(in: defaults))
        #expect(!ChatGPTVoiceMicrophoneStateReading.automaticExposureEnabled)
        defaults.set(true, forKey: ChatGPTVoiceMicrophoneStateReading.preferenceKey)
        #expect(ChatGPTVoiceMicrophoneStateReading.isEnabled(in: defaults))
        defaults.set(false, forKey: ChatGPTVoiceMicrophoneStateReading.preferenceKey)
        #expect(!ChatGPTVoiceMicrophoneStateReading.isEnabled(in: defaults))
    }

    @Test func disabledProductionReaderReturnsBeforeAnyUIReadOrReadbackWait() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let transport = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift"), encoding: .utf8)
        let preparation = try String(contentsOf: root.appendingPathComponent(
            "VoiceInk/Services/ChatGPTVoiceAccessibilityPreparation.swift"), encoding: .utf8)
        #expect(transport.contains("static func microphoneState(applicationPID: pid_t) -> ChatGPTVoiceMicrophoneState? {\n        guard ChatGPTVoiceMicrophoneStateReading.isEnabled() else { return nil }"))
        #expect(transport.contains("func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) async -> ChatGPTVoiceMicrophoneState? {\n        guard ChatGPTVoiceMicrophoneStateReading.isEnabled() else { return nil }"))
        let start = try #require(preparation.range(of: "func startForApplication()"))
        let observer = try #require(preparation.range(of: "NSWorkspace.shared.notificationCenter"))
        let prefix = preparation[start.lowerBound..<observer.lowerBound]
        #expect(prefix.contains("guard ChatGPTVoiceMicrophoneStateReading.isEnabled() else"))
        #expect(prefix.contains("guard ChatGPTVoiceMicrophoneStateReading.automaticExposureEnabled else"))
        #expect(transport.contains("accessibilityLabel: String"))
    }
}
