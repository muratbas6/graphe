import Foundation

public struct DictionaryLookupResult: Equatable, Sendable {
    public let query: String
    public let matchedTerm: String
    public let detectedLanguageCode: String?
    public let detectedLanguageName: String?
    public let definition: String?
    public let formattedSenses: [String]

    public init(
        query: String,
        matchedTerm: String,
        detectedLanguageCode: String?,
        detectedLanguageName: String?,
        definition: String?,
        formattedSenses: [String]
    ) {
        self.query = query
        self.matchedTerm = matchedTerm
        self.detectedLanguageCode = detectedLanguageCode
        self.detectedLanguageName = detectedLanguageName
        self.definition = definition
        self.formattedSenses = formattedSenses
    }
}

public struct VocabularyItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let term: String
    public let definition: String?
    public let translation: String?
    public let languageCode: String?
    public let sourceDocumentTitle: String?
    public let pageIndex: Int?
    public let savedAt: Date

    public init(
        id: UUID = UUID(),
        term: String,
        definition: String? = nil,
        translation: String? = nil,
        languageCode: String? = nil,
        sourceDocumentTitle: String? = nil,
        pageIndex: Int? = nil,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.definition = definition
        self.translation = translation
        self.languageCode = languageCode
        self.sourceDocumentTitle = sourceDocumentTitle
        self.pageIndex = pageIndex
        self.savedAt = savedAt
    }
}

public enum TargetLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case turkish = "tr"
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case arabic = "ar"
    case russian = "ru"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .turkish: return "Türkçe"
        case .english: return "İngilizce"
        case .german: return "Almanca"
        case .french: return "Fransızca"
        case .spanish: return "İspanyolca"
        case .italian: return "İtalyanca"
        case .arabic: return "Arapça"
        case .russian: return "Rusça"
        }
    }

    public var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }
}
