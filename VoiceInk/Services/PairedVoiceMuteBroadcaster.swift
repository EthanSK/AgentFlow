import Foundation
import os

/// Receives this Mac's own capture boundaries from `ChatGPTVoiceCaptureMuteCoordinator`.
/// Both calls are synchronous and must return without waiting on the network: the coordinator
/// invokes them inside the actor turn that orders capture leases, which is what gives the
/// paired requests the same order as the local start/resume/pause/stop intents.
protocol PairedVoiceMuteFanOut: Sendable {
    func captureBegan(localLeaseID: UInt64)
    func captureEnded(localLeaseID: UInt64)
}

/// What the source learned about one delivery. Only `.responded` proves the recipient's Agent
/// Flow processed the request; every other case is logged as not delivered or unknown, never as
/// a successful mute.
enum PairedVoiceMuteDelivery: Equatable, Sendable {
    case responded(PairedVoiceMuteResponse)
    /// The name is not a usable Agent Bridge pairing (missing, or unsafe/invalid fields).
    case notPaired
    /// SSH reported a connection-level failure, so the request never reached the recipient.
    case unreachable
    /// SSH ran but no valid answer came back: the recipient may lack the new Agent Flow, may
    /// have it quit, may be another OS, or may have processed the request before failing.
    case noResponse(exitStatus: Int32)
    /// The bounded deadline expired; the recipient may or may not have processed it.
    case timedOut
    case launchFailed
}

protocol PairedVoiceMuteTransport: Sendable {
    func send(
        _ request: PairedVoiceMuteRequest,
        to recipient: String
    ) async -> PairedVoiceMuteDelivery
}

/// Source side of paired Voice suppression: turns this Mac's capture leases into ordered
/// acquire/renew/release requests for the explicitly configured recipients.
///
/// Every request is sent independently in the background and ordered on the recipient by its
/// sequence number, so a slow or asleep recipient never holds up another recipient, local
/// recording, or transcription. Failed deliveries are not retried: a retried acquire could
/// toggle a call whose first toggle did land, and the recipient's lease expiry already cleans up
/// a release that never arrived. Renewal is a lease keep-alive while capture is live; it reads
/// no ChatGPT or Accessibility state on either Mac.
final class PairedVoiceMuteBroadcaster: PairedVoiceMuteFanOut, @unchecked Sendable {
    static let shared = PairedVoiceMuteBroadcaster(
        recipients: { PairedVoiceMuteSettings.recipients() },
        transport: AgentBridgePairedVoiceMuteTransport(),
        renewalTimer: TaskPairedVoiceMuteLeaseTimer(),
        activity: .shared
    )

    /// Minted per app launch. A restarted source gets a fresh sequence space, and its previous
    /// instance's leases simply expire on the recipients instead of being misordered.
    let sourceID: String

    private struct ActiveSession {
        let localLeaseID: UInt64
        let session: String
        let recipients: [String]
        var renewal: PairedVoiceMuteScheduledTimer?
    }

    private let recipientsProvider: @Sendable () -> [String]
    private let transport: any PairedVoiceMuteTransport
    private let renewalTimer: any PairedVoiceMuteLeaseTimer
    private let leaseSeconds: Int
    private let activity: PairedVoiceMuteActivity?
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var active: ActiveSession?
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "PairedVoiceMute"
    )

    init(
        sourceID: String = UUID().uuidString.lowercased(),
        recipients: @escaping @Sendable () -> [String],
        transport: any PairedVoiceMuteTransport,
        renewalTimer: any PairedVoiceMuteLeaseTimer,
        leaseSeconds: Int = PairedVoiceMuteRequest.defaultLeaseSeconds,
        activity: PairedVoiceMuteActivity? = nil
    ) {
        self.sourceID = sourceID.lowercased()
        self.recipientsProvider = recipients
        self.transport = transport
        self.renewalTimer = renewalTimer
        self.activity = activity
        self.leaseSeconds = min(
            max(leaseSeconds, PairedVoiceMuteRequest.leaseSecondsRange.lowerBound),
            PairedVoiceMuteRequest.leaseSecondsRange.upperBound
        )
    }

    func captureBegan(localLeaseID: UInt64) {
        // Read once per capture and keep for this session, so changing the list mid-recording
        // still releases exactly the Macs that were asked to mute.
        let recipients = recipientsProvider()
        let session = UUID().uuidString.lowercased()
        var outgoing: [(recipient: String, request: PairedVoiceMuteRequest)] = []

        lock.lock()
        if let previous = active {
            // The local coordinator lets a newer capture supersede one that was never released.
            // A recipient still on the list has that older session replaced by the new acquire;
            // one removed from the list is released now rather than waiting for expiry.
            previous.renewal?.cancel()
            for recipient in previous.recipients
            where !recipients.contains(where: { $0.caseInsensitiveCompare(recipient) == .orderedSame }) {
                outgoing.append((
                    recipient: recipient,
                    request: nextRequestLocked(.release, session: previous.session)
                ))
            }
            active = nil
        }
        if !recipients.isEmpty {
            for recipient in recipients {
                outgoing.append((
                    recipient: recipient,
                    request: nextRequestLocked(.acquire, session: session)
                ))
            }
            active = ActiveSession(
                localLeaseID: localLeaseID,
                session: session,
                recipients: recipients,
                renewal: scheduleRenewal(session: session)
            )
        }
        lock.unlock()

        dispatch(outgoing)
    }

    func captureEnded(localLeaseID: UInt64) {
        var outgoing: [(recipient: String, request: PairedVoiceMuteRequest)] = []
        lock.lock()
        if let current = active, current.localLeaseID == localLeaseID {
            current.renewal?.cancel()
            // Send release even when the acquire's outcome was unknown: a recipient that never
            // got the acquire answers `unknownSession`, which is harmless.
            for recipient in current.recipients {
                outgoing.append((
                    recipient: recipient,
                    request: nextRequestLocked(.release, session: current.session)
                ))
            }
            active = nil
        }
        lock.unlock()
        dispatch(outgoing)
    }

    private func renewActiveSession(_ session: String) {
        var outgoing: [(recipient: String, request: PairedVoiceMuteRequest)] = []
        lock.lock()
        if var current = active, current.session == session {
            for recipient in current.recipients {
                outgoing.append((
                    recipient: recipient,
                    request: nextRequestLocked(.renew, session: session)
                ))
            }
            current.renewal = scheduleRenewal(session: session)
            active = current
        }
        lock.unlock()
        dispatch(outgoing)
    }

    /// Caller holds `lock`. Assigning the sequence here, in intent order, is what lets the
    /// recipient discard a late release or a late acquire regardless of SSH arrival order.
    private func nextRequestLocked(
        _ operation: PairedVoiceMuteRequest.Operation,
        session: String
    ) -> PairedVoiceMuteRequest {
        sequence &+= 1
        return PairedVoiceMuteRequest(
            operation: operation,
            source: sourceID,
            sequence: sequence,
            session: session,
            leaseSeconds: leaseSeconds
        )
    }

    private func scheduleRenewal(session: String) -> PairedVoiceMuteScheduledTimer {
        renewalTimer.schedule(after: TimeInterval(leaseSeconds) / 3) { [weak self] in
            self?.renewActiveSession(session)
        }
    }

    private func dispatch(_ outgoing: [(recipient: String, request: PairedVoiceMuteRequest)]) {
        guard !outgoing.isEmpty else { return }
        let transport = self.transport
        let logger = self.logger
        let activity = self.activity
        for item in outgoing {
            // Register before spawning: a normal quit must wait for the final bounded release
            // even if its background task has not started yet. This never delays recording.
            let operation = activity?.beginOperation()
            guard activity == nil || operation != nil else { continue }
            let priority: TaskPriority = item.request.operation == .acquire ? .userInitiated : .utility
            Task.detached(priority: priority) {
                defer { if let operation { activity?.finishOperation(operation) } }
                let delivery = await transport.send(item.request, to: item.recipient)
                Self.log(delivery, request: item.request, recipient: item.recipient, logger: logger)
            }
        }
    }

    /// Recipient names belong to the private Agent Bridge pairing, so they are logged as
    /// private values; the public sequence and session prefix correlate source and recipient
    /// logs. Hosts, users and key paths are never handed to the logger at all.
    private static func log(
        _ delivery: PairedVoiceMuteDelivery,
        request: PairedVoiceMuteRequest,
        recipient: String,
        logger: Logger
    ) {
        let operation = request.operation.rawValue
        let sequence = request.sequence
        let session = String(request.session.prefix(8))
        switch delivery {
        case .responded(let response):
            logger.notice("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) status=\(response.status.rawValue, privacy: .public) detail=\(response.detail ?? "none", privacy: .public)")
        case .notPaired:
            logger.error("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) is not a usable Agent Bridge pairing; nothing was sent")
        case .unreachable:
            logger.error("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) was unreachable; the request was not delivered")
        case .noResponse(let status):
            logger.error("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) gave no Agent Flow answer exit=\(status, privacy: .public); remote outcome unknown")
        case .timedOut:
            logger.error("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) timed out; remote outcome unknown")
        case .launchFailed:
            logger.error("Paired Voice mute \(operation, privacy: .public) seq=\(sequence, privacy: .public) session=\(session, privacy: .public) recipient=\(recipient, privacy: .private) could not start SSH; nothing was sent")
        }
    }
}

/// One Agent Bridge pairing resolved to the endpoint Agent Bridge itself would use.
struct AgentBridgePeerEndpoint: Equatable, Sendable {
    let user: String
    let host: String
    let port: Int
    let identityFile: String?
}

/// Read-only view of Agent Bridge's documented INI pairing file (`~/.agent-bridge/config`).
///
/// Agent Bridge stays the owner of pairing, keys and endpoint policy; this mirrors its
/// `cfg_get`/`cfg_identity_file` rules exactly instead of inventing a second peer registry:
/// case-insensitive section names, first value wins, `identity_file` before legacy `key`,
/// and `internet_host`/`internet_port` replacing LAN `host`/`port` when configured
/// (Tailscale-first, no fallback). Values that could be parsed as SSH options are refused.
enum AgentBridgePeerDirectory {
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-bridge/config")
    }

    static let maximumConfigBytes = 256 * 1024

    static func endpoint(
        named name: String,
        configURL: URL = defaultConfigURL,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AgentBridgePeerEndpoint? {
        guard let data = try? Data(contentsOf: configURL),
              data.count <= maximumConfigBytes,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return endpoint(named: name, configText: text, homeDirectory: homeDirectory)
    }

    static func endpoint(
        named name: String,
        configText: String,
        homeDirectory: String
    ) -> AgentBridgePeerEndpoint? {
        guard PairedVoiceMuteSettings.isValidMachineName(name) else { return nil }
        let wanted = name.lowercased()
        var values: [String: String] = [:]
        var inSection = false
        // `isNewline`, not a "\n" separator: Swift treats CRLF as one Character, so a "\n" split
        // would leave a CRLF file as a single line and hide every pairing in it.
        for rawLine in configText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                inSection = line.dropFirst().dropLast().lowercased() == wanted
                continue
            }
            guard inSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            if values[key] == nil { values[key] = value }
        }

        let internetHost = values["internet_host"].flatMap { $0.isEmpty ? nil : $0 }
        let hostValue: String?
        let portValue: String?
        if let internetHost {
            hostValue = internetHost
            portValue = values["internet_port"]
        } else {
            hostValue = values["host"]
            portValue = values["port"]
        }
        guard let host = hostValue, isSafeHost(host),
              let user = values["user"], isSafeUser(user) else {
            return nil
        }
        let port: Int
        if let portValue, !portValue.isEmpty {
            guard let parsed = Int(portValue), (1...65_535).contains(parsed) else { return nil }
            port = parsed
        } else {
            port = 22
        }

        var identity: String?
        if let keyPath = [values["identity_file"], values["key"]]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }),
           keyPath != "(system default)" {
            // Same rule as Agent Bridge's `${keypath/#\~/$HOME}`: only a leading `~` expands.
            let expanded: String = keyPath.hasPrefix("~")
                ? homeDirectory + String(keyPath.dropFirst())
                : keyPath
            guard expanded.hasPrefix("/"),
                  !expanded.contains(where: { $0 == "\n" || $0 == "\0" }) else {
                return nil
            }
            identity = expanded
        }
        return AgentBridgePeerEndpoint(user: user, host: host, port: port, identityFile: identity)
    }

    private static func isSafeHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_%")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeUser(_ user: String) -> Bool {
        guard !user.isEmpty, user.count <= 64, !user.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return user.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Delivers one request over the recipient's existing Agent Bridge SSH pairing.
///
/// The remote side runs one constant command: the system `nc` connected to the recipient
/// Agent Flow's owner-only socket. The request travels on SSH stdin, so no request byte, name
/// or identifier is ever interpolated into a remote shell string or process arguments, and no
/// generic remote command can be expressed. This is a deterministic utility call over the
/// pairing; it is not an agent message and never wakes or spawns an agent.
struct AgentBridgePairedVoiceMuteTransport: PairedVoiceMuteTransport {
    static let sshExecutable = "/usr/bin/ssh"
    /// Bounded network timeouts, not padding: an unreachable Mac fails within these limits in
    /// the background and never delays recording, stop, paste or transcription.
    static let connectTimeoutSeconds = 5
    static let processDeadlineSeconds: TimeInterval = 10
    static let maximumOutputBytes = 8 * 1024

    /// `$HOME` is expanded by the recipient's own login shell for the paired account, which is
    /// the same home its Agent Flow binds under. `-w` bounds an idle socket on that side too.
    static let remoteCommand =
        "exec /usr/bin/nc -U -w 4 \"$HOME/\(PairedVoiceMuteReceiver.relativeSocketPath)\""

    private let configURL: URL

    init(configURL: URL = AgentBridgePeerDirectory.defaultConfigURL) {
        self.configURL = configURL
    }

    func send(
        _ request: PairedVoiceMuteRequest,
        to recipient: String
    ) async -> PairedVoiceMuteDelivery {
        let configURL = self.configURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: request.operation == .acquire ? .userInitiated : .utility).async {
                guard let endpoint = AgentBridgePeerDirectory.endpoint(
                    named: recipient,
                    configURL: configURL
                ) else {
                    continuation.resume(returning: .notPaired)
                    return
                }
                continuation.resume(returning: Self.run(
                    arguments: Self.sshArguments(for: endpoint),
                    input: request.encodedLine()
                ))
            }
        }
    }

    /// Mirrors Agent Bridge's own SSH options (host-key policy, identity, endpoint) and adds
    /// `BatchMode` so a GUI app can never block on a password or host prompt. The user's
    /// `~/.ssh/config` still applies, which keeps Agent Bridge's Tailscale proxy setup working.
    static func sshArguments(for endpoint: AgentBridgePeerEndpoint) -> [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-p", String(endpoint.port),
        ]
        if let identity = endpoint.identityFile {
            arguments += ["-i", identity, "-o", "IdentitiesOnly=yes"]
        }
        arguments += ["\(endpoint.user)@\(endpoint.host)", remoteCommand]
        return arguments
    }

    /// Same client-side connection-failure phrases Agent Bridge uses to decide a request never
    /// left this Mac. Anything else after a failed run is an unknown remote outcome.
    static func isConnectionFailure(_ stderr: String) -> Bool {
        [
            "ssh: connect to host",
            "ssh: Could not resolve hostname",
            "ssh_exchange_identification:",
            "kex_exchange_identification:",
            "Host key verification failed",
            "Permission denied (publickey",
            "No route to host",
            "Network is unreachable",
            "Name or service not known",
        ].contains { stderr.contains($0) }
    }

    static func classify(
        exitStatus: Int32,
        stdout: Data,
        stderr: String
    ) -> PairedVoiceMuteDelivery {
        if let response = PairedVoiceMuteResponse.decodeLastLine(from: stdout) {
            return .responded(response)
        }
        if exitStatus == 255, isConnectionFailure(stderr) {
            return .unreachable
        }
        return .noResponse(exitStatus: exitStatus)
    }

    private static func run(arguments: [String], input: Data) -> PairedVoiceMuteDelivery {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // A GUI app's PATH omits Homebrew, where a Tailscale `ProxyCommand` helper may live.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = PairedVoiceMuteBoundedBuffer(limit: maximumOutputBytes)
        let errorOutput = PairedVoiceMuteBoundedBuffer(limit: maximumOutputBytes)
        let drainGroup = DispatchGroup()
        drain(outputPipe.fileHandleForReading, into: output, group: drainGroup)
        drain(errorPipe.fileHandleForReading, into: errorOutput, group: drainGroup)

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            return .launchFailed
        }

        // The request is a few hundred bytes, well under the pipe buffer, so this write cannot
        // block on a remote side that never reads. `ssh` can already have exited, and this app
        // does not ignore SIGPIPE: without this flag a failed connection could terminate Agent
        // Flow mid-recording instead of returning an ordinary write error.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        try? inputPipe.fileHandleForWriting.close()

        guard termination.wait(timeout: .now() + processDeadlineSeconds) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 0.5)
            }
            _ = drainGroup.wait(timeout: .now() + 1)
            return .timedOut
        }
        _ = drainGroup.wait(timeout: .now() + 1)
        // stderr is used only to classify the failure and is then discarded: SSH diagnostics
        // can contain the paired host, user or key path.
        return classify(
            exitStatus: process.terminationStatus,
            stdout: output.data(),
            stderr: String(data: errorOutput.data(), encoding: .utf8) ?? ""
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: PairedVoiceMuteBoundedBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
            }
        }
    }
}

/// Keeps only the first `limit` bytes but keeps draining, so a chatty remote shell can neither
/// grow memory without bound nor stall SSH on a full pipe.
private final class PairedVoiceMuteBoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = limit - storage.count
        guard room > 0 else { return }
        storage.append(chunk.prefix(room))
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
