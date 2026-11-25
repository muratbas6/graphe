#if os(macOS)
import CoreServices.DictionaryServices
#endif
import Foundation
import NaturalLanguage

public protocol DictionaryProviding: Sendable {
    func lookup(_ text: String) -> DictionaryLookupResult
    func detectLanguage(for text: String) -> (code: String, name: String)?
    func extractPrimaryWord(from text: String) -> String
}

public struct SystemOfflineDictionaryService: DictionaryProviding {
    public init() {}

    public func lookup(_ text: String) -> DictionaryLookupResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return DictionaryLookupResult(
                query: "",
                matchedTerm: "",
                detectedLanguageCode: nil,
                detectedLanguageName: nil,
                definition: nil,
                formattedSenses: []
            )
        }

        let detected = detectLanguage(for: cleaned)
        let candidateTerm = extractPrimaryWord(from: cleaned)

        // 1. Direct lookup on candidate term
        if let rawDef = querySystemDictionary(candidateTerm) {
            return DictionaryLookupResult(
                query: cleaned,
                matchedTerm: candidateTerm,
                detectedLanguageCode: detected?.code,
                detectedLanguageName: detected?.name,
                definition: rawDef,
                formattedSenses: formatDefinition(rawDef)
            )
        }

        // 2. Fallback to lemma (e.g., "constitutes" -> "constitute", "delivered" -> "deliver")
        if let lemma = lemmatize(candidateTerm),
           lemma.lowercased() != candidateTerm.lowercased(),
           let rawDef = querySystemDictionary(lemma) {
            return DictionaryLookupResult(
                query: cleaned,
                matchedTerm: lemma,
                detectedLanguageCode: detected?.code,
                detectedLanguageName: detected?.name,
                definition: rawDef,
                formattedSenses: formatDefinition(rawDef)
            )
        }

        // 3. Fallback to lowercase lookup
        let lowered = candidateTerm.lowercased()
        if lowered != candidateTerm, let rawDef = querySystemDictionary(lowered) {
            return DictionaryLookupResult(
                query: cleaned,
                matchedTerm: lowered,
                detectedLanguageCode: detected?.code,
                detectedLanguageName: detected?.name,
                definition: rawDef,
                formattedSenses: formatDefinition(rawDef)
            )
        }

        return DictionaryLookupResult(
            query: cleaned,
            matchedTerm: candidateTerm,
            detectedLanguageCode: detected?.code,
            detectedLanguageName: detected?.name,
            definition: nil,
            formattedSenses: []
        )
    }

    public func detectLanguage(for text: String) -> (code: String, name: String)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .turkish, .german, .french, .italian, .spanish]
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else {
            return nil
        }
        let code = dominant.rawValue
        let trLocale = Locale(identifier: "tr")
        let name = trLocale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
        return (code, name)
    }

    public func extractPrimaryWord(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 2 {
            return trimmed.trimmingCharacters(in: .punctuationCharacters)
        }
        // For longer selections (sentences), return first meaningful word for dictionary lookup
        if let firstWord = words.first {
            return String(firstWord).trimmingCharacters(in: .punctuationCharacters)
        }
        return trimmed
    }

    /// Pure offline English suffix lemmatizer — never invokes NLTagger(.lemma), which on macOS 15+
    /// can misdetect short words as Indonesian/Malay and trigger OS "Download Dictionary" prompts.
    public static func lightweightEnglishStems(for word: String) -> [String] {
        let lower = word.lowercased()
        guard lower.count >= 4, lower.allSatisfy(\.isLetter) else { return [] }
        var out: [String] = []
        func add(_ s: String) {
            if s.count >= 3 && s != lower && !out.contains(s) { out.append(s) }
        }
        if lower.hasSuffix("ies") && lower.count >= 5 {
            add(String(lower.dropLast(3)) + "y")
        }
        if lower.hasSuffix("es") {
            add(String(lower.dropLast(2)))
            add(String(lower.dropLast(1)))
        } else if lower.hasSuffix("s") && !lower.hasSuffix("ss") {
            add(String(lower.dropLast(1)))
        }
        if lower.hasSuffix("ied") && lower.count >= 5 {
            add(String(lower.dropLast(3)) + "y")
        } else if lower.hasSuffix("ed") && lower.count >= 5 {
            let base = String(lower.dropLast(2))
            add(base)
            add(base + "e")
        }
        if lower.hasSuffix("ing") && lower.count >= 6 {
            let base = String(lower.dropLast(3))
            add(base)
            add(base + "e")
        }
        return out
    }

    private func lemmatize(_ word: String) -> String? {
        Self.lightweightEnglishStems(for: word).first
    }

    private func querySystemDictionary(_ term: String) -> String? {
        #if os(macOS)
        let nsTerm = term as NSString
        guard nsTerm.length > 0 else { return nil }
        let cfRange = CFRange(location: 0, length: nsTerm.length)
        guard let unmanaged = DCSCopyTextDefinition(nil, nsTerm as CFString, cfRange) else {
            return nil
        }
        let result = (unmanaged.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
        #else
        return nil
        #endif
    }

    public func formatDefinition(_ raw: String) -> [String] {
        // Split dense macOS dictionary strings into cleaner readable paragraphs/senses
        var formatted = raw
        let markers = [" • ", " ▶ ", " ORIGIN ", " DERIVATIVES ", " PHRASES "]
        for marker in markers {
            formatted = formatted.replacingOccurrences(of: marker, with: "\n\(marker.trimmingCharacters(in: .whitespaces)) ")
        }
        return formatted
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
