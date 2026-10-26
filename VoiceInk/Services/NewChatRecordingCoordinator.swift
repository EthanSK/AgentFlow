import Foundation
import CoreFoundation

/// The one chosen-harness preference. The wand transports intent, never a second
/// preferred app. Claude Code means the terminal CLI, not Claude Desktop.
enum NewChatRecordingHarness: String, CaseIterable, Sendable {
    case codex
    case claudeCode

    static let preferenceKey = "VIPPNewChatRecordingHarness"

    static func selected(in defaults: UserDefaults = .standard) -> Self? {
        guard let value = defaults.string(forKey: preferenceKey) else { return .codex }
        return Self(rawValue: value) // Unknown explicit choices must not open Codex instead.
    }
}

enum NewChatRecordingCapture: Equatable {
    case idle
    case voice(UUID)
    case unavailable
}

struct NewChatRecordingRequest: Equatable {
    let id: UUID
    let sentAt: TimeInterval

    static let maximumAge: TimeInterval = 5

    static func decode(object: Any?, userInfo: [AnyHashable: Any]?) -> Self? {
        guard let value = object as? String, value.utf8.count == 36,
              let id = UUID(uuidString: value), let fields = userInfo,
              Set(fields.keys) == Set(["version", "action", "sentAt"].map(AnyHashable.init)),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              fields["action"] as? String == "start",
              let timestamp = fields["sentAt"] as? NSNumber,
              CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              timestamp.doubleValue.isFinite else { return nil }
        return Self(id: id, sentAt: timestamp.doubleValue)
    }

    func isFresh(at now: TimeInterval) -> Bool {
        now.isFinite && sentAt.isFinite && now - sentAt >= -1 && now - sentAt <= Self.maximumAge
    }
}

struct NewChatRecordingStatus: Equatable {
    enum Phase: String { case creating, ready, failed }
    enum Reason: String {
        case none, stale, locked, busy, invalidHarness, overloaded
        case launcherFailed, timedOut, captureChanged, captureFailed, canceled
    }
    let id: UUID
    let target: NewChatRecordingHarness?
    let phase: Phase
    let reason: Reason
}

/// "Double Top" is start-only orchestration, not another recording toggle or
/// delivery route. In particular the first Top may already own live audio. Adopt
/// that same start identity; never stop/restart it to create a chat. Completion
/// still uses Primary/Next's existing policy, including later manual focus changes.
@MainActor
final class NewChatRecordingCoordinator {
    typealias Launch = (UUID, NewChatRecordingHarness, @escaping (Bool) -> Void) -> Void
    typealias Start = (
        _ isCurrent: @escaping @MainActor () -> Bool,
        _ didReserve: @escaping @MainActor (UUID) -> Void
    ) async -> Bool

    private struct Entry {
        var status: NewChatRecordingStatus
        let acceptedAt: TimeInterval
    }
    private struct Operation {
        let id: UUID
        let target: NewChatRecordingHarness
        var capture: NewChatRecordingCapture
        var startingCapture = false
    }

    private let selectedHarness: () -> NewChatRecordingHarness?
    private let capture: () -> NewChatRecordingCapture
    private let inputAllowed: () -> Bool
    private let launch: Launch
    private let cancelLaunch: (UUID) -> Void
    private let start: Start
    private let publish: (NewChatRecordingStatus) -> Void
    private let now: () -> TimeInterval
    private let timeoutNanoseconds: UInt64
    private var entries: [UUID: Entry] = [:]
    private var operation: Operation?
    private var timeoutTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    static let maximumEntries = 128
    static let retention: TimeInterval = 60
    var isCreatingChat: Bool { operation != nil }

    init(
        selectedHarness: @escaping () -> NewChatRecordingHarness?,
        capture: @escaping () -> NewChatRecordingCapture,
        inputAllowed: @escaping () -> Bool,
        launch: @escaping Launch,
        cancelLaunch: @escaping (UUID) -> Void,
        start: @escaping Start,
        publish: @escaping (NewChatRecordingStatus) -> Void,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.selectedHarness = selectedHarness
        self.capture = capture
        self.inputAllowed = inputAllowed
        self.launch = launch
        self.cancelLaunch = cancelLaunch
        self.start = start
        self.publish = publish
        self.now = now
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func receive(_ request: NewChatRecordingRequest) {
        // A retry only replays status. Retain tombstones beyond the wire freshness
        // window and never evict a fresh entry to admit an unbounded request flood.
        let time = now()
        entries = entries.filter { time - $0.value.acceptedAt <= Self.retention }
        if let existing = entries[request.id] { publish(existing.status); return }
        guard request.isFresh(at: time) else { reject(request.id, .stale); return }
        guard entries.count < Self.maximumEntries else { reject(request.id, .overloaded); return }
        guard inputAllowed() else { rememberFailure(request.id, .locked, at: time); return }
        guard operation == nil else { rememberFailure(request.id, .busy, at: time); return }
        guard let target = selectedHarness() else {
            rememberFailure(request.id, .invalidHarness, at: time); return
        }
        let state = capture()
        guard state != .unavailable else { rememberFailure(request.id, .busy, at: time); return }

        let status = NewChatRecordingStatus(id: request.id, target: target, phase: .creating, reason: .none)
        entries[request.id] = Entry(status: status, acceptedAt: time)
        operation = Operation(id: request.id, target: target, capture: state)
        // Record ownership before either callback: injectable/native launchers may
        // complete synchronously. A second request cannot create a second chat.
        publish(status)
        timeoutTask = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            self?.fail(request.id, reason: .timedOut)
        }
        launch(request.id, target) { [weak self] success in
            self?.launcherCompleted(request.id, success: success)
        }
    }

    /// Called after actual capture/session changes and lock/sleep notifications.
    /// No polling, clipboard inspection or foreground-app traversal is involved.
    func captureDidChange() {
        guard let current = operation else { return }
        guard inputAllowed() else { fail(current.id, reason: .locked); return }
        guard capture() == current.capture else { fail(current.id, reason: .captureChanged); return }
    }

    func cancel() {
        if let current = operation { fail(current.id, reason: .canceled) }
    }

    private func launcherCompleted(_ id: UUID, success: Bool) {
        guard let current = operation, current.id == id else { return }
        guard !current.startingCapture else { return }
        guard success else { fail(id, reason: .launcherFailed); return }
        guard inputAllowed(), capture() == current.capture else {
            fail(id, reason: .captureChanged); return
        }
        switch current.capture {
        case .voice:
            finish(id) // The first Top already started; do not toggle it again.
        case .idle:
            // A duplicate native ACK must not start two asynchronous reservations.
            operation?.startingCapture = true
            startTask = Task { [weak self] in
                guard let self else { return }
                let started = await self.start({ [weak self] in
                    guard let self, let current = self.operation else { return false }
                    return current.id == id && self.inputAllowed() && self.capture() == current.capture
                }, { [weak self] startID in
                    guard self?.operation?.id == id else { return }
                    self?.operation?.capture = .voice(startID)
                })
                guard self.operation?.id == id else { return }
                if started, self.inputAllowed(), self.capture() == self.operation?.capture {
                    self.finish(id)
                } else { self.fail(id, reason: .captureFailed) }
            }
        case .unavailable:
            fail(id, reason: .captureChanged)
        }
    }

    private func finish(_ id: UUID) {
        guard let current = operation, current.id == id else { return }
        let status = NewChatRecordingStatus(id: id, target: current.target, phase: .ready, reason: .none)
        entries[id]?.status = status
        operation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        startTask = nil
        publish(status)
    }

    private func fail(_ id: UUID, reason: NewChatRecordingStatus.Reason) {
        guard let current = operation, current.id == id else { return }
        let status = NewChatRecordingStatus(id: id, target: current.target, phase: .failed, reason: reason)
        entries[id]?.status = status
        operation = nil // A late ACK can never restart capture or re-focus a chat.
        timeoutTask?.cancel(); timeoutTask = nil
        startTask?.cancel(); startTask = nil
        cancelLaunch(id)
        publish(status)
    }

    private func rememberFailure(_ id: UUID, _ reason: NewChatRecordingStatus.Reason, at time: TimeInterval) {
        let status = NewChatRecordingStatus(id: id, target: nil, phase: .failed, reason: reason)
        entries[id] = Entry(status: status, acceptedAt: time)
        publish(status)
    }

    private func reject(_ id: UUID, _ reason: NewChatRecordingStatus.Reason) {
        publish(NewChatRecordingStatus(id: id, target: nil, phase: .failed, reason: reason))
    }
}
