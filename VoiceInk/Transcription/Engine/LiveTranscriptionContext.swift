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
/// Stop closes offers but leaves the final accepted snapshot available to drain
/// before the recording's sole commit. Cancel discards it.
final class LiveTranscriptionContextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: TranscriptionRequestContext?
    private var lastPrompt: String?
    private var hasPrompt = false
    private var closed = false

    func offer(_ context: TranscriptionRequestContext) {
        lock.withLock {
            guard !closed else { return }
            let prompt = OpenAITranscriptionConfiguration.normalizedPrompt(context.openAITranscriptionPrompt)
            guard !hasPrompt || prompt != lastPrompt else { return }
            hasPrompt = true
            lastPrompt = prompt
            pending = context
        }
    }

    func take() -> TranscriptionRequestContext? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    func finish(discard: Bool = false) {
        lock.withLock {
            closed = true
            if discard { pending = nil }
        }
    }
}
