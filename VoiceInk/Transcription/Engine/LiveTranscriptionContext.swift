import Foundation
import ImageIO
import Vision

/// Ethan's "selection stuff" can help recognition without a Codex/ChatGPT Voice
/// connection. Only deliberately captured references enter this path. Text is data
/// about the current topic, never an instruction to an agent or required output.
enum LiveTranscriptionContext {
    static let referenceCharacterLimit = 320

    static func boundedReference(_ text: String) -> String? {
        let words = text.prefix(2_000).split(whereSeparator: \.isWhitespace)
        var result = ""
        for word in words {
            let next = result.isEmpty ? String(word) : result + " " + word
            guard next.count <= referenceCharacterLimit else {
                // CJK prose and long identifiers need not contain a word boundary.
                // Preserve a bounded character prefix rather than silently clearing.
                if result.isEmpty { result = String(word.prefix(referenceCharacterLimit)) }
                break
            }
            result = next
        }
        return result.isEmpty ? nil : result
    }

    static func prompt(base: String?, reference: String) -> String? {
        let base = OpenAITranscriptionConfiguration.normalizedPrompt(base)
        guard let reference = boundedReference(reference) else { return base }
        // Fit complete words and the complete JSON string before transport. Preserve
        // static/opt-in startup context; never slice JSON or crowd out Vocabulary.
        var words = reference.split(separator: " ").map(String.init)
        while !words.isEmpty {
            if let data = try? JSONEncoder().encode(words.joined(separator: " ")),
               let quoted = String(data: data, encoding: .utf8) {
                let hint = "Current reference: " + quoted
                let composed = [base, hint].compactMap { $0 }.joined(separator: "\n\n")
                // UTF-8 is conservative for ASCII/code-unit/scalar provider limits,
                // including joined emoji and non-Latin text. Swift Character count
                // alone can hide many code units inside one visible character.
                if composed.utf8.count <= OpenAITranscriptionConfiguration.promptCharacterLimit {
                    return composed
                }
            }
            if words.count == 1, words[0].count > 1 { words[0].removeLast() }
            else { words.removeLast() }
        }
        return base
    }

    /// OCR only the already captured file, off the main actor, with bounded file and
    /// decoded image sizes. No screen capture, clipboard read, remote vision call,
    /// pixels/path logging, or foreground-app inspection occurs here.
    static func textFromCapturedImage(_ url: URL) -> String? {
        guard url.isFileURL, !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let bytes = values.fileSize, bytes > 0, bytes <= 32 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_800,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard !Task.isCancelled else { return nil }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard !Task.isCancelled else { return nil }
            let text = (request.results ?? []).prefix(32)
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return boundedReference(text)
        } catch {
            return nil
        }
    }

    static func imageText(_ url: URL) async -> String? {
        await CapturedTranscriptionImageReader.shared.read(url)
    }
}

/// Stateless serial OCR keeps a burst of screenshots from running many expensive
/// Vision requests at once. Canceled queued work is skipped by the reader's task
/// checks; no captured text or image survives in this shared worker.
private actor CapturedTranscriptionImageReader {
    static let shared = CapturedTranscriptionImageReader()
    func read(_ url: URL) -> String? { LiveTranscriptionContext.textFromCapturedImage(url) }
}

/// Asynchronous OCR cannot replace a newer highlight or outlive capture Stop.
/// The production owner additionally checks its recording identity/lifecycle.
@MainActor
final class LiveTranscriptionReferenceCapture {
    private let imageText: @Sendable (URL) async -> String?
    private let onHint: (String?) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var finished = false

    init(imageText: @escaping @Sendable (URL) async -> String? = { await LiveTranscriptionContext.imageText($0) },
         onHint: @escaping (String?) -> Void) {
        self.imageText = imageText
        self.onHint = onHint
    }

    deinit { task?.cancel() }

    func accept(_ source: LiveSelectionReference.RecognitionSource) {
        guard !finished else { return }
        generation += 1
        let current = generation
        task?.cancel()
        task = nil
        switch source {
        case .text(let text):
            onHint(LiveTranscriptionContext.boundedReference(text))
        case .image(let url):
            let extract = imageText
            task = Task { [weak self] in
                let text = await extract(url)
                guard !Task.isCancelled, let self,
                      !self.finished, self.generation == current else { return }
                self.onHint(text.flatMap(LiveTranscriptionContext.boundedReference))
            }
        }
    }

    func finish() {
        finished = true
        generation += 1
        task?.cancel()
        task = nil
    }
}

/// The existing audio sender is the only consumer. Rapid context changes coalesce
/// here instead of creating concurrent socket sends or an unbounded context queue.
/// Stop/Cancel discard unstarted updates: a new hint cannot help future speech once
/// capture has ended, and must never create another provider turn during the drain.
final class LiveTranscriptionContextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: TranscriptionRequestContext?
    private var appliedPrompt: String?
    private var hasAppliedPrompt = false
    private var inFlightPrompt: String?
    private var hasInFlightPrompt = false
    private var closed = false
    private var offeredAt: TimeInterval = 0

    private static func prompt(_ context: TranscriptionRequestContext) -> String? {
        OpenAITranscriptionConfiguration.normalizedPrompt(context.openAITranscriptionPrompt)
    }

    func offer(_ context: TranscriptionRequestContext, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard !closed else { return }
            let prompt = Self.prompt(context)
            // A revert to the applied prompt must stay pending while a DIFFERENT
            // update is in flight; its acknowledgement will otherwise make it stale.
            if !hasInFlightPrompt && hasAppliedPrompt && prompt == appliedPrompt {
                pending = nil
                return
            }
            pending = context
            offeredAt = now
        }
    }

    func take(maximumAge: TimeInterval? = nil, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TranscriptionRequestContext? {
        lock.withLock {
            guard let context = pending else { return nil }
            pending = nil
            if let maximumAge, now - offeredAt > maximumAge { return nil }
            hasInFlightPrompt = true
            inFlightPrompt = Self.prompt(context)
            return context
        }
    }

    /// Seed after connect or record an acknowledged update. Never overwrite a
    /// newer pending offer; clear only a duplicate of the prompt actually applied.
    func markApplied(_ context: TranscriptionRequestContext) {
        lock.withLock {
            appliedPrompt = Self.prompt(context)
            hasAppliedPrompt = true
            if hasInFlightPrompt && inFlightPrompt == appliedPrompt {
                hasInFlightPrompt = false
                inFlightPrompt = nil
            }
            if let context = pending, Self.prompt(context) == appliedPrompt { pending = nil }
        }
    }

    func finish(discard: Bool = false) {
        lock.withLock {
            closed = true
            if discard { pending = nil }
        }
    }
}

/// Captured hints may close an audio turn only BEFORE speech or after a fully
/// analysed quiet gap. Committing on an arbitrary highlight cut a synthetic word
/// in the real API. Reuse the conservative silence classifier as an observer only:
/// every PCM byte still goes to the provider; no Action here ever omits audio.
struct LiveTranscriptionBoundaryPolicy {
    static let maximumHintAge: TimeInterval = 120
    private var quiet: RealtimeSilenceSleepGate
    private var sentBytes = 0
    private var lastUpdateAt: TimeInterval?
    private var updates = 0

    init() {
        quiet = Self.makeObserver(initialFloor: RealtimeSilenceSleepGate.Configuration.gptLiveDefault.initialNoiseFloorDBFS)
    }

    private static func makeObserver(initialFloor: Double) -> RealtimeSilenceSleepGate {
        var configuration = RealtimeSilenceSleepGate.Configuration.gptLiveDefault
        configuration.trailingQuietSeconds = 1
        configuration.activityHoldSeconds = 0
        configuration.prerollSeconds = 0
        configuration.initialNoiseFloorDBFS = initialFloor
        return RealtimeSilenceSleepGate(configuration: configuration, startedAt: 0)
    }

    func canApplyContext(at now: TimeInterval) -> Bool {
        guard updates < 10,
              lastUpdateAt.map({ now - $0 >= 10 }) ?? true else { return false }
        return sentBytes == 0 || (sentBytes >= 3 * 32_000 && quiet.isAtAnalyzedQuietBoundary)
    }

    mutating func didSend(_ data: Data, at now: TimeInterval) {
        sentBytes += data.count
        _ = quiet.process(data, at: now)
    }

    mutating func didApplyContext(at now: TimeInterval) {
        lastUpdateAt = now
        updates += 1
        // The next turn must establish its OWN complete quiet second. Old quiet
        // evidence plus a delayed short callback could otherwise commit <100ms,
        // below the server minimum. Retain the conservative learned floor.
        quiet = Self.makeObserver(initialFloor: quiet.noiseFloorDBFS)
    }
}
