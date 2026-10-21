import Foundation
import Combine
import Darwin

/// Annotation stays downstream of capture: keep both PCM sinks and Ethan's overlapping words.
struct SpokenReminderWindow: Equatable {
    let id: UUID
    let start: Date
    let end: Date
}

@MainActor
final class SpokenReminderAnnotationState: ObservableObject {
    static let shared = SpokenReminderAnnotationState()
    struct Snapshot: Equatable {
        var windows: [SpokenReminderWindow] = []
        var active = false
    }
    @Published private(set) var snapshot = Snapshot()
    func publish(_ value: Snapshot) { if snapshot != value { snapshot = value } }
}

struct CodexSpeechPlaybackMessage: Decodable {
    let version: Int
    let mode: String
    let type: String
    let speechID: UUID
    let pid: Int32
    let reason: String
    let maxDurationSeconds: Double?
    let audioPID: Int32?
    let startedAtUptime: Double?
    let endedAtUptime: Double?

    static func decode(_ payload: String) -> Self? {
        guard payload.utf8.count <= 2_048,
              let m = try? JSONDecoder().decode(Self.self, from: Data(payload.utf8)),
              ((m.version == 2 && m.mode == "annotate") || (m.version == 3 && m.mode == "idle-only")),
              m.reason == "codex-spoken-reminder",
              ["begin", "playback-started", "heartbeat", "end"].contains(m.type), m.pid > 1,
              m.audioPID == nil || m.audioPID! > 1,
              m.startedAtUptime == nil || (m.startedAtUptime!.isFinite && m.startedAtUptime! >= 0),
              m.endedAtUptime == nil || (m.endedAtUptime!.isFinite && m.endedAtUptime! >= 0) else { return nil }
        if m.type == "begin" {
            guard let d = m.maxDurationSeconds, d.isFinite, d > 0, d <= 30 else { return nil }
        }
        if ["playback-started", "heartbeat"].contains(m.type) {
            guard m.audioPID != nil, m.startedAtUptime != nil else { return nil }
        }
        return m
    }
}

/// PID alone is reusable. Read start time and user, never argv, audio, focus or player state.
struct SpeechPlaybackProcessIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    static func read(_ pid: Int32, audioChild: Bool = false) -> Self? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        guard result == size, info.pbi_uid == geteuid(), info.pbi_status != SZOMB else { return nil }
        if audioChild {
            var path = [CChar](repeating: 0, count: 4_096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { return nil }
            let executable = String(cString: path)
            let systemPython = executable == "/usr/bin/python3" ||
                ((executable.hasPrefix("/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/") ||
                  executable.hasPrefix("/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/")) &&
                 executable.hasSuffix("/Resources/Python.app/Contents/MacOS/Python"))
            let parkedLauncher = systemPython
            guard executable == "/usr/bin/afplay" || parkedLauncher else { return nil }
        }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

struct SpeechPlaybackLeaseBook {
    struct Lease {
        let owner: SpeechPlaybackProcessIdentity
        let armedAt: TimeInterval
        let deadline: TimeInterval
        var audio: SpeechPlaybackProcessIdentity?
        var startedAt: TimeInterval?
    }
    struct Window: Equatable {
        let id: UUID
        let start: TimeInterval
        let end: TimeInterval
    }
    private(set) var leases: [UUID: Lease] = [:]
    private struct Retired {
        let owner: SpeechPlaybackProcessIdentity
        let startedAt: TimeInterval?
        let deadline: TimeInterval
        let expiresAt: TimeInterval
    }
    private var ended: [UUID: Retired] = [:]
    private var completed: [Window] = []
    static let acousticTail: TimeInterval = 0.2

    mutating func accept(_ m: CodexSpeechPlaybackMessage, now: TimeInterval,
                         owner: SpeechPlaybackProcessIdentity?, audio: SpeechPlaybackProcessIdentity?) -> Bool {
        guard m.version == 2, m.mode == "annotate" else { return false }
        ended = ended.filter { $0.value.expiresAt > now }
        switch m.type {
        case "begin":
            if let l = leases[m.speechID] { return l.owner == owner && now < l.deadline }
            guard ended[m.speechID] == nil, ended.count < 128, leases.count < 16,
                  let owner, owner.pid == m.pid, let d = m.maxDurationSeconds,
                  d.isFinite, d > 0, d <= 30 else { return false }
            // Readiness is not audible playback. Failed Process.run produces no annotation.
            leases[m.speechID] = Lease(owner: owner, armedAt: now, deadline: now + d)
            return true
        case "playback-started", "heartbeat":
            guard var l = leases[m.speechID], l.owner == owner, now < l.deadline,
                  let audio, audio.pid == m.audioPID, let start = m.startedAtUptime,
                  start >= l.armedAt - 0.1, start <= now + 0.1, start < l.deadline else { return false }
            // Freeze actual start and exact child. Heartbeats recover a lost start, not extend it.
            if let existing = l.audio, existing != audio { return false }
            if let existing = l.startedAt, existing != start { return false }
            l.audio = audio; l.startedAt = start; leases[m.speechID] = l
            return true
        case "end":
            guard let l = leases[m.speechID] else {
                // The 100ms child-death sweep can win the race with a reaped
                // child's final notice. ACK only its frozen original owner;
                // refine a conservative end earlier, never extend or restart.
                guard let r = ended[m.speechID], r.owner == owner else { return false }
                if let start = r.startedAt {
                    guard let end = m.endedAtUptime, end >= start, end <= now + 0.1,
                          end <= r.deadline + 0.1 else { return false }
                    if let index = completed.firstIndex(where: { $0.id == m.speechID }) {
                        let old = completed[index]
                        completed[index] = Window(id: old.id, start: old.start,
                            end: min(old.end, min(end, r.deadline) + Self.acousticTail))
                    }
                }
                return true
            }
            guard l.owner == owner else { return false }
            if let start = l.startedAt {
                guard let end = m.endedAtUptime, end >= start, end <= now + 0.1,
                      end <= l.deadline + 0.1 else { return false }
                retire(m.speechID, end: min(end, l.deadline), now: now)
            } else { retire(m.speechID, end: now, now: now) }
            return true
        default: return false
        }
    }
    mutating func prune(now: TimeInterval, isAlive: (SpeechPlaybackProcessIdentity) -> Bool) {
        for (id, l) in leases {
            // A child can survive helper death; missing owner/heartbeat is not end proof.
            if now >= l.deadline || (l.audio.map { !isAlive($0) } ?? false) {
                retire(id, end: min(now, l.deadline), now: now)
            }
        }
    }
    private mutating func retire(_ id: UUID, end: TimeInterval, now: TimeInterval) {
        guard let l = leases.removeValue(forKey: id) else { return }
        if let start = l.startedAt {
            completed.append(Window(id: id, start: start, end: end + Self.acousticTail))
            if completed.count > 256 { completed.removeFirst(completed.count - 256) }
        }
        ended[id] = Retired(owner: l.owner, startedAt: l.startedAt,
                            deadline: l.deadline, expiresAt: now + 60)
    }
    func windows(at now: TimeInterval) -> [Window] {
        completed + leases.compactMap { id, l in
            l.startedAt.map { Window(id: id, start: $0, end: min(now, l.deadline) + Self.acousticTail) }
        }
    }
    func isAnnotationActive(at now: TimeInterval) -> Bool {
        leases.values.contains { $0.startedAt != nil } || completed.contains { $0.end > now }
    }
}

/// Delivery ownership also covers microphone-off typing; it is not capture proof.
/// Keep uncertain startup and paused voice sessions conservative, but allow speech
/// beside a settled typing editor. Microphone transitions close that exception
/// before the recorder can yield into hardware startup.
enum CodexSpeechCapturePolicy {
    static func blocksReminder(hasCaptureOwner: Bool, pendingStart: Bool,
                              pendingTypingStart: Bool, liveState: RecordingState?,
                              microphoneOff: Bool, beganMicrophoneOff: Bool,
                              microphoneTransitionPending: Bool) -> Bool {
        if pendingStart { return !pendingTypingStart }
        guard hasCaptureOwner else { return false }
        let settledTyping = liveState == .recording
            || (liveState == .starting && beganMicrophoneOff)
        return !(settledTyping && microphoneOff && !microphoneTransitionPending)
    }
}

/// Recording owns priority. This channel controls only the reminder's audio child;
/// it never mutes the microphone, alters Pause, or classifies the user's words.
@MainActor
final class CodexSpeechPlaybackReceiver: ObservableObject {
    static let shared = CodexSpeechPlaybackReceiver()
    static let notificationName = Notification.Name("com.ethansk.codex.speechPlayback")
    static let acknowledgementName = Notification.Name("com.ethansk.codex.speechPlaybackAck")
    private struct Admission {
        let owner: SpeechPlaybackProcessIdentity
        let deadline: TimeInterval
        let allowsRecording: Bool
        var audio: SpeechPlaybackProcessIdentity?
    }
    private let center: DistributedNotificationCenter
    private var observer: NSObjectProtocol?
    private var admissions: [UUID: Admission] = [:]
    private var recordingActive: () -> Bool?
    private let identity: (Int32, Bool) -> SpeechPlaybackProcessIdentity?
    private let parentMatches: (Int32, Int32) -> Bool
    private let resumeAudio: (SpeechPlaybackProcessIdentity) -> Void
    private let stopAudio: (SpeechPlaybackProcessIdentity) -> Void
    private let sendAck: (([String: Any]) -> Void)?
    private let uptime: () -> TimeInterval
    @Published private(set) var announcementOverrideArmed = false
    private var overrideDeadline: TimeInterval?
    private var overrideTimer: Timer?

    /// Ethan's "override the safeguard" is one explicit, expiring admission.
    /// Keep capture untouched; a new recording still revokes the audio child.
    func allowNextAnnouncementOnce() {
        overrideDeadline = uptime() + 30
        announcementOverrideArmed = true
        overrideTimer?.invalidate()
        overrideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.cancelAnnouncementOverride() }
        }
    }

    func cancelAnnouncementOverride() {
        overrideDeadline = nil
        announcementOverrideArmed = false
        overrideTimer?.invalidate()
        overrideTimer = nil
    }

    init(center: DistributedNotificationCenter = .default(),
         recordingActive: @escaping () -> Bool? = { nil },
         identity: @escaping (Int32, Bool) -> SpeechPlaybackProcessIdentity? = {
             SpeechPlaybackProcessIdentity.read($0, audioChild: $1)
         },
         parentMatches: @escaping (Int32, Int32) -> Bool = { child, owner in
             var info = proc_bsdinfo()
             let size = MemoryLayout<proc_bsdinfo>.size
             return withUnsafeMutablePointer(to: &info) {
                 proc_pidinfo(child, PROC_PIDTBSDINFO, 0, $0, Int32(size))
             } == size && info.pbi_ppid == UInt32(owner)
         },
         resumeAudio: @escaping (SpeechPlaybackProcessIdentity) -> Void = { child in
             if SpeechPlaybackProcessIdentity.read(child.pid, audioChild: true) == child {
                 kill(child.pid, SIGUSR1)
             }
         },
         stopAudio: @escaping (SpeechPlaybackProcessIdentity) -> Void = { child in
             // Revalidate PID incarnation and executable immediately before stopping
             // our admitted afplay, never the recorder or an unrelated process.
             if SpeechPlaybackProcessIdentity.read(child.pid, audioChild: true) == child {
                 kill(child.pid, SIGKILL)
             }
         },
         sendAck: (([String: Any]) -> Void)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.center = center; self.recordingActive = recordingActive
        self.identity = identity; self.parentMatches = parentMatches
        self.resumeAudio = resumeAudio; self.stopAudio = stopAudio; self.sendAck = sendAck
        self.uptime = uptime
        observer = center.addObserver(forName: Self.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let payload = note.userInfo?["payload"] as? String,
                  let message = CodexSpeechPlaybackMessage.decode(payload) else { return }
            Task { @MainActor [weak self] in self?.receive(message) }
        }
    }

    func configure(recordingActive: @escaping () -> Bool?) {
        self.recordingActive = recordingActive
    }

    /// Called synchronously at reservation, before microphone startup. The player
    /// also checks admission immediately before launch and while running, covering
    /// a start notice that races the reservation. Capture itself never waits on TTS.
    func silenceBeforeRecording() {
        cancelAnnouncementOverride()
        for (id, admission) in admissions {
            if let child = admission.audio { stopAudio(child) }
            acknowledge(id, type: "state", allowed: false)
        }
        admissions.removeAll()
    }

    func receive(_ message: CodexSpeechPlaybackMessage) {
        // v2 is historical annotation data only. Old helpers fail their readiness
        // check instead of restoring Potential ignore or microphone suppression.
        guard message.version == 3, message.mode == "idle-only",
              let owner = identity(message.pid, false) else { return }
        let now = uptime()
        if let deadline = overrideDeadline, now >= deadline { cancelAnnouncementOverride() }
        admissions = admissions.filter {
            $0.value.deadline > now && (identity($0.value.owner.pid, false) == $0.value.owner ||
                $0.value.audio.map { identity($0.pid, true) == $0 } == true)
        }
        if message.type == "end" {
            guard admissions[message.speechID]?.owner == owner else { return }
            admissions.removeValue(forKey: message.speechID)
            acknowledge(message.speechID, type: "end-ack", allowed: false)
            return
        }
        let captureState = recordingActive()
        let idle = captureState == false // Unknown/startup is never idle.
        if message.type == "begin" {
            if let previous = admissions[message.speechID], previous.owner != owner { return }
            let override = announcementOverrideArmed && captureState != nil
            if idle || override, admissions[message.speechID] == nil, admissions.count < 16,
               let budget = message.maxDurationSeconds, budget > 0, budget <= 30 {
                admissions[message.speechID] = Admission(owner: owner, deadline: now + budget,
                                                       allowsRecording: override)
                if override { cancelAnnouncementOverride() }
            }
            acknowledge(message.speechID, type: "begin-ack",
                        allowed: admissions[message.speechID].map {
                            captureState != nil && (idle || $0.allowsRecording)
                        } ?? false)
            return
        }
        guard var admission = admissions[message.speechID], admission.owner == owner,
              let pid = message.audioPID, let child = identity(pid, true), parentMatches(pid, message.pid),
              admission.audio == nil || admission.audio == child else {
            if let pid = message.audioPID, let child = identity(pid, true), parentMatches(pid, message.pid) {
                stopAudio(child)
            }
            acknowledge(message.speechID, type: "state", allowed: false)
            return
        }
        let firstStart = admission.audio == nil
        admission.audio = child
        admissions[message.speechID] = admission
        let allowed = captureState != nil && (idle || admission.allowsRecording)
        if allowed, firstStart { resumeAudio(child) }
        if !allowed {
            stopAudio(child)
            admissions.removeValue(forKey: message.speechID)
        }
        acknowledge(message.speechID, type: "state", allowed: allowed)
    }

    private func acknowledge(_ id: UUID, type: String, allowed: Bool) {
        let payload: [String: Any] = ["version": 3, "mode": "idle-only", "speechID": id.uuidString,
            "type": type, "playbackAllowed": allowed, "appPID": getpid()]
        if let sendAck { sendAck(payload); return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        center.postNotificationName(Self.acknowledgementName, object: nil,
                                    userInfo: ["payload": text], deliverImmediately: true)
    }
}
