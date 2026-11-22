import Foundation
import SwiftUI

public enum StarDictEntryFormatter {
    /// Converts raw StarDict entry text (HTML, XDXF, Pango, or plain text) into a clean
    /// plain-text string and a styled SwiftUI AttributedString.
    public static func format(raw: String, typeCode: Character) -> (plainText: String, attributed: AttributedString) {
        let normalizedRaw: String
        switch typeCode {
        case "h", "g":
            normalizedRaw = cleanHTMLToStructuredText(raw)
        case "x":
            normalizedRaw = cleanXDXFToStructuredText(raw)
        default:
            normalizedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let attributed = buildAttributedString(from: normalizedRaw)
        let plain = String(attributed.characters)
        return (plain, attributed)
    }

    private static func cleanXDXFToStructuredText(_ raw: String) -> String {
        var text = raw
        // Convert XDXF semantic tags into lightweight inline markers
        text = text.replacingOccurrences(of: "<k>", with: "**")
        text = text.replacingOccurrences(of: "</k>", with: "**\n")
        text = text.replacingOccurrences(of: "<tr>", with: "[")
        text = text.replacingOccurrences(of: "</tr>", with: "] ")
        text = text.replacingOccurrences(of: "<ex>", with: "\n  _\"")
        text = text.replacingOccurrences(of: "</ex>", with: "\"_")
        text = text.replacingOccurrences(of: "<co>", with: "(")
        text = text.replacingOccurrences(of: "</co>", with: ") ")
        text = text.replacingOccurrences(of: "<dtrn>", with: "")
        text = text.replacingOccurrences(of: "</dtrn>", with: "")
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = stripRemainingTags(text)
        return decodeHTMLEntities(text)
    }

    private static func cleanHTMLToStructuredText(_ raw: String) -> String {
        var text = raw
        // Preserve structure before stripping tags
        let blockPatterns: [(String, String)] = [
            ("<br\\s*/?>", "\n"),
            ("</p>", "\n\n"),
            ("</div>", "\n"),
            ("</li>", "\n"),
            ("<li[^>]*>", "• "),
            ("<b[^>]*>", "**"),
            ("</b>", "**"),
            ("<strong[^>]*>", "**"),
            ("</strong>", "**"),
            ("<i[^>]*>", "_"),
            ("</i>", "_"),
            ("<em[^>]*>", "_"),
            ("</em>", "_")
        ]

        for (pattern, replacement) in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
            }
        }

        text = stripRemainingTags(text)
        text = decodeHTMLEntities(text)
        return collapseBlankLines(text)
    }

    private static func stripRemainingTags(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var text = input
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…")
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }

    private static func collapseBlankLines(_ input: String) -> String {
        let lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var output: [String] = []
        var previousWasEmpty = false
        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty && !output.isEmpty {
                    output.append("")
                }
                previousWasEmpty = true
            } else {
                output.append(line)
                previousWasEmpty = false
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildAttributedString(from markdownLike: String) -> AttributedString {
        // Parse lightweight inline markdown (**bold**, _italic_) safely without failing on unmatched tokens
        if let parsed = try? AttributedString(
            markdown: markdownLike,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(markdownLike)
    }
}
