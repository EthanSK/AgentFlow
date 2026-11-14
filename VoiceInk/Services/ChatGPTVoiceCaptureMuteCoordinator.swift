import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import os

enum ChatGPTVoiceMicrophoneState: Equatable, Hashable, Sendable {
    case listening
    case muted
}

struct ChatGPTVoiceInputSnapshot: Equatable, Sendable {
    let applicationPID: pid_t
    let isInputRunning: Bool
    let microphoneState: ChatGPTVoiceMicrophoneState?
    let call: ChatGPTVoiceCall?
}

struct ChatGPTVoiceCaptureMuteLease: Equatable, Sendable {
    fileprivate let id: UInt64
}

/// What one suppression attempt observed. Local capture ignores it; a paired Mac's request
/// reports it back so the source can log what actually happened instead of claiming success.
enum ChatGPTVoiceSuppressionOutcome: String, Sendable {
    case alreadyOwned
    case noChatGPT
    case noActiveVoice
    case alreadyMuted
    case shortcutFailed
    case stillListening
    case mutedVerified
    case mutedUnverified
}

enum ChatGPTVoiceRestorationOutcome: String, Sendable {
    case notOwned
    /// Another capture owner (local or paired) still needs suppression.
    case heldByOtherCapture
    case processChanged
    case voiceEnded
    case callChanged
    case userUnmuted
    case shortcutFailed
    case restoredVerified
    case restoredUnverified
}

protocol ChatGPTVoiceMuteTransport: Sendable {
    func snapshot() async -> ChatGPTVoiceInputSnapshot?
    func postMicrophoneToggle(
        from before: ChatGPTVoiceInputSnapshot,
        toward target: ChatGPTVoiceMicrophoneState,
        using authority: ChatGPTVoiceShortcutAuthority
    ) async -> Bool
    func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) async -> ChatGPTVoiceMicrophoneState?
}

/// Owns one narrowly scoped lease over ChatGPT Voice's supported microphone-toggle shortcut.
///
/// This is intentionally driven by `Recorder`'s real hardware-capture boundaries rather than by
/// transcription jobs or `RecordingActivityNotifier`: a finished recording may keep transcribing
/// after the microphone belongs to a newer session, while the notifier is reserved for the proven
/// YouTube playback bridge. The coordinator never mutates Accessibility, changes global input
/// state, activates ChatGPT, or moves the pointer.
///
/// Core Audio shows whether ChatGPT is using an input stream, including when its Voice
/// microphone is muted. A separate read-only
/// Accessibility state check recognizes the microphone control when ChatGPT exposes it.
/// Exact local Voice call boundaries distinguish calls that reuse the same process. An
/// identified active call with unreadable mute state still gets the existing single
/// attempt at Start and at most one inverse at Stop. Readable manual mute and unmute
/// states take precedence.
/// Accessibility is never used to activate ChatGPT, set focus, press the control, or move the
/// pointer; the only mutation remains the user-configured keyboard command. VoiceInk++ deliberately
/// does not poll that tree while recording—the rejected polling experiment caused lag.
///
/// Paired Macs: a capture on another explicitly configured Mac is one more *owner* of the same
/// suppression, never a second mechanism. Suppression is attempted when any owner begins (and
/// is a no-op while already owned), and restoration runs only when the last owner ends, so a
/// paired release can never unmute ChatGPT under this Mac's own live capture and vice versa.
/// Paired ordering, duplicates and expiry are decided by `PairedVoiceMuteLedger` before any
/// transition is queued. This Mac's own capture boundaries are forwarded to its configured
/// recipients through `pairedFanOut`; requests received from other Macs are never forwarded,
/// so two Macs configured for each other cannot loop.
///
/// Local capture still requires the exact accepted `F20` binding, while a paired owner on an
/// opted-in Mac uses that Mac's own validated binding for the same command. Ownership remembers
/// which one posted the mute, so the inverse pairs it whichever owner happens to finish last.
actor ChatGPTVoiceCaptureMuteCoordinator {
    static let shared: ChatGPTVoiceCaptureMuteCoordinator = {
        let transport = SystemChatGPTVoiceMuteTransport()
        return ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport,
            pairedFanOut: PairedVoiceMuteBroadcaster.shared,
            localPairedSourceID: PairedVoiceMuteBroadcaster.shared.sourceID,
            pairedActivity: .shared,
            speaker: ChatGPTVoiceCaptureSpeaker(transport: transport)
        )
    }()

    private let transport: any ChatGPTVoiceMuteTransport
    private let pairedFanOut: (any PairedVoiceMuteFanOut)?
    private let localPairedSourceID: String?
    private let pairedLeaseTimer: any PairedVoiceMuteLeaseTimer
    private let pairedActivity: PairedVoiceMuteActivity?
    private let speaker: ChatGPTVoiceCaptureSpeaker?
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "ChatGPTVoiceCaptureMute"
    )

    private var nextLeaseID: UInt64 = 0
    private var requestedLease: ChatGPTVoiceCaptureMuteLease?
    private var appliedLease: ChatGPTVoiceCaptureMuteLease?
    /// Paired-Mac owners admitted by the ledger, applied in the same transition order.
    private var appliedPairedOwners: Set<PairedVoiceMuteOwner> = []
    private var pairedLedger = PairedVoiceMuteLedger()
    private var pairedExpiries: [String: PairedVoiceMuteScheduledTimer] = [:]
    private var ownedMicrophoneMute: (call: ChatGPTVoiceCall, authority: ChatGPTVoiceShortcutAuthority)?
    private var transitionTail: Task<Void, Never> = Task {}

    init(
        transport: any ChatGPTVoiceMuteTransport,
        pairedFanOut: (any PairedVoiceMuteFanOut)? = nil,
        localPairedSourceID: String? = nil,
        pairedLeaseTimer: any PairedVoiceMuteLeaseTimer = TaskPairedVoiceMuteLeaseTimer(),
        pairedActivity: PairedVoiceMuteActivity? = nil,
        speaker: ChatGPTVoiceCaptureSpeaker? = nil
    ) {
        self.transport = transport
        self.pairedFanOut = pairedFanOut
        self.localPairedSourceID = localPairedSourceID?.lowercased()
        self.pairedLeaseTimer = pairedLeaseTimer
        self.pairedActivity = pairedActivity
        self.speaker = speaker
    }

    /// Finish listener suppression before VoiceInk++ opens the shared Core Audio input.
    ///
    /// The background ChatGPT shortcut can stop/reconfigure its existing input stream. Posting it
    /// after AUHAL capture started produced valid WAV containers with no recognisable speech on the
    /// shared Scarlett device. Start and resume therefore await this exact queued transition before
    /// touching capture hardware. Stop/pause still enqueue restoration after hardware has released
    /// the input, preserving rapid-session ordering without delaying final transcription.
    func prepareForCapture() async -> ChatGPTVoiceCaptureMuteLease {
        nextLeaseID &+= 1
        let lease = ChatGPTVoiceCaptureMuteLease(id: nextLeaseID)
        requestedLease = lease
        // Paired Macs get their request in parallel with this Mac's own preflight. The call
        // only records ordered intent and spawns bounded background SSH work; it never waits on
        // the network, so an asleep or unreachable recipient cannot delay the start sound or
        // AUHAL. Typing-only sessions never reach this method, so they mute nothing anywhere.
        pairedFanOut?.captureBegan(localLeaseID: lease.id)

        let previous = transitionTail
        let transition = Task { [weak self] in
            await previous.value
            guard !Task.isCancelled else { return }
            await self?.beginCapture(lease)
        }
        transitionTail = transition
        await transition.value
        return lease
    }

    /// End only the exact capture generation that acquired the lease. Recorder operations can
    /// interleave across an audio-queue await; a late stop from generation A must never restore
    /// ChatGPT while a newer generation B owns the microphone.
    func releaseCapture(_ lease: ChatGPTVoiceCaptureMuteLease) {
        guard requestedLease == lease else {
            logger.debug("Ignored stale ChatGPT Voice capture release lease=\(lease.id, privacy: .public)")
            return
        }
        requestedLease = nil
        // Only the exact current lease reaches paired Macs. A stale release from an older
        // capture generation must not end the newer capture's remote suppression either.
        pairedFanOut?.captureEnded(localLeaseID: lease.id)

        // Recorder Stop can finish before this queued restoration. Keep a cooperative
        // quit from dropping the speaker restore while the existing queue settles.
        let speakerRestoration = speaker == nil ? nil : pairedActivity?.beginOperation()
        let activity = pairedActivity
        let previous = transitionTail
        transitionTail = Task { [weak self] in
            defer {
                if let speakerRestoration { activity?.finishOperation(speakerRestoration) }
            }
            await previous.value
            guard !Task.isCancelled else { return }
            await self?.endCapture(lease)
        }
    }

    /// Applies one request from a paired Mac's capture and reports what this Mac observed.
    ///
    /// The ledger decision and the queued transition are created in one actor turn, so the
    /// transition order always equals the ledger's sequence order even when several SSH
    /// deliveries race. Only `acquire` can post the mute shortcut; `renew` touches neither
    /// ChatGPT nor Accessibility, preserving the no-polling rule during long recordings.
    func handlePairedRequest(_ request: PairedVoiceMuteRequest) async -> PairedVoiceMuteResponse {
        if let localPairedSourceID, request.source == localPairedSourceID {
            // An Agent Bridge alias that resolves back to this Mac. This Mac's own capture
            // already owns suppression locally; a second owner would only delay restoration.
            return PairedVoiceMuteResponse(status: .rejected, detail: "loopback")
        }
        let operation = pairedActivity?.beginOperation()
        guard pairedActivity == nil || operation != nil else {
            return PairedVoiceMuteResponse(status: .rejected, detail: "shuttingDown")
        }
        defer {
            if let operation {
                pairedActivity?.finishOperation(operation,
                    remoteCaptureActive: !pairedLedger.activeOwners.isEmpty)
            }
        }
        let decision = pairedLedger.apply(request, now: ProcessInfo.processInfo.systemUptime)
        switch decision {
        case .stale:
            logger.debug("Ignored a paired Voice mute request that was not newer than its source's last request")
            return PairedVoiceMuteResponse(status: .stale)
        case .unknownSession:
            return PairedVoiceMuteResponse(status: .unknownSession)
        case .capacityExceeded:
            logger.error("Rejected a paired Voice mute request because too many paired sources are tracked")
            return PairedVoiceMuteResponse(status: .rejected, detail: "capacity")
        case .renewed(let owner, let lease):
            schedulePairedExpiry(owner: owner, lease: lease)
            return PairedVoiceMuteResponse(status: .renewed)
        case .acquired(let owner, let replaced, let lease):
            schedulePairedExpiry(owner: owner, lease: lease)
            let transition = enqueuePairedTransition { coordinator in
                await coordinator.beginPairedCapture(owner, replacing: replaced)
            }
            let outcome = await transition.value
            logger.notice("Paired capture acquired seq=\(request.sequence, privacy: .public) session=\(String(request.session.prefix(8)), privacy: .public) outcome=\(outcome?.rawValue ?? "unavailable", privacy: .public)")
            return PairedVoiceMuteResponse(status: .acquired, detail: outcome?.rawValue)
        case .released(let owner):
            cancelPairedExpiry(source: owner.source)
            let transition = enqueuePairedTransition { coordinator in
                await coordinator.endPairedCapture(owner)
            }
            let outcome = await transition.value
            logger.notice("Paired capture released seq=\(request.sequence, privacy: .public) session=\(String(request.session.prefix(8)), privacy: .public) outcome=\(outcome?.rawValue ?? "unavailable", privacy: .public)")
            return PairedVoiceMuteResponse(status: .released, detail: outcome?.rawValue)
        }
    }

    func waitForPendingTransitionsForTesting() async {
        let tail = transitionTail
        await tail.value
    }

    func stateForTesting() -> (captureActive: Bool, ownedMutedApplicationPID: pid_t?) {
        (appliedLease != nil, ownedMicrophoneMute?.call.applicationPID)
    }

    func pairedOwnerCountForTesting() -> Int {
        appliedPairedOwners.count
    }

    private func enqueuePairedTransition<Result: Sendable>(
        _ body: @escaping @Sendable (ChatGPTVoiceCaptureMuteCoordinator) async -> Result
    ) -> Task<Result?, Never> {
        let previous = transitionTail
        let transition = Task { [weak self] () -> Result? in
            await previous.value
            guard let self else { return nil }
            return await body(self)
        }
        transitionTail = Task { _ = await transition.value }
        return transition
    }

    private func schedulePairedExpiry(
        owner: PairedVoiceMuteOwner,
        lease: PairedVoiceMuteLedger.Lease
    ) {
        pairedExpiries.removeValue(forKey: owner.source)?.cancel()
        let source = owner.source
        let generation = lease.generation
        pairedExpiries[source] = pairedLeaseTimer.schedule(
            after: TimeInterval(lease.seconds)
        ) { [weak self] in
            await self?.expirePairedLease(source: source, generation: generation)
        }
    }

    private func cancelPairedExpiry(source: String) {
        pairedExpiries.removeValue(forKey: source)?.cancel()
    }

    /// A source that slept, lost its network or crashed stops renewing. Ending its ownership
    /// here uses the ordinary restoration path, including the exact-call and
    /// readable-user-state checks.
    private func expirePairedLease(source: String, generation: UInt64) async {
        let operation = pairedActivity?.beginOperation()
        guard pairedActivity == nil || operation != nil else { return }
        defer {
            if let operation {
                pairedActivity?.finishOperation(operation,
                    remoteCaptureActive: !pairedLedger.activeOwners.isEmpty)
            }
        }
        guard let owner = pairedLedger.expire(source: source, generation: generation) else {
            return
        }
        pairedExpiries.removeValue(forKey: source)
        logger.notice("A paired Mac's capture lease expired without a release; ending its suppression ownership")
        let transition = enqueuePairedTransition { coordinator in
            await coordinator.endPairedCapture(owner)
        }
        _ = await transition.value
    }

    private func beginCapture(_ lease: ChatGPTVoiceCaptureMuteLease) async {
        appliedLease = lease
        // Run the independent output preflight beside the existing microphone path.
        // Both finish before AUHAL starts, including when the Voice microphone was already muted.
        async let silence: Void? = speaker?.silenceForCapture()
        _ = await suppressChatGPTVoiceIfNeeded(using: .acceptedLocalBinding)
        _ = await silence
    }

    private func endCapture(_ lease: ChatGPTVoiceCaptureMuteLease) async {
        guard appliedLease == lease else { return }
        appliedLease = nil
        // A queued local capture inherits silence. Paired capture owns only the
        // existing microphone path, so it cannot keep the local speaker silenced.
        if !appliedPairedOwners.isEmpty {
            // A paired Mac is still capturing speech that ChatGPT here must not hear.
            logger.notice("Local capture ended while a paired Mac still needs ChatGPT Voice suppression; restoration deferred to the last owner")
        } else {
            _ = await restoreChatGPTVoiceIfOwned()
        }
        if requestedLease == nil {
            await speaker?.restoreAfterCapture()
        }
    }

    private func beginPairedCapture(
        _ owner: PairedVoiceMuteOwner,
        replacing replaced: PairedVoiceMuteOwner?
    ) async -> ChatGPTVoiceSuppressionOutcome {
        // A newer capture from the same source replaces its older session in one step, so the
        // owner set never passes through empty and no restore/re-mute pair is issued.
        if let replaced {
            appliedPairedOwners.remove(replaced)
        }
        appliedPairedOwners.insert(owner)
        return await suppressChatGPTVoiceIfNeeded(using: .deviceConfiguredBinding)
    }

    private func endPairedCapture(
        _ owner: PairedVoiceMuteOwner
    ) async -> ChatGPTVoiceRestorationOutcome {
        guard appliedPairedOwners.remove(owner) != nil else { return .notOwned }
        guard appliedLease == nil, appliedPairedOwners.isEmpty else {
            logger.notice("A paired Mac's capture ended while another capture still needs ChatGPT Voice suppression")
            return .heldByOtherCapture
        }
        return await restoreChatGPTVoiceIfOwned()
    }

    private func suppressChatGPTVoiceIfNeeded(
        using authority: ChatGPTVoiceShortcutAuthority
    ) async -> ChatGPTVoiceSuppressionOutcome {
        guard let before = await transport.snapshot() else {
            logger.debug("Capture began without one resolvable ChatGPT application; listener suppression is a no-op")
            return .noChatGPT
        }
        guard before.isInputRunning, let call = before.call else {
            logger.notice("No uniquely identified active ChatGPT Voice call; microphone shortcut skipped pid=\(before.applicationPID, privacy: .public)")
            return .noActiveVoice
        }
        if ownedMicrophoneMute?.call == call { return .alreadyOwned }
        ownedMicrophoneMute = nil
        guard before.microphoneState != .muted else {
            // A readable muted control belongs to the user; never invert it at recording start.
            logger.debug("Capture began while ChatGPT Voice was already muted; microphone toggle was not posted pid=\(before.applicationPID, privacy: .public)")
            return .alreadyMuted
        }
        if before.microphoneState == nil {
            logger.notice("ChatGPT Voice control was unreadable; using one paired shortcut lease for the active session pid=\(before.applicationPID, privacy: .public)")
        }
        guard await transport.postMicrophoneToggle(from: before, toward: .muted, using: authority) else {
            logger.notice("ChatGPT Voice microphone mute was not posted pid=\(before.applicationPID, privacy: .public)")
            return .shortcutFailed
        }
        let postState: ChatGPTVoiceMicrophoneState?
        if before.microphoneState == .listening {
            postState = await transport.microphoneStateAfterToggle(for: call)
        } else {
            postState = nil
        }
        // A visible failure must not turn into an inverse toggle just because
        // Codex later hides the same call's microphone button at Stop.
        if postState == .listening {
            logger.notice("ChatGPT Voice microphone still showed listening after the mute shortcut; no inverse will be sent")
            return .stillListening
        }

        // An unreadable post-state can still own one paired attempt for this exact call.
        // Codex can ignore a shortcut even though macOS accepted the event.
        ownedMicrophoneMute = (call, authority)
        if postState == .muted {
            logger.notice("VoiceInk++ verified and owns ChatGPT Voice microphone suppression pid=\(before.applicationPID, privacy: .public)")
            return .mutedVerified
        } else {
            logger.notice("VoiceInk++ owns one paired ChatGPT Voice microphone shortcut lease without readable post-state pid=\(before.applicationPID, privacy: .public)")
            return .mutedUnverified
        }
    }

    private func restoreChatGPTVoiceIfOwned() async -> ChatGPTVoiceRestorationOutcome {
        guard let owned = ownedMicrophoneMute else { return .notOwned }
        // A refused post must not leave ownership that a later recording can inherit.
        ownedMicrophoneMute = nil
        let ownedPID = owned.call.applicationPID
        guard let current = await transport.snapshot(),
              current.applicationPID == ownedPID else {
            logger.notice("ChatGPT process changed or exited; stale microphone-suppression ownership was discarded pid=\(ownedPID, privacy: .public)")
            return .processChanged
        }
        guard current.isInputRunning else {
            logger.notice("ChatGPT input stream ended; microphone restoration skipped pid=\(ownedPID, privacy: .public)")
            return .voiceEnded
        }
        guard current.call == owned.call else {
            logger.notice("ChatGPT Voice call changed or could not be identified; microphone restoration skipped pid=\(ownedPID, privacy: .public)")
            return .callChanged
        }
        switch current.microphoneState {
        case .listening:
            logger.notice("ChatGPT Voice microphone was visibly unmuted; restoration ownership was relinquished pid=\(ownedPID, privacy: .public)")
            return .userUnmuted
        case .muted:
            break
        case nil:
            // The same Voice call remains, but its background control is unreadable. Pair the
            // single shortcut posted at capture start exactly once; never retry an unobserved result.
            logger.notice("ChatGPT Voice control remained unreadable; pairing the owned microphone shortcut pid=\(ownedPID, privacy: .public)")
        }
        // Not the authority of whichever owner finished last: on a Mac without the local binding,
        // a local capture that joined a paired mute must still be able to undo that mute.
        guard await transport.postMicrophoneToggle(from: current, toward: .listening, using: owned.authority) else {
            logger.notice("ChatGPT Voice microphone restore was not posted pid=\(ownedPID, privacy: .public)")
            return .shortcutFailed
        }

        let restored: Bool
        if current.microphoneState == .muted {
            restored = await transport.microphoneStateAfterToggle(for: owned.call) == .listening
        } else {
            restored = false
        }
        if restored {
            logger.notice("VoiceInk++ verified ChatGPT Voice microphone restoration pid=\(ownedPID, privacy: .public)")
            return .restoredVerified
        } else {
            // The Voice session may have ended while muted. One targeted toggle was already sent;
            // never retry an unverified toggle because a late first action could invert the state.
            logger.notice("Owned ChatGPT Voice restoration was not observable; ownership ended without retry pid=\(ownedPID, privacy: .public)")
            return .restoredUnverified
        }
    }

}

final class SystemChatGPTVoiceMuteTransport: ChatGPTVoiceMuteTransport, ChatGPTVoiceSpeakerTransport, @unchecked Sendable {
    static let applicationPath = "/Applications/ChatGPT.app"
    static let shortcutCommand = "realtimeVoice.toggleMicrophoneMute"
    static let shortcutAccelerator = "Command+Control+Option+Shift+F20"
    static let speakerShortcutCommand = "realtimeVoice.toggleOutputMute"
    private static let shortcutPostLock = NSLock()

    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "ChatGPTVoiceMuteTransport"
    )

    func snapshot() async -> ChatGPTVoiceInputSnapshot? {
        await Task.detached(priority: .utility) {
            Self.readSnapshot()
        }.value
    }

    func postMicrophoneToggle(
        from before: ChatGPTVoiceInputSnapshot,
        toward target: ChatGPTVoiceMicrophoneState,
        using authority: ChatGPTVoiceShortcutAuthority
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) { [logger] in
            // Resolved for every post, so a binding edited since the mute is never answered
            // with a chord ChatGPT no longer maps to this command.
            guard let call = before.call, let shortcut = Self.shortcut(for: authority) else {
                logger.error("ChatGPT Voice microphone shortcut is missing or changed; refusing targeted input")
                return false
            }
            // Give a visible manual change made after the snapshot priority over the
            // shortcut. Do not lengthen the unknown-state branch with a second scan.
            if before.microphoneState != nil,
               Self.microphoneState(applicationPID: call.applicationPID) == target {
                logger.notice("ChatGPT Voice microphone already reached the requested state before dispatch")
                return false
            }
            // Refresh call identity at the event boundary. A new call can reuse
            // the same PID while the earlier Accessibility read is in flight.
            guard let application = Self.expectedApplication(),
                  application.processIdentifier == call.applicationPID,
                  Self.voiceCall(for: application) == call
            else {
                logger.notice("ChatGPT Voice call changed before microphone shortcut dispatch")
                return false
            }
            guard Self.postTargetedShortcut(shortcut, applicationPID: call.applicationPID) else {
                logger.error("Could not post the targeted ChatGPT Voice microphone shortcut pid=\(call.applicationPID, privacy: .public)")
                return false
            }
            logger.notice("Posted one ChatGPT Voice microphone shortcut toward \(String(describing: target), privacy: .public) pid=\(call.applicationPID, privacy: .public)")
            return true
        }.value
    }

    func activeSpeakerCall() async -> ChatGPTVoiceCall? {
        await Task.detached(priority: .userInitiated) { () -> ChatGPTVoiceCall? in
            guard AXIsProcessTrusted(),
                  Self.configuredSpeakerShortcut() != nil,
                  let application = Self.expectedApplication()
            else { return nil }
            return Self.voiceCall(for: application)
        }.value
    }

    func postSpeakerToggle(
        for call: ChatGPTVoiceCall, mute: Bool
    ) async -> ChatGPTVoiceSpeakerPost {
        await Task.detached(priority: .userInitiated) { () -> ChatGPTVoiceSpeakerPost in
            guard let application = Self.expectedApplication(),
                  application.processIdentifier == call.applicationPID,
                  mute || Self.voiceCall(for: application) == call
            else { return .skipped }
            let controls = Self.readVoiceControls(applicationPID: call.applicationPID, channel: .speaker)
            // A saved call alone is insufficient. For hidden speaker state,
            // require independent evidence from a live native Voice control.
            guard controls.voiceControlFound, controls.isMuted != mute else { return .skipped }
            // Check session identity again after the AX read. A new Voice call
            // can appear in the same desktop process.
            guard Self.voiceCall(for: application) == call,
                  let shortcut = Self.configuredSpeakerShortcut(),
                  Self.postTargetedShortcut(shortcut, applicationPID: call.applicationPID)
            else { return .skipped }
            return .posted(priorStateReadable: controls.isMuted != nil)
        }.value
    }

    private static func configuredSpeakerShortcut() -> ChatGPTVoiceShortcut? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/keybindings.json")
        let resolution = ChatGPTVoiceShortcut.resolve(
            keybindings: try? Data(contentsOf: url), command: speakerShortcutCommand
        )
        guard case .resolved(let shortcut) = resolution,
              shortcut.matchesLayout(producedCharacters: producedCharacters(for: shortcut))
        else { return nil }
        return shortcut
    }

    private static func voiceCall(for application: NSRunningApplication) -> ChatGPTVoiceCall? {
        guard !application.isTerminated,
              let launchedAt = application.launchDate,
              let sessionID = ChatGPTVoiceSessionBoundaryReader.uniqueActiveSession(since: launchedAt)
        else { return nil }
        return .init(applicationPID: application.processIdentifier, sessionID: sessionID)
    }

    private static func postTargetedShortcut(
        _ shortcut: ChatGPTVoiceShortcut,
        applicationPID: pid_t
    ) -> Bool {
        guard isExpectedChatGPTApplicationPID(applicationPID),
              AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.virtualKey, keyDown: false)
        else { return false }

        // A recording may need both channels. Keep each down/up pair together
        // even when their read-only preflights finish at the same time.
        shortcutPostLock.lock()
        defer { shortcutPostLock.unlock() }
        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.timestamp = mach_absolute_time()
        keyDown.postToPid(applicationPID)
        keyUp.timestamp = mach_absolute_time()
        keyUp.postToPid(applicationPID)
        return true
    }

    func microphoneStateAfterToggle(for call: ChatGPTVoiceCall) async -> ChatGPTVoiceMicrophoneState? {
        // One delayed, bounded observation is enough to distinguish a visible state change.
        // Repeated AX traversal was a rejected source of VoiceInk++ UI lag, and an unreadable
        // background surface already has the paired one-shot lease fallback above.
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            return nil
        }
        guard let current = await snapshot(),
              current.call == call else {
            return nil
        }
        return current.microphoneState
    }

    static func readSnapshot() -> ChatGPTVoiceInputSnapshot? {
        guard let application = expectedApplication() else { return nil }
        let processObjects = coreAudioProcessObjects()
        let inputIsRunning = processObjects.contains { processObject in
            guard let pid = processPID(for: processObject),
                  let executablePath = executablePath(for: pid),
                  belongsToChatGPTApplication(executablePath) else {
                return false
            }
            return uint32Property(
                kAudioProcessPropertyIsRunningInput,
                object: processObject
            ) == 1
        }
        // Bind the AX read to the call observed before it begins. The sender
        // checks this same call again before pressing the shortcut.
        let call = inputIsRunning ? voiceCall(for: application) : nil
        return ChatGPTVoiceInputSnapshot(
            applicationPID: application.processIdentifier,
            isInputRunning: inputIsRunning,
            microphoneState: call != nil
                ? microphoneState(applicationPID: application.processIdentifier)
                : nil,
            call: call
        )
    }

    private static func expectedApplication() -> NSRunningApplication? {
        let matchingApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).filter { app in
            guard !app.isTerminated,
                  let bundleURL = app.bundleURL else { return false }
            return normalizedPath(bundleURL.path) == normalizedPath(applicationPath)
        }
        guard matchingApps.count == 1,
              let application = matchingApps.first,
              isExpectedChatGPTApplicationPID(application.processIdentifier) else {
            return nil
        }
        return application
    }

    /// Reads only the current accessible label of ChatGPT Voice's microphone button. The previous
    /// listener experiment failed because `AXPress` could report success without changing state and
    /// its pointer fallback stole Ethan's mouse. This bounded traversal performs no AX action or
    /// attribute write; it exists solely to make the proven keyboard-command lease reversible.
    static func microphoneState(applicationPID: pid_t) -> ChatGPTVoiceMicrophoneState? {
        readVoiceControls(applicationPID: applicationPID, channel: .microphone)
            .isMuted.map { $0 ? .muted : .listening }
    }

    private enum VoiceControlChannel { case microphone, speaker }

    private static func readVoiceControls(
        applicationPID: pid_t, channel: VoiceControlChannel
    ) -> (isMuted: Bool?, voiceControlFound: Bool) {
        guard AXIsProcessTrusted(),
              isExpectedChatGPTApplicationPID(applicationPID) else {
            return (nil, false)
        }

        let application = AXUIElementCreateApplication(applicationPID)
        let windows = elementArrayAttribute(kAXWindowsAttribute, from: application)
        var queue = (windows.isEmpty ? [application] : windows).map { ($0, 0) }
        var index = 0
        var visited: [AXUIElement] = []
        var voiceControlFound = false
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))

        while index < queue.count,
              visited.count < 700,
              ContinuousClock.now < deadline {
            let (element, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)

            if stringAttribute(kAXRoleAttribute, from: element) == kAXButtonRole,
               boolAttribute(kAXEnabledAttribute, from: element) != false {
                for attribute in [
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXHelpAttribute,
                    kAXValueAttribute
                ] {
                    guard let label = stringAttribute(attribute, from: element) else { continue }
                    switch channel {
                    case .microphone:
                        if let state = microphoneState(accessibilityLabel: label) {
                            return (state == .muted, true)
                        }
                    case .speaker:
                        if let muted = speakerMuteState(accessibilityLabel: label) {
                            return (muted, true)
                        }
                        if microphoneState(accessibilityLabel: label) != nil
                            || ["end voice", "end voice chat", "stop voice chat"].contains(
                                label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            ) {
                            voiceControlFound = true
                        }
                    }
                }
            }

            guard depth < 14 else { continue }
            let children = mergedChildren(of: element)
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }

        return (nil, voiceControlFound)
    }

    static func speakerMuteState(accessibilityLabel: String) -> Bool? {
        switch accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mute speakers": return false
        case "unmute speakers": return true
        default: return nil
        }
    }

    static func microphoneState(
        accessibilityLabel: String
    ) -> ChatGPTVoiceMicrophoneState? {
        let normalized = accessibilityLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "mute microphone", "turn off microphone":
            return .listening
        case "unmute microphone", "turn on microphone":
            return .muted
        default:
            return nil
        }
    }

    private static func mergedChildren(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            "AXChildrenInNavigationOrder",
            kAXVisibleChildrenAttribute,
            kAXChildrenAttribute
        ]
        var merged: [AXUIElement] = []
        for attribute in attributes {
            for candidate in elementArrayAttribute(attribute, from: element)
                where !merged.contains(where: { CFEqual($0, candidate) }) {
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func elementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    static func belongsToChatGPTApplication(_ executablePath: String) -> Bool {
        let normalizedExecutable = normalizedPath(executablePath)
        let normalizedApplication = normalizedPath(applicationPath)
        return normalizedExecutable == normalizedApplication
            || normalizedExecutable.hasPrefix(normalizedApplication + "/Contents/")
    }

    static func hasExpectedShortcutBinding(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/keybindings.json")
    ) -> Bool {
        struct Binding: Decodable {
            let command: String
            let key: String?
        }

        guard let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode([Binding].self, from: data) else {
            return false
        }
        return bindings.contains {
            $0.command == shortcutCommand && $0.key == shortcutAccelerator
        }
    }

    /// The chord this Mac's own configuration binds to the real microphone command, for paired
    /// requests and the readiness probe. It reads configuration and builds an unposted event;
    /// it never writes `keybindings.json`, because that file is the user's choice to keep.
    static func deviceShortcutResolution(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/keybindings.json")
    ) -> ChatGPTVoiceShortcutResolution {
        let resolution = ChatGPTVoiceShortcut.resolve(
            keybindings: try? Data(contentsOf: url),
            command: shortcutCommand
        )
        guard case .resolved(let shortcut) = resolution,
              !shortcut.matchesLayout(producedCharacters: producedCharacters(for: shortcut)) else {
            return resolution
        }
        return .unsupported
    }

    private static func shortcut(
        for authority: ChatGPTVoiceShortcutAuthority
    ) -> ChatGPTVoiceShortcut? {
        switch authority {
        case .acceptedLocalBinding:
            return hasExpectedShortcutBinding() ? .acceptedLocal : nil
        case .deviceConfiguredBinding:
            guard case .resolved(let shortcut) = deviceShortcutResolution() else { return nil }
            return shortcut
        }
    }

    /// What the current layout types on this chord's key. Reading a never-posted event avoids
    /// the Text Input Source APIs, which are not safe away from the main thread.
    private static func producedCharacters(for shortcut: ChatGPTVoiceShortcut) -> String? {
        guard shortcut.layoutCharacter != nil,
              let source = CGEventSource(stateID: .privateState),
              let probe = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: shortcut.virtualKey,
                  keyDown: true
              ) else {
            return nil
        }
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        probe.keyboardGetUnicodeString(
            maxStringLength: units.count,
            actualStringLength: &length,
            unicodeString: &units
        )
        return length > 0 ? String(utf16CodeUnits: units, count: length) : nil
    }

    private static func isExpectedChatGPTApplicationPID(_ pid: pid_t) -> Bool {
        guard let path = executablePath(for: pid) else { return false }
        return normalizedPath(path) == normalizedPath(
            applicationPath + "/Contents/MacOS/ChatGPT"
        )
    }

    private static func coreAudioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0 else {
            return []
        }

        var processObjects = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &processObjects
        ) == noErr else {
            return []
        }
        return processObjects
    }

    private static func processPID(for processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &size,
            &pid
        ) == noErr,
        pid > 0 else {
            return nil
        }
        return pid
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        object: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
