import Foundation
import PDFKit

public enum PDFEngineError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case unreadableDocument(URL)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "PDF dosyası bulunamadı: \(url.lastPathComponent)"
        case .unreadableDocument(let url):
            return "PDF dosyası açılamadı veya geçersiz: \(url.lastPathComponent)"
        }
    }
}

public protocol PDFEngineProtocol: Sendable {
    func loadDocument(from url: URL) throws -> (PDFDocument, DocumentMetadata)
    func extractOutline(from document: PDFDocument) -> [OutlineItem]
}
