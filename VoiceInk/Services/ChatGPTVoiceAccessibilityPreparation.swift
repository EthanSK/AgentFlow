import AppKit
import ApplicationServices
import Foundation
import os

struct ChatGPTVoiceAccessibilityProcess: Equatable, Sendable {
    let pid: pid_t
    let launchedAt: Date
}

/// Claim before crossing IPC: simultaneous launch/activation events must not
/// restart Electron's delayed tree preparation. Retain one birth, not a history.
final class ChatGPTVoiceAccessibilityRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ChatGPTVoiceAccessibilityProcess?

    func claim(_ process: ChatGPTVoiceAccessibilityProcess) -> Bool {
        guard process.pid > 0, process.launchedAt.timeIntervalSince1970.isFinite else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let latest, process.launchedAt <= latest.launchedAt { return false }
        latest = process
        return true
    }
}

/// Ethan approved the Codex-only exposure request on 2026-11-14 after the
/// disposable Mini fixture proved the documented request works in the background.
/// It prepares labels with the documented exposure attribute, never presses a
/// control, activates, focuses, toggles audio or changes saved settings.
@MainActor
final class ChatGPTVoiceAccessibilityPreparation {
    static let shared = ChatGPTVoiceAccessibilityPreparation()
    nonisolated private static let requests = ChatGPTVoiceAccessibilityRequests()
    nonisolated private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus", category: "ChatGPTVoiceAccessibility"
    )
    private var observers: [NSObjectProtocol] = []

    func startForApplication() {
        // A test host must not prepare the user's real Codex process as a side
        // effect of starting its app delegate. Fixtures inject their own model.
        guard observers.isEmpty,
              !Self.isTestHost(environment: ProcessInfo.processInfo.environment,
                               xctestLoaded: NSClassFromString("XCTestCase") != nil) else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleURL?.standardizedFileURL.path == SystemChatGPTVoiceMuteTransport.applicationPath
                else { return }
                Self.prepareInBackground(expectedPID: app.processIdentifier)
            })
        }
        Self.prepareInBackground()
    }

    nonisolated static func isTestHost(environment: [String: String], xctestLoaded: Bool) -> Bool {
        xctestLoaded || environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    nonisolated private static func prepareInBackground(expectedPID: pid_t? = nil) {
        Task.detached(priority: .utility) {
            // A configured speaker binding is the opt-in. Do not expose Codex's
            // renderer for users who have not configured this Voice integration.
            let bindings = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/keybindings.json")
            guard case .resolved = ChatGPTVoiceShortcut.resolve(
                keybindings: try? Data(contentsOf: bindings),
                command: SystemChatGPTVoiceMuteTransport.speakerShortcutCommand),
                  AXIsProcessTrusted(),
                  let app = SystemChatGPTVoiceMuteTransport.expectedApplication(),
                  expectedPID == nil || app.processIdentifier == expectedPID,
                  app.isFinishedLaunching, let launchedAt = app.launchDate
            else { return }
            let identity = ChatGPTVoiceAccessibilityProcess(pid: app.processIdentifier, launchedAt: launchedAt)
            guard requests.claim(identity) else { return }
            let root = AXUIElementCreateApplication(identity.pid)
            AXUIElementSetMessagingTimeout(root, 0.04)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, "AXManualAccessibility" as CFString, &value) == .success,
               value as? Bool == true { return }
            guard let fresh = SystemChatGPTVoiceMuteTransport.expectedApplication(),
                  fresh.processIdentifier == identity.pid, fresh.launchDate == identity.launchedAt
            else { return }
            // This is the sole allowed AX write. Request once, never switch it
            // off or retry an unsupported result: Electron may still apply it.
            // Its roughly two-second readiness is ahead of capture, never a
            // new wait or request inside the existing 120ms recording preflight.
            let result = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            logger.notice("Requested Voice Accessibility exposure once pid=\(identity.pid, privacy: .public) result=\(result.rawValue, privacy: .public)")
        }
    }
}
