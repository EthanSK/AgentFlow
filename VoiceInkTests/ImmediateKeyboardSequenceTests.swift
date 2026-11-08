// Real CGEvent construction with a capturing emitter: no desktop input is posted.
// Guards zero-padding order, balanced Command release and unchanged Return flags.
import CoreGraphics
import Foundation
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized) @MainActor
struct ImmediateKeyboardSequenceTests {
    struct Event: Equatable {
        let type: CGEventType
        let key: Int64
        let flags: CGEventFlags
        init(_ event: CGEvent) {
            type = event.type
            key = event.getIntegerValueField(.keyboardEventKeycode)
            flags = event.flags
        }
    }

    @Test func immediateCommandVPostsFourOrderedBalancedEvents() {
        var events: [Event] = []
        var boundaries: [String] = []
        let result = ForegroundKeyboardSequence.commandV(canPost: { true }, ownsClipboard: {
            boundaries.append($0); return true
        }, emit: { events.append(Event($0)) })
        #expect(result == .posted)
        #expect(boundaries == ["beforeCommandDown", "beforeVDown"])
        #expect(events.map(\.key) == [0x37, 0x09, 0x09, 0x37])
        // CoreGraphics normalizes modifier virtual keys to flagsChanged.
        #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(events.map(\.flags) == [.maskCommand, .maskCommand, .maskCommand, []])
    }

    @Test func immediateCommandVReleasesCommandWhenFinalActionOrClipboardCheckFails() {
        for losesClipboard in [false, true] {
            var events: [Event] = []
            var actionCalls = 0
            let result = ForegroundKeyboardSequence.commandV(canPost: {
                actionCalls += 1
                return losesClipboard || actionCalls == 1
            }, ownsClipboard: { boundary in
                !losesClipboard || boundary == "beforeCommandDown"
            }, emit: { events.append(Event($0)) })
            #expect(result == (losesClipboard ? .clipboardLeaseLost : .actionGuardRefused))
            #expect(events.map(\.key) == [0x37, 0x37])
            #expect(events.map(\.type) == [.flagsChanged, .flagsChanged])
            #expect(events.last?.flags.isEmpty == true)
        }
    }

    @Test func immediateCommandVPostsNothingWhenInitialOwnershipIsMissing() {
        for actionAllowed in [false, true] {
            var events = 0
            let result = ForegroundKeyboardSequence.commandV(canPost: { actionAllowed },
                ownsClipboard: { _ in false }, emit: { _ in events += 1 })
            #expect(result == (actionAllowed ? .clipboardLeaseLost : .actionGuardRefused))
            #expect(events == 0)
        }
    }

    @Test func immediateReturnKeepsExactlyOneDownUpAndRequestedFlags() {
        let variants: [CGEventFlags] = [[], .maskShift, .maskCommand]
        for flags in variants {
            var events: [Event] = []
            #expect(ForegroundKeyboardSequence.returnKey(flags: flags, canPost: { true },
                emit: { events.append(Event($0)) }) == .posted)
            #expect(events.map(\.key) == [0x24, 0x24])
            #expect(events.map(\.type) == [.keyDown, .keyUp])
            #expect(events.map(\.flags) == [flags, flags])
        }
        var posts = 0
        #expect(ForegroundKeyboardSequence.returnKey(flags: [], canPost: { false },
            emit: { _ in posts += 1 }) == .actionGuardRefused)
        #expect(posts == 0)
    }

    @Test func ordinaryFinishContainsOnlyApprovedSendAllowanceAndNoUnnecessaryRecipientLookup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let keys = try String(contentsOf: root.appendingPathComponent("VoiceInk/Paste/ForegroundKeyboardSequence.swift"), encoding: .utf8)
        #expect(!keys.contains("Task.sleep") && !keys.contains("await "))
        #expect(!keys.contains("postToPid") && !keys.contains("NSWorkspace"))
        let paster = try String(contentsOf: root.appendingPathComponent("VoiceInk/Paste/CursorPaster.swift"), encoding: .utf8)
        #expect(!paster.contains("prePasteDelay") && !paster.contains("pasteShortcutEventDelay"))
        let delivery = try String(contentsOf: root.appendingPathComponent("VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"), encoding: .utf8)
        let start = try #require(delivery.range(of: "private func deliverPrimaryToCurrentSystemInput("))
        let end = try #require(delivery.range(of: "private func deliverToBackgroundExactInput(", range: start.upperBound..<delivery.endIndex))
        let primary = delivery[start.lowerBound..<end.lowerBound]
        #expect(!primary.contains("NSWorkspace"))
        // Ethan's approved 50 ms/400 ms path has one early wait and two mutually
        // exclusive remaining-deadline branches. Neither may append another full
        // 400 ms wait after the early attempt; all key construction stays immediate.
        #expect(primary.components(separatedBy: "Task.sleep").count == 4)
        #expect(primary.contains("if autoSendKey == .enter, let primarySendPasteProof"))
        #expect(primary.contains("Task.sleep(nanoseconds: PrimarySendAttemptPolicy.earlyNanoseconds)"))
        #expect(primary.components(separatedBy: "fallbackDeadline - ProcessInfo.processInfo.systemUptime").count == 3)
        #expect(primary.contains("if autoSendKey.isEnabled"))
        #expect(delivery.contains("primaryCurrentInputSettleNanoseconds = PrimarySendAttemptPolicy.fallbackNanoseconds"))
        #expect(primary.contains("settleMs=\\(Self.primaryCurrentInputSettleNanoseconds / 1_000_000)"))
        #expect(primary.contains("resolveQueuedAutoSend(autoSendKey)"))
        // Only subsequent clipboard mutation/restoration has its existing deferred
        // ownership window. It does not pad the current message's key sequence.
        #expect(paster.contains("settlementNanoseconds = postPasteSettlementNanoseconds"))
        #expect(paster.contains("scheduleClipboardRestore("))
    }
}
