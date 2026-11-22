import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(
        document: LibraryDocumentRecord,
        annotations: [AnnotationItem],
        exportDate: Date = Date()
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate]
        let dateString = isoFormatter.string(from: exportDate)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"\(escapeYAML(document.title))\"")
        if let author = document.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("author: \"\(escapeYAML(author))\"")
        }
        let allTags = Array(Set(document.tags + annotations.flatMap(\.tags))).sorted()
        if !allTags.isEmpty {
            lines.append("tags:")
            for tag in allTags {
                lines.append("  - \(tag)")
            }
        }
        lines.append("exported: \(dateString)")
        lines.append("source: \"\(escapeYAML(document.path))\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(document.title)")
        lines.append("")

        if annotations.isEmpty {
            lines.append("_Bu belge için henüz vurgu veya not eklenmemiş._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let sorted = annotations.sorted {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            return $0.createdAt < $1.createdAt
        }

        let groupedByPage = Dictionary(grouping: sorted, by: \.pageIndex)
        let sortedPages = groupedByPage.keys.sorted()

        for pageIndex in sortedPages {
            guard let pageItems = groupedByPage[pageIndex] else { continue }
            lines.append("## Sayfa \(pageIndex + 1)")
            lines.append("")

            for item in pageItems {
                if item.kind == .highlight {
                    lines.append("### [\(item.color.meaningLabel)]")
                    if !item.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let quotedLines = item.quote
                            .components(separatedBy: "\n")
                            .map { "> \($0)" }
                            .joined(separator: "\n")
                        lines.append(quotedLines)
                    }
                    if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("")
                        lines.append("**Not:** \(item.note)")
                    }
                } else {
                    lines.append("### Sayfa Notu")
                    if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(item.note)
                    }
                }

                if !item.tags.isEmpty {
                    let tagLine = item.tags.map { "#\($0)" }.joined(separator: " ")
                    lines.append("")
                    lines.append("_\(tagLine)_")
                }

                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    public func exportNotebook(
        document: LibraryDocumentRecord,
        sections: [NotebookSection],
        pagesBySection: [UUID: [NotebookPage]],
        containersByPage: [UUID: [NoteContainer]],
        exportDate: Date = Date()
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate]
        let dateString = isoFormatter.string(from: exportDate)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"\(escapeYAML(document.title)) — Defter\"")
        if let author = document.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("author: \"\(escapeYAML(author))\"")
        }
        if !document.tags.isEmpty {
            lines.append("tags:")
            for tag in document.tags.sorted() {
                lines.append("  - \(tag)")
            }
        }
        lines.append("exported: \(dateString)")
        lines.append("source: \"\(escapeYAML(document.path))\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(document.title) — Defter")
        lines.append("")

        for section in sections {
            lines.append("## \(section.title)")
            lines.append("")
            let pages = pagesBySection[section.id] ?? []
            for page in pages {
                lines.append("### \(page.title)")
                lines.append("")
                let containers = (containersByPage[page.id] ?? []).sorted {
                    if abs($0.y - $1.y) > 24 { return $0.y < $1.y }
                    return $0.x < $1.x
                }
                for c in containers {
                    switch c.kind {
                    case .pdfQuote:
                        if let pageIdx = c.sourcePageIndex {
                            let label = c.accentColor?.meaningLabel ?? "Alıntı"
                            lines.append("**[\(label) · s. \(pageIdx + 1)]**")
                        }
                        if let quote = c.quoteText, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let q = quote.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                            lines.append(q)
                            lines.append("")
                        }
                        if !c.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.append(c.plainText)
                            lines.append("")
                        }
                    case .richText:
                        let text = c.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            lines.append(text)
                            lines.append("")
                        }
                    case .image:
                        if let path = c.imagePath {
                            let formattedPath = (path.contains(" ") || path.contains("(") || path.contains(")"))
                                ? "<\(path)>"
                                : path
                            lines.append("![Not Görseli](\(formattedPath))")
                            lines.append("")
                        }
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func escapeYAML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
