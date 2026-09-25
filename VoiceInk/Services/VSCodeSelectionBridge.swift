import Darwin
import Foundation

/// Monaco's default AX editor explicitly exposes no text unless screen-reader
/// mode is enabled. Better Git uses VS Code's public selection event instead.
/// This is a pull made only for an active recording's real mouse gesture, not
/// an always-on editor feed. No clipboard, AX writes, focus changes or TCP port.
/// Both ends require the current gesture, source PID and a private same-user
/// socket. A missing/ambiguous/stale bridge falls through to read-only AX.
enum VSCodeSelectionBridge {
    struct Request: Encodable, Sendable {
        let version = 1
        let nonce: String
        let sourcePID: Int32
        let gestureStartedAt: Double
        let requestedAt: Double
    }

    struct Response: Codable, Sendable {
        let version: Int
        let nonce: String
        let sourcePID: Int32
        let changedAt: Double
        let text: String
    }

    static func supports(_ bundleID: String?) -> Bool {
        bundleID == "com.microsoft.VSCode" || bundleID == "com.microsoft.VSCodeInsiders"
    }

    static func validatedText(_ response: Response, for request: Request, now: Double) -> String? {
        guard response.version == 1, response.nonce == request.nonce,
              response.sourcePID == request.sourcePID,
              response.changedAt.isFinite, now.isFinite,
              response.changedAt >= request.gestureStartedAt - 30,
              response.changedAt <= now, now - request.requestedAt <= 1000,
              request.requestedAt <= now + 100,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.text.utf16.count <= 8192 else { return nil }
        return response.text
    }

    static func read(sourcePID: pid_t, gestureStartedAt: Date) async -> String? {
        let request = Request(nonce: UUID().uuidString, sourcePID: sourcePID,
                              gestureStartedAt: gestureStartedAt.timeIntervalSince1970 * 1000,
                              requestedAt: Date().timeIntervalSince1970 * 1000)
        let directory = "/tmp/agentflow-selection-\(getuid())"
        // lstat refuses symlinks, and both directory and sockets must belong to
        // this user without group/world access. Never repair permissions here.
        guard isPrivateOwnedPath(directory, type: mode_t(S_IFDIR)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let namesForProcess = names.filter {
            $0.hasPrefix("vscode-\(sourcePID)-") && $0.hasSuffix(".sock") && !$0.contains("/")
        }
        guard !namesForProcess.isEmpty, namesForProcess.count <= 16 else { return nil }
        return await withTaskGroup(of: String?.self) { group in
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
