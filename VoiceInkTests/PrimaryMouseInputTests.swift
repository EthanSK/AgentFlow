import Testing
import Foundation
import Darwin
@testable import VoiceInkPlusPlus

private actor PrimaryMouseTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite(.serialized)
@MainActor
struct PrimaryMouseInputTests {
    private func command(
        _ phase: PrimaryMouseCommand.Phase,
        source: PrimaryMouseCommand.Source = .corsair
    ) -> PrimaryMouseCommand { .init(source: source, phase: phase) }

    @Test func primaryMouseProtocolRejectsUnknownAndOversizedCommands() {
        let valid = #"{"version":1,"action":"primaryRecordingMouse","source":"corsair","phase":"down"}"#
        #expect(PrimaryMouseCommand.decode(Data(valid.utf8)) == command(.down))
        for value in [
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            valid.replacingOccurrences(of: "primaryRecordingMouse", with: "paste"),
            valid.replacingOccurrences(of: "corsair", with: "unknown"),
            valid.replacingOccurrences(of: "down", with: "repeat"),
            valid.dropLast() + ",\"text\":\"not permitted\"}",
            valid + String(repeating: " ", count: 256), "{}", "[]"
        ] {
            #expect(PrimaryMouseCommand.decode(Data(value.utf8)) == nil)
        }
    }

    @Test func primaryMouseOnlyIdleDownStartsAndItsReleaseIsConsumed() {
        var presses = PrimaryMousePressCoordinator()
        #expect(presses.receive(command(.down), eventTime: 10, context: .idle) == .startOnDown)
        #expect(presses.receive(command(.up), eventTime: 10.2, context: .capture(UUID())) == .consumedStartRelease)
        #expect(presses.receive(command(.up), eventTime: 10.3, context: .idle) == .ignored)
    }

    @Test func wandProtocolAcceptsOnlyItsOwnBoundedDownUpMessages() {
        for phase in [PrimaryMouseCommand.Phase.down, .up, .cancel] {
            let payload = "{\"version\":1,\"action\":\"primaryRecordingMouse\",\"source\":\"wand\",\"phase\":\"\(phase.rawValue)\"}"
            #expect(PrimaryMouseCommand.decode(Data(payload.utf8)) == command(phase, source: .wand))
            for rejected in [
                payload.replacingOccurrences(of: "\"wand\"", with: "\"other-wand\""),
                payload.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
                payload.replacingOccurrences(of: "\"phase\":\"\(phase.rawValue)\"", with: "\"phase\":\"repeat\""),
                payload.dropLast() + ",\"repeat\":true}",
                payload + String(repeating: " ", count: 256)
            ] {
                #expect(PrimaryMouseCommand.decode(Data(rejected.utf8)) == nil)
            }
        }
    }

    @Test func wandCancelAllowsImmediateFreshPressWithoutAReleaseAction() {
        for context in [
            PrimaryMousePressCoordinator.Context.idle,
            .capture(UUID()), .pending(UUID()), .unavailable
        ] {
            var presses = PrimaryMousePressCoordinator()
            let expected: PrimaryMousePressCoordinator.Decision = context == .idle ? .startOnDown : .armed
            #expect(presses.receive(command(.down, source: .wand), eventTime: 1, context: context) == expected)
            #expect(presses.receive(command(.cancel, source: .wand), eventTime: 1.1, context: context) == .canceled)
            #expect(presses.receive(command(.up, source: .wand), eventTime: 1.2, context: context) == .ignored)
            #expect(presses.receive(command(.cancel, source: .wand), eventTime: 1.3, context: context) == .ignored)
            #expect(presses.receive(command(.down, source: .wand), eventTime: 1.4, context: context) == expected)
            let release: PrimaryMousePressCoordinator.Decision
            switch context {
            case .idle: release = .consumedStartRelease
            case .capture, .pending: release = .primaryOnRelease
            case .unavailable: release = .ignored
            }
            #expect(presses.receive(command(.up, source: .wand), eventTime: 1.5, context: context) == release)
        }
    }

    @Test func wandCancelCannotClearMouseCyclesOrBypassIngressGuards() {
        for source in [PrimaryMouseCommand.Source.corsair, .razer] {
            let payload = "{\"version\":1,\"action\":\"primaryRecordingMouse\",\"source\":\"\(source.rawValue)\",\"phase\":\"cancel\"}"
            #expect(PrimaryMouseCommand.decode(Data(payload.utf8)) == nil)
            var presses = PrimaryMousePressCoordinator()
            let context = PrimaryMousePressCoordinator.Context.capture(UUID())
            #expect(presses.receive(command(.down, source: source), eventTime: 1, context: context) == .armed)
            #expect(presses.receive(command(.down, source: .wand), eventTime: 1.1, context: context) == .armed)
            #expect(presses.receive(command(.cancel, source: source), eventTime: 1.2, context: context) == .ignored)
            #expect(presses.receive(command(.cancel, source: .wand), eventTime: .nan, context: context) == .ignored)
            #expect(presses.receive(command(.cancel, source: .wand), eventTime: 1.15, context: context) == .ignored)
            #expect(presses.receive(command(.cancel, source: .wand), eventTime: 1.3, context: context) == .canceled)
            #expect(presses.receive(command(.up, source: source), eventTime: 1.4, context: context) == .primaryOnRelease)
        }
        let manager = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoiceInk/Shortcuts/RecordingShortcutManager.swift"), encoding: .utf8)
        #expect(manager?.contains("guard decision == .startOnDown || decision == .primaryOnRelease else { return }") == true)
    }

    @Test func wandStartHoldReleaseAndLaterGestureKeepPrimaryTiming() {
        var presses = PrimaryMousePressCoordinator()
        let session = UUID()
        #expect(presses.receive(command(.down, source: .wand), eventTime: 10, context: .idle) == .startOnDown)
        #expect(presses.receive(command(.down, source: .wand), eventTime: 10.1, context: .capture(session)) == .ignored)
        #expect(presses.receive(command(.up, source: .wand), eventTime: 12, context: .capture(session)) == .consumedStartRelease)
        #expect(presses.receive(command(.down, source: .wand), eventTime: 13, context: .capture(session)) == .armed)
        #expect(presses.receive(command(.up, source: .wand), eventTime: 13.4, context: .capture(session)) == .primaryOnRelease)
    }

    @Test func wandCyclesCannotCompleteMouseOrDifferentSessionGestures() {
        for mouse in [PrimaryMouseCommand.Source.corsair, .razer] {
            var presses = PrimaryMousePressCoordinator()
            let session = UUID()
            #expect(presses.receive(command(.down, source: mouse), eventTime: 1, context: .capture(session)) == .armed)
            #expect(presses.receive(command(.up, source: .wand), eventTime: 1.1, context: .capture(session)) == .ignored)
            #expect(presses.receive(command(.down, source: .wand), eventTime: 1.2, context: .capture(session)) == .armed)
            #expect(presses.receive(command(.up, source: .wand), eventTime: 1.3, context: .capture(UUID())) == .ignored)
            #expect(presses.receive(command(.up, source: mouse), eventTime: 1.4, context: .capture(session)) == .primaryOnRelease)
        }
        var presses = PrimaryMousePressCoordinator()
        let context = PrimaryMousePressCoordinator.Context.pending(UUID())
        #expect(presses.receive(command(.down, source: .wand), eventTime: 2, context: context) == .armed)
        #expect(presses.receive(command(.up, source: .wand), eventTime: 63, context: context) == .ignored)
        #expect(presses.receive(command(.down, source: .wand), eventTime: 64, context: context) == .armed)
        presses.reset()
        #expect(presses.receive(command(.up, source: .wand), eventTime: 64.1, context: context) == .ignored)
    }

    @Test func wandSocketUsesTheExistingReadinessAndGenerationBoundary() async throws {
        let directory = "/private/tmp/vipp-wand-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/p.sock"
        let receiver = PrimaryMouseCommandReceiver(path: path)
        var received: [PrimaryMouseCommandReceiver.Event] = []
        try receiver.start { received.append($0) }
        let payload = Data(#"{"version":1,"action":"primaryRecordingMouse","source":"wand","phase":"down"}"#.utf8)
        try sendTestDatagram(to: path, payload: payload)
        receiver.setEnabled(true) // Drain the pre-readiness command; it cannot unlock the gate.
        try sendTestDatagram(to: path, payload: payload)
        for _ in 0..<50 where received.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received.count == 1)
        let event = try #require(received.first)
        #expect(event.command == command(.down, source: .wand))
        #expect(receiver.isCurrent(event))
        receiver.setEnabled(false)
        #expect(!receiver.isCurrent(event))
        receiver.stop()
    }

    @Test func primaryMouseStartingReleaseCannotCancelSlowStartup() {
        var presses = PrimaryMousePressCoordinator()
        #expect(presses.receive(command(.down), eventTime: 10, context: .idle) == .startOnDown)
        // No engine session exists yet while cleanup/permission is awaiting.
        #expect(presses.receive(command(.up), eventTime: 10.05, context: .unavailable) == .consumedStartRelease)
        #expect(presses.receive(command(.down), eventTime: 11, context: .capture(UUID())) == .armed)
    }

    @Test func primaryMouseRecordingPausedAndPendingActionsRemainOnRelease() {
        for context in [
            PrimaryMousePressCoordinator.Context.capture(UUID()),
            .pending(UUID())
        ] {
            var presses = PrimaryMousePressCoordinator()
            #expect(presses.receive(command(.down), eventTime: 10, context: context) == .armed)
            #expect(presses.receive(command(.up), eventTime: 10.8, context: context) == .primaryOnRelease)
        }
    }

    @Test func primaryMouseDuplicateDownOrphanAndStaleReleaseDoNothing() {
        var presses = PrimaryMousePressCoordinator()
        let context = PrimaryMousePressCoordinator.Context.capture(UUID())
        #expect(presses.receive(command(.up), eventTime: 1, context: context) == .ignored)
        #expect(presses.receive(command(.down), eventTime: 2, context: context) == .armed)
        #expect(presses.receive(command(.down), eventTime: 2.1, context: context) == .ignored)
        #expect(presses.receive(command(.up), eventTime: 63, context: context) == .ignored)
        #expect(presses.receive(command(.down), eventTime: 64, context: context) == .armed)
        #expect(presses.receive(command(.up), eventTime: 64.1, context: .capture(UUID())) == .ignored)
    }

    @Test func primaryMouseSourcesKeepIndependentCyclesAndResetDropsLateUp() {
        var presses = PrimaryMousePressCoordinator()
        let context = PrimaryMousePressCoordinator.Context.capture(UUID())
        #expect(presses.receive(command(.down), eventTime: 1, context: .idle) == .startOnDown)
        #expect(presses.receive(command(.down, source: .razer), eventTime: 1.2, context: context) == .armed)
        #expect(presses.receive(command(.up), eventTime: 1.3, context: context) == .consumedStartRelease)
        #expect(presses.receive(command(.up, source: .razer), eventTime: 1.4, context: context) == .primaryOnRelease)
        #expect(presses.receive(command(.down), eventTime: 2, context: context) == .armed)
        presses.reset()
        #expect(presses.receive(command(.up), eventTime: 2.1, context: context) == .ignored)

        // Paired controls held for half a second must still release as the one
        // original Start, not turn the second control's delayed up into Stop.
        presses.reset()
        #expect(presses.receive(command(.down), eventTime: 3, context: .idle) == .startOnDown)
        #expect(presses.receive(command(.down, source: .razer), eventTime: 3.02, context: context) == .coalescedStartDown)
        #expect(presses.receive(command(.up), eventTime: 3.5, context: context) == .consumedStartRelease)
        #expect(presses.receive(command(.up, source: .razer), eventTime: 3.52, context: context) == .consumedStartRelease)
    }

    @Test func primaryMouseSessionGateRequiresOrdinaryInputAfterLaunchWakeAndUnlock() {
        var gate = PrimaryMouseSessionReadiness()
        #expect(!gate.isReady)
        gate.ordinaryInput(frontmostBundle: "com.apple.loginwindow")
        #expect(!gate.isReady)
        gate.ordinaryInput(frontmostBundle: "com.example.editor")
        #expect(gate.isReady)
        gate.resign()
        gate.wake()
        gate.ordinaryInput(frontmostBundle: "com.example.editor")
        #expect(!gate.isReady) // Wake cannot undo an explicitly resigned session.
        gate.becomeActive()
        #expect(!gate.isReady)
        gate.ordinaryInput(frontmostBundle: "com.example.editor")
        #expect(gate.isReady)
        gate.sleep()
        gate.ordinaryInput(frontmostBundle: "com.example.editor")
        #expect(!gate.isReady)
        gate.wake()
        #expect(!gate.isReady)
        gate.ordinaryInput(frontmostBundle: "com.example.editor")
        #expect(gate.isReady)
    }

    @Test func primaryMouseAsyncStartDoesNotHoldKeyboardLatchOrCoalesceLaterGesture() async throws {
        var state = RecordingState.idle
        var starts = 0
        var clipboardSelections = 0
        let startGate = PrimaryMouseTestGate()
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { true },
            recordingState: { state }, toggleRecorderPanel: { _, _ in },
            setActiveRecordingCompletionDisposition: { disposition in
                if disposition == .clipboardOnly { clipboardSelections += 1 }
            }, cancelRecording: {},
            startReservedRecording: { _, _ in
                starts += 1
                state = .recording
                await startGate.wait()
            }
        )
        let start = Task { await handler.handlePrimaryMouseActivation(eventTime: 10) }
        for _ in 0..<100 where starts == 0 { await Task.yield() }
        #expect(starts == 1)
        // The first Start release contributes no activation. Later *released*
        // presses retain the established double-click Won't paste decision.
        await handler.handlePrimaryMouseActivation(eventTime: 11)
        await handler.handlePrimaryMouseActivation(eventTime: 11.2)
        #expect(clipboardSelections == 1)
        handler.cancelPendingPrimaryDecisions()
        await startGate.open()
        await start.value
    }

    @Test func primaryMouseGateClosingDuringReservationCannotResurrectStart() async {
        var current = true
        var reserved = false
        var starts = 0
        var canceled = 0
        let reservation = PrimaryMouseTestGate()
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { false },
            recordingState: { .idle }, toggleRecorderPanel: { _, _ in },
            cancelRecording: {}, reserveRecordingStart: {
                reserved = true
                await reservation.wait()
                return UUID()
            }, cancelRecordingStartReservation: { _ in canceled += 1 },
            startReservedRecording: { _, _ in starts += 1 }
        )
        let action = Task {
            await handler.handlePrimaryMouseActivation(eventTime: 10, isCurrent: { current })
        }
        for _ in 0..<100 where !reserved { await Task.yield() }
        #expect(reserved)
        current = false
        handler.cancelPendingPrimaryDecisions()
        await reservation.open()
        await action.value
        #expect(starts == 0)
        #expect(canceled == 1)
    }

    @Test func primaryMouseSharesNarrowDuplicateProtectionWithKeyboardPrimary() async {
        var starts = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { true },
            recordingState: { .idle }, toggleRecorderPanel: { _, _ in },
            cancelRecording: {}, startReservedRecording: { _, _ in starts += 1 }
        )
        await handler.handlePrimaryMouseActivation(eventTime: 10)
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 10.02, mode: .toggle)
        await handler.handleKeyUp(action: .primaryRecording, eventTime: 10.03, mode: .toggle)
        #expect(starts == 1)
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 11, mode: .toggle)
        await handler.handleKeyUp(action: .primaryRecording, eventTime: 11.1, mode: .toggle)
        #expect(starts == 2)
    }

    @Test func primaryMouseDecisionEntryUnblocksBeforeAsyncStartupCompletes() async {
        let entered = PrimaryMouseDecisionBarrier()
        let audio = PrimaryMouseTestGate()
        var startupWaiting = false
        var startupCompleted = false
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { false },
            recordingState: { .idle }, toggleRecorderPanel: { _, _ in },
            cancelRecording: {}, startReservedRecording: { _, _ in
                startupWaiting = true
                await audio.wait()
                startupCompleted = true
            }
        )
        let start = Task {
            await handler.handlePrimaryMouseActivation(
                eventTime: 1, decisionRegistered: { entered.open() }
            )
        }
        await entered.wait()
        for _ in 0..<100 where !startupWaiting { await Task.yield() }
        #expect(startupWaiting)
        #expect(!startupCompleted)
        await audio.open()
        await start.value
        #expect(startupCompleted)
    }

    @Test func primaryMouseReadinessLossCancelsOnlyMouseOwnedPendingGestures() async throws {
        var stops = 0
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { true },
            recordingState: { .recording }, toggleRecorderPanel: { _, _ in stops += 1 },
            cancelRecording: {}, primaryDoublePressInterval: 0.02
        )
        await handler.handleKeyDown(action: .primaryRecording, eventTime: 1, mode: .toggle)
        await handler.handleKeyUp(action: .primaryRecording, eventTime: 1.01, mode: .toggle)
        handler.cancelPendingPrimaryMouseDecisions()
        try await Task.sleep(for: .milliseconds(60))
        #expect(stops == 1)
        handler.cancelPendingPrimaryDecisions()
        await handler.handlePrimaryMouseActivation(eventTime: 2)
        handler.cancelPendingPrimaryMouseDecisions()
        try await Task.sleep(for: .milliseconds(60))
        #expect(stops == 1)
    }

    @Test func primaryMouseReceiverCannotReplaceUnownedEndpoint() throws {
        let directory = "/private/tmp/vipp-mouse-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/p.sock"
        try "preserve unrelated file".write(toFile: path, atomically: true, encoding: .utf8)
        let receiver = PrimaryMouseCommandReceiver(path: path)
        #expect(throws: (any Error).self) { try receiver.start { _ in } }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "preserve unrelated file")
    }

    @Test func primaryMouseReceiverRecoversOnlyUnboundRecordedSocketAfterDeviceChange() throws {
        for changedDevice in [false, true] {
            let directory = "/private/tmp/vipp-rebind-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let path = directory + "/p.sock"
            let fd = try makeRecordedSocketFixture(path: path, mismatch: changedDevice ? "device" : nil)
            close(fd) // Simulate a crashed/restored endpoint, retaining its socket inode.
            #expect(passiveTestConnect(to: path) == ECONNREFUSED)
            let receiver = PrimaryMouseCommandReceiver(path: path)
            try receiver.start { _ in Issue.record("A passive probe must not emit a recording command") }
            #expect(passiveTestConnect(to: path) == 0)
            receiver.stop()
        }
    }

    @Test func primaryMouseReceiverPreservesLiveAndUnrelatedSocketIdentities() throws {
        for scenario in ["live", "live-device", "inode", "owner"] {
            let directory = "/private/tmp/vipp-rebind-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let path = directory + "/p.sock"
            var fd = try makeRecordedSocketFixture(
                path: path, mismatch: scenario == "live" ? nil :
                    (scenario == "live-device" ? "device" : scenario)
            )
            defer { if fd >= 0 { close(fd) } }
            let live = scenario.hasPrefix("live")
            if !live { close(fd); fd = -1 }
            var before = stat()
            #expect(lstat(path, &before) == 0)
            let receiver = PrimaryMouseCommandReceiver(path: path)
            #expect(throws: (any Error).self) { try receiver.start { _ in } }
            var after = stat()
            #expect(lstat(path, &after) == 0)
            #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
            #expect(passiveTestConnect(to: path) == (live ? 0 : ECONNREFUSED))
        }
    }

    @Test func primaryMouseReceiverProtectsSocketAndRejectsSecondOwner() throws {
        let directory = "/private/tmp/vipp-mouse-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/p.sock"
        let receiver = PrimaryMouseCommandReceiver(path: path)
        try receiver.start { _ in Issue.record("No input was sent") }
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o777 == 0o600)
        let second = PrimaryMouseCommandReceiver(path: path)
        #expect(throws: (any Error).self) { try second.start { _ in } }
        receiver.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        try second.start { _ in }
        second.stop()
    }

    @Test func primaryMouseReceiverGenerationInvalidatesQueuedInputAcrossGateClose() async throws {
        let directory = "/private/tmp/vipp-mouse-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let receiver = PrimaryMouseCommandReceiver(path: directory + "/p.sock")
        var received: [PrimaryMouseCommandReceiver.Event] = []
        try receiver.start { received.append($0) }
        try sendTestDatagram(to: directory + "/p.sock", payload: Data())
        try sendTestDatagram(to: directory + "/p.sock")
        receiver.setEnabled(true)
        try sendTestDatagram(to: directory + "/p.sock")
        for _ in 0..<50 where received.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let event = try #require(received.first)
        try await Task.sleep(for: .milliseconds(20))
        #expect(received.count == 1) // Neither pre-readiness packet can replay.
        #expect(receiver.isCurrent(event))
        receiver.setEnabled(false)
        #expect(!receiver.isCurrent(event))
        receiver.setEnabled(true)
        #expect(!receiver.isCurrent(event))
        receiver.stop()
    }

    @Test func primaryMouseReceiverDropsQueuedEdgesWhenSessionGateCloses() async throws {
        let directory = "/private/tmp/vipp-mouse-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let receiver = PrimaryMouseCommandReceiver(path: directory + "/p.sock")
        var count = 0
        try receiver.start { _ in count += 1 }
        receiver.setEnabled(true)
        try sendTestDatagram(to: directory + "/p.sock")
        // Deliberately stall only this disposable Mini test's main thread long
        // enough for serial ingress to queue its event, then close the generation.
        usleep(20_000)
        receiver.setEnabled(false)
        receiver.setEnabled(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(count == 0)
        receiver.stop()
    }

    private func makeRecordedSocketFixture(path: String, mismatch: String?) throws -> Int32 {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
            }
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0 else { throw POSIXError(.EIO) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw POSIXError(.EIO) }
            var marker: [String: UInt64] = [
                "device": UInt64(info.st_dev), "inode": UInt64(info.st_ino), "owner": UInt64(info.st_uid)
            ]
            if let mismatch { marker[mismatch, default: 0] += 1 }
            let data = try JSONSerialization.data(withJSONObject: marker)
            guard FileManager.default.createFile(
                atPath: path + ".lock", contents: data, attributes: [.posixPermissions: 0o600]
            ) else { throw POSIXError(.EIO) }
            return fd
        } catch { close(fd); throw error }
    }

    private func passiveTestConnect(to path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
            }
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    private func sendTestDatagram(to path: String, payload: Data? = nil) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { string in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, string, capacity - 1) }
            }
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        let bytes = payload ?? Data(#"{"version":1,"action":"primaryRecordingMouse","source":"corsair","phase":"down"}"#.utf8)
        let sent = bytes.withUnsafeBytes { data in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, data.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        #expect(sent == bytes.count)
    }
}
