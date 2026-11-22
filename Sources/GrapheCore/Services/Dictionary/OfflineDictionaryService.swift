import CoreServices.DictionaryServices
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

    private func lemmatize(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let range = word.startIndex..<word.endIndex
        var foundLemma: String?
        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let raw = tag?.rawValue, !raw.isEmpty {
                foundLemma = raw
                return false
            }
            return true
        }
        return foundLemma
    }

    private func querySystemDictionary(_ term: String) -> String? {
        let nsTerm = term as NSString
        guard nsTerm.length > 0 else { return nil }
        let cfRange = CFRange(location: 0, length: nsTerm.length)
        guard let unmanaged = DCSCopyTextDefinition(nil, nsTerm as CFString, cfRange) else {
            return nil
        }
        let result = (unmanaged.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
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
