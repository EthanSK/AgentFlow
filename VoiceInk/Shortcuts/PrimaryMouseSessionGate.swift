import AppKit

/// Native input readiness is independent of Karabiner's unlocked-session lease.
/// NSWorkspace has no public synchronous lock query; launch/wake therefore need
/// ordinary session input, never receipt of a socket command, as positive proof.
struct PrimaryMouseSessionReadiness {
    private(set) var isReady = false
    private(set) var explicitlyResigned = false
    private(set) var sleeping = false

    mutating func resign() { explicitlyResigned = true; isReady = false }
    mutating func becomeActive() { explicitlyResigned = false; isReady = false }
    mutating func sleep() { sleeping = true; isReady = false }
    mutating func wake() { sleeping = false; isReady = false }
    mutating func block() { isReady = false }
    mutating func ordinaryInput(frontmostBundle: String?) {
        guard !explicitlyResigned, !sleeping,
              !Self.blocksSession(frontmostBundle) else { return }
        isReady = true
    }
    static func blocksSession(_ bundle: String?) -> Bool {
        switch bundle {
        case nil, "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver":
            return true
        default: return false
        }
    }
}

@MainActor
final class PrimaryMouseSessionGate {
    static let shared = PrimaryMouseSessionGate()
    private(set) var readiness = PrimaryMouseSessionReadiness()
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.receive(note) }
            })
        }
        armOrdinaryInputProof()
    }

    private func receive(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.sessionDidResignActiveNotification: readiness.resign()
        case NSWorkspace.sessionDidBecomeActiveNotification: readiness.becomeActive()
        case NSWorkspace.willSleepNotification: readiness.sleep()
        case NSWorkspace.didWakeNotification: readiness.wake()
        case NSWorkspace.didActivateApplicationNotification:
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if PrimaryMouseSessionReadiness.blocksSession(app?.bundleIdentifier) { readiness.block() }
            else if readiness.isReady { return }
        default: return
        }
        // Even a repeated closed-state notification invalidates queued commands.
        onChange?(false)
        removeInputMonitors()
        if !readiness.explicitlyResigned, !readiness.sleeping { armOrdinaryInputProof() }
    }

    private func armOrdinaryInputProof() {
        guard globalInputMonitor == nil, !readiness.isReady else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown, .flagsChanged
        ]
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeOrdinaryInput() }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observeOrdinaryInput() }
            return event // This observer never swallows or rewrites another input.
        }
    }

    private func observeOrdinaryInput() {
        readiness.ordinaryInput(frontmostBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard readiness.isReady else { return }
        removeInputMonitors()
        onChange?(true)
    }

    private func removeInputMonitors() {
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        globalInputMonitor = nil
        localInputMonitor = nil
    }
}
