import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import Combine

/// A rejected quit remains a quit request. Wait for actual work-state changes,
/// then retry ordinary termination so its fresh all-session guard runs again.
/// No microphone action, forced exit, or repeating readiness poll belongs here.
@MainActor
final class DeferredTerminationCoordinator {
    private let isBlocked: () -> Bool
    private let retry: () -> Void
    private var observation: AnyCancellable?
    private var checkScheduled = false
    private var generation = 0

    init(isBlocked: @escaping () -> Bool, retry: @escaping () -> Void) {
        self.isBlocked = isBlocked
        self.retry = retry
    }

    func waitForIdle(changes: AnyPublisher<Void, Never>) {
        guard observation == nil else { return }
        observation = changes.sink { [weak self] in self?.scheduleCheck() }
        scheduleCheck()
    }

    func cancel() {
        generation += 1
        observation = nil
        checkScheduled = false
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        let currentGeneration = generation
        // @Published emits before assignment. Defer the read until after the
        // entire MainActor transition, including reservation -> session handoff.
        DispatchQueue.main.async { [weak self] in
            guard let self, currentGeneration == self.generation else { return }
            self.checkScheduled = false
            guard self.observation != nil, !self.isBlocked() else { return }
            self.cancel()
            self.retry()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    weak var voiceInkEngine: VoiceInkEngine?
    weak var newChatRecordingService: NewChatRecordingService?
    @MainActor private lazy var deferredTermination = DeferredTerminationCoordinator(
        isBlocked: { [weak self] in self?.terminationIsBlocked ?? true },
        retry: { NSApp.terminate(nil) }
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Inactive launches can receive sessionDidResignActive before did-finish.
        // Subscribe early; a socket command is never evidence of an unlocked Mac.
        PrimaryMouseSessionGate.shared.startObserving()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        // Remember selection gestures from launch, not from recording start, so a
        // highlight made just before or during recorder start-up is not missed.
        // It records only pointer edges; text is read only during a recording.
        SelectionGestureWatcher.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    static func shouldBlockTermination(
        hasInFlightSessions: Bool,
        hasHistoryRetries: Bool = false,
        hasPendingRecordingStart: Bool = false
    ) -> Bool {
        hasInFlightSessions || hasHistoryRetries || hasPendingRecordingStart
    }

    @MainActor
    static func makeTerminationRetryAction(retry: @escaping () -> Void) -> (label: String, action: () -> Void) {
        (String(localized: "I've finished"), retry)
    }

    @MainActor private var terminationIsBlocked: Bool {
        let hasInFlightSessions = voiceInkEngine?.sessions.isEmpty == false
        // An accepted Primary/typing start owns its reservation, startup bar and
        // Next-only input before its session card exists, and may still be waiting on
        // exact-input capture, an older delivery or model cleanup. A cooperative quit
        // (including a release swap) in that window must wait like a live recording.
        // New-chat creation is an unfinished voice-start intent even before audio
        // is reserved. Do not replace the app while its native launcher can still
        // create/focus that input; the bounded operation must finish or cancel first.
        let hasPendingRecordingStart = voiceInkEngine?.hasPendingRecordingStart == true
            || newChatRecordingService?.isCreatingChat == true
        return Self.shouldBlockTermination(
            hasInFlightSessions: hasInFlightSessions,
            hasHistoryRetries: !HistoryAudioRetryState.shared.activeIDs.isEmpty,
            hasPendingRecordingStart: hasPendingRecordingStart
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationIsBlocked else {
            deferredTermination.cancel()
            return .terminateNow
        }

        var changes = [HistoryAudioRetryState.shared.$activeIDs.map { _ in () }.eraseToAnyPublisher()]
        if let voiceInkEngine { changes.append(voiceInkEngine.terminationActivityChanges) }
        if let newChatRecordingService {
            changes.append(newChatRecordingService.$isCreatingChat.map { _ in () }.eraseToAnyPublisher())
        }
        // Ethan's "I've finished" is an optional immediate check. Finishing the
        // final session/retry/start now triggers that same guarded quit itself.
        deferredTermination.waitForIdle(changes: Publishers.MergeMany(changes).eraseToAnyPublisher())

        // A normal quit/release swap must never discard live microphone audio or an
        // in-flight transcription, including file-only History retries which do not
        // own a recorder session. Returning terminateCancel keeps the external
        // installer waiting until this app actually exits. Force-kill/crash recovery is a
        // separate boundary; this guard protects every cooperative app replacement.
        NotificationManager.shared.showNotification(
            title: String(localized: "Agent Flow is still recording or transcribing — finish or cancel it before quitting"),
            type: .error,
            duration: 12,
            // Ethan's "I've finished" retries the normal quit, not Stop/Cancel.
            // The same live all-session veto runs again if capture/start/delivery
            // is still active. A guarded installer waits for process exit and owns
            // replacement/relaunch; this button never starts an independent updater.
            actionButton: Self.makeTerminationRetryAction { sender.terminate(nil) },
            dismissesAutomatically: false
        )
        return .terminateCancel
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI’s WindowGroup-created ContentView and let it process this later.
            pendingOpenFileURL = url
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            menuBarManager?.focusMainWindow()
            NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
