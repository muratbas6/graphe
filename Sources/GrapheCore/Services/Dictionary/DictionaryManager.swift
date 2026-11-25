import Foundation
import NaturalLanguage
import Observation

public struct InstalledStarDictConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: String { ifoPath }
    public let ifoPath: String
    public var bookName: String
    public var wordCount: Int
    public var isEnabled: Bool

    public var ifoURL: URL { URL(fileURLWithPath: ifoPath) }

    public init(ifoPath: String, bookName: String, wordCount: Int, isEnabled: Bool = true) {
        self.ifoPath = ifoPath
        self.bookName = bookName
        self.wordCount = wordCount
        self.isEnabled = isEnabled
    }
}

public struct DictionaryCardResult: Identifiable, Equatable {
    public let id: String
    public let sourceName: String
    public let matchedHeadword: String
    public let plainText: String
    public let attributedText: AttributedString
    public let isSystemDictionary: Bool

    public init(
        id: String,
        sourceName: String,
        matchedHeadword: String,
        plainText: String,
        attributedText: AttributedString,
        isSystemDictionary: Bool = false
    ) {
        self.id = id
        self.sourceName = sourceName
        self.matchedHeadword = matchedHeadword
        self.plainText = plainText
        self.attributedText = attributedText
        self.isSystemDictionary = isSystemDictionary
    }
}

public struct MultiDictionaryLookupResult: Equatable {
    public let query: String
    public let primaryWord: String
    public let detectedLanguageCode: String?
    public let detectedLanguageName: String?
    public let cards: [DictionaryCardResult]
    public let nearbySuggestions: [String]

    public init(
        query: String,
        primaryWord: String,
        detectedLanguageCode: String?,
        detectedLanguageName: String?,
        cards: [DictionaryCardResult],
        nearbySuggestions: [String]
    ) {
        self.query = query
        self.primaryWord = primaryWord
        self.detectedLanguageCode = detectedLanguageCode
        self.detectedLanguageName = detectedLanguageName
        self.cards = cards
        self.nearbySuggestions = nearbySuggestions
    }
}

@Observable
@MainActor
public final class DictionaryManager {
    public var installedDictionaries: [InstalledStarDictConfig] = []
    public var includeSystemDictionary: Bool = false
    public var lastError: String?

    private var loadedCache: [String: StarDictDictionary] = [:]
    private var prewarmingPaths: Set<String> = []
    private let systemService: DictionaryProviding
    private let defaults: UserDefaults
    private let configKey = "graphe.stardict.configs.v1"
    private let systemDictKey = "graphe.stardict.includeSystem.v1"

    public init(
        systemService: DictionaryProviding = SystemOfflineDictionaryService(),
        defaults: UserDefaults = .standard
    ) {
        self.systemService = systemService
        self.defaults = defaults
        loadSavedConfigs()
        discoverBundledDictionaries()
    }

    /// Automatically registers any StarDict dictionaries bundled inside `Graphe.app/Contents/Resources/BundledDictionaries`.
    public func discoverBundledDictionaries(in customDirectory: URL? = nil) {
        let bundledDir = customDirectory
            ?? Bundle.main.resourceURL?.appendingPathComponent("BundledDictionaries", isDirectory: true)
        guard let bundledDir, FileManager.default.fileExists(atPath: bundledDir.path) else {
            return
        }

        // Remove stale entries pointing to an old moved app bundle's BundledDictionaries
        let beforeStaleCleanup = installedDictionaries.count
        installedDictionaries.removeAll { config in
            config.ifoPath.contains("/Contents/Resources/BundledDictionaries/")
                && !FileManager.default.fileExists(atPath: config.ifoPath)
        }
        var changed = installedDictionaries.count != beforeStaleCleanup

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundledDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            if changed { persistConfigs() }
            return
        }

        var bundledBookNames: Set<String> = []
        var bundledFileNames: Set<String> = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "ifo" else { continue }
            let std = fileURL.standardizedFileURL
            bundledFileNames.insert(std.lastPathComponent.lowercased())
            if let info = try? StarDictDictionary.parseIfo(at: std) {
                bundledBookNames.insert(info.bookName.lowercased())
                if !installedDictionaries.contains(where: { $0.ifoPath == std.path }) {
                    installedDictionaries.append(
                        InstalledStarDictConfig(
                            ifoPath: std.path,
                            bookName: info.bookName,
                            wordCount: info.wordCount,
                            isEnabled: true
                        )
                    )
                    changed = true
                }
            }
        }

        // Remove duplicate external entries (e.g., previously added from ~/Downloads) that are now bundled inside Graphe.app
        let beforeDedup = installedDictionaries.count
        installedDictionaries.removeAll { config in
            let isBundled = config.ifoPath.hasPrefix(bundledDir.standardizedFileURL.path)
            if isBundled { return false }
            let fileName = URL(fileURLWithPath: config.ifoPath).lastPathComponent.lowercased()
            return bundledFileNames.contains(fileName) || bundledBookNames.contains(config.bookName.lowercased())
        }
        if installedDictionaries.count != beforeDedup {
            changed = true
        }

        if changed {
            persistConfigs()
        }
    }

    /// Loads enabled StarDict dictionaries on a background thread at launch so the first lookup never stalls the UI.
    public func prewarmDictionariesAsync() {
        let toPrewarm = installedDictionaries.filter {
            $0.isEnabled && loadedCache[$0.ifoPath] == nil && !prewarmingPaths.contains($0.ifoPath)
        }
        guard !toPrewarm.isEmpty else { return }

        for config in toPrewarm {
            prewarmingPaths.insert(config.ifoPath)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for config in toPrewarm {
                let loaded: StarDictDictionary?
                if FileManager.default.fileExists(atPath: config.ifoPath) {
                    loaded = try? StarDictDictionary(ifoURL: config.ifoURL)
                } else {
                    loaded = nil
                }
                let path = config.ifoPath
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.prewarmingPaths.remove(path)
                    if let loaded, self.loadedCache[path] == nil {
                        self.loadedCache[path] = loaded
                    }
                }
            }
        }
    }

    public func addDictionary(ifoURL: URL) {
        let standardized = ifoURL.standardizedFileURL
        do {
            let dict = try StarDictDictionary(ifoURL: standardized)
            loadedCache[standardized.path] = dict

            if let idx = installedDictionaries.firstIndex(where: { $0.ifoPath == standardized.path }) {
                installedDictionaries[idx].bookName = dict.info.bookName
                installedDictionaries[idx].wordCount = dict.info.wordCount
                installedDictionaries[idx].isEnabled = true
            } else {
                installedDictionaries.append(
                    InstalledStarDictConfig(
                        ifoPath: standardized.path,
                        bookName: dict.info.bookName,
                        wordCount: dict.info.wordCount,
                        isEnabled: true
                    )
                )
            }
            lastError = nil
            persistConfigs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func scanFolder(at folderURL: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var addedCount = 0
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "ifo" {
                let beforeCount = installedDictionaries.count
                addDictionary(ifoURL: fileURL)
                if installedDictionaries.count > beforeCount {
                    addedCount += 1
                }
            }
        }
        return addedCount
    }

    public func toggleEnabled(id: String) {
        guard let idx = installedDictionaries.firstIndex(where: { $0.id == id }) else { return }
        installedDictionaries[idx].isEnabled.toggle()
        if !installedDictionaries[idx].isEnabled {
            loadedCache.removeValue(forKey: id)
        }
        persistConfigs()
    }

    public func moveUp(id: String) {
        guard let idx = installedDictionaries.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        installedDictionaries.swapAt(idx, idx - 1)
        persistConfigs()
    }

    public func moveDown(id: String) {
        guard let idx = installedDictionaries.firstIndex(where: { $0.id == id }),
              idx < installedDictionaries.count - 1 else { return }
        installedDictionaries.swapAt(idx, idx + 1)
        persistConfigs()
    }

    public func removeDictionary(id: String) {
        installedDictionaries.removeAll { $0.id == id }
        loadedCache.removeValue(forKey: id)
        persistConfigs()
    }

    public func setIncludeSystemDictionary(_ enabled: Bool) {
        includeSystemDictionary = enabled
        defaults.set(enabled, forKey: systemDictKey)
    }

    public func lookup(_ rawText: String) -> MultiDictionaryLookupResult {
        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return MultiDictionaryLookupResult(
                query: "",
                primaryWord: "",
                detectedLanguageCode: nil,
                detectedLanguageName: nil,
                cards: [],
                nearbySuggestions: []
            )
        }

        let detected = systemService.detectLanguage(for: cleaned)
        let primaryWord = systemService.extractPrimaryWord(from: cleaned)
        let candidates = buildCandidates(fullQuery: cleaned, primaryWord: primaryWord)

        var cards: [DictionaryCardResult] = []
        var suggestions: [String] = []
        var suggestionSet = Set<String>()

        // 1. Query enabled StarDict dictionaries in user priority order
        for config in installedDictionaries where config.isEnabled {
            guard let dict = loadOrCachedDictionary(for: config) else { continue }
            let hits = dict.lookup(candidates: candidates)
            for (hitIdx, hit) in hits.enumerated() {
                let formatted = StarDictEntryFormatter.format(raw: hit.rawText, typeCode: hit.typeCode)
                cards.append(
                    DictionaryCardResult(
                        id: "\(config.id)#\(hitIdx)#\(hit.matchedHeadword)",
                        sourceName: hit.dictionaryName,
                        matchedHeadword: hit.matchedHeadword,
                        plainText: formatted.plainText,
                        attributedText: formatted.attributed,
                        isSystemDictionary: false
                    )
                )
            }

            if hits.isEmpty && suggestions.count < 6 {
                for word in dict.suggestNearby(for: primaryWord, limit: 6) {
                    if !suggestionSet.contains(word) {
                        suggestionSet.insert(word)
                        suggestions.append(word)
                        if suggestions.count >= 6 { break }
                    }
                }
            }
        }

        // 2. Append macOS built-in system dictionary if enabled
        if includeSystemDictionary {
            let sys = systemService.lookup(cleaned)
            if let def = sys.definition, !def.isEmpty {
                let joined = sys.formattedSenses.joined(separator: "\n")
                cards.append(
                    DictionaryCardResult(
                        id: "system#\(sys.matchedTerm)",
                        sourceName: "macOS Yerleşik Sözlük",
                        matchedHeadword: sys.matchedTerm,
                        plainText: joined,
                        attributedText: AttributedString(joined),
                        isSystemDictionary: true
                    )
                )
            }
        }

        return MultiDictionaryLookupResult(
            query: cleaned,
            primaryWord: primaryWord,
            detectedLanguageCode: detected?.code,
            detectedLanguageName: detected?.name,
            cards: cards,
            nearbySuggestions: suggestions
        )
    }

    private func buildCandidates(fullQuery: String, primaryWord: String) -> [String] {
        var list: [String] = []
        func appendUnique(_ value: String) {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !list.contains(t) {
                list.append(t)
            }
        }

        if fullQuery.split(whereSeparator: { $0.isWhitespace }).count <= 3 {
            appendUnique(fullQuery.trimmingCharacters(in: .punctuationCharacters))
        }
        appendUnique(primaryWord)
        appendUnique(primaryWord.lowercased())
        for stem in SystemOfflineDictionaryService.lightweightEnglishStems(for: primaryWord) {
            appendUnique(stem)
        }
        return list
    }

    private func loadOrCachedDictionary(for config: InstalledStarDictConfig) -> StarDictDictionary? {
        if let cached = loadedCache[config.ifoPath] {
            return cached
        }
        // Avoid duplicating heavy .dict.dz decompression on @MainActor while background prewarm is in flight
        if prewarmingPaths.contains(config.ifoPath) {
            return nil
        }
        guard FileManager.default.fileExists(atPath: config.ifoPath),
              let loaded = try? StarDictDictionary(ifoURL: config.ifoURL) else {
            return nil
        }
        loadedCache[config.ifoPath] = loaded
        return loaded
    }

    private func loadSavedConfigs() {
        if defaults.object(forKey: systemDictKey) != nil {
            includeSystemDictionary = defaults.bool(forKey: systemDictKey)
        }
        guard let data = defaults.data(forKey: configKey),
              let saved = try? JSONDecoder().decode([InstalledStarDictConfig].self, from: data) else {
            return
        }
        installedDictionaries = saved
    }

    private func persistConfigs() {
        if let data = try? JSONEncoder().encode(installedDictionaries) {
            defaults.set(data, forKey: configKey)
        }
    }
}
