import Foundation

public enum PDFTextNormalizer {
    /// Cleans raw PDF text by rejoining hyphenated line-wraps and collapsing hard
    /// single-line breaks into continuous paragraphs while preserving real paragraph breaks.
    public static func normalize(_ raw: String) -> String {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !unified.isEmpty else { return "" }

        // Split into paragraphs separated by one or more blank lines
        let paragraphBlocks = unified
            .components(separatedBy: "\n\n")
            .map { cleanParagraph($0) }
            .filter { !$0.isEmpty }

        return paragraphBlocks.joined(separator: "\n\n")
    }

    private static func cleanParagraph(_ block: String) -> String {
        let lines = block
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }

        var result = lines[0]

        for i in 1..<lines.count {
            let nextLine = lines[i]
            if shouldDeHyphenate(previous: result, next: nextLine) {
                // Remove trailing hyphen (ASCII '-', soft hyphen '\u{00AD}', or unicode hyphen '\u{2010}')
                result.removeLast()
                result += nextLine
            } else {
                result += " " + nextLine
            }
        }

        // Collapse runs of spaces in a single O(n) pass
        return collapseSpaces(result).trimmingCharacters(in: .whitespaces)
    }

    private static func collapseSpaces(_ input: String) -> String {
        var output = String()
        output.reserveCapacity(input.count)
        var previousWasSpace = false
        for ch in input {
            if ch == " " {
                if !previousWasSpace {
                    output.append(ch)
                    previousWasSpace = true
                }
            } else {
                output.append(ch)
                previousWasSpace = false
            }
        }
        return output
    }

    private static func shouldDeHyphenate(previous: String, next: String) -> Bool {
        guard let lastChar = previous.last,
              let firstNext = next.first else {
            return false
        }

        let isHyphen = (lastChar == "-" || lastChar == "\u{00AD}" || lastChar == "\u{2010}")
        guard isHyphen else { return false }

        // Check that character before hyphen is a letter (avoid stripping standalone dashes like " — ")
        let beforeHyphen = previous.dropLast().last
        let hasLetterBefore = beforeHyphen?.isLetter ?? false

        // Join when next line starts with a lowercase letter (e.g. "Prole-\ngomena" -> "Prolegomena")
        return hasLetterBefore && firstNext.isLetter && firstNext.isLowercase
    }
}
