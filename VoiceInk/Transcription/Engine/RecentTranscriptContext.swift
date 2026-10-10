import Foundation
import SwiftData
import os

/// Opt-in runtime flag for the active-Codex-task transcription context hint.
///
/// Default OFF. While off, VoiceInk++ builds byte-identical legacy provider requests:
/// the static `TranscriptionPrompt` is the only prompt any provider ever sees.
enum RecentTranscriptContextSettings {
    static let enabledKey = "VIPPRecentTranscriptContextEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

/// Per-user GPT Live shortlist. Vocabulary remains the source of truth for every provider;
/// excluding a term here never deletes it or changes another provider's request. A missing
/// setting preserves the previous complete keyword list, and previously unseen new terms
/// participate automatically. Do not use a shorter alphabetical prefix: it can silently
/// lose the tail without regard to which spelling Ethan needs help with.
enum OpenAIKeywordSelection {
    static let excludedWordsKey = "VIPPExcludedOpenAIKeywords"

    static var excludedWords: Set<String> {
        excludedWords(in: .standard)
    }

    static func excludedWords(in defaults: UserDefaults) -> Set<String> {
        Set((defaults.stringArray(forKey: excludedWordsKey) ?? []).map(normalizedKey))
    }

    static func selected(from vocabulary: [String], excluding excluded: Set<String>) -> [String] {
        vocabulary.filter { !excluded.contains(normalizedKey($0)) }
    }

    static func selected(from vocabulary: [String]) -> [String] {
        selected(from: vocabulary, excluding: excludedWords)
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}


/// Store-backed inputs captured at most once by one recording-owned lazy cache.
///
/// Mode resolution may run twice (a synchronous provisional Mode, then an asynchronous
/// URL-specific Mode). The first OpenAI resolution freezes this value and every later
/// resolution reuses it, so neither chat context nor Vocabulary can change under one recording
/// while that lookup is in flight. A recording that never resolves to OpenAI never captures it.
struct TranscriptionRequestInputSnapshot {
    let staticPrompt: String?
    let vocabulary: [String]
    let codexMessages: [CodexConversationContextMessage]
    let capturedAt: Date
    let recentContextEnabled: Bool
}

/// Recording-owned lazy cache. Constructing it is cheap: no SwiftData query runs until a
/// resolver call that selects OpenAI actually asks for the snapshot. A provisional OpenAI
/// Mode may therefore capture once even if URL-specific resolution later selects another
/// provider; a resolver call that selects only another provider cannot trigger the fetch.
@MainActor
final class TranscriptionRequestInputSnapshotCache {
    let staticPrompt: String?

    private let modelContext: ModelContext
    private let isRecentContextEnabled: Bool
    private let captureSnapshot: @MainActor (String?, ModelContext, Bool) -> TranscriptionRequestInputSnapshot
    private var frozen: TranscriptionRequestInputSnapshot?

    init(
        staticPrompt: String?,
        modelContext: ModelContext,
        isRecentContextEnabled: Bool = RecentTranscriptContextSettings.isEnabled,
        captureSnapshot: @escaping @MainActor (String?, ModelContext, Bool) -> TranscriptionRequestInputSnapshot = {
            staticPrompt,
            modelContext,
            includeRecentContext in
            TranscriptionRequestContextSnapshot.capture(
                staticPrompt: staticPrompt,
                modelContext: modelContext,
                includeRecentContext: includeRecentContext
            )
        }
    ) {
        self.staticPrompt = staticPrompt
        self.modelContext = modelContext
        self.isRecentContextEnabled = isRecentContextEnabled
        self.captureSnapshot = captureSnapshot
    }

    func snapshot() -> TranscriptionRequestInputSnapshot {
        if let frozen { return frozen }
        let captured = captureSnapshot(
            staticPrompt,
            modelContext,
            isRecentContextEnabled
        )
        frozen = captured
        return captured
    }
}

/// Captures and composes immutable per-recording OpenAI request inputs.
@MainActor
enum TranscriptionRequestContextSnapshot {
    private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "TranscriptionRequestContext"
    )

    static func capture(
        staticPrompt: String?,
        modelContext: ModelContext,
        includeRecentContext: Bool,
        now: Date = Date()
    ) -> TranscriptionRequestInputSnapshot {
        capture(
            staticPrompt: staticPrompt,
            includeRecentContext: includeRecentContext,
            now: now,
            vocabulary: { OpenAIKeywordSelection.selected(from: frozenVocabulary(from: modelContext)) },
            codexMessages: { CodexConversationContextReader.recentMessagesIfFrontmost() }
        )
    }

    /// Loader seam used by focused tests to prove the disabled path never reads Codex.
    /// History has no loader at all: a shared Mode cannot prove conversation identity.
    /// Production still enters through the ModelContext overload above.
    static func capture(
        staticPrompt: String?,
        includeRecentContext: Bool,
        now: Date,
        vocabulary: () -> [String],
        codexMessages: () -> [CodexConversationContextMessage] = { [] }
    ) -> TranscriptionRequestInputSnapshot {
        let frozenCodexMessages = includeRecentContext ? codexMessages() : []
        return TranscriptionRequestInputSnapshot(
            staticPrompt: staticPrompt,
            vocabulary: vocabulary(),
            // Only exact active-Codex messages may accompany this recording. Without them
            // send the static prompt and Vocabulary alone, never another task's History
            // merely because it used one Mode. No History query runs on either path.
            codexMessages: frozenCodexMessages,
            capturedAt: now,
            recentContextEnabled: includeRecentContext
        )
    }

    static func make(
        language: String?,
        modeID: UUID?,
        snapshot: TranscriptionRequestInputSnapshot
    ) -> TranscriptionRequestContext {
        guard snapshot.recentContextEnabled else {
            return TranscriptionRequestContext(
                language: language,
                prompt: snapshot.staticPrompt,
                promptWithRecentContext: nil,
                vocabulary: snapshot.vocabulary
            )
        }

        let composition = CodexConversationContextPolicy.composition(
            staticPrompt: snapshot.staticPrompt,
            messages: snapshot.codexMessages
        )
        let effectivePrompt = composition.prompt
            ?? OpenAITranscriptionConfiguration.normalizedPrompt(snapshot.staticPrompt)

        // Counts now describe the post-fit payload, not pre-budget candidates or network
        // requests. Provisional/final Mode resolution may still log twice for one update;
        // whitespace-only static text is counted as absent just as transport sends it.
        // Counts only. Prompt text, context entries, dictionary terms, transcript
        // excerpts, and Mode-identifying values must never enter any log.
        logger.info(
            "request context frozen recentEntries=0 codexMessages=\(composition.includedMessages, privacy: .public) contextChars=\(composition.contextCharacters, privacy: .public) promptChars=\(effectivePrompt?.count ?? 0, privacy: .public) keywords=\(snapshot.vocabulary.count, privacy: .public)"
        )

        return TranscriptionRequestContext(
            language: language,
            prompt: snapshot.staticPrompt,
            promptWithRecentContext: composition.prompt,
            vocabulary: snapshot.vocabulary
        )
    }

    /// Same trim/dedupe/order contract the live cloud and streaming fetches already use,
    /// so freezing the list cannot change the request bytes; it only stops the realtime
    /// session and its completed-audio fallback from reading the store at two moments.
    private static func frozenVocabulary(from modelContext: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        guard let words = try? modelContext.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        var unique: [String] = []
        for word in words {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            unique.append(trimmed)
        }
        return unique
    }
}
