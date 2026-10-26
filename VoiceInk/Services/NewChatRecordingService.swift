import AppKit
import Combine
import CoreFoundation

/// App-lifetime IPC glue. Agentic Mouse owns app automation; Agent Flow owns the
/// selected harness and voice lifecycle. Neither side owns a new paste target.
@MainActor
final class NewChatRecordingService: ObservableObject {
    static let requestName = Notification.Name("com.ethansk.AgentFlow.newChatRecording.v1")
    static let resultName = Notification.Name("com.ethansk.AgentFlow.newChatRecording.result.v1")
    static let launchName = Notification.Name("com.ethansk.AgenticMouse.newChat.v1")
    static let launchResultName = Notification.Name("com.ethansk.AgenticMouse.newChat.result.v1")
    static let cancelName = Notification.Name("com.ethansk.AgenticMouse.newChat.cancel.v1")

    private weak var engine: VoiceInkEngine?
    private weak var recorderUI: RecorderUIManager?
    private let center: DistributedNotificationCenter
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var replies: [UUID: (Bool) -> Void] = [:]

    private lazy var coordinator = NewChatRecordingCoordinator(
        selectedHarness: { NewChatRecordingHarness.selected() },
        capture: { [weak self] in self?.engine?.newChatRecordingCapture ?? .unavailable },
        inputAllowed: { PrimaryMouseSessionGate.shared.readiness.isReady },
        launch: { [weak self] id, target, completion in
            self?.requestLaunch(id: id, target: target, completion: completion)
        },
        cancelLaunch: { [weak self] id in self?.cancelLaunch(id: id) },
        start: { [weak self] isCurrent, didReserve in
            guard let self, let engine = self.engine, let recorderUI = self.recorderUI else { return false }
            await recorderUI.resetOnLaunch()
            guard !Task.isCancelled, isCurrent(), engine.newChatRecordingCapture == .idle,
                  let startID = engine.reserveRecordingStart() else { return false }
            didReserve(startID)
            // The reserved overload is deliberately start-only. A concurrent
            // ordinary Primary can never turn this delayed request into Stop.
            await recorderUI.toggleRecorderPanel(reservedStartRequestID: startID)
            return engine.newChatRecordingCapture == .voice(startID)
        },
        publish: { [weak self] status in self?.publish(status) }
    )

    init(
        engine: VoiceInkEngine,
        recorderUI: RecorderUIManager,
        center: DistributedNotificationCenter = .default()
    ) {
        self.engine = engine
        self.recorderUI = recorderUI
        self.center = center
        distributedObservers.append(center.addObserver(
            forName: Self.requestName, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let request = NewChatRecordingRequest.decode(object: note.object, userInfo: note.userInfo) else { return }
                self?.coordinator.receive(request)
            }
        })
        distributedObservers.append(center.addObserver(
            forName: Self.launchResultName, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.receiveLaunchResult(note) }
        })

        // @Published emits before assignment. Read the actual post-change engine
        // on the next main-loop turn; no timer or per-frame AX scan is needed.
        engine.$recordingState.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.coordinator.captureDidChange() }
            .store(in: &subscriptions)
        engine.$sessions.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.coordinator.captureDidChange() }
            .store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.cancel() }
            })
        }
    }

    deinit {
        for observer in distributedObservers { center.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func requestLaunch(id: UUID, target: NewChatRecordingHarness, completion: @escaping (Bool) -> Void) {
        replies[id] = completion
        center.postNotificationName(Self.launchName, object: id.uuidString, userInfo: [
            "version": 1, "target": target.rawValue, "sentAt": Date().timeIntervalSince1970
        ], deliverImmediately: true)
    }

    private func receiveLaunchResult(_ note: Notification) {
        guard let object = note.object as? String, object.utf8.count == 36,
              let id = UUID(uuidString: object), let fields = note.userInfo,
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let status = fields["status"] as? String,
              status == "ready" || status == "failed",
              let reply = replies.removeValue(forKey: id) else { return }
        reply(status == "ready")
    }

    private func cancelLaunch(id: UUID) {
        replies.removeValue(forKey: id)
        center.postNotificationName(Self.cancelName, object: id.uuidString, userInfo: ["version": 1], deliverImmediately: true)
    }

    private func publish(_ status: NewChatRecordingStatus) {
        var fields: [String: Any] = [
            "version": 1, "phase": status.phase.rawValue, "reason": status.reason.rawValue
        ]
        if let target = status.target { fields["target"] = target.rawValue }
        center.postNotificationName(Self.resultName, object: status.id.uuidString, userInfo: fields, deliverImmediately: true)
    }
}
