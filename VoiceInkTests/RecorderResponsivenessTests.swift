import Darwin
import Foundation
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct RecorderResponsivenessTests {
    @Test func captureInteractionHasExplicitInteractivePriorityWithoutPromotingIdlePreparation() {
        #expect(RecorderWorkPriority.captureInteraction.qosClass == .userInteractive)
        #expect(RecorderWorkPriority.idleHardware.qosClass == .userInitiated)
        #expect(RecorderWorkPriority.interactionFlags.contains(.enforceQoS))
    }

    @Test func interactiveStartKeepsHardwareFIFOAndRunsAtRequestedQoS() async {
        // Microphone-free scheduler fixture: a higher-priority Start still follows
        // a preceding hardware operation, and later cleanup cannot overtake it.
        let queue = DispatchQueue(label: "AgentFlow.tests.hardware-priority", qos: RecorderWorkPriority.idleHardware)
        let observations = PriorityObservations()
        queue.async { observations.append("previous-stop") }
        queue.async(qos: RecorderWorkPriority.captureInteraction, flags: RecorderWorkPriority.interactionFlags) {
            observations.append("start", qos: qos_class_self())
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                observations.append("later-maintenance")
                continuation.resume()
            }
        }
        let result = observations.snapshot()
        #expect(result.order == ["previous-stop", "start", "later-maintenance"])
        #expect(result.startQoS == QOS_CLASS_USER_INTERACTIVE)
    }

    @Test func priorityChangeIsBoundedToInitialStartAndResumeWithoutGlobalSchedulingOrFocusMutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("VoiceInk/Recorder.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "audioSetupQueue.async(qos: RecorderWorkPriority.captureInteraction").count - 1 == 3)
        #expect(!source.contains("setpriority("))
        #expect(!source.contains(".latencyCritical"))
        #expect(!source.contains("NSApplication.shared.activate"))
        let preparation = try #require(source.range(of: "private func schedulePrepareForCurrentDevice(reason: String)"))
        let preparationTail = String(source[preparation.lowerBound...])
        #expect(!preparationTail.contains("qos: RecorderWorkPriority.captureInteraction"))
    }
}

private final class PriorityObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var startQoS: qos_class_t?

    func append(_ name: String, qos: qos_class_t? = nil) {
        lock.lock()
        defer { lock.unlock() }
        order.append(name)
        if let qos { startQoS = qos }
    }

    func snapshot() -> (order: [String], startQoS: qos_class_t?) {
        lock.lock()
        defer { lock.unlock() }
        return (order, startQoS)
    }
}
