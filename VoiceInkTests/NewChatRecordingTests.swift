import Testing
import Foundation
@testable import VoiceInkPlusPlus

@MainActor
private final class NewChatRecordingTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite(.serialized)
@MainActor
struct NewChatRecordingTests {
    @MainActor
    private final class Fixture {
        var time: TimeInterval = 100
        var target: NewChatRecordingHarness? = .codex
        var state: NewChatRecordingCapture = .idle
        var allowed = true
        var launched: [(UUID, NewChatRecordingHarness)] = []
        var canceled: [UUID] = []
        var statuses: [NewChatRecordingStatus] = []
        var completions: [UUID: (Bool) -> Void] = [:]
        var starts = 0
        var startSucceeds = true
        var startGate: NewChatRecordingTestGate?
        let startEntered = NewChatRecordingTestGate()
        var timeout: UInt64 = 10_000_000_000
        lazy var coordinator = NewChatRecordingCoordinator(
            selectedHarness: { [unowned self] in target },
            capture: { [unowned self] in state },
            inputAllowed: { [unowned self] in allowed },
            launch: { [unowned self] id, target, completion in
                launched.append((id, target)); completions[id] = completion
            },
            cancelLaunch: { [unowned self] in canceled.append($0) },
            start: { [unowned self] isCurrent, didReserve in
                starts += 1
                guard isCurrent(), startSucceeds else { startEntered.open(); return false }
                let startID = UUID()
                state = .voice(startID)
                didReserve(startID)
                startEntered.open()
                await startGate?.wait()
                return isCurrent()
            },
            publish: { [unowned self] in statuses.append($0) },
            now: { [unowned self] in time },
            timeoutNanoseconds: timeout
        )
        func request(_ id: UUID = UUID()) -> NewChatRecordingRequest { .init(id: id, sentAt: time) }
        func finish(_ id: UUID, success: Bool = true) { completions[id]?(success) }
    }

    @Test func wireRequestRejectsMalformedExpandedAndBooleanFields() {
        let id = UUID()
        let fields: [AnyHashable: Any] = ["version": 1, "action": "start", "sentAt": 100.0]
        #expect(NewChatRecordingRequest.decode(object: id.uuidString, userInfo: fields) == .init(id: id, sentAt: 100))
        for (key, value) in [("version", true as Any), ("version", 2), ("action", "toggle"), ("sentAt", true), ("sentAt", Double.infinity)] {
            var bad = fields; bad[key] = value
            #expect(NewChatRecordingRequest.decode(object: id.uuidString, userInfo: bad) == nil)
        }
        var expanded = fields; expanded["target"] = "codex"
        #expect(NewChatRecordingRequest.decode(object: id.uuidString, userInfo: expanded) == nil)
        #expect(NewChatRecordingRequest.decode(object: "bad", userInfo: fields) == nil)
        #expect(NewChatRecordingRequest.decode(object: id.uuidString, userInfo: nil) == nil)
    }

    @Test func oneCanonicalPreferenceDefaultsToCodexAndRejectsUnknownExplicitTarget() {
        let name = "NewChatRecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(NewChatRecordingHarness.selected(in: defaults) == .codex)
        for target in NewChatRecordingHarness.allCases {
            defaults.set(target.rawValue, forKey: NewChatRecordingHarness.preferenceKey)
            #expect(NewChatRecordingHarness.selected(in: defaults) == target)
        }
        defaults.set("claudeDesktop", forKey: NewChatRecordingHarness.preferenceKey)
        #expect(NewChatRecordingHarness.selected(in: defaults) == nil)
        #expect(defaults.string(forKey: NewChatRecordingHarness.preferenceKey) == "claudeDesktop")
    }

    @Test func existingVoiceStartIsAdoptedAndRetriesCreateOnlyOneChat() {
        let f = Fixture(); let captureID = UUID(); f.state = .voice(captureID)
        let request = f.request()
        f.coordinator.receive(request); f.coordinator.receive(request)
        #expect(f.launched.count == 1)
        f.finish(request.id)
        f.coordinator.receive(request); f.finish(request.id)
        #expect(f.launched.count == 1)
        #expect(f.starts == 0)
        #expect(f.state == .voice(captureID))
        #expect(f.statuses.last?.phase == .ready)
        f.coordinator.cancel()
    }

    @Test func idleRequestWaitsForReadyThenReservesOneStartDespiteDuplicateAck() async {
        let f = Fixture(); let gate = NewChatRecordingTestGate(); f.startGate = gate
        let request = f.request(); f.coordinator.receive(request)
        #expect(f.starts == 0)
        f.finish(request.id)
        await f.startEntered.wait()
        f.finish(request.id); f.coordinator.receive(request)
        #expect(f.starts == 1)
        #expect(f.statuses.last?.phase == .creating)
        gate.open()
        for _ in 0..<20 where f.statuses.last?.phase != .ready { await Task.yield() }
        #expect(f.statuses.last?.phase == .ready)
        #expect(f.launched.count == 1)
        f.coordinator.cancel()
    }

    @Test func separateRequestCannotReplaceInFlightChatAndBusyRetryStaysRejected() {
        let f = Fixture(); f.state = .voice(UUID())
        let first = f.request(); let second = f.request()
        f.coordinator.receive(first); f.coordinator.receive(second)
        #expect(f.statuses.last?.reason == .busy)
        #expect(f.coordinator.isCreatingChat)
        f.finish(first.id); f.coordinator.receive(second)
        #expect(f.launched.count == 1)
        #expect(f.statuses.last?.reason == .busy)
        #expect(!f.coordinator.isCreatingChat)
        f.coordinator.cancel()
    }

    @Test func targetIsFrozenOnceBeforeAsyncLaunch() {
        let f = Fixture(); f.state = .voice(UUID()); f.target = .claudeCode
        let request = f.request(); f.coordinator.receive(request)
        f.target = .codex
        f.finish(request.id)
        #expect(f.launched.first?.1 == .claudeCode)
        #expect(f.statuses.last?.target == .claudeCode)
        f.coordinator.cancel()
    }

    @Test func staleFutureLockedUnavailableAndUnknownTargetsHaveNoEffects() {
        for scenario in 0..<5 {
            let f = Fixture()
            var request = f.request()
            switch scenario {
            case 0: request = .init(id: request.id, sentAt: 94)
            case 1: request = .init(id: request.id, sentAt: 102)
            case 2: f.allowed = false
            case 3: f.state = .unavailable
            default: f.target = nil
            }
            f.coordinator.receive(request)
            #expect(f.launched.isEmpty)
            #expect(f.starts == 0)
            #expect(f.statuses.last?.phase == .failed)
            f.coordinator.cancel()
        }
    }

    @Test func lockCancelsPendingLaunchAndLateCompletionCannotStartAudio() {
        let f = Fixture(); let request = f.request(); f.coordinator.receive(request)
        f.allowed = false; f.coordinator.captureDidChange(); f.finish(request.id)
        #expect(f.canceled == [request.id])
        #expect(f.starts == 0)
        #expect(f.statuses.last?.reason == .locked)
        f.coordinator.cancel()
    }

    @Test func endingOrReplacingOriginalCaptureCancelsLaunchWithoutTouchingNewCapture() {
        for replacement in [NewChatRecordingCapture.idle, .voice(UUID()), .unavailable] {
            let f = Fixture(); f.state = .voice(UUID()); let request = f.request()
            f.coordinator.receive(request)
            f.state = replacement; f.coordinator.captureDidChange(); f.finish(request.id)
            #expect(f.canceled == [request.id])
            #expect(f.starts == 0)
            #expect(f.state == replacement)
            #expect(f.statuses.last?.reason == .captureChanged)
            f.coordinator.cancel()
        }
    }

    @Test func nativeFailurePreservesExistingVoiceAndNeverRetriesCreate() {
        let f = Fixture(); f.state = .voice(UUID()); let before = f.state
        let request = f.request(); f.coordinator.receive(request); f.finish(request.id, success: false)
        f.coordinator.receive(request)
        #expect(f.state == before)
        #expect(f.starts == 0)
        #expect(f.launched.count == 1)
        #expect(f.statuses.last?.reason == .launcherFailed)
        f.coordinator.cancel()
    }

    @Test func deadlineCancelsOnlyLauncherAndIgnoresLateReady() async throws {
        let f = Fixture(); f.timeout = 1_000_000; f.state = .voice(UUID()); let before = f.state
        let request = f.request(); f.coordinator.receive(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        f.finish(request.id)
        #expect(f.canceled == [request.id])
        #expect(f.state == before)
        #expect(f.starts == 0)
        #expect(f.statuses.last?.reason == .timedOut)
        f.coordinator.cancel()
    }

    @Test func failedIdleCaptureNeverReportsReady() async {
        let f = Fixture(); f.startSucceeds = false
        let request = f.request(); f.coordinator.receive(request); f.finish(request.id)
        await f.startEntered.wait()
        for _ in 0..<20 where f.statuses.last?.phase != .failed { await Task.yield() }
        #expect(f.statuses.last?.reason == .captureFailed)
        #expect(f.starts == 1)
        f.coordinator.cancel()
    }

    @Test func replayBudgetRejectsFloodRatherThanEvictingFreshTombstones() {
        let f = Fixture(); f.state = .voice(UUID())
        let first = f.request()
        f.coordinator.receive(first); f.finish(first.id)
        for _ in 1..<NewChatRecordingCoordinator.maximumEntries {
            let request = f.request(); f.coordinator.receive(request); f.finish(request.id)
        }
        f.coordinator.receive(f.request())
        #expect(f.launched.count == NewChatRecordingCoordinator.maximumEntries)
        #expect(f.statuses.last?.reason == .overloaded)
        f.coordinator.receive(first)
        #expect(f.launched.count == NewChatRecordingCoordinator.maximumEntries)
        f.time += NewChatRecordingCoordinator.retention + 1
        f.coordinator.receive(first)
        #expect(f.statuses.last?.reason == .stale)
        f.coordinator.cancel()
    }

    @Test func pendingChatCreationParticipatesInCooperativeQuitVeto() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let appDelegate = try String(contentsOf: root.appendingPathComponent("VoiceInk/AppDelegate.swift"), encoding: .utf8)
        #expect(appDelegate.contains("newChatRecordingService?.isCreatingChat == true"))
        #expect(AppDelegate.shouldBlockTermination(hasInFlightSessions: false, hasPendingRecordingStart: true))
    }
}
