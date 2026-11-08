import Foundation

// Paired-Mac Voice microphone suppression.
//
// When Agent Flow opens its microphone on one Mac (the *source*), the same ChatGPT Voice
// microphone suppression can be requested on explicitly configured paired Macs (the
// *recipients*). Each recipient runs its own Agent Flow, which already owns the Accessibility
// permission and the accepted local coordinator, so the remote side reuses that exact
// mechanism instead of a new permission owner, an agent message, or a spawned agent.
//
// Transport is Agent Bridge's existing authenticated SSH pairing (see
// `AgentBridgePairedVoiceMuteTransport`). This file holds only the wire format, the
// recipient-side ownership ledger and the per-machine settings; none of it touches ChatGPT.
//
// Long-form setup, limits and verification live in PAIRED_VOICE_MUTE.md.

/// Explicit per-machine configuration. Both values default to off/empty so an unconfigured
/// Agent Flow never contacts another Mac and never accepts a request from one.
enum PairedVoiceMuteSettings {
    /// Agent Bridge machine names (sections in `~/.agent-bridge/config`) that should mute
    /// their ChatGPT Voice microphone while this Mac captures speech. Explicit recipients
    /// only: Agent Flow never broadcasts to every pairing, because a pairing can be another
    /// OS, an alias of a Mac already listed, or a machine the user did not mean to control.
    static let recipientsKey = "VIPPPairedVoiceMuteRecipients"
    /// Opt-in for this Mac to accept requests from paired Macs. Release is always accepted
    /// so a source can end a lease after the user turns this off; acquire and renew are not.
    static let receiverEnabledKey = "VIPPPairedVoiceMuteReceiverEnabled"
    static let maximumRecipients = 8
    /// Mirrors Agent Bridge's reserved same-machine aliases. SSH loopback is pointless and
    /// Agent Bridge itself rejects `run` against them.
    static let reservedLocalAliases: Set<String> = ["local", "self", "localhost"]

    static func recipients(defaults: UserDefaults = .standard) -> [String] {
        let raw: [String]
        switch defaults.object(forKey: recipientsKey) {
        case let names as [String]:
            raw = names
        case let text as String:
            raw = text
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        default:
            raw = []
        }
        return normalizedRecipients(raw)
    }

    static func receiverEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: receiverEnabledKey)
    }

    /// Case-insensitive de-duplication matches Agent Bridge's case-insensitive section lookup.
    static func normalizedRecipients(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in raw {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard isValidMachineName(name),
                  !reservedLocalAliases.contains(key),
                  seen.insert(key).inserted else { continue }
            result.append(name)
            if result.count == maximumRecipients { break }
        }
        return result
    }

    static func isValidMachineName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-") else { return false }
        let punctuation = CharacterSet(charactersIn: "._-")
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || punctuation.contains($0)
        }
    }
}

/// One capture-ownership message from a source Agent Flow.
///
/// `source` is a random identifier minted once per source app launch, and `sequence` is
/// strictly increasing within it in the order the source's capture intents occurred. The
/// recipient therefore orders duplicate, retried, or reordered SSH deliveries without
/// trusting either Mac's wall clock: the highest-sequence message per source wins.
/// `session` identifies one local capture lease (start/resume until pause/stop).
struct PairedVoiceMuteRequest: Equatable, Sendable {
    enum Operation: String, Sendable {
        /// A new capture began on the source. The only message that may post a mute.
        case acquire
        /// The same capture is still live; extends the lease without any ChatGPT read or input.
        case renew
        /// The source's capture paused or stopped.
        case release
    }

    static let protocolVersion = 1
    static let maximumEncodedBytes = 512
    /// A vanished source (sleep, network loss, crash) must not hold a recipient's Voice muted
    /// forever. The source renews every third of this while capture is live.
    static let defaultLeaseSeconds = 90
    static let leaseSecondsRange = 15...300

    let operation: Operation
    let source: String
    let sequence: UInt64
    let session: String
    let leaseSeconds: Int

    init(
        operation: Operation,
        source: String,
        sequence: UInt64,
        session: String,
        leaseSeconds: Int = PairedVoiceMuteRequest.defaultLeaseSeconds
    ) {
        self.operation = operation
        self.source = source.lowercased()
        self.sequence = sequence
        self.session = session.lowercased()
        self.leaseSeconds = min(
            max(leaseSeconds, Self.leaseSecondsRange.lowerBound),
            Self.leaseSecondsRange.upperBound
        )
    }

    var owner: PairedVoiceMuteOwner {
        PairedVoiceMuteOwner(source: source, session: session)
    }

    func encodedLine() -> Data {
        let wire = PairedVoiceMuteWireRequest(
            v: Self.protocolVersion,
            op: operation.rawValue,
            source: source,
            seq: sequence,
            session: session,
            lease: leaseSeconds
        )
        var data = (try? JSONEncoder().encode(wire)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Everything a recipient socket accepts. `status` is a side-effect-free readiness probe for
/// setup verification: it never reads ChatGPT, never touches the ledger and never posts input.
enum PairedVoiceMuteMessage: Equatable, Sendable {
    case lease(PairedVoiceMuteRequest)
    case status

    static func decode(line: Data) -> PairedVoiceMuteMessage? {
        guard !line.isEmpty, line.count <= PairedVoiceMuteRequest.maximumEncodedBytes,
              let wire = try? JSONDecoder().decode(PairedVoiceMuteWireRequest.self, from: line),
              wire.v == PairedVoiceMuteRequest.protocolVersion else {
            return nil
        }
        if wire.op == "status" { return .status }
        guard let operation = PairedVoiceMuteRequest.Operation(rawValue: wire.op),
              let source = wire.source, UUID(uuidString: source) != nil,
              let session = wire.session, UUID(uuidString: session) != nil,
              let sequence = wire.seq, sequence > 0 else {
            return nil
        }
        return .lease(PairedVoiceMuteRequest(
            operation: operation,
            source: source,
            sequence: sequence,
            session: session,
            leaseSeconds: wire.lease ?? PairedVoiceMuteRequest.defaultLeaseSeconds
        ))
    }

    static func statusLine() -> Data {
        var data = (try? JSONEncoder().encode(PairedVoiceMuteWireRequest(
            v: PairedVoiceMuteRequest.protocolVersion,
            op: "status",
            source: nil,
            seq: nil,
            session: nil,
            lease: nil
        ))) ?? Data()
        data.append(0x0A)
        return data
    }
}

private struct PairedVoiceMuteWireRequest: Codable {
    let v: Int
    let op: String
    let source: String?
    let seq: UInt64?
    let session: String?
    let lease: Int?
}

/// The recipient's answer. `detail` is restricted to fixed vocabulary (outcome enum raw
/// values or a short rejection reason); it never carries ChatGPT labels, paths or identities.
struct PairedVoiceMuteResponse: Equatable, Sendable {
    enum Status: String, Sendable {
        case acquired
        case renewed
        case released
        /// Not newer than the last message from that source: a duplicate or late delivery.
        case stale
        /// Renew/release for a session the recipient does not hold (already ended, expired,
        /// replaced, or the recipient restarted). Never a reason for the source to re-acquire.
        case unknownSession
        case disabled
        case rejected
        case ready
    }

    let status: Status
    let detail: String?

    init(status: Status, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    func encodedLine() -> Data {
        var data = (try? JSONEncoder().encode(Wire(
            v: PairedVoiceMuteRequest.protocolVersion,
            status: status.rawValue,
            detail: detail
        ))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// A remote login shell may print unrelated text before the helper runs. Accept only
    /// the last line that is a complete response in this protocol version.
    static func decodeLastLine(from output: Data) -> PairedVoiceMuteResponse? {
        let lines = output.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.count <= PairedVoiceMuteRequest.maximumEncodedBytes,
                  let wire = try? JSONDecoder().decode(Wire.self, from: Data(line)),
                  wire.v == PairedVoiceMuteRequest.protocolVersion,
                  let status = Status(rawValue: wire.status) else { continue }
            return PairedVoiceMuteResponse(status: status, detail: wire.detail)
        }
        return nil
    }

    private struct Wire: Codable {
        let v: Int
        let status: String
        let detail: String?
    }
}

/// One paired capture owner as seen by a recipient's coordinator.
struct PairedVoiceMuteOwner: Hashable, Sendable {
    let source: String
    let session: String
}

/// Recipient-side ordering and lease bookkeeping. Pure value logic with no ChatGPT access so
/// every race is testable without a live Voice session.
///
/// Each source has at most one live session, matching the source coordinator's single local
/// lease: a newer acquire from that source replaces its older session rather than stacking a
/// second owner. A source that disappears without release is cleaned up by lease expiry.
struct PairedVoiceMuteLedger {
    struct Lease: Equatable, Sendable {
        let session: String
        /// Bumped on every acquire/renew so an expiry timer armed for an older lease can
        /// never end a renewed one.
        let generation: UInt64
        let seconds: Int
    }

    enum Decision: Equatable {
        case acquired(PairedVoiceMuteOwner, replacing: PairedVoiceMuteOwner?, lease: Lease)
        case renewed(PairedVoiceMuteOwner, lease: Lease)
        case released(PairedVoiceMuteOwner)
        case stale
        case unknownSession
        case capacityExceeded
    }

    private struct SourceRecord {
        var lastSequence: UInt64
        var lease: Lease?
        var lastActivity: TimeInterval
    }

    static let maximumSources = 16
    /// Remembering an idle source's last sequence only needs to outlive a delayed SSH delivery
    /// (bounded by the source's process deadline), not the app's lifetime.
    static let idleSourceRetention: TimeInterval = 600

    private var sources: [String: SourceRecord] = [:]
    private var nextGeneration: UInt64 = 0

    var activeOwners: [PairedVoiceMuteOwner] {
        sources.compactMap { source, record in
            record.lease.map { PairedVoiceMuteOwner(source: source, session: $0.session) }
        }
    }

    mutating func apply(_ request: PairedVoiceMuteRequest, now: TimeInterval) -> Decision {
        prune(now: now)
        var record: SourceRecord
        if let existing = sources[request.source] {
            // Duplicate SSH retries and reordered deliveries are both "not newer". Dropping
            // them is what keeps a late release from undoing a newer capture and a late
            // acquire from muting after its own release.
            guard request.sequence > existing.lastSequence else { return .stale }
            record = existing
        } else {
            guard sources.count < Self.maximumSources else { return .capacityExceeded }
            // Remember even a release/renew from an unknown source: its acquire may still be
            // in flight, and must then be rejected as older.
            record = SourceRecord(lastSequence: 0, lease: nil, lastActivity: now)
        }
        record.lastSequence = request.sequence
        record.lastActivity = now
        defer { sources[request.source] = record }

        let owner = request.owner
        switch request.operation {
        case .acquire:
            let previous = record.lease
            nextGeneration &+= 1
            let lease = Lease(
                session: request.session,
                generation: nextGeneration,
                seconds: request.leaseSeconds
            )
            record.lease = lease
            if previous?.session == request.session {
                // The same capture can arrive twice through two Agent Bridge aliases of one
                // Mac. Treat the second as a renewal so it never re-attempts suppression.
                return .renewed(owner, lease: lease)
            }
            return .acquired(
                owner,
                replacing: previous.map {
                    PairedVoiceMuteOwner(source: request.source, session: $0.session)
                },
                lease: lease
            )
        case .renew:
            guard let current = record.lease, current.session == request.session else {
                return .unknownSession
            }
            nextGeneration &+= 1
            let lease = Lease(
                session: current.session,
                generation: nextGeneration,
                seconds: request.leaseSeconds
            )
            record.lease = lease
            return .renewed(owner, lease: lease)
        case .release:
            guard let current = record.lease, current.session == request.session else {
                return .unknownSession
            }
            record.lease = nil
            return .released(owner)
        }
    }

    /// Ends a lease only if no acquire/renew superseded the timer that fired.
    mutating func expire(source: String, generation: UInt64) -> PairedVoiceMuteOwner? {
        guard var record = sources[source],
              let lease = record.lease,
              lease.generation == generation else {
            return nil
        }
        record.lease = nil
        sources[source] = record
        return PairedVoiceMuteOwner(source: source, session: lease.session)
    }

    mutating func prune(now: TimeInterval) {
        sources = sources.filter { _, record in
            record.lease != nil || now - record.lastActivity < Self.idleSourceRetention
        }
    }

    var sourceCountForTesting: Int { sources.count }
}

/// A cancellable one-shot timer used for recipient lease expiry and source renewal.
/// Neither is a user-path delay: recording start, stop, paste and transcription never wait
/// on it. Injected so tests can fire expiries deterministically.
struct PairedVoiceMuteScheduledTimer: Sendable {
    let cancel: @Sendable () -> Void
}

protocol PairedVoiceMuteLeaseTimer: Sendable {
    func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @Sendable () async -> Void
    ) -> PairedVoiceMuteScheduledTimer
}

struct TaskPairedVoiceMuteLeaseTimer: PairedVoiceMuteLeaseTimer {
    func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @Sendable () async -> Void
    ) -> PairedVoiceMuteScheduledTimer {
        let task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            } catch {
                return
            }
            await action()
        }
        return PairedVoiceMuteScheduledTimer(cancel: { task.cancel() })
    }
}
