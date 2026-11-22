import Foundation

public enum CitationStyle: String, CaseIterable, Identifiable, Sendable {
    case chicago = "Chicago"
    case apa7 = "APA 7"
    case mla = "MLA"
    case bibtex = "BibTeX"

    public var id: String { rawValue }
}

public struct CitationFormatter: Sendable {
    public init() {}

    public func format(
        document: LibraryDocumentRecord,
        pageNumber: Int? = nil,
        quote: String? = nil,
        style: CitationStyle = .chicago
    ) -> String {
        let author = document.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let publisher = document.publisher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let yearStr = document.year.map(String.init) ?? ""

        let reference: String
        switch style {
        case .chicago:
            reference = formatChicago(author: author, title: title, publisher: publisher, year: yearStr, page: pageNumber)
        case .apa7:
            reference = formatAPA7(author: author, title: title, publisher: publisher, year: yearStr, page: pageNumber)
        case .mla:
            reference = formatMLA(author: author, title: title, publisher: publisher, year: yearStr, page: pageNumber)
        case .bibtex:
            return formatBibTeX(document: document)
        }

        if let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            return "“\(quote)” — \(reference)"
        }
        return reference
    }

    private func formatChicago(author: String, title: String, publisher: String, year: String, page: Int?) -> String {
        var parts: [String] = []
        if !author.isEmpty { parts.append("\(author),") }
        parts.append(title)

        let pubInfo = [publisher, year].filter { !$0.isEmpty }.joined(separator: ", ")
        if !pubInfo.isEmpty {
            parts.append("(\(pubInfo))")
        }

        var result = parts.joined(separator: " ")
        if let page, page > 0 {
            result += ", \(page)."
        } else {
            result += "."
        }
        return result
    }

    private func formatAPA7(author: String, title: String, publisher: String, year: String, page: Int?) -> String {
        var segments: [String] = []
        if !author.isEmpty {
            segments.append(formatAPAAuthors(author))
        }
        if !year.isEmpty {
            segments.append("(\(year)).")
        } else if !segments.isEmpty {
            segments.append("(n.d.).")
        }
        segments.append("\(title).")
        if !publisher.isEmpty {
            segments.append("\(publisher).")
        }
        if let page, page > 0 {
            segments.append("p. \(page).")
        }
        return segments.joined(separator: " ")
    }

    private func formatMLA(author: String, title: String, publisher: String, year: String, page: Int?) -> String {
        var segments: [String] = []
        if !author.isEmpty {
            let formattedAuthors = formatMLAAuthors(author)
            segments.append(formattedAuthors.hasSuffix(".") ? formattedAuthors : "\(formattedAuthors).")
        }
        segments.append("\(title).")
        let pubYear = [publisher, year].filter { !$0.isEmpty }.joined(separator: ", ")
        if !pubYear.isEmpty {
            segments.append("\(pubYear).")
        }
        if let page, page > 0 {
            segments.append("p. \(page).")
        }
        return segments.joined(separator: " ")
    }

    private func formatBibTeX(document: LibraryDocumentRecord) -> String {
        let author = document.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let surname = asciiSlug(extractPrimarySurname(from: author))
        let year = document.year.map(String.init) ?? "nd"
        let firstTitleWord = document.title
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map { asciiSlug(String($0)) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "book"
        let citeKey = "\(surname.isEmpty ? "ref" : surname)\(year)\(firstTitleWord)"

        var lines: [String] = ["@book{\(citeKey),"]
        if !author.isEmpty {
            let bibAuthors = splitAuthors(author)
                .map { escapeBibTeX($0) }
                .joined(separator: " and ")
            lines.append("  author = {\(bibAuthors)},")
        }
        lines.append("  title = {\(escapeBibTeX(document.title))},")
        if let yearVal = document.year {
            lines.append("  year = {\(yearVal)},")
        }
        if let pub = document.publisher, !pub.isEmpty {
            lines.append("  publisher = {\(escapeBibTeX(pub))},")
        }
        if let isbn = document.isbn, !isbn.isEmpty {
            lines.append("  isbn = {\(escapeBibTeX(isbn))},")
        }
        if let doi = document.doi, !doi.isEmpty {
            lines.append("  doi = {\(escapeBibTeX(doi))},")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func splitAuthors(_ raw: String) -> [String] {
        raw.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func formatAPAAuthors(_ raw: String) -> String {
        let authors = splitAuthors(raw).map { formatSingleAuthorLastFirst($0) }
        switch authors.count {
        case 0: return ""
        case 1: return authors[0]
        case 2: return "\(authors[0]), & \(authors[1])"
        default:
            let head = authors.dropLast().joined(separator: ", ")
            return "\(head), & \(authors.last!)"
        }
    }

    private func formatMLAAuthors(_ raw: String) -> String {
        let authors = splitAuthors(raw)
        switch authors.count {
        case 0: return ""
        case 1: return formatSingleAuthorLastFirst(authors[0])
        case 2: return "\(formatSingleAuthorLastFirst(authors[0])), and \(authors[1])"
        default: return "\(formatSingleAuthorLastFirst(authors[0])), et al."
        }
    }

    private func formatSingleAuthorLastFirst(_ author: String) -> String {
        if author.contains(",") { return author }
        let words = author.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2, let last = words.last else { return author }
        let given = words.dropLast().joined(separator: " ")
        return "\(last), \(given)"
    }

    private func extractPrimarySurname(from raw: String) -> String {
        let firstAuthor = splitAuthors(raw).first ?? raw
        if let comma = firstAuthor.firstIndex(of: ",") {
            return String(firstAuthor[..<comma])
        }
        return firstAuthor.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? firstAuthor
    }

    private func asciiSlug(_ raw: String) -> String {
        let folded = raw
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "I")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return folded.filter { $0.isASCII && $0.isLetter }
    }

    private func escapeBibTeX(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
