import Foundation
import PDFKit

public struct PDFKitEngine: PDFEngineProtocol {
    public init() {}

    public func loadDocument(from url: URL) throws -> (PDFDocument, DocumentMetadata) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFEngineError.fileNotFound(url)
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFEngineError.unreadableDocument(url)
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw PDFEngineError.unreadableDocument(url)
        }

        let rawTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : url.deletingPathExtension().lastPathComponent
        let author = (document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outline = extractOutline(from: document)

        let metadata = DocumentMetadata(
            url: url,
            title: title,
            author: (author?.isEmpty == false) ? author : nil,
            pageCount: document.pageCount,
            outline: outline
        )
        return (document, metadata)
    }

    public func extractOutline(from document: PDFDocument) -> [OutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        return collectChildren(of: root, in: document)
    }

    private func collectChildren(of outline: PDFOutline, in document: PDFDocument) -> [OutlineItem] {
        var items: [OutlineItem] = []
        for idx in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: idx) else { continue }
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Bölüm \(idx + 1)"
            let subItems = collectChildren(of: child, in: document)

            let resolvedPageIndex: Int?
            if let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page {
                let resolvedIndex = document.index(for: page)
                if resolvedIndex != NSNotFound && resolvedIndex >= 0 && resolvedIndex < document.pageCount {
                    resolvedPageIndex = resolvedIndex
                } else {
                    resolvedPageIndex = nil
                }
            } else {
                resolvedPageIndex = nil
            }

            // Inherit first child's page for destination-less group headers instead of jumping to page 0
            if let pageIndex = resolvedPageIndex ?? subItems.first?.pageIndex {
                items.append(OutlineItem(title: label, pageIndex: max(0, pageIndex), children: subItems))
            }
        }
        return items
    }
}
