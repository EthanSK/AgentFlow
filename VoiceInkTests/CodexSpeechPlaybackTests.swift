import AppKit
import SwiftUI
import AVFoundation
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct CodexSpeechPlaybackTests {
    private let owner = SpeechPlaybackProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 2)
    private let child = SpeechPlaybackProcessIdentity(pid: 101, startSeconds: 3, startMicroseconds: 4)
    private func message(_ type: String, id: UUID, budget: Double = 10,
                         start: Double? = nil, end: Double? = nil) -> CodexSpeechPlaybackMessage {
        .init(version: 2, mode: "annotate", type: type, speechID: id, pid: 100,
              reason: "codex-spoken-reminder", maxDurationSeconds: budget,
              audioPID: start == nil ? nil : 101, startedAtUptime: start, endedAtUptime: end)
    }

    @Test func protocolRejectsMuteV1MalformedUnboundedAndUnrelatedMessages() throws {
        let good: [String: Any] = ["version": 2, "mode": "annotate", "type": "begin",
            "speechID": UUID().uuidString, "pid": 100, "reason": "codex-spoken-reminder", "maxDurationSeconds": 10]
        func decode(_ object: [String: Any]) throws -> CodexSpeechPlaybackMessage? {
            CodexSpeechPlaybackMessage.decode(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        #expect(try decode(good) != nil)
        for (key, value) in [("version", 1 as Any), ("mode", "mute"), ("type", "pause"),
                             ("pid", 0), ("speechID", "bad"), ("reason", "recordingStarted"),
                             ("maxDurationSeconds", 31), ("maxDurationSeconds", 0)] {
            var invalid = good; invalid[key] = value
            #expect(try decode(invalid) == nil)
        }
        #expect(CodexSpeechPlaybackMessage.decode(String(repeating: "x", count: 2_049)) == nil)
        var missingStart = good; missingStart["type"] = "playback-started"
        #expect(try decode(missingStart) == nil)
    }

    @Test func readinessAndFailedLaunchNeverAnnotateSpeech() {
        var book = SpeechPlaybackLeaseBook()
        let id = UUID()
        let accepted = book.accept(message("begin", id: id), now: 1, owner: owner, audio: nil)
        #expect(accepted && !book.isAnnotationActive(at: 2) && book.windows(at: 2).isEmpty)
        let ended = book.accept(message("end", id: id), now: 3, owner: owner, audio: nil)
        #expect(ended && book.windows(at: 3).isEmpty)
    }

    @Test func duplicateBeginStartAndHeartbeatFreezeBudgetChildAndClock() {
        var book = SpeechPlaybackLeaseBook()
        let id = UUID()
        let began = book.accept(message("begin", id: id), now: 1, owner: owner, audio: nil)
        let duplicate = book.accept(message("begin", id: id, budget: 30), now: 8, owner: owner, audio: nil)
        let start = book.accept(message("heartbeat", id: id, start: 2), now: 8, owner: owner, audio: child)
        let repeatStart = book.accept(message("playback-started", id: id, start: 2), now: 9, owner: owner, audio: child)
        let changed = book.accept(message("heartbeat", id: id, start: 3), now: 10, owner: owner, audio: child)
        #expect(began && duplicate && start && repeatStart && !changed)
        #expect(book.leases[id]?.deadline == 11 && book.leases[id]?.startedAt == 2)
        let reused = SpeechPlaybackProcessIdentity(pid: 101, startSeconds: 99, startMicroseconds: 4)
        let replaced = book.accept(message("heartbeat", id: id, start: 2), now: 10, owner: owner, audio: reused)
        #expect(!replaced)
        book.prune(now: 11, isAlive: { _ in true })
        #expect(book.leases.isEmpty && book.isAnnotationActive(at: 11.1))
        #expect(!book.isAnnotationActive(at: 11.21))
        let replay = book.accept(message("begin", id: id), now: 12, owner: owner, audio: nil)
        #expect(!replay)
    }

    @Test func nestedEndAndAcousticTailDoNotClearAnotherPlayback() {
        var book = SpeechPlaybackLeaseBook()
        let a = UUID(), b = UUID()
        for id in [a, b] {
            let began = book.accept(message("begin", id: id), now: 1, owner: owner, audio: nil)
            let started = book.accept(message("playback-started", id: id, start: 2), now: 2, owner: owner, audio: child)
            #expect(began && started)
        }
        let endedA = book.accept(message("end", id: a, end: 3), now: 3, owner: owner, audio: nil)
        #expect(endedA && book.isAnnotationActive(at: 3.5))
        let endedB = book.accept(message("end", id: b, end: 4), now: 4, owner: owner, audio: nil)
        #expect(endedB && book.isAnnotationActive(at: 4.1))
        #expect(!book.isAnnotationActive(at: 4.21) && book.windows(at: 5).count == 2)
    }

    @Test func futureClocksDeadChildrenAndHelperCrashRemainBounded() {
        var book = SpeechPlaybackLeaseBook()
        let id = UUID()
        let began = book.accept(message("begin", id: id, budget: 2), now: 1, owner: owner, audio: nil)
        let future = book.accept(message("playback-started", id: id, start: 2), now: 1.1, owner: owner, audio: child)
        let stale = book.accept(message("playback-started", id: id, start: 0.5), now: 1.1, owner: owner, audio: child)
        let started = book.accept(message("playback-started", id: id, start: 1.2), now: 1.2, owner: owner, audio: child)
        #expect(began && !future && !stale && started)
        book.prune(now: 2, isAlive: { $0 == child }) // Audio survives helper death.
        #expect(book.isAnnotationActive(at: 2))
        book.prune(now: 3, isAlive: { _ in true })
        #expect(!book.isAnnotationActive(at: 3.21))
        let reused = SpeechPlaybackProcessIdentity(pid: 100, startSeconds: 99, startMicroseconds: 2)
        let wrongOwnerEnd = book.accept(message("end", id: id, end: 3), now: 3, owner: reused, audio: nil)
        #expect(!wrongOwnerEnd)
    }

    @Test func endAfterChildDeathSweepIsIdempotentAndCannotExtendPlayback() {
        var book = SpeechPlaybackLeaseBook()
        let id = UUID()
        let began = book.accept(message("begin", id: id), now: 1, owner: owner, audio: nil)
        let started = book.accept(message("playback-started", id: id, start: 2), now: 2, owner: owner, audio: child)
        #expect(began && started)
        book.prune(now: 3.1, isAlive: { _ in false })
        let ended = book.accept(message("end", id: id, end: 3), now: 3.15, owner: owner, audio: nil)
        #expect(ended)
        #expect(book.windows(at: 4).first?.end == 3.2)
        let duplicateEnd = book.accept(message("end", id: id, end: 3.5), now: 4, owner: owner, audio: nil)
        #expect(duplicateEnd)
        #expect(book.windows(at: 4).first?.end == 3.2 && !book.isAnnotationActive(at: 4))
        let replay = book.accept(message("begin", id: id), now: 4, owner: owner, audio: nil)
        #expect(!replay)
    }

    @Test func syntheticWAVAndRealtimeRetainAllBeforeDuringAfterPCM() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        let samples = try #require(buffer.floatChannelData)[0]
        for i in 0..<100 { samples[i] = 0.25 }
        let url = directory.appendingPathComponent("synthetic.wav")
        var output: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        var streamedChunks = 0
        for _ in 0..<3 {
            try output?.write(from: buffer)
            streamedChunks += 1 // Production has no reminder gate at either sink.
        }
        output = nil
        #expect(try AVAudioFile(forReading: url).length == 300 && streamedChunks == 3)
        #expect(!CoreAudioRecorder.shouldProcessInputBuffer(isRecording: true, isPaused: true))
    }

    @Test func productionCaptureHasNoReminderMuteOrOtherAppMutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let core = try String(contentsOf: root.appendingPathComponent("VoiceInk/CoreAudioRecorder.swift"), encoding: .utf8)
        let service = try String(contentsOf: root.appendingPathComponent("VoiceInk/Services/CodexSpeechPlaybackReceiver.swift"), encoding: .utf8)
        #expect(!core.contains("SpokenReminderCaptureGate") && !core.contains("reminderRenderToken"))
        #expect(core.contains("guard acceptsInputBuffers.load(ordering: .acquiring) else"))
        #expect(core.contains("let writeStatus = ExtAudioFileWrite") && core.contains("audioChunk(Data(bytes: outputBuffer"))
        for forbidden in ["pauseRecording(", "resumeRecording(", "RecordingActivityNotifier.",
                          "muteSystemAudio(", "AudioObjectSetPropertyData", "AXUIElement", "PlaybackController"] {
            #expect(!service.contains(forbidden))
        }
    }

    private func idleMessage(_ type: String, id: UUID) -> CodexSpeechPlaybackMessage {
        .init(version: 3, mode: "idle-only", type: type, speechID: id, pid: 100,
              reason: "codex-spoken-reminder", maxDurationSeconds: 20,
              audioPID: type == "playback-started" ? 101 : nil,
              startedAtUptime: type == "playback-started" ? ProcessInfo.processInfo.systemUptime : nil,
              endedAtUptime: nil)
    }

    @Test func typingOnlyDoesNotOwnReminderCapturePriority() {
        func blocks(_ state: RecordingState?, micOff: Bool = true,
                    beganOff: Bool = true, transition: Bool = false,
                    owner: Bool = true, pending: Bool = false, typing: Bool = false) -> Bool {
            CodexSpeechCapturePolicy.blocksReminder(hasCaptureOwner: owner,
                pendingStart: pending, pendingTypingStart: typing, liveState: state,
                microphoneOff: micOff, beganMicrophoneOff: beganOff,
                microphoneTransitionPending: transition)
        }
        #expect(!blocks(nil, owner: false))
        #expect(!blocks(nil, pending: true, typing: true))
        #expect(blocks(nil, pending: true))
        #expect(!blocks(.starting))
        #expect(!blocks(.recording))
        #expect(!blocks(.recording, beganOff: false)) // Explicit microphone off after voice.
        #expect(blocks(.starting, beganOff: false)) // Late Command cannot prove capture stopped.
        #expect(blocks(.recording, micOff: false))
        #expect(blocks(.recording, transition: true))
        #expect(blocks(.paused)) // Pause remains a reserved voice session.
        #expect(blocks(nil)) // Unresolved owner is not proof of typing-only.
    }

    @MainActor @Test func typingAdmissionSurvivesHeartbeatUntilMicrophoneEnable() {
        var transition = false
        var replies: [[String: Any]] = []
        var resumed = 0, stopped = 0
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: {
            CodexSpeechCapturePolicy.blocksReminder(hasCaptureOwner: true,
                pendingStart: false, pendingTypingStart: false, liveState: .recording,
                microphoneOff: true, beganMicrophoneOff: true,
                microphoneTransitionPending: transition)
        }, identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in true }, resumeAudio: { _ in resumed += 1 },
            stopAudio: { _ in stopped += 1 }, sendAck: { replies.append($0) })
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        receiver.receive(idleMessage("playback-started", id: id))
        let heartbeat = CodexSpeechPlaybackMessage(version: 3, mode: "idle-only",
            type: "heartbeat", speechID: id, pid: 100, reason: "codex-spoken-reminder",
            maxDurationSeconds: nil, audioPID: 101,
            startedAtUptime: ProcessInfo.processInfo.systemUptime, endedAtUptime: nil)
        receiver.receive(heartbeat)
        #expect(resumed == 1 && stopped == 0)
        #expect(replies.last?["playbackAllowed"] as? Bool == true)
        transition = true
        receiver.silenceBeforeRecording()
        receiver.receive(heartbeat)
        #expect(resumed == 1 && stopped == 2)
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
    }

    @Test func microphoneEnableRevokesSpeechBeforeBothHardwareAwaits() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/VoiceInkEngine.swift"), encoding: .utf8)
        let enables = engine.components(separatedBy: "try await recorder.enableMicrophoneCapture()")
        #expect(enables.count == 3)
        for prefix in enables.dropLast() {
            #expect(prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("CodexSpeechPlaybackReceiver.shared.silenceBeforeRecording()"))
        }
        let app = try String(contentsOf: root.appendingPathComponent("VoiceInk/VoiceInk.swift"), encoding: .utf8)
        #expect(app.contains("engine.map { $0.blocksSpokenReminders }"))
    }

    @MainActor @Test func recordingUnknownAndBusyDenyPlaybackThenIdleAdmits() {
        var active: Bool? = nil
        var replies: [[String: Any]] = []
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { active },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in true }, resumeAudio: { _ in }, stopAudio: { _ in },
            sendAck: { replies.append($0) })
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        active = true
        receiver.receive(idleMessage("begin", id: id))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        active = false
        receiver.receive(idleMessage("begin", id: id))
        #expect(replies.last?["playbackAllowed"] as? Bool == true)
        let count = replies.count
        receiver.receive(message("begin", id: UUID()))
        #expect(replies.count == count) // v2 cannot revive live annotation.
    }

    @MainActor @Test func explicitOverrideAdmitsOneRecordingAnnouncementAndKeepsItsHeartbeat() {
        var replies: [[String: Any]] = []
        var resumed = 0, stopped = 0
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { true },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in true }, resumeAudio: { _ in resumed += 1 },
            stopAudio: { _ in stopped += 1 }, sendAck: { replies.append($0) })
        receiver.allowNextAnnouncementOnce()
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        #expect(replies.last?["playbackAllowed"] as? Bool == true)
        #expect(!receiver.announcementOverrideArmed)
        receiver.receive(idleMessage("begin", id: id)) // Duplicate consumes no new grant.
        #expect(replies.last?["playbackAllowed"] as? Bool == true)
        receiver.receive(idleMessage("playback-started", id: id))
        receiver.receive(.init(version: 3, mode: "idle-only", type: "heartbeat", speechID: id,
            pid: 100, reason: "codex-spoken-reminder", maxDurationSeconds: nil,
            audioPID: 101, startedAtUptime: ProcessInfo.processInfo.systemUptime, endedAtUptime: nil))
        #expect(resumed == 1 && stopped == 0)
        #expect(replies.last?["playbackAllowed"] as? Bool == true)
        receiver.receive(idleMessage("begin", id: UUID()))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        receiver.silenceBeforeRecording() // A new capture reservation wins again.
        #expect(stopped == 1)
    }

    @MainActor @Test func overrideExpiresCancelsAndNeverBypassesUnknownCapture() {
        var now: TimeInterval = 100
        var active: Bool? = nil
        var replies: [[String: Any]] = []
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { active },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            sendAck: { replies.append($0) }, uptime: { now })
        receiver.allowNextAnnouncementOnce()
        receiver.receive(idleMessage("begin", id: UUID()))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        #expect(receiver.announcementOverrideArmed)
        active = true
        now = 130
        receiver.receive(idleMessage("begin", id: UUID()))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        #expect(!receiver.announcementOverrideArmed)
        receiver.allowNextAnnouncementOnce()
        receiver.cancelAnnouncementOverride()
        receiver.receive(idleMessage("begin", id: UUID()))
        #expect(replies.last?["playbackAllowed"] as? Bool == false)
        receiver.allowNextAnnouncementOnce()
        receiver.silenceBeforeRecording()
        #expect(!receiver.announcementOverrideArmed)
    }

    @MainActor @Test func recordingReservationStopsAdmittedChildBeforeCapture() {
        var active = false
        var resumed: [Int32] = [], stopped: [Int32] = []
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { active },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in true }, resumeAudio: { resumed.append($0.pid) },
            stopAudio: { stopped.append($0.pid) }, sendAck: { _ in })
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        receiver.receive(idleMessage("playback-started", id: id))
        #expect(resumed == [101])
        receiver.silenceBeforeRecording()
        active = true
        #expect(stopped == [101])
        receiver.receive(idleMessage("playback-started", id: id))
        #expect(resumed == [101] && stopped == [101, 101]) // Lost start can't resume.
    }

    @MainActor @Test func recordingBetweenAdmissionAndParkedStartNeverResumesAudio() {
        var active = false
        var resumed = 0, stopped = 0
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { active },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in true }, resumeAudio: { _ in resumed += 1 },
            stopAudio: { _ in stopped += 1 }, sendAck: { _ in })
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        active = true
        receiver.receive(idleMessage("playback-started", id: id))
        #expect(resumed == 0 && stopped == 1)
    }

    @MainActor @Test func unrelatedAudioChildIsNeverSignalled() {
        var signals = 0
        let receiver = CodexSpeechPlaybackReceiver(recordingActive: { false },
            identity: { pid, _ in pid == 100 ? self.owner : self.child },
            parentMatches: { _, _ in false }, resumeAudio: { _ in signals += 1 },
            stopAudio: { _ in signals += 1 }, sendAck: { _ in })
        let id = UUID()
        receiver.receive(idleMessage("begin", id: id))
        receiver.receive(idleMessage("playback-started", id: id))
        receiver.silenceBeforeRecording()
        #expect(signals == 0)
    }

    @MainActor @Test func parkedSystemChildOnlyRunsAfterIdleAdmission() throws {
        for recording in [false, true] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(atPath: marker.path + ".ready") }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", """
            import os,signal,sys,time
            admitted = False
            def admit(signum, frame):
                global admitted
                admitted = True
            signal.signal(signal.SIGUSR1, admit)
            signal.alarm(3)
            open(sys.argv[1]+'.ready','w').close()
            while not admitted:
                time.sleep(0.01)
            open(sys.argv[1],'w').write('ran')
            """, marker.path]
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
            let limit = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: marker.path + ".ready") && Date() < limit {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(SpeechPlaybackProcessIdentity.read(child.processIdentifier, audioChild: true) != nil)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            var active = false
            let receiver = CodexSpeechPlaybackReceiver(recordingActive: { active }, sendAck: { _ in })
            let id = UUID()
            receiver.receive(.init(version: 3, mode: "idle-only", type: "begin", speechID: id,
                pid: getpid(), reason: "codex-spoken-reminder", maxDurationSeconds: 10,
                audioPID: nil, startedAtUptime: nil, endedAtUptime: nil))
            active = recording
            receiver.receive(.init(version: 3, mode: "idle-only", type: "playback-started", speechID: id,
                pid: getpid(), reason: "codex-spoken-reminder", maxDurationSeconds: nil,
                audioPID: child.processIdentifier, startedAtUptime: ProcessInfo.processInfo.systemUptime, endedAtUptime: nil))
            let finish = Date().addingTimeInterval(2)
            while child.isRunning && Date() < finish { Thread.sleep(forTimeInterval: 0.01) }
            #expect(!child.isRunning)
            #expect(FileManager.default.fileExists(atPath: marker.path) == !recording)
        }
    }

    private func mixedReferences(_ start: Date) -> [LiveSelectionReference] {
        let refs: [LiveSelectionReference] = [
            .speechTiming(after: "Before", startedAt: start, endedAt: start.addingTimeInterval(1)),
            LiveSelectionReference("Quoted context")!.anchored(after: "Before"),
            .speechTiming(after: "Before my own request and unrelated reminder", startedAt: start.addingTimeInterval(2), endedAt: start.addingTimeInterval(4)),
            .speechTiming(after: "Before my own request and unrelated reminder After", startedAt: start.addingTimeInterval(6), endedAt: start.addingTimeInterval(7))
        ]
        return LiveSelectionReference.annotatingSpeech(refs,
            overlaps: [DateInterval(start: start.addingTimeInterval(2), end: start.addingTimeInterval(3.2))],
            sessionStartedAt: start, captureEndedAt: start.addingTimeInterval(7))
    }

    @MainActor @Test func mixedPromptHUDViewerRawAndCompactKeepEveryWord() throws {
        let transcript = "Before my own request and unrelated reminder After"
        let refs = mixedReferences(Date(timeIntervalSince1970: 100))
        let source = LiveSelectionReference.interleaving(refs, with: transcript, includeTiming: true)
        let events = AgentFlowPromptViewer.events(source)
        #expect(events.map(\.tag) == ["speech", "codex_selection", "potential_tts", "speech"])
        #expect(events.filter { $0.tag != "codex_selection" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") == transcript)
        #expect(source.contains("overlap_timing=\"utterance_window\"") && source.contains("My own speech may be included."))
        let hud = LiveSelectionReference.previewParts(refs, with: transcript)
        #expect(hud.contains(.potentialTTS("my own request and unrelated reminder")))
        let raw = LiveSelectionReference.interleaving(refs.filter(\.hasSpeechTiming), with: transcript)
        #expect(!raw.contains("potential_tts") && raw.split(whereSeparator: \.isWhitespace).joined(separator: " ") == transcript)
        let sections = LiveSelectionReference.compactPromptSections(refs, with: transcript)
        let bubble = try #require(AgentFlowPromptPreview.make(authoredText: transcript, sections: sections,
            fileURL: URL(fileURLWithPath: "/tmp/prompt.md")))
        #expect(bubble.contains("`<potential_tts>` my own request and unrelated reminder `</potential_tts>`"))
        let html = AgentFlowPromptViewer.html(source, rainbowStartIndex: 0)
        #expect(html.contains("Potential ignore") && html.contains("style=\"color:#fbbf24\">my own request"))
        #expect(AgentFlowPromptViewer.authoredWordCount(source) == 8)
        #expect(html.contains("style=\"color:#93fa70\">After</span>")) // Cursor advanced through amber words.

        // Inspectable real exported pair and the production SwiftUI HUD component, not a mock.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentflow-tts-overlap-404")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try AgentFlowPromptArchive.write(source, recordID: UUID(), directory: directory)
        try AgentFlowPromptArchive.writeViewer(source, for: file, rainbowStartIndex: 0)
        let viewer = try #require(AgentFlowPromptArchive.viewerURL(for: file))
        let view = LiveTranscriptView(text: transcript, potentialTTSActive: false, selectionReferences: refs, height: 130)
            .frame(width: 680, height: 130).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 130)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("hud.png"), options: .atomic)
        print("TTS_FIXTURE source=\(file.path) viewer=\(viewer.path) hud=\(directory.path)/hud.png")
    }

    @MainActor @Test func newRecordingsNeverAddPotentialIgnoreEvenWithLegacySnapshot() {
        let session = RecordingSession()
        let t = session.createdAt
        session.receiveReminderSnapshot(.init(windows: [.init(id: UUID(), start: t.addingTimeInterval(-1), end: t.addingTimeInterval(2))], active: true))
        #expect(!session.potentialTTSActive)
        #expect(!AgentFlowPromptArchive.interpretationReminder.contains("potential_tts"))
        session.endLiveSelectionCapture(at: t.addingTimeInterval(3))
        let source = LiveSelectionReference.interleaving(session.liveSelectionReferencesForDelivery,
            with: "Late final includes my real request", includeTiming: true)
        #expect(!source.contains("<potential_tts") && source.contains("timing=\"session_window\""))
        #expect(source.contains("Late final includes my real request"))
        #expect(!session.potentialTTSActive)
    }

    @MainActor @Test func manualPauseExcludesPlaybackButDoesNotChangeReminderOwnership() {
        let session = RecordingSession()
        session.liveRecordingState = .paused
        let t = Date()
        session.receiveReminderSnapshot(.init(windows: [.init(id: UUID(), start: t, end: t.addingTimeInterval(1))], active: true))
        #expect(!session.potentialTTSActive && session.liveRecordingState == .paused)
        session.endLiveSelectionCapture(at: t.addingTimeInterval(2))
        let source = LiveSelectionReference.interleaving(session.liveSelectionReferencesForDelivery, with: "Captured before pause", includeTiming: true)
        #expect(!source.contains("<potential_tts"))
    }

    @MainActor @Test func activeRecoveryKeepsCurrentTypingAndPossibleSpeechWithoutDuplicating() {
        let session = RecordingSession()
        let t = session.createdAt
        session.receiveReminderSnapshot(.init(windows: [.init(id: UUID(), start: t, end: t.addingTimeInterval(2))], active: true))
        session.recordSpeechActivity("My real speech and reminder", at: t.addingTimeInterval(1))
        session.partialTranscript = "My real speech and reminder"
        session.updateTypedInput("My typed request", at: t.addingTimeInterval(1.5))
        session.endLiveSelectionCapture(at: t.addingTimeInterval(3))
        let source = LiveSelectionReference.interleaving(session.liveSelectionReferencesForRecovery,
            with: session.partialTranscript, includeTiming: true)
        #expect(!source.contains("<potential_tts") && source.contains("<typed_text"))
        #expect(source.components(separatedBy: "My real speech and reminder").count == 2)
        #expect(source.components(separatedBy: "My typed request").count == 2)
        let record = Transcription(text: "", duration: 3, realtimeDraftText: source,
            transcriptionStatus: .recoveredAfterInterruption)
        #expect(HistoryContextPresentation.recoveredCodexText(for: record) == source)
        let history = HistoryContextPresentation.document(source)
        #expect(!history.hasFormatting && history.plainText == source)
        #expect(!history.runs.contains { $0.colorHex == "#fbbf24" && $0.text.contains("My real speech and reminder") })
    }
}
