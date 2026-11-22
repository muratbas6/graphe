import Foundation

public enum StarDictError: LocalizedError, Sendable {
    case invalidIfoFile(URL)
    case missingIdxFile(URL)
    case missingDictFile(URL)
    case corruptIndex(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidIfoFile(let url):
            return "Geçersiz StarDict .ifo dosyası: \(url.lastPathComponent)"
        case .missingIdxFile(let url):
            return ".idx dosyası bulunamadı: \(url.deletingPathExtension().lastPathComponent)"
        case .missingDictFile(let url):
            return ".dict veya .dict.dz dosyası bulunamadı: \(url.deletingPathExtension().lastPathComponent)"
        case .corruptIndex(let url):
            return "StarDict indeks dosyası okunamadı: \(url.lastPathComponent)"
        }
    }
}

public struct StarDictInfo: Sendable, Equatable {
    public let ifoURL: URL
    public let bookName: String
    public let wordCount: Int
    public let synWordCount: Int
    public let idxOffsetBits: Int
    public let sameTypeSequence: String?
    public let description: String?
}

public struct StarDictHit: Equatable, Sendable {
    public let dictionaryName: String
    public let matchedHeadword: String
    public let rawText: String
    public let typeCode: Character
}

private struct StarDictIndexEntry: Sendable {
    let word: String
    let normalizedWord: String
    let offset: UInt64
    let size: UInt32
}

public final class StarDictDictionary: @unchecked Sendable {
    public let info: StarDictInfo

    private let entries: [StarDictIndexEntry]
    private let exactLookup: [String: [Int]]
    private let normalizedLookup: [String: [Int]]
    private let synonymLookup: [String: [Int]]
    private let dictData: Data

    public init(ifoURL: URL) throws {
        let info = try StarDictDictionary.parseIfo(at: ifoURL)
        self.info = info

        let baseURL = ifoURL.deletingPathExtension()
        let idxURL = baseURL.appendingPathExtension("idx")
        let idxGzURL = idxURL.appendingPathExtension("gz")
        let dictURL = baseURL.appendingPathExtension("dict")
        let dictDzURL = dictURL.appendingPathExtension("dz")
        let synURL = baseURL.appendingPathExtension("syn")
        let synGzURL = synURL.appendingPathExtension("gz")

        // 1. Load .idx or .idx.gz
        let idxData: Data
        if FileManager.default.fileExists(atPath: idxURL.path) {
            idxData = try Data(contentsOf: idxURL)
        } else if FileManager.default.fileExists(atPath: idxGzURL.path) {
            idxData = try ZlibDecompressor.decompress(Data(contentsOf: idxGzURL))
        } else {
            throw StarDictError.missingIdxFile(ifoURL)
        }

        // 2. Load .dict or .dict.dz
        if FileManager.default.fileExists(atPath: dictURL.path) {
            self.dictData = try Data(contentsOf: dictURL, options: .mappedIfSafe)
        } else if FileManager.default.fileExists(atPath: dictDzURL.path) {
            self.dictData = try ZlibDecompressor.decompress(Data(contentsOf: dictDzURL))
        } else {
            throw StarDictError.missingDictFile(ifoURL)
        }

        // 3. Parse index entries
        let parsedEntries = try StarDictDictionary.parseIndex(
            data: idxData,
            offsetBits: info.idxOffsetBits,
            ifoURL: ifoURL
        )
        self.entries = parsedEntries

        var exact: [String: [Int]] = [:]
        var norm: [String: [Int]] = [:]
        exact.reserveCapacity(parsedEntries.count)
        norm.reserveCapacity(parsedEntries.count)

        for (index, entry) in parsedEntries.enumerated() {
            exact[entry.word, default: []].append(index)
            norm[entry.normalizedWord, default: []].append(index)
        }
        self.exactLookup = exact
        self.normalizedLookup = norm

        // 4. Parse optional .syn or .syn.gz
        var synMap: [String: [Int]] = [:]
        if FileManager.default.fileExists(atPath: synURL.path),
           let synData = try? Data(contentsOf: synURL) {
            synMap = StarDictDictionary.parseSynonyms(data: synData, maxIndex: parsedEntries.count)
        } else if FileManager.default.fileExists(atPath: synGzURL.path),
                  let compressed = try? Data(contentsOf: synGzURL),
                  let synData = try? ZlibDecompressor.decompress(compressed) {
            synMap = StarDictDictionary.parseSynonyms(data: synData, maxIndex: parsedEntries.count)
        }
        self.synonymLookup = synMap
    }

    public func lookup(candidates: [String]) -> [StarDictHit] {
        var matchedIndices: [Int] = []
        var seen = Set<Int>()

        func appendUnique(_ indices: [Int]) {
            for idx in indices where !seen.contains(idx) {
                seen.insert(idx)
                matchedIndices.append(idx)
            }
        }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Tier 1: Exact match
            if let exact = exactLookup[trimmed] {
                appendUnique(exact)
            }

            // Tier 2: Case & diacritic insensitive normalized match
            let normKey = StarDictDictionary.normalizeKey(trimmed)
            if let norm = normalizedLookup[normKey] {
                appendUnique(norm)
            }

            // Tier 3: .syn synonym match
            if let syns = synonymLookup[normKey] {
                appendUnique(syns)
            }

            if !matchedIndices.isEmpty {
                break
            }
        }

        return matchedIndices.prefix(3).compactMap { readEntry(at: $0) }
    }

    public func suggestNearby(for query: String, limit: Int = 6) -> [String] {
        let normQuery = StarDictDictionary.normalizeKey(query)
        guard normQuery.count >= 2 else { return [] }

        var prefixMatches: [String] = []
        var seen = Set<String>()

        // Fast prefix scan
        for entry in entries {
            if entry.normalizedWord.hasPrefix(normQuery) && !seen.contains(entry.word) {
                seen.insert(entry.word)
                prefixMatches.append(entry.word)
                if prefixMatches.count >= limit {
                    return prefixMatches
                }
            }
        }

        // If fewer than limit, try shorter prefix (first 3 chars)
        if prefixMatches.count < limit && normQuery.count >= 4 {
            let shortPrefix = String(normQuery.prefix(3))
            for entry in entries where entry.normalizedWord.hasPrefix(shortPrefix) {
                if !seen.contains(entry.word) &&
                   abs(entry.normalizedWord.count - normQuery.count) <= 4 {
                    seen.insert(entry.word)
                    prefixMatches.append(entry.word)
                    if prefixMatches.count >= limit {
                        break
                    }
                }
            }
        }

        return prefixMatches
    }

    private func readEntry(at index: Int) -> StarDictHit? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let start = Int(entry.offset)
        let end = start + Int(entry.size)
        guard start >= 0, end <= dictData.count, end > start else { return nil }

        let slice = dictData.subdata(in: start..<end)

        if let seq = info.sameTypeSequence, let firstType = seq.first {
            // Single-type or multi-field sequence
            let text = extractTextFromSequence(slice: slice, sequence: seq)
            return StarDictHit(
                dictionaryName: info.bookName,
                matchedHeadword: entry.word,
                rawText: text,
                typeCode: firstType
            )
        } else {
            // Per-entry type byte prefix
            guard let typeByte = slice.first else { return nil }
            let typeChar = Character(UnicodeScalar(typeByte))
            let payload = slice.dropFirst()
            let text = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1)
                ?? ""
            return StarDictHit(
                dictionaryName: info.bookName,
                matchedHeadword: entry.word,
                rawText: text,
                typeCode: typeChar
            )
        }
    }

    private func extractTextFromSequence(slice: Data, sequence: String) -> String {
        if sequence.count == 1 {
            return String(data: slice, encoding: .utf8)
                ?? String(data: slice, encoding: .isoLatin1)
                ?? ""
        }
        // Multi-field sametypesequence (null-separated until last field)
        var parts: [String] = []
        var cursor = slice.startIndex
        for (idx, _) in sequence.enumerated() {
            let isLast = (idx == sequence.count - 1)
            if isLast {
                let chunk = slice[cursor..<slice.endIndex]
                if let s = String(data: chunk, encoding: .utf8), !s.isEmpty {
                    parts.append(s)
                }
            } else if let nullIdx = slice[cursor..<slice.endIndex].firstIndex(of: 0) {
                let chunk = slice[cursor..<nullIdx]
                if let s = String(data: chunk, encoding: .utf8), !s.isEmpty {
                    parts.append(s)
                }
                cursor = slice.index(after: nullIdx)
            } else {
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    public static func normalizeKey(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    public static func parseIfo(at url: URL) throws -> StarDictInfo {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw StarDictError.invalidIfoFile(url)
        }

        var bookName = url.deletingPathExtension().lastPathComponent
        var wordCount = 0
        var synWordCount = 0
        var idxOffsetBits = 32
        var sameTypeSequence: String?
        var description: String?
        var hasHeader = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("StarDict's dict ifo file") {
                hasHeader = true
                continue
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "bookname":
                if !value.isEmpty { bookName = value }
            case "wordcount":
                wordCount = Int(value) ?? 0
            case "synwordcount":
                synWordCount = Int(value) ?? 0
            case "idxoffsetbits":
                idxOffsetBits = Int(value) ?? 32
            case "sametypesequence":
                sameTypeSequence = value.isEmpty ? nil : value
            case "description":
                description = value.isEmpty ? nil : value
            default:
                break
            }
        }

        guard hasHeader else {
            throw StarDictError.invalidIfoFile(url)
        }

        return StarDictInfo(
            ifoURL: url,
            bookName: bookName,
            wordCount: wordCount,
            synWordCount: synWordCount,
            idxOffsetBits: idxOffsetBits,
            sameTypeSequence: sameTypeSequence,
            description: description
        )
    }

    private static func parseIndex(data: Data, offsetBits: Int, ifoURL: URL) throws -> [StarDictIndexEntry] {
        var result: [StarDictIndexEntry] = []
        let bytes = [UInt8](data)
        let count = bytes.count
        let offsetByteCount = (offsetBits == 64) ? 8 : 4
        var i = 0

        while i < count {
            let wordStart = i
            while i < count && bytes[i] != 0 {
                i += 1
            }
            guard i < count else { break }

            let wordBytes = bytes[wordStart..<i]
            i += 1 // skip null terminator

            guard i + offsetByteCount + 4 <= count else {
                throw StarDictError.corruptIndex(ifoURL)
            }

            var offset: UInt64 = 0
            for b in 0..<offsetByteCount {
                offset = (offset << 8) | UInt64(bytes[i + b])
            }
            i += offsetByteCount

            var size: UInt32 = 0
            for b in 0..<4 {
                size = (size << 8) | UInt32(bytes[i + b])
            }
            i += 4

            let word = String(decoding: wordBytes, as: UTF8.self)
            result.append(
                StarDictIndexEntry(
                    word: word,
                    normalizedWord: normalizeKey(word),
                    offset: offset,
                    size: size
                )
            )
        }

        return result
    }

    private static func parseSynonyms(data: Data, maxIndex: Int) -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        let bytes = [UInt8](data)
        let count = bytes.count
        var i = 0

        while i < count {
            let wordStart = i
            while i < count && bytes[i] != 0 {
                i += 1
            }
            guard i < count else { break }

            let wordBytes = bytes[wordStart..<i]
            i += 1

            guard i + 4 <= count else { break }
            var idx: UInt32 = 0
            for b in 0..<4 {
                idx = (idx << 8) | UInt32(bytes[i + b])
            }
            i += 4

            let target = Int(idx)
            if target >= 0 && target < maxIndex {
                let word = String(decoding: wordBytes, as: UTF8.self)
                let norm = normalizeKey(word)
                map[norm, default: []].append(target)
            }
        }
        return map
    }
}
