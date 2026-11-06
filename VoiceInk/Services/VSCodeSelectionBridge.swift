import Darwin
import Foundation
import ApplicationServices
import AppKit

/// Monaco's default AX editor explicitly exposes no text unless screen-reader
/// mode is enabled. Better Git uses VS Code's public selection event instead;
/// terminal snapshots use its local terminal tool.
/// This is a pull made only at recording start or for its explicit selection gesture, not
/// an always-on editor feed. No clipboard, focus changes or TCP port. The sole
/// AX write is the approved VS Code-only request to expose its Accessibility tree.
/// Both ends require explicit startup intent or a current gesture, the source PID
/// and a private same-user socket. A missing/ambiguous/stale bridge falls through
/// to read-only AX.
enum VSCodeSelectionBridge {
    private final class AccessibilityRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var enabledProcesses: [String: TimeInterval] = [:]

        func enableIfNeeded(_ app: AXUIElement, identity: String) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            if let readyAt = enabledProcesses[identity] { return readyAt }
            // Ethan approved this VS Code-only exception on 2026-11-05. This
            // documented Electron request exposes its AX tree without Copy,
            // focus writes, or changing the editor's saved accessibility setting.
            // Do not toggle it off: other assistive clients may now rely on it.
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                // Electron itself debounces this request for two seconds. Start
                // it at capture/app activation; repeating it resets that timer.
                let readyAt = ProcessInfo.processInfo.systemUptime + 3
                enabledProcesses[identity] = readyAt
                return readyAt
            }
            return nil
        }
    }
    private static let accessibilityRequests = AccessibilityRequests()

    struct Request: Encodable, Sendable {
        let version = 1
        let nonce: String
        let sourcePID: Int32
        let gestureStartedAt: Double
        let requestedAt: Double
        var inputKind: String? = nil
        var inputDirection: String? = nil
        var surface: String? = nil
        var captureKind: String? = nil
    }

    struct Response: Codable, Sendable {
        let version: Int
        let nonce: String
        let sourcePID: Int32
        let changedAt: Double?
        let text: String
        var inputKind: String? = nil
        var surface: String? = nil
        var observedAt: Double? = nil
        var captureKind: String? = nil
    }

    static func supports(_ bundleID: String?) -> Bool {
        bundleID == "com.microsoft.VSCode" || bundleID == "com.microsoft.VSCodeInsiders"
    }

    static func validatedText(_ response: Response, for request: Request, now: Double) -> String? {
        guard response.version == 1, response.nonce == request.nonce,
              response.sourcePID == request.sourcePID,
              request.surface == nil || request.surface == "editor" || request.surface == "terminal",
              request.captureKind == nil || request.captureKind == "startup",
              response.captureKind == request.captureKind,
              ["mouse", "keyboard", "selectAll"].contains(request.inputKind ?? "mouse"),
              (response.inputKind ?? "mouse") == (request.inputKind ?? "mouse"),
              now.isFinite, now - request.requestedAt <= 1000,
              request.requestedAt <= now + 100,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.text.utf16.count <= 8192 else { return nil }
        if request.captureKind == "startup" {
            // A preselected range need not have changed after recording began.
            // Require an explicit fresh snapshot from the proven focused pane;
            // an older companion's cached gesture response cannot satisfy it.
            guard let surface = request.surface, response.surface == surface,
                  response.captureKind == "startup", let observedAt = response.observedAt,
                  observedAt.isFinite, observedAt >= request.requestedAt,
                  observedAt <= now else { return nil }
        } else if request.surface == "terminal" {
            // A terminal read is a fresh snapshot, not an editor change event.
            // Older companions ignore surface and may answer with editor text:
            // that must never satisfy a terminal request.
            guard response.surface == "terminal", let observedAt = response.observedAt,
                  observedAt.isFinite, observedAt >= request.requestedAt,
                  observedAt <= now else { return nil }
        } else {
            guard response.surface == nil || response.surface == "editor",
                  let changedAt = response.changedAt, changedAt.isFinite,
                  changedAt >= request.gestureStartedAt - 30,
                  changedAt <= now else { return nil }
        }
        return response.text
    }

    static func read(sourcePID: pid_t, gestureStartedAt: Date, inputKind: String? = nil,
                     inputDirection: String? = nil, context: FocusedContext? = nil,
                     isInitialSelection: Bool = false) async -> String? {
        let request = Request(nonce: UUID().uuidString, sourcePID: sourcePID,
                              gestureStartedAt: gestureStartedAt.timeIntervalSince1970 * 1000,
                              requestedAt: Date().timeIntervalSince1970 * 1000,
                              inputKind: inputKind, inputDirection: inputDirection,
                              surface: context?.surface,
                              captureKind: isInitialSelection ? "startup" : nil)
        let directory = "/tmp/agentflow-selection-\(getuid())"
        // lstat refuses symlinks, and both directory and sockets must belong to
        // this user without group/world access. Never repair permissions here.
        guard isPrivateOwnedPath(directory, type: mode_t(S_IFDIR)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let namesForProcess = names.filter {
            $0.hasPrefix("vscode-\(sourcePID)-") && $0.hasSuffix(".sock") && !$0.contains("/")
        }
        guard !namesForProcess.isEmpty, namesForProcess.count <= 16 else { return nil }
        let result = await withTaskGroup(of: String?.self) { group in
            for name in namesForProcess {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    // Blocking POSIX I/O stays off MainActor and has one 250 ms
                    // monotonic deadline, including connect, write and response.
                    return await Task.detached(priority: .userInitiated) {
                        query(path: directory + "/" + name, request: request)
                    }.value
                }
            }
            var matches: [String] = []
            for await text in group { if let text { matches.append(text) } }
            // Two focused extension hosts are ambiguous even if their text agrees.
            return !Task.isCancelled && matches.count == 1 ? matches[0] : nil
        }
        guard let result else { return nil }
        // The user can switch panes while the companion answers. Never emit a
        // terminal snapshot or an editor range after its original field lost focus.
        if let context, !(await context.isCurrent(sourcePID: sourcePID)) { return nil }
        return result
    }

    /// A retained, read-only AX identity. All access stays in detached work;
    /// the reference is never used to write focus, activate, or read document text.
    struct FocusedContext: @unchecked Sendable {
        let element: AXUIElement
        let surface: String
        let bounds: CGRect?

        func isCurrent(sourcePID: pid_t) async -> Bool {
            await Task.detached(priority: .userInitiated) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
                let app = AXUIElementCreateApplication(sourcePID)
                _ = AXUIElementSetMessagingTimeout(app, 0.2)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                      let value else { return false }
                return CFEqual(element, value) && NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID
            }.value
        }
    }

    static func surface(role: String?, label: String?) -> String? {
        if role == kAXTextFieldRole,
           let label, label == "Terminal input" || label.range(of: #"^Terminal [0-9]+,"#, options: .regularExpression) != nil {
            return "terminal"
        }
        return role == kAXTextAreaRole ? "editor" : nil
    }

    static func prepareAccessibility(sourcePID: pid_t) async -> TimeInterval? {
        await Task.detached(priority: .userInitiated) { () -> TimeInterval? in
            guard AXIsProcessTrusted(), let running = NSRunningApplication(processIdentifier: sourcePID),
                  supports(running.bundleIdentifier) else { return nil }
            // LaunchServices omits launchDate for a CLI-launched Code process.
            // Kernel birth time still distinguishes a restarted/reused PID.
            var process = proc_bsdinfo()
            let processInfoSize = MemoryLayout<proc_bsdinfo>.size
            let count = withUnsafeMutablePointer(to: &process) {
                proc_pidinfo(sourcePID, PROC_PIDTBSDINFO, 0, $0, Int32(processInfoSize))
            }
            guard count == processInfoSize, process.pbi_uid == geteuid(), process.pbi_status != SZOMB else { return nil }
            let identity = "\(sourcePID):\(process.pbi_start_tvsec):\(process.pbi_start_tvusec)"
            let app = AXUIElementCreateApplication(sourcePID)
            _ = AXUIElementSetMessagingTimeout(app, 0.2)
            return accessibilityRequests.enableIfNeeded(app, identity: identity)
        }.value
    }

    static func focusedContext(sourcePID: pid_t) async -> FocusedContext? {
        guard let deadline = await prepareAccessibility(sourcePID: sourcePID) else { return nil }
        // Wait for actual Electron readiness, not fixed per-highlight padding.
        // The bounded check stops as soon as the requested tree is available;
        // new gestures and capture.stop cancel it. Warm reads do not sleep.
        while true {
            let state = await readFocusedContext(sourcePID: sourcePID)
            if state.available { return state.context }
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
        }
    }

    private static func readFocusedContext(sourcePID: pid_t) async -> (available: Bool, context: FocusedContext?) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, FocusedContext?) in
            let app = AXUIElementCreateApplication(sourcePID)
            _ = AXUIElementSetMessagingTimeout(app, 0.2)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.35
            func copy(_ key: String, from element: AXUIElement) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
            }
            guard let value = copy(kAXFocusedUIElementAttribute, from: app),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return (false, nil) }
            let focused = value as! AXUIElement
            _ = AXUIElementSetMessagingTimeout(focused, 0.2)
            let role = copy(kAXRoleAttribute, from: focused) as? String
            let labels = [copy(kAXDescriptionAttribute, from: focused) as? String,
                          copy(kAXTitleAttribute, from: focused) as? String]
            guard let surface = labels.compactMap({ surface(role: role, label: $0) }).first else { return (true, nil) }
            func frame(_ element: AXUIElement) -> CGRect? {
                var point = CGPoint.zero, size = CGSize.zero
                guard let position = copy(kAXPositionAttribute, from: element), CFGetTypeID(position) == AXValueGetTypeID(),
                      let dimensions = copy(kAXSizeAttribute, from: element), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                      AXValueGetValue(position as! AXValue, .cgPoint, &point),
                      AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else { return nil }
                return CGRect(origin: point, size: size)
            }
            var bounds = frame(focused)
            if surface == "terminal" {
                // xterm's focused input is a tiny hidden textarea. Pointer
                // evidence must use its own terminal, never the whole window.
                bounds = nil
                var ancestor = focused
                for _ in 0..<10 {
                    let classes = copy("AXDOMClassList", from: ancestor) as? [String] ?? []
                    if classes.contains("terminal") && classes.contains("xterm") {
                        bounds = frame(ancestor)
                        break
                    }
                    guard let parent = copy(kAXParentAttribute, from: ancestor),
                          CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    ancestor = parent as! AXUIElement
                }
            }
            return (true, FocusedContext(element: focused, surface: surface, bounds: bounds))
        }.value
    }

    private static func isPrivateOwnedPath(_ path: String, type: mode_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid() &&
            info.st_mode & mode_t(S_IFMT) == type && info.st_mode & 0o077 == 0
    }

    private static func query(path: String, request: Request) -> String? {
        guard isPrivateOwnedPath(path, type: mode_t(S_IFSOCK)),
              let encoded = try? JSONEncoder().encode(request) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 || errno == EINPROGRESS else { return nil }
        guard ready(fd, events: Int16(POLLOUT), until: deadline) else { return nil }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: error))
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { return nil }
        let outgoing = encoded + Data([10])
        var sent = 0
        while sent < outgoing.count {
            guard ready(fd, events: Int16(POLLOUT), until: deadline) else { return nil }
            let count = outgoing.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), outgoing.count - sent, 0) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }
            sent += count
        }
        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while incoming.count <= 65_536 {
            guard ready(fd, events: Int16(POLLIN), until: deadline) else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }
            incoming.append(contentsOf: buffer.prefix(count))
            if incoming.last == 10 {
                guard let response = try? JSONDecoder().decode(Response.self, from: incoming) else { return nil }
                return validatedText(response, for: request, now: Date().timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    private static func ready(_ fd: Int32, events: Int16, until deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && descriptor.revents & events != 0
        }
    }
}
