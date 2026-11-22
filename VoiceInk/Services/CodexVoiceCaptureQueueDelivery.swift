// Writes an event-only receipt before one ordinary Codex queue submission. The same
// recording ID is never automatically resubmitted after acceptance, failure or uncertainty.
import AppKit
import Foundation

struct CodexVoiceCaptureQueueReceipt: Codable, Sendable {
    let notice: CodexVoiceCaptureNotice
    let enqueueRequestedAt: Date
    let speakerObservedAtEnqueue: ChatGPTVoiceSpeakerObservation?
    var queueAcceptanceObservedAt: Date?
    var queueAccepted: Bool?
}

enum CodexVoiceCaptureQueueDelivery {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentFlow/Voice Events", isDirectory: true)
    }

    /// Uses the existing queue producer once, independently of dictated-text auto-send. — GPT-6.1 Sol
    static func enqueue(
        _ notice: CodexVoiceCaptureNotice,
        directory: URL = CodexVoiceCaptureQueueDelivery.directory,
        executable: URL? = nil,
        observe: @Sendable (ChatGPTVoiceCall) async -> ChatGPTVoiceSpeakerObservation? = {
            await SystemChatGPTVoiceMuteTransport().speakerObservation(for: $0)
        },
        queue: @Sendable (CodexRecordingTarget, String) async -> Bool = { await $0.enqueue($1) }
    ) async -> String {
        let event = notice.ended
        guard notice.started.phase == "started", ["stopped", "paused"].contains(event.phase),
              notice.started.id == event.id, notice.started.call == event.call,
              notice.started.occurredAt == event.startedAt,
              event.occurredAt >= event.startedAt, let threadID = event.call.threadID else {
            return "unresolvedVoiceChat"
        }
        let bundle = NSRunningApplication(processIdentifier: event.call.applicationPID)?.bundleURL
        guard let executable = executable ?? bundle.flatMap(CodexRecordingTarget.executable) else {
            return "cliUnavailable"
        }
        let file = directory.appendingPathComponent("\(event.id.uuidString.lowercased()).json")
        // Existence is a durable one-attempt boundary, including an indeterminate previous result.
        guard !FileManager.default.fileExists(atPath: file.path) else { return "alreadyAttempted" }
        let observation = await observe(event.call)
        let requestedAt = Date()
        var receipt = CodexVoiceCaptureQueueReceipt(notice: notice, enqueueRequestedAt: requestedAt,
            speakerObservedAtEnqueue: observation?.call == event.call ? observation : nil)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try encoded(receipt).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { return "receiptNotSaved" }

        let target = CodexRecordingTarget(id: threadID, name: "Voice", executable: executable)
        let accepted = await queue(target, notice.queuedMessage(requestedAt: requestedAt, receiptURL: file))
        receipt.queueAccepted = accepted
        // This is producer confirmation, not the original mute time or proof of chat arrival.
        receipt.queueAcceptanceObservedAt = accepted ? Date() : nil
        do {
            try encoded(receipt).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { return accepted ? "queuedReceiptUpdateFailed" : "notConfirmedReceiptUpdateFailed" }
        return accepted ? "queued" : "notConfirmed"
    }

    private static func encoded(_ receipt: CodexVoiceCaptureQueueReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CodexVoiceCaptureEvent.timestamp(date))
        }
        return try encoder.encode(receipt)
    }
}
