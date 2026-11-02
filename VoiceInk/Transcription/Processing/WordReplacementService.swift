// Formats explicit spoken website separators before the user's dictionary rules,
// then applies those rules through a shared compiled-expression cache.
// All callers supply recognized speech, so HUD typing and captured context stay literal.
import Foundation
import SwiftData

/// Dictionary rules and filler words rebuilt the same `NSRegularExpression`
/// objects on every finish, on the UI actor. The objects are immutable and
/// thread-safe, so keep a small bounded cache keyed by pattern text plus options.
/// Keying by text (never by rule object) means an edited or deleted rule can
/// never resurrect stale behavior; a changed rule simply compiles a new pattern.
/// The cap is a memory bound, not an LRU: exceeding it clears everything, which
/// only costs one recompilation pass.
enum CompiledExpressionCache {
    static let capacity = 512

    private static let storage = Storage()

    static var count: Int { storage.count }

    static func expression(for pattern: String,
                           options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        storage.expression(for: pattern, options: options)
    }

    // Same lock-protected storage shape as AuthoredTextRainbow.ViewerCursors, so
    // off-main callers (imports, History retries) share it safely.
    private final class Storage: @unchecked Sendable {
        private struct Key: Hashable {
            let pattern: String
            let options: UInt
        }

        private let lock = NSLock()
        private var expressions: [Key: NSRegularExpression] = [:]

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return expressions.count
        }

        func expression(for pattern: String,
                        options: NSRegularExpression.Options) -> NSRegularExpression? {
            let key = Key(pattern: pattern, options: options.rawValue)
            lock.lock()
            if let cached = expressions[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            // Compile outside the lock; an invalid pattern stays uncached and nil,
            // exactly as the former `try?` construction behaved.
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if expressions.count >= CompiledExpressionCache.capacity {
                expressions.removeAll(keepingCapacity: true)
            }
            expressions[key] = compiled
            return compiled
        }
    }
}

/// Ethan's "speak the URL" means spelling a website, not opening it or guessing
/// a domain from a brand name. This local pass costs no extra model request.
enum SpokenWebsiteAddressFormatter {
    private static let spaces = #"[ \t]+"#
    private static let component = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
    private static let label = component + "(?:" + spaces + "(?:dash|hyphen)" + spaces + component + "){0,4}"
    private static let separator = "(?:" + spaces + "dot" + spaces + #"|\.)"#
    private static let address = try? NSRegularExpression(
        pattern: #"(?<![\w@/.-])((?:https?://)?)("# + label + "(?:" + separator + label + "){1,9})(" +
            "(?:" + spaces + "slash" + spaces + #"[a-z0-9_~%+-]+){0,8})"# + #"(?![\w-])"#,
        options: .caseInsensitive
    )
    private static let spokenDot = try? NSRegularExpression(pattern: spaces + "dot" + spaces, options: .caseInsensitive)
    private static let spokenDash = try? NSRegularExpression(pattern: spaces + "(?:dash|hyphen)" + spaces, options: .caseInsensitive)
    private static let spokenSlash = try? NSRegularExpression(pattern: spaces + "slash" + spaces, options: .caseInsensitive)
    private static let inlineCode = try? NSRegularExpression(pattern: #"`[^`]*`"#)
    private static let commonEndings: Set<String> = [
        "com", "net", "org", "io", "ai", "dev", "app", "co", "uk", "me", "info",
        "edu", "gov", "biz", "us", "ca", "eu", "au", "de", "fr", "es", "it", "nl",
        "tech", "xyz", "tv", "fm", "ly", "gg", "cloud", "online", "site", "store",
        "tools", "games", "wiki", "shop", "pro"
    ]
    // A spoken "dot" in prose isn't automatically a URL. In particular, preserve
    // "the dot com boom", "I use dot net", maths, and named .NET frameworks.
    private static let proseLabels: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "our", "their", "this", "that",
        "these", "those", "i", "we", "you", "it", "is", "are", "was", "be", "use",
        "using", "learn", "learning", "about", "with", "in", "on", "at", "for", "and",
        "or", "to", "from", "not", "of", "say", "said", "word", "called"
    ]
    private static let dotNetFrameworkLabels: Set<String> = ["microsoft", "asp", "vb", "ado"]

    static func format(_ text: String, preserving protectedRanges: () -> [NSRange] = { [] }) -> String {
        guard text.localizedCaseInsensitiveContains("dot") || text.localizedCaseInsensitiveContains("slash"),
              let address else { return text }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = address.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }
        // Ordinary dictation must not pay for another dictionary scan. Only
        // resolve protection after this text actually contains an address shape.
        let excludedRanges = protectedRanges() + (inlineCode?.matches(in: text, range: fullRange).map(\.range) ?? [])
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let scheme = source.substring(with: match.range(at: 1))
            let rawHost = source.substring(with: match.range(at: 2))
            let rawPath = source.substring(with: match.range(at: 3))
            let host = replacing(spokenDash, in: replacing(spokenDot, in: rawHost, with: "."), with: "-").lowercased()
            let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard host != rawHost.lowercased() || !rawPath.isEmpty,
                  host.utf8.count <= 253,
                  labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }),
                  let first = labels.first, let last = labels.last,
                  commonEndings.contains(last), !proseLabels.contains(first),
                  !(last == "net" && dotNetFrameworkLabels.contains(first)) else { continue }
            let path = replacing(spokenSlash, in: rawPath, with: "/")
            result.replaceCharacters(in: match.range, with: scheme + host + path)
        }
        return result as String
    }

    private static func replacing(_ expression: NSRegularExpression?, in text: String, with replacement: String) -> String {
        expression?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement) ?? text
    }
}

class WordReplacementService {
    static let shared = WordReplacementService()

    private init() {}

    func applyReplacements(to text: String, using context: ModelContext) -> String {
        let descriptor = FetchDescriptor<WordReplacement>(
            predicate: #Predicate { $0.isEnabled }
        )

        guard let replacements = try? context.fetch(descriptor), !replacements.isEmpty else {
            return SpokenWebsiteAddressFormatter.format(text)
        }

        // One owner for live/batch, imports and History retries. Preserve phrases
        // already claimed by an enabled dictionary rule, then format other URLs
        // before the existing single replacement pass. Thus a spoken-form rule
        // still matches, canonical-domain rules see the URL, and replacement text
        // itself is never rewritten or subjected to a second cascading pass.
        // The pipeline's raw/skip branch bypasses this whole service.
        let fullRange = NSRange(text.startIndex..., in: text)
        let formattedText = SpokenWebsiteAddressFormatter.format(text) {
            replacements.flatMap { replacement in
                replacement.originalText.split(separator: ",").flatMap { variant -> [NSRange] in
                    let original = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !original.isEmpty else { return [] }
                    return self.replacementExpression(for: original)?.matches(in: text, range: fullRange).map(\.range) ?? []
                }
            }
        }
        var modifiedText = formattedText

        // Longest-first so specific triggers match before shorter overlapping ones
        let sortedReplacements = replacements.sorted {
            $0.originalText.count > $1.originalText.count
        }

        // Apply replacements (case-insensitive)
        for replacement in sortedReplacements {
            let originalGroup = replacement.originalText
            let replacementText = replacement.replacementText

            let variants = originalGroup
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            for original in variants {
                let usesBoundaries = usesWordBoundaries(for: original)

                if usesBoundaries {
                    if let regex = replacementExpression(for: original) {
                        let range = NSRange(modifiedText.startIndex..., in: modifiedText)
                        modifiedText = regex.stringByReplacingMatches(
                            in: modifiedText,
                            options: [],
                            range: range,
                            withTemplate: replacementText
                        )
                    }
                } else {
                    // Fallback substring replace for non-spaced scripts
                    modifiedText = modifiedText.replacingOccurrences(of: original, with: replacementText, options: .caseInsensitive)
                }
            }
        }

        return modifiedText
    }

    /// Extraction of the existing applyReplacements regex construction. Share its
    /// exact boundaries with URL protection so the new formatter cannot consume a
    /// spoken phrase that the user's existing rule would have replaced.
    private func replacementExpression(for original: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: original)
        // Lookarounds instead of \b so punctuation acts as a word boundary.
        let pattern = usesWordBoundaries(for: original)
            ? "(?<![a-zA-Z0-9])\(escaped)(?![a-zA-Z0-9])" : escaped
        // Every finish rebuilt one expression per rule variant (twice when URL
        // protection ran). Reuse the compiled object; behavior is unchanged.
        return CompiledExpressionCache.expression(for: pattern, options: .caseInsensitive)
    }

    private func usesWordBoundaries(for text: String) -> Bool {
        // Returns false for languages without spaces (CJK, Thai), true for spaced languages
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F, // Hiragana
            0x30A0...0x30FF, // Katakana
            0x4E00...0x9FFF, // CJK Unified Ideographs
            0xAC00...0xD7AF, // Hangul Syllables
            0x0E00...0x0E7F, // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}
