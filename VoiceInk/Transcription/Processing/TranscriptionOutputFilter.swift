// Local transcript processing: provider/filler filtering and spoken backspace.
// The pipeline and HUD share the pure edit reducer below. — GPT-6.1 Sol
import Foundation

struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,     // []
        #"\(.*?\)"#,     // ()
        #"\{.*?\}"#      // {}
    ]

    // Fixed patterns compile once. This filter runs on the UI actor for every
    // finish, so per-call compilation was avoidable local work; the output is
    // byte-identical to the former per-call construction.
    private static let tagBlockExpression = try? NSRegularExpression(
        pattern: #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#)
    private static let hallucinationExpressions = hallucinationPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }
    private static let repeatedWhitespaceExpression = try? NSRegularExpression(pattern: #"\s{2,}"#)

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        if let regex = tagBlockExpression {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for regex in hallucinationExpressions {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove configured filler words. An empty list is naturally a no-op.
        // The user's list changes rarely; the shared cache keys by pattern text,
        // so an edited list still takes effect on the next finish.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
            if let regex = CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Clean whitespace
        if let regex = repeatedWhitespaceExpression {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: " ")
        }
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }
}

/// Ethan's spoken “backspace” removes one preceding dictated word, never text in
/// another app. Re-evaluate each cumulative partial so recognition revisions do
/// not execute an edit twice. Raw mode keeps the original speech. — GPT-6.1 Sol
enum SpokenBackspace {
    struct Result {
        let text: String
        let commandCount: Int
        private let retainedWordIndices: [Int]?

        fileprivate init(text: String, commandCount: Int, retainedWordIndices: [Int]? = nil) {
            self.text = text
            self.commandCount = commandCount
            self.retainedWordIndices = retainedWordIndices
        }

        // Context anchors count whitespace-delimited provider words. Deleted words
        // and commands must not push a highlight or typed run into later speech. — GPT-6.1 Sol
        func wordCount(before originalCount: Int) -> Int {
            guard let retainedWordIndices else { return originalCount }
            var low = 0, high = retainedWordIndices.count
            while low < high {
                let middle = (low + high) / 2
                if retainedWordIndices[middle] < originalCount { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
    }

    static func apply(_ transcript: String) -> Result {
        // Ordinary growing transcripts keep their bytes and avoid token arrays.
        guard transcript.range(of: "backspace", options: .caseInsensitive) != nil else {
            return .init(text: transcript, commandCount: 0)
        }
        let words = transcript.split(whereSeparator: \.isWhitespace)
        var kept: [(index: Int, separator: String, word: Substring)] = []
        var pendingSeparator: String?
        var commands = 0
        var escaped = false
        var index = 0
        while index < words.count {
            let word = words[index]
            let previousEnd = index == 0 ? transcript.startIndex : words[index - 1].endIndex
            let separator = pendingSeparator ?? String(transcript[previousEnd..<word.startIndex])
            // “Literal backspace” is the escape when discussing the command.
            if core(word) == "literal", index + 1 < words.count, core(words[index + 1]) == "backspace" {
                kept.append((index + 1, kept.isEmpty ? "" : separator, words[index + 1]))
                pendingSeparator = nil
                escaped = true
                index += 2
                continue
            }
            if core(word) == "backspace" {
                commands += 1
                if let removed = kept.popLast() { pendingSeparator = removed.separator }
                else { pendingSeparator = "" }
            } else {
                kept.append((index, kept.isEmpty && pendingSeparator != nil ? "" : separator, word))
                pendingSeparator = nil
            }
            index += 1
        }
        guard commands > 0 || escaped else { return .init(text: transcript, commandCount: 0) }
        let trailing = pendingSeparator == nil && !kept.isEmpty
            ? String(transcript[(words.last?.endIndex ?? transcript.endIndex)...]) : ""
        return .init(text: kept.map { $0.separator + String($0.word) }.joined() + trailing,
                     commandCount: commands, retainedWordIndices: kept.map(\.index))
    }

    private static func core(_ word: Substring) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}
