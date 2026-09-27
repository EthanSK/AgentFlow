import AppKit
import SwiftUI

/// Read-only presentation for the small LaTeX vocabulary Agent Flow emits. History
/// is not a TeX interpreter: arbitrary commands, HTML and selected source stay inert.
/// Stored output and Copy remain byte-for-byte unchanged; no migration or API call.
enum HistoryContextPresentation {
    struct Run: Equatable {
        var text: String
        var colorHex: String?
        var italic: Bool = false
    }

    struct Document {
        var runs: [Run]
        var hasFormatting: Bool
        var plainText: String { runs.map(\.text).joined() }
    }

    private static let prefix = "\\(\\textsf{\\color{"
    private static let escapes: [(String, String)] = [
        ("\\textbackslash{}", "\\"), ("\\textasciicircum{}", "^"),
        ("\\textasciitilde{}", "~"), ("\\{", "{"), ("\\}", "}"),
        ("\\$", "$"), ("\\&", "&"), ("\\#", "#"), ("\\%", "%"),
        ("\\_", "_"), ("\\ ", " "), ("{[}", "["), ("{]}", "]"), ("{}", "")
    ]

    static func document(_ source: String) -> Document {
        var runs: [Run] = []
        var cursor = source.startIndex
        var search = cursor
        var hasFormatting = false
        while let opening = source.range(of: prefix, range: search..<source.endIndex) {
            guard let colorEnd = source[opening.upperBound...].firstIndex(of: "}"),
                  let closing = source.range(of: "\\)", range: colorEnd..<source.endIndex) else { break }
            let color = String(source[opening.upperBound..<colorEnd])
            let bodyStart = source.index(after: colorEnd)
            var body = String(source[bodyStart..<closing.lowerBound])
            guard color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
                  body.hasSuffix("}") else {
                search = closing.upperBound
                continue
            }
            body.removeLast()
            let italic = body.hasPrefix("\\textit{")
            if italic {
                guard body.hasSuffix("}") else { search = closing.upperBound; continue }
                body = String(body.dropFirst("\\textit{".count).dropLast())
            }
            guard let decoded = decodeText(body) else {
                search = closing.upperBound
                continue
            }
            var between = String(source[cursor..<opening.lowerBound])
            // Only the producer's adjacent-formula separator is presentation.
            // Do not strip invisible characters from arbitrary user payloads.
            if hasFormatting && between == "\u{200B}" { between = "" }
            if !between.isEmpty { runs.append(Run(text: between)) }
            runs.append(Run(text: decoded, colorHex: color, italic: italic))
            hasFormatting = true
            cursor = closing.upperBound
            search = cursor
        }
        if cursor < source.endIndex { runs.append(Run(text: String(source[cursor...]))) }
        return Document(runs: runs, hasFormatting: hasFormatting)
    }

    private static func decodeText(_ body: String) -> String? {
        var result = ""
        var cursor = body.startIndex
        while cursor < body.endIndex {
            if let (encoded, decoded) = escapes.first(where: { body[cursor...].hasPrefix($0.0) }) {
                result += decoded
                cursor = body.index(cursor, offsetBy: encoded.count)
            } else {
                let character = body[cursor]
                // Unknown commands or group nesting are literal fallback, never
                // silently erased or interpreted as executable TeX/Markdown.
                guard character != "\\", character != "{", character != "}" else { return nil }
                result.append(character)
                cursor = body.index(after: cursor)
            }
        }
        return result
    }

    static func listPreview(_ source: String) -> String {
        // A two-line row needs only the beginning. Bound work independently of
        // very large historical transcripts; expanded/copy content stays whole.
        let readable = document(String(source.prefix(8_192))).plainText
        if let envelope = readable.range(of: "<agent_flow_context") {
            let opening = readable[..<envelope.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !opening.isEmpty { return opening }
        }
        return readable.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributed(_ document: Document, fontSize: CGFloat, foreground: Color) -> AttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in document.runs {
            let regular = NSFont.systemFont(ofSize: fontSize)
            let font = run.italic ? NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask) : regular
            let color = run.colorHex.flatMap(nsColor) ?? NSColor(foreground)
            result.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: color]))
        }
        return AttributedString(result)
    }

    private static func nsColor(_ hex: String) -> NSColor? {
        guard let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// Both History layouts use the same native renderer. It never loads a web view,
/// evaluates pasted markup, fetches links or reads screenshot files automatically.
struct HistoryMessageContentView: View {
    let text: String
    var fontSize: CGFloat = 14
    var foregroundColor: Color = AppTheme.Text.primary
    var alignment: Alignment = .leading

    var body: some View {
        let document = HistoryContextPresentation.document(text)
        if document.hasFormatting {
            Text(HistoryContextPresentation.attributed(document, fontSize: fontSize, foreground: foregroundColor))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            MarkdownContentView(text, fontSize: fontSize, foregroundColor: foregroundColor, alignment: alignment)
        }
    }
}
