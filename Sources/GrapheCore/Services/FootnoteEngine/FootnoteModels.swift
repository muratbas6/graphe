import CoreGraphics
import Foundation

public enum FootnoteOrigin: String, Sendable {
    case pdfLink
    case pageBottomHeuristic
    case endnoteHeuristic

    public var badgeTitle: String {
        switch self {
        case .pdfLink: return "Bağlantı"
        case .pageBottomHeuristic: return "Sayfa Dipnotu"
        case .endnoteHeuristic: return "Sonnot"
        }
    }
}

public struct FootnotePreview: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let marker: String
    public let sourcePageIndex: Int
    public let targetPageIndex: Int
    public let targetRect: CGRect?
    public let extractedText: String
    public let snapshotImage: PlatformImage?
    public let origin: FootnoteOrigin
    public let documentTitle: String
    public let documentHash: String?

    public init(
        id: UUID = UUID(),
        marker: String,
        sourcePageIndex: Int,
        targetPageIndex: Int,
        targetRect: CGRect?,
        extractedText: String,
        snapshotImage: PlatformImage?,
        origin: FootnoteOrigin,
        documentTitle: String,
        documentHash: String? = nil
    ) {
        self.id = id
        self.marker = marker
        self.sourcePageIndex = sourcePageIndex
        self.targetPageIndex = targetPageIndex
        self.targetRect = targetRect
        self.extractedText = extractedText
        self.snapshotImage = snapshotImage
        self.origin = origin
        self.documentTitle = documentTitle
        self.documentHash = documentHash
    }

    public var prefersSnapshotByDefault: Bool {
        extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshotImage != nil
    }
}

public struct PageFootnoteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let marker: String
    public let text: String
    public let pageIndex: Int

    public init(id: String, marker: String, text: String, pageIndex: Int) {
        self.id = id
        self.marker = marker
        self.text = text
        self.pageIndex = pageIndex
    }
}
