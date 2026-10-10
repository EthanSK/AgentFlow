import Darwin
import Foundation

/// Karabiner's documented send_user_command UNIX datagram transport, isolated
/// from Agentic Mouse's socket. No shell, key synthesis, or forwarding process is
/// involved. The serial ingress clock is retained through MainActor congestion.
final class PrimaryMouseCommandReceiver: @unchecked Sendable {
    struct Event: Sendable {
        let command: PrimaryMouseCommand
        let receivedAt: TimeInterval
        let generation: UInt64
    }
    enum Failure: Error { case system(String, Int32), occupied, insecureDirectory }
    private struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
    }

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInkPlusPlus/MouseInput/p.sock").path
    }
    private let path: String
    private let queue = DispatchQueue(label: "com.ethansk.VoiceInkPlusPlus.primary-mouse")
    private let key = DispatchSpecificKey<Void>()
    private var descriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var identity: Identity?
    private var generation: UInt64 = 0
    private var enabled = false
    private var queuedEvents = 0
    private static let maximumQueuedEvents = 32

    init(path: String = PrimaryMouseCommandReceiver.socketPath) {
        self.path = path
        queue.setSpecific(key: key, value: ())
    }

    deinit { stop() }

    func start(handler: @escaping @MainActor @Sendable (Event) -> Void) throws {
        try queue.sync {
            guard descriptor < 0 else { return }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(directory, &info) == 0,
                  info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_mode & 0o077) == 0 else { throw Failure.insecureDirectory }

            let lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { throw Failure.system("open lock", errno) }
            guard fstat(lockFD, &info) == 0, info.st_uid == geteuid(),
                  (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & 0o077) == 0,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                throw Failure.occupied
            }
            lockDescriptor = lockFD
            do {
                if lstat(path, &info) == 0 {
                    guard let current = Self.socketIdentity(path),
                          current == Self.readIdentity(lockFD) else { throw Failure.occupied }
                    guard unlink(path) == 0 else { throw Failure.system("unlink stale socket", errno) }
                } else if errno != ENOENT {
                    throw Failure.system("inspect socket", errno)
                }

                descriptor = try Self.bind(path)
                guard chmod(path, 0o600) == 0,
                      let bound = Self.socketIdentity(path) else {
                    throw Failure.system("protect socket", errno)
                }
                identity = bound
                let marker = try JSONEncoder().encode(bound)
                guard ftruncate(lockFD, 0) == 0, lseek(lockFD, 0, SEEK_SET) == 0,
                      marker.withUnsafeBytes({ Darwin.write(lockFD, $0.baseAddress, $0.count) }) == marker.count,
                      fsync(lockFD) == 0 else { throw Failure.system("write identity", errno) }
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw Failure.system("nonblocking socket", errno)
                }
                generation &+= 1
                let fd = descriptor
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.receive(fd: fd, handler: handler) }
                source.setCancelHandler { close(fd) }
                readSource = source
                source.resume()
            } catch {
                stopOnQueue()
                throw error
            }
        }
    }

    /// Gate changes invalidate both buffered socket input and already-dispatched
    /// MainActor events. An inbound command can never open this gate itself.
    @discardableResult
    func setEnabled(_ value: Bool) -> Bool {
        queue.sync {
            generation &+= 1
            enabled = false
            guard descriptor >= 0, let identity,
                  identity == Self.socketIdentity(path) else { return false }
            var bytes = [UInt8](repeating: 0, count: 257)
            for _ in 0..<256 {
                let count = recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    enabled = value
                    return enabled
                }
                if count < 0 { return false }
                // A zero-length datagram is still a consumed packet, not EOF.
                // Continue draining so input queued before unlock cannot replay.
            }
            return false // A flooding sender cannot block the UI or reopen readiness.
        }
    }

    func isCurrent(_ event: Event) -> Bool {
        queue.sync {
            enabled && generation == event.generation && descriptor >= 0 &&
                identity == Self.socketIdentity(path)
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: key) != nil { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        enabled = false
        generation &+= 1
        if let readSource {
            readSource.setEventHandler {}
            readSource.cancel()
            self.readSource = nil
        } else if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        if let identity, Self.socketIdentity(path) == identity { unlink(path) }
        identity = nil
        if lockDescriptor >= 0 {
            // Keep the marker inode stable: unlinking a flock file permits a new
            // process to lock a replacement while an old waiter owns the old inode.
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private func receive(fd: Int32, handler: @escaping @MainActor @Sendable (Event) -> Void) {
        var bytes = [UInt8](repeating: 0, count: PrimaryMouseCommand.maximumPayloadBytes + 1)
        // Bound work per dispatch as well as pending MainActor messages. Malformed
        // or flooding local senders cannot build an unbounded recording-action queue.
        for _ in 0..<64 {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return }
            let time = ProcessInfo.processInfo.systemUptime
            guard enabled, queuedEvents < Self.maximumQueuedEvents,
                  count <= PrimaryMouseCommand.maximumPayloadBytes,
                  let command = PrimaryMouseCommand.decode(Data(bytes.prefix(count))) else { continue }
            let event = Event(command: command, receivedAt: time, generation: generation)
            queuedEvents += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isCurrent(event) { handler(event) }
                self.queue.async { self.queuedEvents -= 1 }
            }
        }
    }

    private static func socketIdentity(_ path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), owner: info.st_uid)
    }

    private static func readIdentity(_ fd: Int32) -> Identity? {
        guard lseek(fd, 0, SEEK_SET) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: Data(bytes.prefix(count)))
    }

    private static func bind(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8CString.count <= capacity else { throw Failure.system("path length", ENAMETOOLONG) }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strncpy(destination, source, capacity - 1)
                }
            }
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind", code)
        }
        return fd
    }
}
