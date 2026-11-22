import Foundation
import PDFKit

public struct BookMetadataDraft: Equatable, Sendable {
    public var title: String
    public var author: String
    public var year: Int?
    public var publisher: String
    public var isbn: String
    public var doi: String

    public init(
        title: String = "",
        author: String = "",
        year: Int? = nil,
        publisher: String = "",
        isbn: String = "",
        doi: String = ""
    ) {
        self.title = title
        self.author = author
        self.year = year
        self.publisher = publisher
        self.isbn = isbn
        self.doi = doi
    }

    /// Formats a clean academic filename stem: `Yazar - Kitap Adı (Yıl)`
    public func suggestedFileStem() -> String {
        let cleanTitle = sanitizeFilenameComponent(title)
        let cleanAuthor = sanitizeFilenameComponent(shortAuthorForFilename(author))

        var stem: String
        if !cleanAuthor.isEmpty && !cleanTitle.isEmpty {
            stem = "\(cleanAuthor) - \(cleanTitle)"
        } else if !cleanTitle.isEmpty {
            stem = cleanTitle
        } else if !cleanAuthor.isEmpty {
            stem = cleanAuthor
        } else {
            stem = "Belge"
        }

        if let year, (1400...2100).contains(year) {
            stem += " (\(year))"
        }
        return String(stem.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortAuthorForFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Keep first author if multiple separated by ; or &
        let first = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ";"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        return first
    }

    private func sanitizeFilenameComponent(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let stripped = raw
            .components(separatedBy: forbidden)
            .joined(separator: " ")
        return stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
    }
}

public enum BookMetadataError: Error, LocalizedError {
    case networkUnavailable(String)
    case noMatchFound

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable(let detail):
            return "Çevrimiçi metadata sorgusu başarısız: \(detail)"
        case .noMatchFound:
            return "CrossRef / OpenLibrary üzerinde eşleşen kayıt bulunamadı."
        }
    }
}

public final class BookMetadataService: @unchecked Sendable {
    private static let junkTagRegex = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:[^)\]]*(?:z-lib|z-library|1lib|libgen|anna'?s\s*archive|pdfdrive|b-ok|etc\.|zlib)[^)\]]*)[\)\]]"#,
        options: [.caseInsensitive]
    )
    private static let doiRegex = try! NSRegularExpression(
        pattern: #"\b(10\.\d{4,9}/[-._;()/:A-Za-z0-9]+)\b"#
    )
    private static let isbn13Regex = try! NSRegularExpression(
        pattern: #"\b(97[89][-\s]?(?:\d[-\s]?){9}\d)\b"#
    )
    private static let isbn10Regex = try! NSRegularExpression(
        pattern: #"(?:ISBN(?:-10)?[:\s]+)([0-9][0-9\-\s]{8,11}[0-9Xx])\b"#,
        options: [.caseInsensitive]
    )
    private static let copyrightYearRegex = try! NSRegularExpression(
        pattern: #"(?:©|copyright|\(c\)|published(?:\s+in)?|first\s+published|(?:second|third|fourth|fifth|revised|updated|new|\d+(?:st|nd|rd|th))\s+edition|bask[ıi])\D{0,32}\b(1[5-9]\d{2}|20[0-2]\d)(?:\s*[,/-]\s*(1[5-9]\d{2}|20[0-2]\d))?\b"#,
        options: [.caseInsensitive]
    )
    private static let publisherRegex = try! NSRegularExpression(
        pattern: #"\b([A-ZÇĞİÖŞÜ][A-Za-zÇĞİÖŞÜçğıöşü&\-\.\s]{2,42}(?:University Press|Press|Verlag|Yayınları|Yayınevi|Publishing|Publishers|Books|Routledge|Springer|MIT Press|Oxford|Cambridge))\b"#
    )
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"\b(1[5-9]\d{2}|20[0-2]\d)\b"#
    )
    private static let doiPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        return allowed
    }()

    public init() {}

    // MARK: - 1. Clean Noisy Filenames (z-library, libgen, underscores)

    public func cleanFilenameTitle(_ rawStem: String) -> String {
        var s = rawStem.replacingOccurrences(of: "_", with: " ")
        let fullRange = NSRange(s.startIndex..., in: s)
        s = Self.junkTagRegex.stringByReplacingMatches(in: s, range: fullRange, withTemplate: "")
        // Collapse repeated whitespace and trailing stray punctuation
        let collapsed = s
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,;"))
        return collapsed.isEmpty ? rawStem : collapsed
    }

    // MARK: - 2. Offline Extraction (PDF Attributes + First 6 Pages)

    public func extractOfflineMetadata(
        from pdfURL: URL,
        existing: LibraryDocumentRecord? = nil
    ) -> BookMetadataDraft {
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        let cleanedFilename = cleanFilenameTitle(stem)

        var title = existing?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title == stem {
            title = cleanedFilename
        }
        var author = existing?.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var year = existing?.year
        var publisher = existing?.publisher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var isbn = existing?.isbn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var doi = existing?.doi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let doc = PDFDocument(url: pdfURL) {
            if let attrs = doc.documentAttributes {
                if let attrTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !attrTitle.isEmpty,
                   attrTitle.count > 2,
                   !attrTitle.lowercased().hasSuffix(".pdf"),
                   !attrTitle.lowercased().hasPrefix("microsoft word") {
                    let cleanedAttr = cleanFilenameTitle(attrTitle)
                    if title == cleanedFilename || title.isEmpty {
                        title = cleanedAttr
                    }
                }
                if author.isEmpty,
                   let attrAuthor = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !attrAuthor.isEmpty,
                   attrAuthor.count <= 100 {
                    author = attrAuthor
                }
            }

            // Scan first 6 pages (title page + copyright / colophon page)
            let scanLimit = min(6, doc.pageCount)
            var frontMatter = ""
            for idx in 0..<scanLimit {
                if let pageText = doc.page(at: idx)?.string, !pageText.isEmpty {
                    frontMatter += "\n" + pageText
                }
            }

            if doi.isEmpty, let foundDOI = firstMatch(Self.doiRegex, in: frontMatter, group: 1) {
                doi = foundDOI.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]"))
            }

            if isbn.isEmpty {
                if let raw13 = firstMatch(Self.isbn13Regex, in: frontMatter, group: 1) {
                    isbn = raw13.filter { $0.isNumber }
                } else if let raw10 = firstMatch(Self.isbn10Regex, in: frontMatter, group: 1) {
                    isbn = raw10.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
                }
            }

            if year == nil {
                year = extractBestEditionYear(from: frontMatter)
            }

            if publisher.isEmpty, let pub = firstMatch(Self.publisherRegex, in: frontMatter, group: 1) {
                publisher = pub.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }

        // Also parse "Author - Title (Year)" if present in filename
        if author.isEmpty && cleanedFilename.contains(" - ") {
            let parts = cleanedFilename.components(separatedBy: " - ")
            if parts.count >= 2 {
                let candidateAuthor = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateTitle = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                if candidateAuthor.count >= 3 && candidateAuthor.count <= 50 && candidateTitle.count >= 3 {
                    author = candidateAuthor
                    title = candidateTitle
                }
            }
        }

        return BookMetadataDraft(
            title: title,
            author: author,
            year: year,
            publisher: publisher,
            isbn: isbn,
            doi: doi
        )
    }

    // MARK: - 3. Opt-In Online Enrichment (CrossRef Polite Pool -> OpenLibrary -> Google Books)

    private static let politeUserAgent = "Graphe/1.1 (https://github.com/muratbas6/graphe; mailto:graphe-app@users.noreply.github.com)"
    private static let politeMailto = "graphe-app@users.noreply.github.com"

    public func enrichOnline(draft: BookMetadataDraft) async throws -> BookMetadataDraft {
        let result = draft
        var lastNetworkError: Error?

        // 1) DOI -> CrossRef exact work lookup (highest accuracy)
        if !draft.doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let enriched = try await queryCrossRef(doi: draft.doi, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }
        }

        // 2) ISBN -> CrossRef ISBN filter (fast & exact) -> OpenLibrary ISBN fallback
        let cleanISBN = draft.isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if cleanISBN.count == 10 || cleanISBN.count == 13 {
            do {
                if let enriched = try await queryCrossRef(isbn: cleanISBN, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }
            do {
                if let enriched = try await queryOpenLibrary(isbn: cleanISBN, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }
        }

        // 3) Structured Title + Author -> CrossRef Books (polite pool, strict title/author verification)
        let cleanTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAuthor = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            do {
                if let enriched = try await searchCrossRef(title: cleanTitle, author: cleanAuthor, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }

            // 4) Fallback: OpenLibrary structured search (shorter timeout so it never hangs)
            do {
                if let enriched = try await searchOpenLibrary(title: cleanTitle, author: cleanAuthor, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }

            // 5) Fallback: Google Books (may rate-limit anonymous requests with 429)
            let gbQuery = cleanAuthor.isEmpty
                ? cleanTitle
                : "intitle:\(stripEditionSuffix(from: cleanTitle))+inauthor:\(cleanAuthor)"
            do {
                if let enriched = try await searchGoogleBooks(query: gbQuery, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }
        }

        if let lastNetworkError {
            throw lastNetworkError
        }
        throw BookMetadataError.noMatchFound
    }

    // MARK: - Private Network Helpers

    private func fetchJSON(from url: URL, timeout: TimeInterval = 10.0) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(Self.politeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw BookMetadataError.networkUnavailable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BookMetadataError.networkUnavailable("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BookMetadataError.noMatchFound
        }
        return obj
    }

    private func queryCrossRef(isbn: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = [
            URLQueryItem(name: "filter", value: "isbn:\(isbn)"),
            URLQueryItem(name: "rows", value: "3"),
            URLQueryItem(name: "mailto", value: Self.politeMailto)
        ]
        guard let url = components?.url else { return nil }
        let json = try await fetchJSON(from: url)
        guard let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]],
              let first = items.first else {
            return nil
        }
        return applyCrossRefItem(first, to: base)
    }

    private func searchCrossRef(title: String, author: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        let queryTitle = stripEditionSuffix(from: title)
        let editionHint = extractEditionHint(from: title)

        // Try book types first (avoids dissertations & book reviews overriding actual books)
        if let bookMatch = try await runCrossRefQuery(
            queryTitle: queryTitle,
            author: author,
            typeFilter: "type:book,type:monograph,type:edited-book",
            base: base,
            editionHint: editionHint
        ) {
            return bookMatch
        }

        // Fallback to journal articles & book chapters for academic papers
        return try await runCrossRefQuery(
            queryTitle: queryTitle,
            author: author,
            typeFilter: "type:journal-article,type:book-chapter",
            base: base,
            editionHint: editionHint
        )
    }

    private func runCrossRefQuery(
        queryTitle: String,
        author: String,
        typeFilter: String,
        base: BookMetadataDraft,
        editionHint: String?
    ) async throws -> BookMetadataDraft? {
        var queryItems = [
            URLQueryItem(name: "query.title", value: queryTitle),
            URLQueryItem(name: "filter", value: typeFilter),
            URLQueryItem(name: "rows", value: "6"),
            URLQueryItem(name: "mailto", value: Self.politeMailto)
        ]
        if !author.isEmpty {
            queryItems.append(URLQueryItem(name: "query.author", value: author))
        }
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        let json = try await fetchJSON(from: url)
        guard let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]],
              !items.isEmpty else {
            return nil
        }

        let scored: [([String: Any], Int)] = items.compactMap { item in
            guard let score = scoreCrossRefCandidate(item, queryTitle: queryTitle, queryAuthor: author, base: base, editionHint: editionHint) else {
                return nil
            }
            return (item, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else {
            return nil
        }
        return applyCrossRefItem(best, to: base)
    }

    private func scoreCrossRefCandidate(
        _ item: [String: Any],
        queryTitle: String,
        queryAuthor: String,
        base: BookMetadataDraft,
        editionHint: String?
    ) -> Int? {
        guard let titles = item["title"] as? [String], let rawTitle = titles.first, !rawTitle.isEmpty else {
            return nil
        }

        // 1) Strict title match check so unrelated books/dissertations are NEVER accepted
        let queryTokens = normalizedTokens(queryTitle)
        let candidateTokens = normalizedTokens(rawTitle)
        guard !queryTokens.isEmpty && !candidateTokens.isEmpty else { return nil }
        let overlap = queryTokens.intersection(candidateTokens).count
        let queryCoverage = Double(overlap) / Double(queryTokens.count)
        let candidateCoverage = Double(overlap) / Double(candidateTokens.count)
        guard queryCoverage >= 0.6 && candidateCoverage >= 0.5 else {
            return nil
        }

        // 2) Author surname check when author was supplied
        var score = Int(queryCoverage * 40 + candidateCoverage * 40)
        if !queryAuthor.isEmpty {
            let expectedLast = queryAuthor
                .components(separatedBy: CharacterSet(charactersIn: ";,&"))
                .first?
                .split(whereSeparator: { $0.isWhitespace })
                .last?
                .lowercased() ?? ""
            let itemAuthors = (item["author"] as? [[String: Any]] ?? []).compactMap { a -> String? in
                let f = (a["family"] as? String) ?? ""
                let g = (a["given"] as? String) ?? ""
                return "\(g) \(f)".lowercased()
            }
            if !expectedLast.isEmpty {
                if itemAuthors.contains(where: { $0.contains(expectedLast) }) {
                    score += 35
                } else {
                    return nil
                }
            }
        }

        // 3) Publisher match bonus (e.g. Routledge in Restall PDF)
        let basePub = base.publisher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !basePub.isEmpty, let pub = (item["publisher"] as? String)?.lowercased(),
           pub.contains(basePub) || basePub.contains(pub) {
            score += 30
        }

        // 4) Year / Edition alignment
        if let issued = item["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]],
           let y = parts.first?.first {
            if let baseYear = base.year {
                let diff = abs(y - baseYear)
                if diff == 0 { score += 30 }
                else if diff <= 1 { score += 18 }
            } else if editionHint != nil {
                // For Second/Third/Revised editions, strongly prefer the newer edition
                score += min(25, max(0, y - 1995))
            }
        }

        // Prefer monographs over edited-books when scores tie
        if (item["type"] as? String) == "monograph" {
            score += 4
        }
        return score
    }

    private func applyCrossRefItem(_ item: [String: Any], to base: BookMetadataDraft) -> BookMetadataDraft {
        var updated = base
        if let titles = item["title"] as? [String], let t = titles.first, !t.isEmpty {
            let cleaned = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // Preserve edition suffix (e.g. "Second Edition") if the user's title had it and CrossRef omitted it
            if let hint = extractEditionHint(from: base.title),
               !cleaned.lowercased().contains(hint) {
                updated.title = "\(cleaned) (\(hint.capitalized))"
            } else {
                updated.title = cleaned
            }
        }
        if let authors = item["author"] as? [[String: Any]] {
            let names = authors.compactMap { a -> String? in
                let given = (a["given"] as? String) ?? ""
                let family = (a["family"] as? String) ?? ""
                let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                return full.isEmpty ? nil : full
            }
            if !names.isEmpty {
                updated.author = names.prefix(3).joined(separator: "; ")
            }
        }
        if let pub = item["publisher"] as? String, !pub.isEmpty {
            updated.publisher = cleanPublisherName(pub)
        }
        if let issued = item["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]],
           let y = parts.first?.first {
            if let existingYear = base.year, extractEditionHint(from: base.title) != nil, y < existingYear {
                updated.year = existingYear
            } else {
                updated.year = y
            }
        }
        if updated.doi.isEmpty, let foundDOI = item["DOI"] as? String, !foundDOI.isEmpty {
            updated.doi = foundDOI
        }
        if updated.isbn.isEmpty, let isbns = item["ISBN"] as? [String],
           let bestISBN = isbns.first(where: { $0.filter(\.isNumber).count == 13 }) ?? isbns.first,
           !bestISBN.isEmpty {
            updated.isbn = bestISBN
        }
        return updated
    }

    private func cleanPublisherName(_ raw: String) -> String {
        var s = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Fix CrossRef's occasional duplicated city suffix like "Oxford University PressOxford"
        for suffix in ["Oxford", "Cambridge", "London", "New York"] {
            if s.hasPrefix(suffix) && s.hasSuffix(suffix) && s.count > suffix.count * 2 {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    private func stripEditionSuffix(from title: String) -> String {
        let pattern = #"[\s,:\-\(]*(?:second|third|fourth|fifth|revised|updated|\d+(?:st|nd|rd|th))\s+edition[\)\s]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title
        }
        let range = NSRange(title.startIndex..., in: title)
        let stripped = regex.stringByReplacingMatches(in: title, range: range, withTemplate: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :-,"))
        return stripped.isEmpty ? title : stripped
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to", "for", "edition", "second", "third", "2nd", "3rd"]
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        let filtered = Set(words.filter { $0.count >= 2 && !stopWords.contains($0) })
        return filtered.isEmpty ? Set(words) : filtered
    }

    private func searchGoogleBooks(query: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "5"),
            URLQueryItem(name: "printType", value: "books")
        ]
        guard let url = components?.url else { return nil }
        let json = try await fetchJSON(from: url)
        guard let items = json["items"] as? [[String: Any]], !items.isEmpty else {
            return nil
        }

        let editionHint = extractEditionHint(from: base.title)
        let bestVolumeInfo: [String: Any]? = items
            .compactMap { $0["volumeInfo"] as? [String: Any] }
            .max { a, b in
                scoreGoogleBooksCandidate(a, against: base, editionHint: editionHint)
                    < scoreGoogleBooksCandidate(b, against: base, editionHint: editionHint)
            }
        guard let volumeInfo = bestVolumeInfo else { return nil }

        var updated = base
        if let t = volumeInfo["title"] as? String, !t.isEmpty {
            if let sub = volumeInfo["subtitle"] as? String, !sub.isEmpty, !t.localizedCaseInsensitiveContains(sub) {
                updated.title = "\(t): \(sub)"
            } else {
                updated.title = t
            }
        }
        if let authors = volumeInfo["authors"] as? [String], !authors.isEmpty {
            updated.author = authors.prefix(3).joined(separator: "; ")
        }
        if let pub = volumeInfo["publisher"] as? String, !pub.isEmpty {
            updated.publisher = pub
        }
        if let pubDate = volumeInfo["publishedDate"] as? String,
           let match = firstMatch(Self.yearRegex, in: pubDate, group: 1),
           let y = Int(match) {
            // Avoid overwriting a newer edition year already confirmed on the PDF copyright page with a 1st-edition year
            if let existingYear = base.year, editionHint != nil, y < existingYear {
                updated.year = existingYear
            } else {
                updated.year = y
            }
        }
        if updated.isbn.isEmpty,
           let identifiers = volumeInfo["industryIdentifiers"] as? [[String: Any]] {
            let isbn13 = identifiers.first(where: { ($0["type"] as? String) == "ISBN_13" })?["identifier"] as? String
            let isbn10 = identifiers.first(where: { ($0["type"] as? String) == "ISBN_10" })?["identifier"] as? String
            if let best = isbn13 ?? isbn10, !best.isEmpty {
                updated.isbn = best
            }
        }
        return updated
    }

    private func extractBestEditionYear(from frontMatter: String) -> Int? {
        let range = NSRange(frontMatter.startIndex..., in: frontMatter)
        let matches = Self.copyrightYearRegex.matches(in: frontMatter, range: range)
        let currentYear = Calendar.current.component(.year, from: Date())
        var years: [Int] = []
        for match in matches {
            for group in 1..<match.numberOfRanges {
                let r = match.range(at: group)
                guard r.location != NSNotFound, let swiftRange = Range(r, in: frontMatter),
                      let y = Int(frontMatter[swiftRange]),
                      y >= 1500 && y <= currentYear + 1 else {
                    continue
                }
                years.append(y)
            }
        }
        // Copyright pages list "First published 2000; Second edition 2017" — prefer the latest edition year.
        return years.max()
    }

    private func extractEditionHint(from title: String) -> String? {
        let lower = title.lowercased()
        let hints = ["second edition", "2nd edition", "third edition", "3rd edition", "fourth edition", "4th edition", "revised edition", "expanded edition"]
        return hints.first(where: { lower.contains($0) })
    }

    private func scoreGoogleBooksCandidate(_ info: [String: Any], against base: BookMetadataDraft, editionHint: String?) -> Int {
        var score = 0
        let combinedTitle = [info["title"] as? String, info["subtitle"] as? String]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if let hint = editionHint {
            let normalizedHint = hint.replacingOccurrences(of: "second", with: "2nd")
            if combinedTitle.contains(hint) || combinedTitle.contains(normalizedHint) {
                score += 40
            }
        }
        if let pubDate = info["publishedDate"] as? String,
           let match = firstMatch(Self.yearRegex, in: pubDate, group: 1),
           let y = Int(match) {
            if let baseYear = base.year, y == baseYear {
                score += 30
            } else if editionHint != nil {
                score += min(20, max(0, (y - 1990) / 2))
            }
        }
        if let pub = info["publisher"] as? String, !pub.isEmpty {
            score += 5
        }
        if let ids = info["industryIdentifiers"] as? [[String: Any]], !ids.isEmpty {
            score += 5
        }
        return score
    }

    private func queryCrossRef(doi: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        let trimmedDOI = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmedDOI.addingPercentEncoding(withAllowedCharacters: Self.doiPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        let json = try await fetchJSON(from: url)
        guard let message = json["message"] as? [String: Any] else { return nil }

        var updated = base
        if let titles = message["title"] as? [String], let first = titles.first, !first.isEmpty {
            updated.title = first
        }
        if let authors = message["author"] as? [[String: Any]] {
            let names = authors.compactMap { a -> String? in
                let given = (a["given"] as? String) ?? ""
                let family = (a["family"] as? String) ?? ""
                let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                return full.isEmpty ? nil : full
            }
            if !names.isEmpty {
                updated.author = names.joined(separator: "; ")
            }
        }
        if let pub = message["publisher"] as? String, !pub.isEmpty {
            updated.publisher = pub
        }
        if let issued = message["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]],
           let y = parts.first?.first {
            updated.year = y
        }
        return updated
    }

    private func queryOpenLibrary(isbn: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        guard let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data") else {
            return nil
        }
        let json = try await fetchJSON(from: url)
        guard let record = json["ISBN:\(isbn)"] as? [String: Any] else { return nil }

        var updated = base
        if let t = record["title"] as? String, !t.isEmpty {
            if let sub = record["subtitle"] as? String, !sub.isEmpty {
                updated.title = "\(t): \(sub)"
            } else {
                updated.title = t
            }
        }
        if let authors = record["authors"] as? [[String: Any]] {
            let names = authors.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty {
                updated.author = names.joined(separator: "; ")
            }
        }
        if let pubs = record["publishers"] as? [[String: Any]], let firstPub = pubs.first?["name"] as? String, !firstPub.isEmpty {
            updated.publisher = firstPub
        }
        if let pubDate = record["publish_date"] as? String,
           let match = firstMatch(Self.yearRegex, in: pubDate, group: 1),
           let y = Int(match) {
            updated.year = y
        }
        return updated
    }

    private func searchOpenLibrary(title: String, author: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var queryItems = [
            URLQueryItem(name: "title", value: stripEditionSuffix(from: title)),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publish_year,publisher,isbn")
        ]
        if !author.isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: author))
        }
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            return nil
        }
        let json = try await fetchJSON(from: url, timeout: 6.0)
        guard let docs = json["docs"] as? [[String: Any]], let first = docs.first else { return nil }

        var updated = base
        if let t = first["title"] as? String, !t.isEmpty {
            updated.title = t
        }
        if let authors = first["author_name"] as? [String], !authors.isEmpty {
            updated.author = authors.prefix(3).joined(separator: "; ")
        }
        let editionHint = extractEditionHint(from: base.title)
        if editionHint != nil, let pubYears = first["publish_year"] as? [Int], let latest = pubYears.max() {
            updated.year = base.year ?? latest
        } else if let y = first["first_publish_year"] as? Int {
            updated.year = base.year ?? y
        }
        if let pubs = first["publisher"] as? [String], let firstPub = pubs.first, !firstPub.isEmpty {
            updated.publisher = firstPub
        }
        if updated.isbn.isEmpty, let isbns = first["isbn"] as? [String], let best = isbns.first(where: { $0.count == 13 }) ?? isbns.first {
            updated.isbn = best
        }
        return updated
    }

    private func firstMatch(_ regex: NSRegularExpression, in text: String, group: Int) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[r])
    }
}
