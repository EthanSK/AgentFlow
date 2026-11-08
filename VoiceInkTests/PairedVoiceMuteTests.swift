import Darwin
import Foundation
import Testing
@testable import VoiceInkPlusPlus

// Generic fixtures only: documentation addresses (RFC 5737 / RFC 6598), example users and
// made-up machine names. Never put a real pairing, host, user or key path in this file.

private let sourceA = "11111111-1111-4111-8111-111111111111"
private let sourceB = "22222222-2222-4222-8222-222222222222"
private let session1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
private let session2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
private let sessionB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"

private func request(
    _ operation: PairedVoiceMuteRequest.Operation,
    _ source: String,
    _ sequence: UInt64,
    _ session: String
) -> PairedVoiceMuteRequest {
    PairedVoiceMuteRequest(operation: operation, source: source, sequence: sequence, session: session)
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

/// Same observable model as the local coordinator tests' fake, plus a snapshot counter so a
/// renew can be proven not to read ChatGPT state.
private actor PairedFakeVoiceTransport: ChatGPTVoiceMuteTransport {
    private var currentSnapshot: ChatGPTVoiceInputSnapshot?
    private var posts: [pid_t] = []
    private var authorities: [ChatGPTVoiceShortcutAuthority] = []
    private let refusedAuthority: ChatGPTVoiceShortcutAuthority?
    private var snapshots = 0
    private var holdRestoration = false
    private var restorationContinuation: CheckedContinuation<Void, Never>?

    init(
        snapshot: ChatGPTVoiceInputSnapshot?,
        refusing refusedAuthority: ChatGPTVoiceShortcutAuthority? = nil
    ) {
        currentSnapshot = snapshot
        self.refusedAuthority = refusedAuthority
    }

    func snapshot() async -> ChatGPTVoiceInputSnapshot? {
        snapshots += 1
        return currentSnapshot
    }

    func postMicrophoneToggle(
        to applicationPID: pid_t,
        using authority: ChatGPTVoiceShortcutAuthority
    ) async -> Bool {
        authorities.append(authority)
        guard authority != refusedAuthority else { return false }
        posts.append(applicationPID)
        if posts.count == 2, holdRestoration {
            await withCheckedContinuation { restorationContinuation = $0 }
        }
        if let currentSnapshot, currentSnapshot.applicationPID == applicationPID {
            self.currentSnapshot = ChatGPTVoiceInputSnapshot(
                applicationPID: applicationPID,
                isInputRunning: currentSnapshot.isInputRunning,
                microphoneState: currentSnapshot.microphoneState.map {
                    $0 == .listening ? .muted : .listening
                }
            )
        }
        return true
    }

    func waitForMicrophoneState(
        _ microphoneState: ChatGPTVoiceMicrophoneState,
        applicationPID: pid_t
    ) async -> Bool {
        currentSnapshot?.applicationPID == applicationPID
            && currentSnapshot?.microphoneState == microphoneState
    }

    func postedPIDs() -> [pid_t] { posts }
    func usedAuthorities() -> [ChatGPTVoiceShortcutAuthority] { authorities }
    func snapshotCount() -> Int { snapshots }
    func microphoneState() -> ChatGPTVoiceMicrophoneState? { currentSnapshot?.microphoneState }
    func blockRestoration() { holdRestoration = true }
    func restorationIsWaiting() -> Bool { restorationContinuation != nil }
    func allowRestoration() {
        holdRestoration = false
        restorationContinuation?.resume()
        restorationContinuation = nil
    }
}

struct PairedVoiceMuteActivityTests {
    @Test func admissionAndIdleQuitCannotBothWin() throws {
        let running = PairedVoiceMuteActivity()
        let operation = try #require(running.beginOperation())
        #expect(running.hasWork)
        #expect(!running.closeIfIdle())
        running.finishOperation(operation)
        #expect(!running.hasWork)
        #expect(running.closeIfIdle())
        #expect(running.beginOperation() == nil)

        let closing = PairedVoiceMuteActivity()
        #expect(closing.closeIfIdle())
        #expect(closing.beginOperation() == nil)
        #expect(!closing.hasWork)
    }

    @Test func outboundCompletionCannotClearRecipientOwnership() throws {
        let activity = PairedVoiceMuteActivity()
        let acquire = try #require(activity.beginOperation())
        activity.finishOperation(acquire, remoteCaptureActive: true)
        let outbound = try #require(activity.beginOperation())
        activity.finishOperation(outbound)
        #expect(activity.hasWork)
        #expect(!activity.closeIfIdle())
        // Repeated/stale completion cannot accidentally clear a later capture owner.
        activity.finishOperation(acquire, remoteCaptureActive: false)
        #expect(activity.hasWork)
        let release = try #require(activity.beginOperation())
        activity.finishOperation(release, remoteCaptureActive: false)
        #expect(activity.closeIfIdle())
    }

    @Test func recipientQuitWaitsThroughTheFinalRestorationNotJustLedgerRemoval() async throws {
        let activity = PairedVoiceMuteActivity()
        let transport = PairedFakeVoiceTransport(snapshot: ChatGPTVoiceInputSnapshot(
            applicationPID: 4_242, isInputRunning: true, microphoneState: .listening
        ))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer(), pairedActivity: activity
        )
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(activity.hasWork)
        #expect(!activity.closeIfIdle())
        await transport.blockRestoration()
        let release = Task { await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1)) }
        for _ in 0..<400 {
            if await transport.restorationIsWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let isWaiting = await transport.restorationIsWaiting()
        #expect(isWaiting)
        #expect(activity.hasWork)
        #expect(!activity.closeIfIdle())
        await transport.allowRestoration()
        #expect(await release.value.detail == "restoredVerified")
        #expect(!activity.hasWork)
        #expect(activity.closeIfIdle())
        let denied = await coordinator.handlePairedRequest(request(.acquire, sourceA, 3, session2))
        #expect(denied == PairedVoiceMuteResponse(status: .rejected, detail: "shuttingDown"))
        #expect(await transport.postedPIDs() == [4_242, 4_242])
    }

    @Test func expiryReleasesQuitProtectionAfterItsOwnedRestoration() async {
        let activity = PairedVoiceMuteActivity()
        let timer = ManualPairedTimer()
        let transport = PairedFakeVoiceTransport(snapshot: ChatGPTVoiceInputSnapshot(
            applicationPID: 4_242, isInputRunning: true, microphoneState: .listening
        ))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: timer, pairedActivity: activity
        )
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(!activity.closeIfIdle())
        await timer.fireLive()
        #expect(!activity.hasWork)
        #expect(activity.closeIfIdle())
        #expect(await transport.postedPIDs() == [4_242, 4_242])
    }
}

/// Deterministic stand-in for lease expiry and renewal deadlines.
private final class ManualPairedTimer: PairedVoiceMuteLeaseTimer, @unchecked Sendable {
    private struct Entry {
        let seconds: TimeInterval
        let action: @Sendable () async -> Void
        var live: Bool
        var fired: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @Sendable () async -> Void
    ) -> PairedVoiceMuteScheduledTimer {
        lock.lock()
        let index = entries.count
        entries.append(Entry(seconds: seconds, action: action, live: true, fired: false))
        lock.unlock()
        return PairedVoiceMuteScheduledTimer(cancel: { [weak self] in self?.cancel(index) })
    }

    private func cancel(_ index: Int) {
        lock.lock()
        entries[index].live = false
        lock.unlock()
    }

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.live && !$0.fired }.count
    }

    var lastScheduledSeconds: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last?.seconds
    }

    /// Fires every armed, uncancelled deadline as if it elapsed.
    func fireLive() async {
        await fire { $0.live }
    }

    /// Fires deadlines that were cancelled, modelling a timer task already past its sleep when
    /// cancellation arrived. Whatever it calls must be a no-op.
    func fireCancelled() async {
        await fire { !$0.live }
    }

    private func fire(where include: (Entry) -> Bool) async {
        lock.lock()
        var due: [@Sendable () async -> Void] = []
        for index in entries.indices where !entries[index].fired && include(entries[index]) {
            entries[index].fired = true
            due.append(entries[index].action)
        }
        lock.unlock()
        for action in due { await action() }
    }
}

private final class RecordingFanOut: PairedVoiceMuteFanOut, @unchecked Sendable {
    enum Event: Equatable {
        case began(UInt64)
        case ended(UInt64)
    }

    private let box = LockedBox<[Event]>([])

    func captureBegan(localLeaseID: UInt64) { box.mutate { $0.append(.began(localLeaseID)) } }
    func captureEnded(localLeaseID: UInt64) { box.mutate { $0.append(.ended(localLeaseID)) } }
    var events: [Event] { box.get() }
}

private final class RecordingPairedTransport: PairedVoiceMuteTransport, @unchecked Sendable {
    private let box = LockedBox<[(recipient: String, request: PairedVoiceMuteRequest)]>([])

    func send(
        _ request: PairedVoiceMuteRequest,
        to recipient: String
    ) async -> PairedVoiceMuteDelivery {
        box.mutate { $0.append((recipient: recipient, request: request)) }
        return .responded(PairedVoiceMuteResponse(status: .acquired))
    }

    var count: Int { box.get().count }

    /// Arrival order of detached sends is not deterministic; sequence order is the contract.
    var deliveries: [(recipient: String, request: PairedVoiceMuteRequest)] {
        box.get().sorted { $0.request.sequence < $1.request.sequence }
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct PairedVoiceMuteLedgerTests {
    @Test func ledgerOrdersEachSourceBySequenceAndDropsLateOrDuplicateDeliveries() throws {
        var ledger = PairedVoiceMuteLedger()
        let owner = PairedVoiceMuteOwner(source: sourceA, session: session1)

        guard case .acquired(let acquired, let replaced, let lease) = ledger.apply(
            request(.acquire, sourceA, 1, session1), now: 0
        ) else {
            Issue.record("first acquire must be admitted")
            return
        }
        #expect(acquired == owner)
        #expect(replaced == nil)
        #expect(lease.seconds == PairedVoiceMuteRequest.defaultLeaseSeconds)

        #expect(ledger.apply(request(.acquire, sourceA, 1, session1), now: 1) == .stale)
        #expect(ledger.apply(request(.release, sourceA, 2, session2), now: 2) == .unknownSession)
        #expect(ledger.apply(request(.release, sourceA, 3, session1), now: 3) == .released(owner))
        #expect(ledger.apply(request(.renew, sourceA, 4, session1), now: 4) == .unknownSession)
        #expect(ledger.activeOwners.isEmpty)

        // A release can overtake its own acquire over two SSH connections. The late acquire is
        // older than what the source already said, so it must never mute.
        #expect(ledger.apply(request(.release, sourceB, 2, sessionB), now: 5) == .unknownSession)
        #expect(ledger.apply(request(.acquire, sourceB, 1, sessionB), now: 6) == .stale)
        #expect(ledger.activeOwners.isEmpty)
    }

    @Test func newerSessionReplacesTheOlderOneAndASecondAliasDeliveryIsOnlyARenewal() {
        var ledger = PairedVoiceMuteLedger()
        _ = ledger.apply(request(.acquire, sourceA, 1, session1), now: 0)

        // The same capture reaching this Mac through a second Agent Bridge alias.
        guard case .renewed = ledger.apply(request(.acquire, sourceA, 2, session1), now: 1) else {
            Issue.record("same-session acquire must not re-attempt suppression")
            return
        }
        guard case .acquired(_, let replaced, _) = ledger.apply(
            request(.acquire, sourceA, 3, session2), now: 2
        ) else {
            Issue.record("newer session must be admitted")
            return
        }
        #expect(replaced == PairedVoiceMuteOwner(source: sourceA, session: session1))
        #expect(ledger.activeOwners == [PairedVoiceMuteOwner(source: sourceA, session: session2)])
        #expect(ledger.apply(request(.release, sourceA, 4, session1), now: 3) == .unknownSession)
        #expect(ledger.activeOwners.count == 1)
    }

    @Test func expiryEndsOnlyTheCurrentLeaseGeneration() throws {
        var ledger = PairedVoiceMuteLedger()
        guard case .acquired(let owner, _, let first) = ledger.apply(
            request(.acquire, sourceA, 1, session1), now: 0
        ), case .renewed(_, let renewed) = ledger.apply(
            request(.renew, sourceA, 2, session1), now: 30
        ) else {
            Issue.record("acquire and renew must be admitted")
            return
        }
        #expect(first.generation != renewed.generation)
        #expect(ledger.expire(source: sourceA, generation: first.generation) == nil)
        #expect(ledger.activeOwners == [owner])
        #expect(ledger.expire(source: sourceA, generation: renewed.generation) == owner)
        #expect(ledger.activeOwners.isEmpty)
        #expect(ledger.apply(request(.release, sourceA, 3, session1), now: 31) == .unknownSession)
    }

    @Test func trackedSourcesAreBoundedAndOnlyIdleOnesArePruned() {
        var ledger = PairedVoiceMuteLedger()
        let sources = (0..<PairedVoiceMuteLedger.maximumSources).map { _ in
            UUID().uuidString.lowercased()
        }
        for source in sources {
            guard case .acquired = ledger.apply(request(.acquire, source, 1, session1), now: 0) else {
                Issue.record("acquire within capacity must be admitted")
                return
            }
        }
        let extra = UUID().uuidString.lowercased()
        #expect(ledger.apply(request(.acquire, extra, 1, session1), now: 1) == .capacityExceeded)

        for source in sources.dropFirst() {
            _ = ledger.apply(request(.release, source, 2, session1), now: 2)
        }
        let later = 2 + PairedVoiceMuteLedger.idleSourceRetention + 1
        guard case .acquired = ledger.apply(request(.acquire, extra, 1, session1), now: later) else {
            Issue.record("idle sources must be pruned to admit a new one")
            return
        }
        // The one source still holding a lease survives pruning.
        #expect(ledger.sourceCountForTesting == 2)
        #expect(ledger.activeOwners.count == 2)
    }
}

struct PairedVoiceMuteWireTests {
    @Test func requestRoundTripsLowercasesIdentifiersAndClampsTheLease() {
        let long = PairedVoiceMuteRequest(
            operation: .acquire,
            source: sourceA.uppercased(),
            sequence: 7,
            session: session1.uppercased(),
            leaseSeconds: 5_000
        )
        #expect(long.source == sourceA)
        #expect(long.session == session1)
        #expect(long.leaseSeconds == PairedVoiceMuteRequest.leaseSecondsRange.upperBound)
        let line = long.encodedLine()
        #expect(line.last == 0x0A)
        #expect(PairedVoiceMuteMessage.decode(line: Data(line.dropLast())) == .lease(long))

        let short = PairedVoiceMuteRequest(
            operation: .renew, source: sourceA, sequence: 8, session: session1, leaseSeconds: 1
        )
        #expect(short.leaseSeconds == PairedVoiceMuteRequest.leaseSecondsRange.lowerBound)
        #expect(PairedVoiceMuteMessage.decode(line: Data(PairedVoiceMuteMessage.statusLine().dropLast())) == .status)
    }

    @Test func malformedOrForeignRequestsAreRejected() {
        let lines = [
            #"{"v":2,"op":"acquire","source":"\#(sourceA)","seq":1,"session":"\#(session1)"}"#,
            #"{"v":1,"op":"mute","source":"\#(sourceA)","seq":1,"session":"\#(session1)"}"#,
            #"{"v":1,"op":"acquire","source":"not-a-uuid","seq":1,"session":"\#(session1)"}"#,
            #"{"v":1,"op":"acquire","source":"\#(sourceA)","seq":0,"session":"\#(session1)"}"#,
            #"{"v":1,"op":"acquire","source":"\#(sourceA)","seq":1}"#,
            #"{"v":1,"op":"release","source":"\#(sourceA)","seq":-1,"session":"\#(session1)"}"#,
            "not json",
            "",
            #"{"v":1,"op":"acquire","source":"\#(sourceA)","seq":1,"session":"\#(session1)","pad":""#
                + String(repeating: "x", count: 600) + #""}"#,
        ]
        for line in lines {
            #expect(PairedVoiceMuteMessage.decode(line: Data(line.utf8)) == nil, "\(line.prefix(60))")
        }
    }

    @Test func sourceAcceptsOnlyTheLastCompleteResponseLine() {
        let response = PairedVoiceMuteResponse(status: .released, detail: "restoredUnverified")
        var output = Data("Last login: shell noise\n".utf8)
        output.append(response.encodedLine())
        #expect(PairedVoiceMuteResponse.decodeLastLine(from: output) == response)
        #expect(PairedVoiceMuteResponse.decodeLastLine(from: Data("garbage\n".utf8)) == nil)
        #expect(PairedVoiceMuteResponse.decodeLastLine(
            from: Data(#"{"v":1,"status":"muted"}"#.utf8)
        ) == nil)
        #expect(PairedVoiceMuteResponse.decodeLastLine(
            from: Data(#"{"v":2,"status":"acquired"}"#.utf8)
        ) == nil)
    }
}

struct PairedVoiceMuteConfigurationTests {
    @Test func recipientsAreExplicitDeduplicatedValidatedAndBounded() throws {
        let suite = "vipp-paired-voice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Off by default in both directions.
        #expect(PairedVoiceMuteSettings.recipients(defaults: defaults).isEmpty)
        #expect(!PairedVoiceMuteSettings.receiverEnabled(defaults: defaults))

        defaults.set(
            ["Studio-Mac", "studio-mac", "LOCAL", "self", "-oProxyCommand=x", "has space", "Travel.Mac", ""],
            forKey: PairedVoiceMuteSettings.recipientsKey
        )
        #expect(PairedVoiceMuteSettings.recipients(defaults: defaults) == ["Studio-Mac", "Travel.Mac"])

        defaults.set("Studio-Mac, Travel-Mac", forKey: PairedVoiceMuteSettings.recipientsKey)
        #expect(PairedVoiceMuteSettings.recipients(defaults: defaults) == ["Studio-Mac", "Travel-Mac"])

        defaults.set((0..<12).map { "Mac-\($0)" }, forKey: PairedVoiceMuteSettings.recipientsKey)
        #expect(PairedVoiceMuteSettings.recipients(defaults: defaults).count
            == PairedVoiceMuteSettings.maximumRecipients)
    }

    @Test func agentBridgePairingsResolveExactlyAsAgentBridgeSelectsEndpoints() {
        let config = """
        [Studio-Mac]\r
        host=192.0.2.10\r
        user=example\r
        port=22\r
        key=~/.agent-bridge/keys/agent-bridge_Studio-Mac\r
        identity_file=~/.agent-bridge/keys/agent-bridge_Studio-Mac\r
        paired_at=2026-01-01T00:00:00Z\r
        \r
        [Travel-Mac]
        host=192.0.2.20
        user=example
        port=22
        key=/Users/example/.agent-bridge/keys/travel
        internet_host=100.64.0.20
        internet_port=2222

        [No-Port]
        host=studio.example.test
        user=example
        key=(system default)
        """
        let home = "/Users/example"
        #expect(AgentBridgePeerDirectory.endpoint(named: "studio-mac", configText: config, homeDirectory: home)
            == AgentBridgePeerEndpoint(
                user: "example", host: "192.0.2.10", port: 22,
                identityFile: "/Users/example/.agent-bridge/keys/agent-bridge_Studio-Mac"
            ))
        // internet_host replaces LAN host and port: Agent Bridge's Tailscale-first rule.
        #expect(AgentBridgePeerDirectory.endpoint(named: "Travel-Mac", configText: config, homeDirectory: home)
            == AgentBridgePeerEndpoint(
                user: "example", host: "100.64.0.20", port: 2222,
                identityFile: "/Users/example/.agent-bridge/keys/travel"
            ))
        #expect(AgentBridgePeerDirectory.endpoint(named: "No-Port", configText: config, homeDirectory: home)
            == AgentBridgePeerEndpoint(user: "example", host: "studio.example.test", port: 22, identityFile: nil))
        #expect(AgentBridgePeerDirectory.endpoint(named: "Missing", configText: config, homeDirectory: home) == nil)
    }

    @Test func crlfConfigStillFindsItsPairing() {
        let config = "[Studio-Mac]\r\nhost=192.0.2.10\r\nuser=example\r\nport=22\r\n"
        #expect(AgentBridgePeerDirectory.endpoint(
            named: "Studio-Mac", configText: config, homeDirectory: "/Users/example"
        ) == AgentBridgePeerEndpoint(user: "example", host: "192.0.2.10", port: 22, identityFile: nil))
    }

    @Test func unsafeOrIncompletePairingsAreRefusedBeforeSSHRuns() {
        let config = """
        [Option-Host]
        host=-oProxyCommand=touch /tmp/x
        user=example

        [Option-User]
        host=192.0.2.30
        user=-lroot

        [Bad-Port]
        host=192.0.2.31
        user=example
        port=99999

        [No-User]
        host=192.0.2.32

        [Relative-Key]
        host=192.0.2.33
        user=example
        key=keys/relative

        [Spaced-Host]
        host=192.0.2.34 -p 1
        user=example
        """
        for name in ["Option-Host", "Option-User", "Bad-Port", "No-User", "Relative-Key", "Spaced-Host", "-bad"] {
            #expect(AgentBridgePeerDirectory.endpoint(
                named: name, configText: config, homeDirectory: "/Users/example"
            ) == nil, "\(name)")
        }
    }

    @Test func sshCarriesTheRequestOnlyOnStdinWithAConstantRemoteCommand() {
        let endpoint = AgentBridgePeerEndpoint(
            user: "example", host: "192.0.2.10", port: 2222,
            identityFile: "/Users/example/.agent-bridge/keys/k"
        )
        let arguments = AgentBridgePairedVoiceMuteTransport.sshArguments(for: endpoint)
        #expect(arguments.first == "-T")
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ConnectTimeout=\(AgentBridgePairedVoiceMuteTransport.connectTimeoutSeconds)"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.firstIndex(of: "-p").map { arguments[$0 + 1] } == "2222")
        #expect(Array(arguments.suffix(2)) == [
            "example@192.0.2.10",
            AgentBridgePairedVoiceMuteTransport.remoteCommand,
        ])
        #expect(AgentBridgePairedVoiceMuteTransport.remoteCommand
            == #"exec /usr/bin/nc -U -w 4 "$HOME/Library/Application Support/VoiceInkPlusPlus/VoiceMute/v.sock""#)

        let sample = request(.acquire, sourceA, 1, session1)
        #expect(!arguments.contains { $0.contains(sample.session) || $0.contains(sample.source) })

        let noKey = AgentBridgePairedVoiceMuteTransport.sshArguments(for: AgentBridgePeerEndpoint(
            user: "example", host: "192.0.2.10", port: 22, identityFile: nil
        ))
        #expect(!noKey.contains("-i"))
        #expect(PairedVoiceMuteReceiver.defaultSocketPath.utf8.count < 104)
    }

    @Test func deliveryClassificationNeverReportsAnUnansweredRequestAsSuccess() {
        let answered = PairedVoiceMuteResponse(status: .acquired, detail: "mutedUnverified")
        #expect(AgentBridgePairedVoiceMuteTransport.classify(
            exitStatus: 0, stdout: answered.encodedLine(), stderr: ""
        ) == .responded(answered))
        #expect(AgentBridgePairedVoiceMuteTransport.classify(
            exitStatus: 255, stdout: Data(),
            stderr: "ssh: connect to host 192.0.2.10 port 22: Operation timed out"
        ) == .unreachable)
        // Exit 255 without a client connection phrase may be the remote side; outcome unknown.
        #expect(AgentBridgePairedVoiceMuteTransport.classify(
            exitStatus: 255, stdout: Data(), stderr: "something else"
        ) == .noResponse(exitStatus: 255))
        // Old Agent Flow, quit app, or another OS: no socket answer.
        #expect(AgentBridgePairedVoiceMuteTransport.classify(
            exitStatus: 1, stdout: Data("'exec' is not recognized\n".utf8), stderr: ""
        ) == .noResponse(exitStatus: 1))
    }
}

struct PairedVoiceMuteBroadcasterTests {
    @Test func anUnconfiguredMacNeverContactsAnotherMac() async throws {
        let transport = RecordingPairedTransport()
        let timer = ManualPairedTimer()
        let broadcaster = PairedVoiceMuteBroadcaster(
            sourceID: sourceA, recipients: { [] }, transport: transport, renewalTimer: timer
        )
        broadcaster.captureBegan(localLeaseID: 1)
        broadcaster.captureEnded(localLeaseID: 1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(transport.count == 0)
        #expect(timer.scheduledCount == 0)
    }

    @Test func captureSendsOrderedAcquireThenReleaseOnlyForTheCurrentLease() async throws {
        let transport = RecordingPairedTransport()
        let timer = ManualPairedTimer()
        let broadcaster = PairedVoiceMuteBroadcaster(
            sourceID: sourceA,
            recipients: { ["Studio-Mac", "Travel-Mac"] },
            transport: transport,
            renewalTimer: timer
        )

        broadcaster.captureBegan(localLeaseID: 1)
        try await waitUntil { transport.count == 2 }
        let acquires = transport.deliveries
        #expect(acquires.map { $0.recipient } == ["Studio-Mac", "Travel-Mac"])
        #expect(acquires.map { $0.request.operation } == [.acquire, .acquire])
        #expect(acquires.map { $0.request.sequence } == [1, 2])
        #expect(acquires.allSatisfy { $0.request.source == sourceA })
        let session = try #require(acquires.first?.request.session)
        #expect(acquires.allSatisfy { $0.request.session == session })

        broadcaster.captureEnded(localLeaseID: 99) // stale lease: must not release anything
        broadcaster.captureEnded(localLeaseID: 1)
        try await waitUntil { transport.count == 4 }
        let releases = Array(transport.deliveries.suffix(2))
        #expect(releases.map { $0.recipient } == ["Studio-Mac", "Travel-Mac"])
        #expect(releases.map { $0.request.operation } == [.release, .release])
        #expect(releases.map { $0.request.sequence } == [3, 4])
        #expect(releases.allSatisfy { $0.request.session == session })
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.count == 4)
        #expect(timer.liveCount == 0)
    }

    @Test func renewalKeepsTheLeaseAliveOnlyWhileCaptureIsLive() async throws {
        let transport = RecordingPairedTransport()
        let timer = ManualPairedTimer()
        let broadcaster = PairedVoiceMuteBroadcaster(
            sourceID: sourceA, recipients: { ["Studio-Mac"] }, transport: transport, renewalTimer: timer
        )

        broadcaster.captureBegan(localLeaseID: 1)
        try await waitUntil { transport.count == 1 }
        #expect(timer.liveCount == 1)
        #expect(timer.lastScheduledSeconds == TimeInterval(PairedVoiceMuteRequest.defaultLeaseSeconds) / 3)

        await timer.fireLive()
        try await waitUntil { transport.count == 2 }
        let renew = try #require(transport.deliveries.last)
        #expect(renew.request.operation == .renew)
        #expect(renew.request.sequence == 2)
        #expect(renew.request.session == transport.deliveries.first?.request.session)
        #expect(timer.liveCount == 1) // re-armed for the next keep-alive

        broadcaster.captureEnded(localLeaseID: 1)
        try await waitUntil { transport.count == 3 }
        #expect(transport.deliveries.last?.request.operation == .release)
        #expect(timer.liveCount == 0)

        // A renewal deadline that raced its cancellation must not revive the ended session.
        await timer.fireCancelled()
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.count == 3)
    }

    @Test func aSupersedingCaptureReplacesTheSessionAndReleasesRecipientsRemovedFromTheList() async throws {
        let transport = RecordingPairedTransport()
        let recipients = LockedBox(["Studio-Mac", "Travel-Mac"])
        let broadcaster = PairedVoiceMuteBroadcaster(
            sourceID: sourceA,
            recipients: { recipients.get() },
            transport: transport,
            renewalTimer: ManualPairedTimer()
        )

        broadcaster.captureBegan(localLeaseID: 1)
        try await waitUntil { transport.count == 2 }
        let firstSession = try #require(transport.deliveries.first?.request.session)

        recipients.set(["Studio-Mac"])
        broadcaster.captureBegan(localLeaseID: 2)
        try await waitUntil { transport.count == 4 }
        let next = Array(transport.deliveries.suffix(2))
        #expect(next[0].recipient == "Travel-Mac")
        #expect(next[0].request.operation == .release)
        #expect(next[0].request.session == firstSession)
        #expect(next[1].recipient == "Studio-Mac")
        #expect(next[1].request.operation == .acquire)
        #expect(next[1].request.session != firstSession)

        broadcaster.captureEnded(localLeaseID: 1) // the superseded lease
        broadcaster.captureEnded(localLeaseID: 2)
        try await waitUntil { transport.count == 5 }
        let last = try #require(transport.deliveries.last)
        #expect(last.recipient == "Studio-Mac")
        #expect(last.request.operation == .release)
        #expect(last.request.session == next[1].request.session)
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.count == 5)
    }
}

struct PairedVoiceMuteCoordinatorTests {
    private let pid: pid_t = 4_242

    private func listening() -> ChatGPTVoiceInputSnapshot {
        ChatGPTVoiceInputSnapshot(applicationPID: pid, isInputRunning: true, microphoneState: .listening)
    }

    @Test func pairedAcquireMutesAndItsReleaseRestoresThroughTheSameOwnership() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )

        let acquired = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(acquired == PairedVoiceMuteResponse(status: .acquired, detail: "mutedVerified"))
        #expect(await transport.postedPIDs() == [pid])
        #expect(await coordinator.pairedOwnerCountForTesting() == 1)

        let released = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(released == PairedVoiceMuteResponse(status: .released, detail: "restoredVerified"))
        #expect(await transport.postedPIDs() == [pid, pid])
        #expect(await transport.microphoneState() == .listening)
        #expect(await coordinator.pairedOwnerCountForTesting() == 0)
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == nil)
    }

    @Test func localAndPairedCapturesOverlapAndOnlyTheLastOwnerRestores() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )

        // Local capture first, paired capture joins, local stops first.
        let lease = await coordinator.prepareForCapture()
        #expect(await transport.postedPIDs() == [pid])
        let joined = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(joined.detail == "alreadyOwned")
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedPIDs() == [pid])
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == pid)
        let released = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(released.detail == "restoredVerified")
        #expect(await transport.postedPIDs() == [pid, pid])

        // Paired capture first, local capture joins, paired stops first.
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 3, session2))
        #expect(await transport.postedPIDs() == [pid, pid, pid])
        let localLease = await coordinator.prepareForCapture()
        #expect(await transport.postedPIDs() == [pid, pid, pid])
        let held = await coordinator.handlePairedRequest(request(.release, sourceA, 4, session2))
        #expect(held == PairedVoiceMuteResponse(status: .released, detail: "heldByOtherCapture"))
        #expect(await transport.postedPIDs() == [pid, pid, pid])
        await coordinator.releaseCapture(localLease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedPIDs() == [pid, pid, pid, pid])
        #expect(await transport.microphoneState() == .listening)
    }

    @Test func twoPairedSourcesShareOneSuppression() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1)).detail == "mutedVerified")
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceB, 1, sessionB)).detail == "alreadyOwned")
        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1)).detail == "heldByOtherCapture")
        #expect(await transport.postedPIDs() == [pid])
        #expect(await coordinator.handlePairedRequest(request(.release, sourceB, 2, sessionB)).detail == "restoredVerified")
        #expect(await transport.postedPIDs() == [pid, pid])
    }

    @Test func duplicateReorderedAndLateRequestsNeverToggleAgain() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1)).status == .acquired)
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1)).status == .stale)
        #expect(await transport.postedPIDs() == [pid])

        // A newer capture from the same source replaces the session without a restore/mute pair.
        let replaced = await coordinator.handlePairedRequest(request(.acquire, sourceA, 3, session2))
        #expect(replaced == PairedVoiceMuteResponse(status: .acquired, detail: "alreadyOwned"))
        // The older capture's release arrives late (older sequence) and then again (newer
        // sequence, wrong session). Neither may unmute the newer capture.
        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1)).status == .stale)
        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 4, session1)).status == .unknownSession)
        #expect(await transport.postedPIDs() == [pid])
        #expect(await coordinator.pairedOwnerCountForTesting() == 1)

        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 5, session2)).detail == "restoredVerified")
        #expect(await transport.postedPIDs() == [pid, pid])

        // Release overtaking its acquire: the late acquire must not mute.
        #expect(await coordinator.handlePairedRequest(request(.release, sourceB, 2, sessionB)).status == .unknownSession)
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceB, 1, sessionB)).status == .stale)
        #expect(await transport.postedPIDs() == [pid, pid])
        #expect(await coordinator.pairedOwnerCountForTesting() == 0)
    }

    @Test func renewalReadsNoChatGPTStateAndAnExpiredLeaseRestoresThroughTheNormalChecks() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let timer = ManualPairedTimer()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport, pairedLeaseTimer: timer)

        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(timer.liveCount == 1)
        #expect(timer.lastScheduledSeconds == TimeInterval(PairedVoiceMuteRequest.defaultLeaseSeconds))
        let snapshotsAfterAcquire = await transport.snapshotCount()

        #expect(await coordinator.handlePairedRequest(request(.renew, sourceA, 2, session1)).status == .renewed)
        #expect(await transport.snapshotCount() == snapshotsAfterAcquire)
        #expect(timer.liveCount == 1)

        // The deadline armed before the renewal fires late: it must not end the renewed lease.
        await timer.fireCancelled()
        #expect(await coordinator.pairedOwnerCountForTesting() == 1)
        #expect(await transport.postedPIDs() == [pid])

        // The source vanished: the current deadline ends ownership and restores.
        await timer.fireLive()
        #expect(await coordinator.pairedOwnerCountForTesting() == 0)
        #expect(await transport.postedPIDs() == [pid, pid])
        #expect(await transport.microphoneState() == .listening)
        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 3, session1)).status == .unknownSession)
        #expect(await transport.postedPIDs() == [pid, pid])
    }

    @Test func aReleasedLeaseCancelsItsExpiry() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let timer = ManualPairedTimer()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(transport: transport, pairedLeaseTimer: timer)
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        _ = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(timer.liveCount == 0)
        _ = await coordinator.prepareForCapture() // a later local capture owns a new mute
        #expect(await transport.postedPIDs() == [pid, pid, pid])
        await timer.fireCancelled()
        #expect(await transport.postedPIDs() == [pid, pid, pid])
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == pid)
    }

    @Test func recipientUserMutedVoiceIsNeitherToggledNorOwned() async {
        let transport = PairedFakeVoiceTransport(snapshot: ChatGPTVoiceInputSnapshot(
            applicationPID: pid, isInputRunning: true, microphoneState: .muted
        ))
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
            == PairedVoiceMuteResponse(status: .acquired, detail: "alreadyMuted"))
        #expect(await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
            == PairedVoiceMuteResponse(status: .released, detail: "notOwned"))
        #expect(await transport.postedPIDs().isEmpty)
        #expect(await transport.microphoneState() == .muted)
    }

    @Test func absentVoiceOnTheRecipientIsReportedNotMuted() async {
        let absent = PairedFakeVoiceTransport(snapshot: nil)
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: absent, pairedLeaseTimer: ManualPairedTimer()
        )
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1)).detail == "noChatGPT")
        #expect(await absent.postedPIDs().isEmpty)
    }

    @Test func aRequestFromThisMacsOwnSourceIsRejectedAsLoopback() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport,
            localPairedSourceID: sourceA.uppercased(),
            pairedLeaseTimer: ManualPairedTimer()
        )
        #expect(await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
            == PairedVoiceMuteResponse(status: .rejected, detail: "loopback"))
        #expect(await transport.postedPIDs().isEmpty)
        #expect(await coordinator.pairedOwnerCountForTesting() == 0)
    }

    @Test func pairedCaptureUsesTheDeviceBindingWhileLocalCaptureKeepsTheAcceptedOne() async {
        let paired = PairedFakeVoiceTransport(snapshot: listening())
        let pairedCoordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: paired, pairedLeaseTimer: ManualPairedTimer()
        )
        _ = await pairedCoordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        _ = await pairedCoordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(await paired.usedAuthorities() == [.deviceConfiguredBinding, .deviceConfiguredBinding])

        let local = PairedFakeVoiceTransport(snapshot: listening())
        let localCoordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: local, pairedLeaseTimer: ManualPairedTimer()
        )
        let lease = await localCoordinator.prepareForCapture()
        await localCoordinator.releaseCapture(lease)
        await localCoordinator.waitForPendingTransitionsForTesting()
        #expect(await local.usedAuthorities() == [.acceptedLocalBinding, .acceptedLocalBinding])
    }

    @Test func restorationPairsTheBindingThatMutedWhicheverOwnerFinishesLast() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening())
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )

        // The paired owner mutes; a local capture joins and finishes last.
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        let first = await coordinator.prepareForCapture()
        _ = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(await transport.usedAuthorities() == [.deviceConfiguredBinding])
        await coordinator.releaseCapture(first)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.usedAuthorities() == [.deviceConfiguredBinding, .deviceConfiguredBinding])

        // The local owner mutes; a paired capture joins and finishes last.
        let second = await coordinator.prepareForCapture()
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 3, session2))
        await coordinator.releaseCapture(second)
        await coordinator.waitForPendingTransitionsForTesting()
        _ = await coordinator.handlePairedRequest(request(.release, sourceA, 4, session2))
        #expect(await transport.usedAuthorities() == [
            .deviceConfiguredBinding, .deviceConfiguredBinding,
            .acceptedLocalBinding, .acceptedLocalBinding
        ])
    }

    @Test func aMacWithoutTheLocalBindingStillMutesForPairedCaptureAndCanRestoreIt() async {
        let transport = PairedFakeVoiceTransport(snapshot: listening(), refusing: .acceptedLocalBinding)
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport, pairedLeaseTimer: ManualPairedTimer()
        )

        // The unavailable local binding refuses the local toggle and owns nothing, as before.
        let lease = await coordinator.prepareForCapture()
        #expect(await transport.postedPIDs().isEmpty)
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == nil)

        let acquired = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        #expect(acquired.detail == "mutedVerified")
        await coordinator.releaseCapture(lease)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(await transport.postedPIDs() == [pid])

        let released = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(released.detail == "restoredVerified")
        #expect(await transport.postedPIDs() == [pid, pid])
        #expect(await coordinator.stateForTesting().ownedMutedApplicationPID == nil)
    }

    @Test func onlyCurrentLocalCaptureBoundariesReachPairedMacs() async {
        let fanOut = RecordingFanOut()
        let coordinator = ChatGPTVoiceCaptureMuteCoordinator(
            transport: PairedFakeVoiceTransport(snapshot: nil),
            pairedFanOut: fanOut,
            pairedLeaseTimer: ManualPairedTimer()
        )
        let older = await coordinator.prepareForCapture()
        let newer = await coordinator.prepareForCapture()
        await coordinator.releaseCapture(older) // stale: a newer capture owns the microphone
        await coordinator.releaseCapture(newer)
        await coordinator.waitForPendingTransitionsForTesting()
        #expect(fanOut.events == [.began(1), .began(2), .ended(2)])

        // Requests received from other Macs are never forwarded onward.
        _ = await coordinator.handlePairedRequest(request(.acquire, sourceA, 1, session1))
        _ = await coordinator.handlePairedRequest(request(.release, sourceA, 2, session1))
        #expect(fanOut.events == [.began(1), .began(2), .ended(2)])
    }
}

struct PairedVoiceMuteShortcutTests {
    private let command = SystemChatGPTVoiceMuteTransport.shortcutCommand

    private func resolve(_ json: String) -> ChatGPTVoiceShortcutResolution {
        ChatGPTVoiceShortcut.resolve(keybindings: Data(json.utf8), command: command)
    }

    private func binding(_ command: String, _ key: String) -> String {
        #"{"command":"\#(command)","key":"\#(key)"}"#
    }

    @Test func acceleratorsParseInAnyOrderCaseAndSpelling() throws {
        let chord = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Control+Shift+K"))
        #expect(chord.virtualKey == 0x28)
        #expect(chord.flags == [.maskCommand, .maskControl, .maskShift])
        #expect(chord.layoutCharacter == "k")
        #expect(ChatGPTVoiceShortcut(accelerator: "cmd+ctrl+shift+k") == chord)
        #expect(ChatGPTVoiceShortcut(accelerator: "Shift+Control+Command+K") == chord)
        #expect(ChatGPTVoiceShortcut(accelerator: "CmdOrCtrl+Control+Shift+k") == chord)

        #expect(ChatGPTVoiceShortcut(accelerator: "Alt+M")
            == ChatGPTVoiceShortcut(accelerator: "Option+M"))
        #expect(ChatGPTVoiceShortcut(accelerator: "Command+Control+Option+Shift+F20") == .acceptedLocal)
        #expect(ChatGPTVoiceShortcut(accelerator: "Shift+F13")?.layoutCharacter == nil)
        #expect(ChatGPTVoiceShortcut(accelerator: "F13") != nil)
    }

    @Test func acceleratorsThatCouldTypeOrCannotBeProvenAreRefused() {
        for accelerator in ["", "+", "M", "Shift+M", "7", "Command+", "Command+Command+M", "AltGr+M",
                            "Hyper+M", "Command+Space", "Command+Return", "Command+Tab",
                            "Command+Backspace", "Command+;", "Command+F21", "Command+MM"] {
            #expect(ChatGPTVoiceShortcut(accelerator: accelerator) == nil, "\(accelerator)")
        }
    }

    @Test func resolverUsesWhateverThisMacBindsToTheRealCommandOnly() throws {
        for accelerator in ["Command+Control+Shift+M", "Command+Option+K", "Control+F7"] {
            let expected = try #require(ChatGPTVoiceShortcut(accelerator: accelerator))
            let json = "[\(binding("other.command", "Command+Y")),\(binding(command, accelerator))]"
            #expect(resolve(json) == .resolved(expected), "\(accelerator)")
        }
        #expect(resolve("[\(binding(command, "Command+Control+Option+Shift+F20"))]") == .resolved(.acceptedLocal))
    }

    @Test func absentBindingsAreMissing() {
        #expect(ChatGPTVoiceShortcut.resolve(keybindings: nil, command: command) == .missing)
        #expect(resolve("not json") == .missing)
        #expect(resolve("{}") == .missing)
        #expect(resolve("[]") == .missing)
        #expect(resolve("[\(binding("realtimeVoice.toggleOutputMute", "Command+M"))]") == .missing)
        #expect(resolve(#"[{"command":"\#(command)","key":null}]"#) == .missing)
    }

    @Test func ambiguousSharedOrUnpostableBindingsAreUnsupported() throws {
        #expect(resolve("[\(binding(command, "Command+Space"))]") == .unsupported)
        #expect(resolve("[\(binding(command, "Command+J")),\(binding(command, "Command+K"))]") == .unsupported)
        #expect(resolve("[\(binding(command, "Command+Shift+K")),\(binding("other.command", "shift+cmd+k"))]")
            == .unsupported)
        // Unrelated commands and identical duplicates do not make the binding ambiguous.
        let only = try #require(ChatGPTVoiceShortcut(accelerator: "Command+J"))
        #expect(resolve("[\(binding(command, "Command+J")),\(binding(command, "cmd+j")),\(binding("other.command", "Command+K"))]")
            == .resolved(only))
    }

    @Test func theAcceptedChordWinsWhenAMacBindsItAlongsideAnother() {
        #expect(resolve("[\(binding(command, "Command+J")),\(binding(command, "Command+Control+Option+Shift+F20"))]")
            == .resolved(.acceptedLocal))
    }

    @Test func layoutCheckRefusesOnlyAPositiveMismatch() throws {
        let letter = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Shift+K"))
        #expect(letter.matchesLayout(producedCharacters: "k"))
        #expect(letter.matchesLayout(producedCharacters: "K"))
        #expect(!letter.matchesLayout(producedCharacters: "t"))
        #expect(letter.matchesLayout(producedCharacters: nil))
        #expect(letter.matchesLayout(producedCharacters: ""))
        #expect(ChatGPTVoiceShortcut.acceptedLocal.matchesLayout(producedCharacters: "t"))
    }

    @Test func aDeviceBindingNeverWidensTheLocalBindingCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        #expect(SystemChatGPTVoiceMuteTransport.deviceShortcutResolution(at: file) == .missing)

        // A function key so this test does not depend on the keyboard layout of the test Mac.
        try Data("[\(binding(command, "Command+Shift+F13"))]".utf8).write(to: file)
        let expected = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Shift+F13"))
        #expect(SystemChatGPTVoiceMuteTransport.deviceShortcutResolution(at: file) == .resolved(expected))
        #expect(!SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))
    }

    @Test func readinessReportsTheBindingAPairedRequestWouldUse() throws {
        let shortcut = try #require(ChatGPTVoiceShortcut(accelerator: "Command+Control+Shift+K"))
        #expect(PairedVoiceMuteReceiver.readiness(
            shortcut: .resolved(shortcut), accessibilityTrusted: true
        ) == "ready")
        #expect(PairedVoiceMuteReceiver.readiness(
            shortcut: .resolved(shortcut), accessibilityTrusted: false
        ) == "accessibilityMissing")
        #expect(PairedVoiceMuteReceiver.readiness(
            shortcut: .missing, accessibilityTrusted: true
        ) == "shortcutMissing")
        #expect(PairedVoiceMuteReceiver.readiness(
            shortcut: .unsupported, accessibilityTrusted: true
        ) == "shortcutUnsupported")
    }
}

struct PairedVoiceMuteReceiverTests {
    @Test func optInGatesAcquireAndRenewButNeverRelease() {
        let acquire = request(.acquire, sourceA, 1, session1)
        let renew = request(.renew, sourceA, 2, session1)
        let release = request(.release, sourceA, 3, session1)
        #expect(!PairedVoiceMuteReceiver.admits(acquire, receiverEnabled: false))
        #expect(!PairedVoiceMuteReceiver.admits(renew, receiverEnabled: false))
        #expect(PairedVoiceMuteReceiver.admits(release, receiverEnabled: false))
        #expect(PairedVoiceMuteReceiver.admits(acquire, receiverEnabled: true))
    }

    @Test func socketAnswersOneLineAndHonoursTheOptIn() async throws {
        let directory = "/private/tmp/vipp-pvm-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/v.sock"
        let enabled = LockedBox(false)
        let handled = LockedBox<[PairedVoiceMuteRequest]>([])
        let receiver = PairedVoiceMuteReceiver(
            path: path,
            isEnabled: { enabled.get() },
            readiness: { "ready" },
            handler: { request in
                handled.mutate { $0.append(request) }
                return PairedVoiceMuteResponse(
                    status: request.operation == .release ? .released : .acquired,
                    detail: "fixture"
                )
            }
        )
        try receiver.start()
        defer { receiver.stop() }

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())

        #expect(try exchange(path, PairedVoiceMuteMessage.statusLine())
            == PairedVoiceMuteResponse(status: .disabled))
        #expect(try exchange(path, request(.acquire, sourceA, 1, session1).encodedLine())
            == PairedVoiceMuteResponse(status: .disabled))
        #expect(handled.get().isEmpty)
        #expect(try exchange(path, request(.release, sourceA, 2, session1).encodedLine())
            == PairedVoiceMuteResponse(status: .released, detail: "fixture"))
        #expect(handled.get().map(\.operation) == [.release])

        enabled.set(true)
        #expect(try exchange(path, PairedVoiceMuteMessage.statusLine())
            == PairedVoiceMuteResponse(status: .ready, detail: "ready"))
        #expect(try exchange(path, request(.acquire, sourceA, 3, session2).encodedLine())
            == PairedVoiceMuteResponse(status: .acquired, detail: "fixture"))
        #expect(handled.get().map(\.operation) == [.release, .acquire])

        #expect(try exchange(path, Data("rm -rf ~\n".utf8))
            == PairedVoiceMuteResponse(status: .rejected, detail: "malformed"))
        #expect(handled.get().count == 2)
    }

    @Test func endpointIsSingleOwnerAndNeverReplacesAnUnrelatedFile() throws {
        let directory = "/private/tmp/vipp-pvm-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/v.sock"
        let make = {
            PairedVoiceMuteReceiver(
                path: path,
                isEnabled: { false },
                readiness: { "ready" },
                handler: { _ in PairedVoiceMuteResponse(status: .rejected) }
            )
        }

        let first = make()
        try first.start()
        let second = make()
        #expect(throws: (any Error).self) { try second.start() }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        try second.start()
        second.stop()

        try "preserve unrelated file".write(toFile: path, atomically: true, encoding: .utf8)
        let third = make()
        #expect(throws: (any Error).self) { try third.start() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "preserve unrelated file")
    }

    /// One request/response exchange exactly as `nc -U` performs it over SSH.
    private func exchange(_ path: String, _ line: Data) throws -> PairedVoiceMuteResponse? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let sent = line.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == line.count else { throw POSIXError(.EIO) }
        shutdown(fd, SHUT_WR)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            output.append(contentsOf: buffer[0..<count])
        }
        return PairedVoiceMuteResponse.decodeLastLine(from: output)
    }
}

struct PairedVoiceMuteBoundaryTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func pairedRequestsFollowOnlyHardwareCaptureLeasesNeverTypingNotifierOrTranscription() throws {
        let recorder = try source("VoiceInk/Recorder.swift")
        let notifier = try source("VoiceInk/Notifications/RecordingActivityNotifier.swift")
        let coordinator = try source("VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift")
        let transcriptionDirectory = root.appendingPathComponent("VoiceInk/Transcription")
        let transcription = try FileManager.default
            .subpathsOfDirectory(atPath: transcriptionDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: transcriptionDirectory.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        // The Recorder still talks only to the coordinator; no second capture hook exists.
        #expect(!recorder.contains("PairedVoiceMute"))
        #expect(!notifier.contains("PairedVoiceMute"))
        #expect(!transcription.contains("PairedVoiceMute"))

        // A typing-only start returns before any microphone suppression is prepared.
        let typedStart = try #require(recorder.range(of: "if initiallyPaused {"))
        let typedReturn = try #require(recorder.range(
            of: "return nil", range: typedStart.upperBound..<recorder.endIndex
        ))
        #expect(!recorder[typedStart.lowerBound..<typedReturn.upperBound]
            .contains("ChatGPTVoiceCaptureMuteCoordinator"))

        // Fan-out is recorded before the local transition is awaited, and only after the
        // stale-release guard.
        let prepare = try #require(coordinator.range(of: "func prepareForCapture() async"))
        let began = try #require(coordinator.range(
            of: "pairedFanOut?.captureBegan(localLeaseID: lease.id)", range: prepare.upperBound..<coordinator.endIndex
        ))
        let awaitLocal = try #require(coordinator.range(
            of: "await transition.value", range: prepare.upperBound..<coordinator.endIndex
        ))
        #expect(began.lowerBound < awaitLocal.lowerBound)
        let release = try #require(coordinator.range(of: "func releaseCapture("))
        let staleGuard = try #require(coordinator.range(
            of: "guard requestedLease == lease else", range: release.upperBound..<coordinator.endIndex
        ))
        let ended = try #require(coordinator.range(
            of: "pairedFanOut?.captureEnded(localLeaseID: lease.id)", range: release.upperBound..<coordinator.endIndex
        ))
        #expect(staleGuard.lowerBound < ended.lowerBound)
        #expect(try source("VoiceInk/AppDelegate.swift")
            .contains("PairedVoiceMuteReceiver.shared.startForApplication()"))
    }

    @Test func pairedTransportAndReceiverPostNoInputAndRunNoShell() throws {
        let broadcaster = try source("VoiceInk/Services/PairedVoiceMuteBroadcaster.swift")
        let receiver = try source("VoiceInk/Services/PairedVoiceMuteReceiver.swift")
        let wire = try source("VoiceInk/Services/PairedVoiceMuteProtocol.swift")

        #expect(broadcaster.contains("\"/usr/bin/ssh\""))
        #expect(broadcaster.contains("\"BatchMode=yes\""))
        #expect(broadcaster.contains("process.standardInput = inputPipe"))
        #expect(broadcaster.contains("inputPipe.fileHandleForWriting.write(contentsOf: input)"))
        #expect(broadcaster.contains("F_SETNOSIGPIPE"))
        // The chord type only describes input. The accepted transport is the one place that posts.
        let shortcut = try source("VoiceInk/Services/ChatGPTVoiceShortcut.swift")
        for forbidden in ["postToPid", "AXUIElement", "Process()", ".post(", ".write("] {
            #expect(!shortcut.contains(forbidden), "shortcut parsing must not use \(forbidden)")
        }
        for forbidden in ["/bin/sh", "/bin/zsh", "/bin/bash", "\"-c\"", "agent-bridge run",
                          "bridge_send_message", "postToPid", "CGEvent", "AXUIElement",
                          ".activate(", "RecordingActivityNotifier", "Task.sleep"] {
            #expect(!broadcaster.contains(forbidden), "broadcaster must not use \(forbidden)")
        }
        for forbidden in ["postToPid", "CGEvent", "AXUIElement", ".activate(", "Process()",
                          "RecordingActivityNotifier", "Task.sleep"] {
            #expect(!receiver.contains(forbidden), "receiver must not use \(forbidden)")
            #expect(!wire.contains(forbidden) || forbidden == "Task.sleep", "wire format must not use \(forbidden)")
        }
    }
}
