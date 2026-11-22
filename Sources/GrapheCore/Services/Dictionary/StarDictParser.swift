import Darwin
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

private enum SortOrder: Sendable {
    case asciiCaseInsensitive
    case unicodeLowercase
    case unsorted
}

/// Memory-mapped sparse-checkpoint index over a StarDict `.idx` or `.syn` binary file.
/// Uses ~4 bytes per `stride` entries (~230 KB total for 6+ million entries) instead of
/// hundreds of megabytes of Swift Strings and Dictionary hash tables.
private struct SparseWordTable: Sendable {
    let data: Data
    let payloadByteCount: Int // 8 or 12 for .idx, 4 for .syn
    let stride: Int
    let checkpoints: [UInt32]
    let entryCount: Int
    let sortOrder: SortOrder

    init(data: Data, payloadByteCount: Int, stride: Int, ifoURL: URL?) throws {
        self.data = data
        self.payloadByteCount = payloadByteCount
        self.stride = stride

        var checkpoints: [UInt32] = []
        var entryCount = 0
        var isSortedAscii = true
        var isSortedUnicode = true

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let total = raw.count
            checkpoints.reserveCapacity(max(16, total / (stride * 18)))

            var i = 0
            var prevStart = -1
            var prevLen = 0

            while i < total {
                let wordStart = i
                guard let wordEnd = SparseWordTable.findNull(base: base, from: i, total: total) else {
                    break
                }
                let wordLen = wordEnd - wordStart
                let payloadEnd = wordEnd + 1 + payloadByteCount
                guard payloadEnd <= total else {
                    if let ifoURL {
                        throw StarDictError.corruptIndex(ifoURL)
                    }
                    break
                }

                if entryCount % stride == 0 {
                    checkpoints.append(UInt32(wordStart))
                }

                if prevStart >= 0 && isSortedAscii {
                    let cmpAscii = SparseWordTable.compareAsciiLower(
                        base.advanced(by: prevStart), prevLen,
                        base.advanced(by: wordStart), wordLen
                    )
                    if cmpAscii > 0 {
                        isSortedAscii = false
                    }
                }

                prevStart = wordStart
                prevLen = wordLen
                entryCount += 1
                i = payloadEnd
            }

            // Only verify Unicode lowercase order if ASCII-case-insensitive order failed.
            // Pure-ASCII pairs agree with compareAsciiLower; any pair involving non-ASCII bytes
            // must be checked with String.lowercased() so we never falsely mark an unsorted table
            // as .unicodeLowercase.
            if !isSortedAscii {
                var uPos = 0
                var uPrevStart = -1
                var uPrevLen = 0
                var uPrevNonAscii = false
                var uPrevLower: String?

                while uPos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: uPos, total: total) else {
                        break
                    }
                    let wordLen = wordEnd - uPos
                    let nextPos = wordEnd + 1 + payloadByteCount
                    guard nextPos <= total else { break }

                    let curNonAscii = SparseWordTable.containsNonAscii(base.advanced(by: uPos), wordLen)
                    var curLower: String?

                    if uPrevStart >= 0 {
                        if !uPrevNonAscii && !curNonAscii {
                            if SparseWordTable.compareAsciiLower(
                                base.advanced(by: uPrevStart), uPrevLen,
                                base.advanced(by: uPos), wordLen
                            ) > 0 {
                                isSortedUnicode = false
                                break
                            }
                        } else {
                            let prevStr = uPrevLower ?? String(
                                decoding: UnsafeBufferPointer(start: base.advanced(by: uPrevStart), count: uPrevLen),
                                as: UTF8.self
                            ).lowercased()
                            let nextStr = String(
                                decoding: UnsafeBufferPointer(start: base.advanced(by: uPos), count: wordLen),
                                as: UTF8.self
                            ).lowercased()
                            curLower = nextStr
                            if prevStr > nextStr {
                                isSortedUnicode = false
                                break
                            }
                        }
                    }

                    uPrevStart = uPos
                    uPrevLen = wordLen
                    uPrevNonAscii = curNonAscii
                    uPrevLower = curLower
                    uPos = nextPos
                }
            }
        }

        self.checkpoints = checkpoints
        self.entryCount = entryCount
        if isSortedAscii {
            self.sortOrder = .asciiCaseInsensitive
        } else if isSortedUnicode {
            self.sortOrder = .unicodeLowercase
        } else {
            self.sortOrder = .unsorted
        }
    }

    /// Reads the raw word string and payload bytes for entry at `entryIndex` in O(stride) (~2 µs).
    func readRecord(atIndex entryIndex: Int) -> (word: String, payloadOffset: Int)? {
        guard entryIndex >= 0, entryIndex < entryCount else { return nil }
        let block = entryIndex / stride
        guard block < checkpoints.count else { return nil }
        let startOffset = Int(checkpoints[block])
        let skipCount = entryIndex % stride

        return data.withUnsafeBytes { raw -> (word: String, payloadOffset: Int)? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let total = raw.count
            var pos = startOffset
            var remaining = skipCount

            while pos < total {
                guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { return nil }
                let payloadOffset = wordEnd + 1
                let nextPos = payloadOffset + payloadByteCount
                guard nextPos <= total else { return nil }

                if remaining == 0 {
                    let word = String(
                        decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordEnd - pos),
                        as: UTF8.self
                    )
                    return (word, payloadOffset)
                }
                remaining -= 1
                pos = nextPos
            }
            return nil
        }
    }

    /// Finds all entry indices matching `query` (exact or case-insensitive depending on sort order).
    /// Returns up to `maxHits` entry indices (for `.idx`) or target indices (for `.syn` via `extractPayload`).
    func findMatchingEntries(for query: String, maxHits: Int = 6) -> [(entryIndex: Int, word: String, payloadOffset: Int)] {
        guard entryCount > 0, !query.isEmpty else { return [] }

        let queryBytes = Array(query.utf8)
        let queryLower = query.lowercased()

        return data.withUnsafeBytes { raw -> [(entryIndex: Int, word: String, payloadOffset: Int)] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let total = raw.count
            var matches: [(entryIndex: Int, word: String, payloadOffset: Int)] = []

            switch sortOrder {
            case .asciiCaseInsensitive:
                let block = lowerBoundBlockAscii(base: base, total: total, keyBytes: queryBytes)
                let startBlock = max(0, block - 1)
                var pos = Int(checkpoints[startBlock])
                var idx = startBlock * stride

                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let payloadOffset = wordEnd + 1
                    let nextPos = payloadOffset + payloadByteCount
                    guard nextPos <= total else { break }

                    let cmp = SparseWordTable.compareAsciiLower(
                        base.advanced(by: pos), wordEnd - pos,
                        queryBytes, queryBytes.count
                    )
                    if cmp == 0 {
                        let word = String(
                            decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordEnd - pos),
                            as: UTF8.self
                        )
                        matches.append((idx, word, payloadOffset))
                        if matches.count >= maxHits { break }
                    } else if cmp > 0 {
                        break
                    }
                    idx += 1
                    pos = nextPos
                }

            case .unicodeLowercase:
                let block = lowerBoundBlockUnicode(base: base, total: total, keyLower: queryLower)
                let startBlock = max(0, block - 1)
                var pos = Int(checkpoints[startBlock])
                var idx = startBlock * stride

                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let payloadOffset = wordEnd + 1
                    let nextPos = payloadOffset + payloadByteCount
                    guard nextPos <= total else { break }

                    let word = String(
                        decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordEnd - pos),
                        as: UTF8.self
                    )
                    let wordLower = word.lowercased()
                    if wordLower == queryLower {
                        matches.append((idx, word, payloadOffset))
                        if matches.count >= maxHits { break }
                    } else if wordLower > queryLower {
                        break
                    }
                    idx += 1
                    pos = nextPos
                }

            case .unsorted:
                let normQuery = StarDictDictionary.normalizeKey(query)
                var pos = 0
                var idx = 0
                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let payloadOffset = wordEnd + 1
                    let nextPos = payloadOffset + payloadByteCount
                    guard nextPos <= total else { break }

                    let word = String(
                        decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordEnd - pos),
                        as: UTF8.self
                    )
                    if word == query || StarDictDictionary.normalizeKey(word) == normQuery {
                        matches.append((idx, word, payloadOffset))
                        if matches.count >= maxHits { break }
                    }
                    idx += 1
                    pos = nextPos
                }
            }

            return matches
        }
    }

    /// O(log N) prefix search for nearby word suggestions.
    func suggestByPrefix(_ prefix: String, limit: Int, maxLengthDelta: Int? = nil, targetLength: Int = 0, seen: inout Set<String>) -> [String] {
        guard entryCount > 0, !prefix.isEmpty, limit > 0 else { return [] }

        let prefixBytes = Array(prefix.utf8)
        let prefixLower = prefix.lowercased()

        return data.withUnsafeBytes { raw -> [String] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let total = raw.count
            var results: [String] = []

            switch sortOrder {
            case .asciiCaseInsensitive:
                let block = lowerBoundBlockAscii(base: base, total: total, keyBytes: prefixBytes)
                let startBlock = max(0, block - 1)
                var pos = Int(checkpoints[startBlock])
                var scannedAfterMatch = 0

                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let wordLen = wordEnd - pos
                    let nextPos = wordEnd + 1 + payloadByteCount
                    guard nextPos <= total else { break }

                    if SparseWordTable.hasAsciiLowerPrefix(base.advanced(by: pos), wordLen, prefixBytes) {
                        let word = String(
                            decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordLen),
                            as: UTF8.self
                        )
                        let lengthOK = maxLengthDelta.map { abs(word.count - targetLength) <= $0 } ?? true
                        if lengthOK && !seen.contains(word) {
                            seen.insert(word)
                            results.append(word)
                            if results.count >= limit { break }
                        }
                        scannedAfterMatch += 1
                        if maxLengthDelta != nil && scannedAfterMatch > 400 { break }
                    } else {
                        let cmp = SparseWordTable.compareAsciiLower(
                            base.advanced(by: pos), wordLen,
                            prefixBytes, prefixBytes.count
                        )
                        if cmp > 0 { break }
                    }
                    pos = nextPos
                }

            case .unicodeLowercase:
                let block = lowerBoundBlockUnicode(base: base, total: total, keyLower: prefixLower)
                let startBlock = max(0, block - 1)
                var pos = Int(checkpoints[startBlock])
                var scannedAfterMatch = 0

                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let wordLen = wordEnd - pos
                    let nextPos = wordEnd + 1 + payloadByteCount
                    guard nextPos <= total else { break }

                    let word = String(
                        decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordLen),
                        as: UTF8.self
                    )
                    let wordLower = word.lowercased()
                    if wordLower.hasPrefix(prefixLower) {
                        let lengthOK = maxLengthDelta.map { abs(word.count - targetLength) <= $0 } ?? true
                        if lengthOK && !seen.contains(word) {
                            seen.insert(word)
                            results.append(word)
                            if results.count >= limit { break }
                        }
                        scannedAfterMatch += 1
                        if maxLengthDelta != nil && scannedAfterMatch > 400 { break }
                    } else if wordLower > prefixLower {
                        break
                    }
                    pos = nextPos
                }

            case .unsorted:
                var pos = 0
                while pos < total {
                    guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else { break }
                    let wordLen = wordEnd - pos
                    let nextPos = wordEnd + 1 + payloadByteCount
                    guard nextPos <= total else { break }

                    let word = String(
                        decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordLen),
                        as: UTF8.self
                    )
                    if StarDictDictionary.normalizeKey(word).hasPrefix(prefixLower) {
                        let lengthOK = maxLengthDelta.map { abs(word.count - targetLength) <= $0 } ?? true
                        if lengthOK && !seen.contains(word) {
                            seen.insert(word)
                            results.append(word)
                            if results.count >= limit { break }
                        }
                    }
                    pos = nextPos
                }
            }

            return results
        }
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, offset + 4 <= raw.count else {
                return 0
            }
            return (UInt32(base[offset]) << 24)
                | (UInt32(base[offset + 1]) << 16)
                | (UInt32(base[offset + 2]) << 8)
                | UInt32(base[offset + 3])
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, offset + 8 <= raw.count else {
                return 0
            }
            var value: UInt64 = 0
            for b in 0..<8 {
                value = (value << 8) | UInt64(base[offset + b])
            }
            return value
        }
    }

    @inline(__always)
    private static func findNull(base: UnsafePointer<UInt8>, from offset: Int, total: Int) -> Int? {
        guard offset < total, let nullPtr = memchr(base.advanced(by: offset), 0, total - offset) else {
            return nil
        }
        return UnsafePointer(nullPtr.assumingMemoryBound(to: UInt8.self)) - base
    }

    private func lowerBoundBlockAscii(base: UnsafePointer<UInt8>, total: Int, keyBytes: [UInt8]) -> Int {
        var lo = 0
        var hi = checkpoints.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let pos = Int(checkpoints[mid])
            guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else {
                hi = mid
                continue
            }
            let wordLen = wordEnd - pos
            let cmp = SparseWordTable.compareAsciiLower(base.advanced(by: pos), wordLen, keyBytes, keyBytes.count)
            if cmp < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func lowerBoundBlockUnicode(base: UnsafePointer<UInt8>, total: Int, keyLower: String) -> Int {
        var lo = 0
        var hi = checkpoints.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let pos = Int(checkpoints[mid])
            guard let wordEnd = SparseWordTable.findNull(base: base, from: pos, total: total) else {
                hi = mid
                continue
            }
            let wordLen = wordEnd - pos
            let wordLower = String(
                decoding: UnsafeBufferPointer(start: base.advanced(by: pos), count: wordLen),
                as: UTF8.self
            ).lowercased()
            if wordLower < keyLower {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    @inline(__always)
    private static func containsNonAscii(_ ptr: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        for i in 0..<len {
            if ptr[i] >= 0x80 { return true }
        }
        return false
    }

    @inline(__always)
    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? (byte &+ 32) : byte
    }

    @inline(__always)
    private static func compareAsciiLower(
        _ a: UnsafePointer<UInt8>, _ aLen: Int,
        _ b: UnsafePointer<UInt8>, _ bLen: Int
    ) -> Int {
        let minLen = min(aLen, bLen)
        for i in 0..<minLen {
            let ca = asciiLower(a[i])
            let cb = asciiLower(b[i])
            if ca != cb {
                return ca < cb ? -1 : 1
            }
        }
        if aLen != bLen {
            return aLen < bLen ? -1 : 1
        }
        return 0
    }

    @inline(__always)
    private static func hasAsciiLowerPrefix(
        _ word: UnsafePointer<UInt8>, _ wordLen: Int,
        _ prefix: [UInt8]
    ) -> Bool {
        let pLen = prefix.count
        guard wordLen >= pLen else { return false }
        for i in 0..<pLen {
            if asciiLower(word[i]) != asciiLower(prefix[i]) {
                return false
            }
        }
        return true
    }
}

private enum DictPayloadStorage: Sendable {
    case mappedPlain(Data)
    case dictZip(DictZipReader)
    case decompressed(Data)

    func read(offset: UInt64, size: UInt32) -> Data? {
        switch self {
        case .mappedPlain(let data), .decompressed(let data):
            guard let start = Int(exactly: offset), start >= 0 else { return nil }
            let (end, overflow) = start.addingReportingOverflow(Int(size))
            guard !overflow, end <= data.count, end > start else { return nil }
            return data.subdata(in: start..<end)
        case .dictZip(let reader):
            return reader.read(offset: offset, size: size)
        }
    }
}

public final class StarDictDictionary: @unchecked Sendable {
    public let info: StarDictInfo

    private let idxTable: SparseWordTable
    private let offsetByteCount: Int
    private let dictStorage: DictPayloadStorage

    // Lazy .syn table (e.g., wiktionary-tr-en's 54 MB .syn is only mapped/indexed when actually queried)
    private let synURL: URL?
    private let synGzURL: URL?
    private let synLock = NSLock()
    private var synLoaded = false
    private var synTable: SparseWordTable?

    private static let turkishLocale = Locale(identifier: "tr_TR")

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

        // 1. Memory-map .idx (or decompress .idx.gz) and build sparse checkpoints
        let idxData: Data
        if FileManager.default.fileExists(atPath: idxURL.path) {
            idxData = try Data(contentsOf: idxURL, options: .mappedIfSafe)
        } else if FileManager.default.fileExists(atPath: idxGzURL.path) {
            idxData = try ZlibDecompressor.decompress(Data(contentsOf: idxGzURL))
        } else {
            throw StarDictError.missingIdxFile(ifoURL)
        }

        let offsetBytes = (info.idxOffsetBits == 64) ? 8 : 4
        self.offsetByteCount = offsetBytes
        self.idxTable = try SparseWordTable(
            data: idxData,
            payloadByteCount: offsetBytes + 4,
            stride: 64,
            ifoURL: ifoURL
        )

        // 2. Open .dict or .dict.dz using zero-copy mmap + dictzip random access
        if FileManager.default.fileExists(atPath: dictURL.path) {
            let mapped = try Data(contentsOf: dictURL, options: .mappedIfSafe)
            self.dictStorage = .mappedPlain(mapped)
        } else if FileManager.default.fileExists(atPath: dictDzURL.path) {
            let mapped = try Data(contentsOf: dictDzURL, options: .mappedIfSafe)
            if let reader = DictZipReader(mappedData: mapped) {
                self.dictStorage = .dictZip(reader)
            } else {
                // Fallback for non-dictzip plain gzipped .dict.dz files
                let decompressed = try ZlibDecompressor.decompress(mapped)
                self.dictStorage = .decompressed(decompressed)
            }
        } else {
            throw StarDictError.missingDictFile(ifoURL)
        }

        // 3. Record optional .syn / .syn.gz URLs for lazy loading on first synonym lookup
        self.synURL = FileManager.default.fileExists(atPath: synURL.path) ? synURL : nil
        self.synGzURL = FileManager.default.fileExists(atPath: synGzURL.path) ? synGzURL : nil
    }

    public func lookup(candidates: [String]) -> [StarDictHit] {
        var matchedIndices: [Int] = []
        var seen = Set<Int>()

        func appendUnique(_ idx: Int) {
            if idx >= 0 && idx < idxTable.entryCount && !seen.contains(idx) {
                seen.insert(idx)
                matchedIndices.append(idx)
            }
        }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Build case variants (handles Turkish İ/i, I/ı and standard Unicode/ASCII)
            let searchForms = buildSearchForms(for: trimmed)

            // Tier 1 & 2: Exact + Case-insensitive match in .idx
            for form in searchForms {
                let idxMatches = idxTable.findMatchingEntries(for: form, maxHits: 4)
                for m in idxMatches {
                    appendUnique(m.entryIndex)
                }
            }

            // Tier 3: .syn synonym / inflected form match
            if matchedIndices.isEmpty, let syn = loadSynTableIfNeeded() {
                for form in searchForms {
                    let synMatches = syn.findMatchingEntries(for: form, maxHits: 4)
                    for m in synMatches {
                        let targetIdx = Int(syn.readUInt32BE(at: m.payloadOffset))
                        appendUnique(targetIdx)
                    }
                    if !matchedIndices.isEmpty { break }
                }
            }

            if !matchedIndices.isEmpty {
                break
            }
        }

        return matchedIndices.prefix(3).compactMap { readEntry(at: $0) }
    }

    public func suggestNearby(for query: String, limit: Int = 6) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var prefixMatches: [String] = []
        var seen = Set<String>()

        let primaryPrefix = trimmed.lowercased()
        prefixMatches.append(
            contentsOf: idxTable.suggestByPrefix(primaryPrefix, limit: limit, seen: &seen)
        )

        if prefixMatches.count < limit {
            let trPrefix = trimmed.lowercased(with: Self.turkishLocale)
            if trPrefix != primaryPrefix {
                prefixMatches.append(
                    contentsOf: idxTable.suggestByPrefix(trPrefix, limit: limit - prefixMatches.count, seen: &seen)
                )
            }
        }

        if prefixMatches.count < limit {
            let trCapPrefix = trimmed.capitalized(with: Self.turkishLocale)
            if trCapPrefix != primaryPrefix && trCapPrefix.utf8.contains(where: { $0 >= 0x80 }) {
                prefixMatches.append(
                    contentsOf: idxTable.suggestByPrefix(trCapPrefix, limit: limit - prefixMatches.count, seen: &seen)
                )
            }
        }

        // If fewer than limit, try shorter prefix (first 3 chars)
        if prefixMatches.count < limit && primaryPrefix.count >= 4 {
            let shortPrefix = String(primaryPrefix.prefix(3))
            prefixMatches.append(
                contentsOf: idxTable.suggestByPrefix(
                    shortPrefix,
                    limit: limit - prefixMatches.count,
                    maxLengthDelta: 4,
                    targetLength: primaryPrefix.count,
                    seen: &seen
                )
            )
        }

        return Array(prefixMatches.prefix(limit))
    }

    private func loadSynTableIfNeeded() -> SparseWordTable? {
        synLock.lock()
        if synLoaded {
            let table = synTable
            synLock.unlock()
            return table
        }
        synLock.unlock()

        var built: SparseWordTable?
        if let synURL,
           let synData = try? Data(contentsOf: synURL, options: .mappedIfSafe) {
            built = try? SparseWordTable(data: synData, payloadByteCount: 4, stride: 128, ifoURL: nil)
        } else if let synGzURL,
                  let compressed = try? Data(contentsOf: synGzURL),
                  let synData = try? ZlibDecompressor.decompress(compressed) {
            built = try? SparseWordTable(data: synData, payloadByteCount: 4, stride: 128, ifoURL: nil)
        }

        synLock.lock()
        if !synLoaded {
            synTable = built
            synLoaded = true
        }
        let result = synTable
        synLock.unlock()
        return result
    }

    private func buildSearchForms(for term: String) -> [String] {
        var forms: [String] = [term]
        func appendUnique(_ value: String) {
            if !forms.contains(value) {
                forms.append(value)
            }
        }

        let lower = term.lowercased()
        appendUnique(lower)

        let trLower = term.lowercased(with: Self.turkishLocale)
        appendUnique(trLower)

        // For .asciiCaseInsensitive dictionaries (e.g. TDK), non-ASCII uppercase headwords
        // like "Çanakkale", "İstanbul", "Orta Çağ" do not fold via ASCII lowercase; include
        // Turkish and standard capitalized forms when they contain non-ASCII bytes.
        let trCap = trLower.capitalized(with: Self.turkishLocale)
        if trCap.utf8.contains(where: { $0 >= 0x80 }) {
            appendUnique(trCap)
        }
        let stdCap = lower.capitalized
        if stdCap.utf8.contains(where: { $0 >= 0x80 }) {
            appendUnique(stdCap)
        }
        return forms
    }

    private func readEntry(at index: Int) -> StarDictHit? {
        guard let record = idxTable.readRecord(atIndex: index) else { return nil }

        let offset: UInt64
        let size: UInt32
        if offsetByteCount == 8 {
            offset = idxTable.readUInt64BE(at: record.payloadOffset)
            size = idxTable.readUInt32BE(at: record.payloadOffset + 8)
        } else {
            offset = UInt64(idxTable.readUInt32BE(at: record.payloadOffset))
            size = idxTable.readUInt32BE(at: record.payloadOffset + 4)
        }

        guard let slice = dictStorage.read(offset: offset, size: size) else { return nil }

        if let seq = info.sameTypeSequence, let firstType = seq.first {
            let text = extractTextFromSequence(slice: slice, sequence: seq)
            return StarDictHit(
                dictionaryName: info.bookName,
                matchedHeadword: record.word,
                rawText: text,
                typeCode: firstType
            )
        } else {
            guard let typeByte = slice.first else { return nil }
            let typeChar = Character(UnicodeScalar(typeByte))
            let payload = slice.dropFirst()
            let text = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1)
                ?? ""
            return StarDictHit(
                dictionaryName: info.bookName,
                matchedHeadword: record.word,
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
}
