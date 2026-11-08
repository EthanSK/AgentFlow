import ApplicationServices
import Darwin
import Foundation
import os

/// Recipient side of paired Voice suppression: an owner-only UNIX stream socket that the paired
/// source reaches through its Agent Bridge SSH login plus the system `nc`.
///
/// It lives inside the recipient's running Agent Flow so the only input ever posted is the same
/// PID-targeted ChatGPT microphone command, sent with this Mac's own validated binding for it,
/// under the Accessibility permission Agent Flow already holds. No helper binary, shell
/// interpreter or new permission owner exists on this side.
///
/// Safety boundaries:
/// - Requests are opt-in per machine (`PairedVoiceMuteSettings.receiverEnabledKey`). While off,
///   only `release` is honoured so an earlier lease can still end cleanly.
/// - The socket and its directory are private to this user, and each connection's peer must be
///   this same user. Over SSH that is the paired account, which Agent Bridge pairing already
///   grants full shell authority; this endpoint adds no wider authority than that.
/// - One bounded line in, one line out, a small connection cap, and no request can do anything
///   except the three ownership operations or the side-effect-free `status` probe.
final class PairedVoiceMuteReceiver: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case system(String, Int32)
        case occupied
        case insecureDirectory

        var diagnostic: String {
            switch self {
            case .system(let operation, let code): return "\(operation) errno=\(code)"
            case .occupied: return "endpoint owned by another process or not a socket"
            case .insecureDirectory: return "insecure directory"
            }
        }
    }

    /// Shared with `AgentBridgePairedVoiceMuteTransport.remoteCommand`; the remote shell
    /// prefixes the paired account's `$HOME`. Kept short for the 104-byte socket path limit.
    static let relativeSocketPath = "Library/Application Support/VoiceInkPlusPlus/VoiceMute/v.sock"
    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeSocketPath).path
    }
    static let maximumConcurrentConnections = 4
    static let socketIOTimeoutSeconds = 2

    static let shared = PairedVoiceMuteReceiver(
        path: defaultSocketPath,
        isEnabled: { PairedVoiceMuteSettings.receiverEnabled() },
        readiness: { PairedVoiceMuteReceiver.systemReadiness() },
        handler: { request in
            await ChatGPTVoiceCaptureMuteCoordinator.shared.handlePairedRequest(request)
        }
    )

    private struct SocketIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private let path: String
    private let isEnabled: @Sendable () -> Bool
    private let readiness: @Sendable () -> String
    private let handler: @Sendable (PairedVoiceMuteRequest) async -> PairedVoiceMuteResponse
    private let queue = DispatchQueue(label: "com.ethansk.VoiceInkPlusPlus.paired-voice-mute")
    private let connectionQueue = DispatchQueue(
        label: "com.ethansk.VoiceInkPlusPlus.paired-voice-mute.connection",
        attributes: .concurrent
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private var listenDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var boundIdentity: SocketIdentity?
    private var acceptSource: DispatchSourceRead?
    private var activeConnections = 0
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "PairedVoiceMuteReceiver"
    )

    init(
        path: String,
        isEnabled: @escaping @Sendable () -> Bool,
        readiness: @escaping @Sendable () -> String,
        handler: @escaping @Sendable (PairedVoiceMuteRequest) async -> PairedVoiceMuteResponse
    ) {
        self.path = path
        self.isEnabled = isEnabled
        self.readiness = readiness
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    /// Acquire and renew need the opt-in. Release never does: refusing it would only keep a
    /// paired lease (and possibly the mute) alive until expiry after the user turned this off.
    static func admits(_ request: PairedVoiceMuteRequest, receiverEnabled: Bool) -> Bool {
        receiverEnabled || request.operation == .release
    }

    /// Read-only prerequisites for the `status` probe. Neither check posts input or reads
    /// ChatGPT's interface.
    static func systemReadiness() -> String {
        readiness(
            shortcut: SystemChatGPTVoiceMuteTransport.deviceShortcutResolution(),
            accessibilityTrusted: AXIsProcessTrusted()
        )
    }

    /// Reports the binding a paired request would actually use, not the stricter local one:
    /// a recipient keeps whatever validated shortcut its user already has for this command.
    static func readiness(
        shortcut: ChatGPTVoiceShortcutResolution,
        accessibilityTrusted: Bool
    ) -> String {
        switch shortcut {
        case .missing: return "shortcutMissing"
        case .unsupported: return "shortcutUnsupported"
        case .resolved: return accessibilityTrusted ? "ready" : "accessibilityMissing"
        }
    }

    /// Launch-time entry point. A failure is logged and leaves every local feature unchanged.
    func startForApplication() {
        do {
            try start()
            logger.info("Paired Voice mute endpoint listening; requests are honoured only when enabled")
        } catch {
            let reason = (error as? Failure)?.diagnostic ?? "filesystem"
            logger.error("Paired Voice mute endpoint unavailable reason=\(reason, privacy: .public); local capture is unchanged")
        }
    }

    func start() throws {
        try queue.sync {
            guard listenDescriptor < 0 else { return }
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(directory, &info) == 0,
                  info.st_uid == geteuid(),
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_mode & 0o077) == 0 else {
                throw Failure.insecureDirectory
            }

            let lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw Failure.system("open lock", errno) }
            guard fstat(lockFD, &info) == 0,
                  info.st_uid == geteuid(),
                  (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & 0o077) == 0,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                throw Failure.occupied
            }
            lockDescriptor = lockFD

            do {
                if lstat(path, &info) == 0 {
                    // Every live owner holds the exclusive lock for its lifetime and the kernel
                    // drops it when that process exits, so a socket left behind now is stale.
                    // Anything that is not this user's socket is preserved, never deleted.
                    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else {
                        throw Failure.occupied
                    }
                    guard unlink(path) == 0 else { throw Failure.system("unlink stale socket", errno) }
                } else if errno != ENOENT {
                    throw Failure.system("inspect socket", errno)
                }

                let fd = try Self.bindAndListen(path)
                listenDescriptor = fd
                guard chmod(path, 0o600) == 0, let identity = Self.socketIdentity(path) else {
                    throw Failure.system("protect socket", errno)
                }
                boundIdentity = identity
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw Failure.system("nonblocking socket", errno)
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptPending(fd) }
                source.setCancelHandler { close(fd) }
                acceptSource = source
                source.resume()
            } catch {
                stopOnQueue()
                throw error
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        if let acceptSource {
            acceptSource.setEventHandler {}
            acceptSource.cancel()
            self.acceptSource = nil
        } else if listenDescriptor >= 0 {
            close(listenDescriptor)
        }
        listenDescriptor = -1
        if let boundIdentity, Self.socketIdentity(path) == boundIdentity {
            unlink(path)
        }
        boundIdentity = nil
        if lockDescriptor >= 0 {
            // Keep the lock file inode stable; unlinking it would let a second process lock a
            // replacement while a waiter still holds the original.
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private func acceptPending(_ listener: Int32) {
        var remaining = 16
        while remaining > 0 {
            remaining -= 1
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard Self.peerIsCurrentUser(client),
                  activeConnections < Self.maximumConcurrentConnections else {
                close(client)
                continue
            }
            activeConnections += 1
            connectionQueue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        Self.configureConnection(client)
        guard let line = Self.readRequestLine(client),
              let message = PairedVoiceMuteMessage.decode(line: line) else {
            finish(client, response: PairedVoiceMuteResponse(status: .rejected, detail: "malformed"))
            return
        }
        let request: PairedVoiceMuteRequest
        switch message {
        case .status:
            let response = isEnabled()
                ? PairedVoiceMuteResponse(status: .ready, detail: readiness())
                : PairedVoiceMuteResponse(status: .disabled)
            finish(client, response: response)
            return
        case .lease(let leaseRequest):
            request = leaseRequest
        }
        guard Self.admits(request, receiverEnabled: isEnabled()) else {
            finish(client, response: PairedVoiceMuteResponse(status: .disabled))
            return
        }
        let handler = self.handler
        Task.detached(priority: .userInitiated) { [self] in
            let response = await handler(request)
            connectionQueue.async { [self] in finish(client, response: response) }
        }
    }

    private func finish(_ client: Int32, response: PairedVoiceMuteResponse) {
        Self.writeAll(client, response.encodedLine())
        shutdown(client, SHUT_RDWR)
        close(client)
        queue.async { [self] in activeConnections = max(0, activeConnections - 1) }
    }

    private static func configureConnection(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: socketIOTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads one newline-terminated request within the size and time bounds. A sender that
    /// closes without a newline is accepted too, because `nc` may half-close after stdin EOF.
    private static func readRequestLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        let deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(socketIOTimeoutSeconds)
        while buffer.count <= PairedVoiceMuteRequest.maximumEncodedBytes,
              ProcessInfo.processInfo.systemUptime < deadline {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 {
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<newline])
            }
        }
        return nil
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let sent = send(fd, pointer, remaining, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
        }
    }

    private static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    private static func socketIdentity(_ path: String) -> SocketIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else {
            return nil
        }
        return SocketIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func bindAndListen(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8CString.count <= capacity else {
            throw Failure.system("path length", ENAMETOOLONG)
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strncpy(destination, source, capacity - 1)
                }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        // Agent Flow also spawns SSH for its own paired requests; never leak this listener.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind", code)
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Failure.system("listen", code)
        }
        return fd
    }
}
