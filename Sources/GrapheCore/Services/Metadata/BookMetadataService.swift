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
        pattern: #"(?:©|copyright|\(c\)|published(?:\s+in)?|first\s+published|bask[ıi])\D{0,24}\b(1[5-9]\d{2}|20[0-2]\d)\b"#,
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

            if year == nil, let yStr = firstMatch(Self.copyrightYearRegex, in: frontMatter, group: 1),
               let yVal = Int(yStr) {
                year = yVal
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

    // MARK: - 3. Opt-In Online Enrichment (CrossRef / Google Books / OpenLibrary)

    public func enrichOnline(draft: BookMetadataDraft) async throws -> BookMetadataDraft {
        let result = draft
        var lastNetworkError: Error?

        // 1) DOI -> CrossRef (highest accuracy for academic articles & books)
        if !draft.doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let enriched = try await queryCrossRef(doi: draft.doi, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }
        }

        // 2) ISBN -> Google Books (fast) -> OpenLibrary (fallback)
        let cleanISBN = draft.isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if cleanISBN.count == 10 || cleanISBN.count == 13 {
            do {
                if let enriched = try await searchGoogleBooks(query: "isbn:\(cleanISBN)", mergingInto: result) {
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

        // 3) Title + Author -> Google Books (fast & reliable) -> CrossRef -> OpenLibrary
        let cleanTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAuthor = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryParts = [cleanTitle, cleanAuthor].filter { !$0.isEmpty }
        if !queryParts.isEmpty {
            let gbQuery: String
            if !cleanTitle.isEmpty && !cleanAuthor.isEmpty {
                gbQuery = "intitle:\(cleanTitle)+inauthor:\(cleanAuthor)"
            } else {
                gbQuery = queryParts.joined(separator: " ")
            }
            do {
                if let enriched = try await searchGoogleBooks(query: gbQuery, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }

            let joined = queryParts.joined(separator: " ")
            do {
                if let enriched = try await searchCrossRef(query: joined, mergingInto: result) {
                    return enriched
                }
            } catch {
                lastNetworkError = error
            }

            do {
                if let enriched = try await searchOpenLibrary(query: joined, mergingInto: result) {
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

    private func fetchJSON(from url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 12.0)
        req.setValue("Graphe/1.1 (macOS Academic PDF Reader)", forHTTPHeaderField: "User-Agent")
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

    private func searchGoogleBooks(query: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "printType", value: "books")
        ]
        guard let url = components?.url else { return nil }
        let json = try await fetchJSON(from: url)
        guard let items = json["items"] as? [[String: Any]],
              let volumeInfo = items.first?["volumeInfo"] as? [String: Any] else {
            return nil
        }

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
            updated.year = y
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

    private func searchCrossRef(query: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "rows", value: "1")
        ]
        guard let url = components?.url else { return nil }
        let json = try await fetchJSON(from: url)
        guard let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]],
              let first = items.first else {
            return nil
        }

        var updated = base
        if let titles = first["title"] as? [String], let t = titles.first, !t.isEmpty {
            updated.title = t
        }
        if let authors = first["author"] as? [[String: Any]] {
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
        if let pub = first["publisher"] as? String, !pub.isEmpty {
            updated.publisher = pub
        }
        if let issued = first["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]],
           let y = parts.first?.first {
            updated.year = y
        }
        if updated.doi.isEmpty, let foundDOI = first["DOI"] as? String, !foundDOI.isEmpty {
            updated.doi = foundDOI
        }
        if updated.isbn.isEmpty, let isbns = first["ISBN"] as? [String], let firstISBN = isbns.first, !firstISBN.isEmpty {
            updated.isbn = firstISBN
        }
        return updated
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

    private func searchOpenLibrary(query: String, mergingInto base: BookMetadataDraft) async throws -> BookMetadataDraft? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publisher,isbn")
        ]
        guard let url = components?.url else {
            return nil
        }
        let json = try await fetchJSON(from: url)
        guard let docs = json["docs"] as? [[String: Any]], let first = docs.first else { return nil }

        var updated = base
        if let t = first["title"] as? String, !t.isEmpty {
            updated.title = t
        }
        if let authors = first["author_name"] as? [String], !authors.isEmpty {
            updated.author = authors.prefix(3).joined(separator: "; ")
        }
        if let y = first["first_publish_year"] as? Int {
            updated.year = y
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
