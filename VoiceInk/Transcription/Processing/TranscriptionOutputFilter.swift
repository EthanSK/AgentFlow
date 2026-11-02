// Strips provider tag blocks, bracketed hallucinations and configured filler
// words from a finished transcript before formatting and dictionary rules.
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
