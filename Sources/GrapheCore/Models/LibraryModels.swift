#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import SwiftUI

public enum HighlightColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case yellow
    case blue
    case pink
    case green
    case purple

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yellow: return "Sarı"
        case .blue: return "Mavi"
        case .pink: return "Pembe"
        case .green: return "Yeşil"
        case .purple: return "Mor"
        }
    }

    public var meaningLabel: String {
        switch self {
        case .yellow: return "Ana Fikir"
        case .blue: return "Kavram / Tanım"
        case .pink: return "İtiraz / Soru"
        case .green: return "Alıntı / Referans"
        case .purple: return "Kendi Yorumum"
        }
    }

    public var fullLabel: String {
        "\(displayName) · \(meaningLabel)"
    }

    public var shortcutDigit: String {
        switch self {
        case .yellow: return "1"
        case .blue: return "2"
        case .pink: return "3"
        case .green: return "4"
        case .purple: return "5"
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .yellow: return Color(red: 0.96, green: 0.82, blue: 0.20)
        case .blue: return Color(red: 0.28, green: 0.62, blue: 0.96)
        case .pink: return Color(red: 0.94, green: 0.40, blue: 0.56)
        case .green: return Color(red: 0.34, green: 0.78, blue: 0.48)
        case .purple: return Color(red: 0.68, green: 0.45, blue: 0.92)
        }
    }

    #if canImport(AppKit)
    public var pdfNSColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.24, alpha: 0.36)
        case .blue: return NSColor(calibratedRed: 0.32, green: 0.66, blue: 0.98, alpha: 0.30)
        case .pink: return NSColor(calibratedRed: 0.96, green: 0.44, blue: 0.60, alpha: 0.30)
        case .green: return NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.50, alpha: 0.30)
        case .purple: return NSColor(calibratedRed: 0.70, green: 0.48, blue: 0.94, alpha: 0.30)
        }
    }
    #elseif canImport(UIKit)
    public var pdfUIColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 0.98, green: 0.86, blue: 0.24, alpha: 0.36)
        case .blue: return UIColor(red: 0.32, green: 0.66, blue: 0.98, alpha: 0.30)
        case .pink: return UIColor(red: 0.96, green: 0.44, blue: 0.60, alpha: 0.30)
        case .green: return UIColor(red: 0.36, green: 0.82, blue: 0.50, alpha: 0.30)
        case .purple: return UIColor(red: 0.70, green: 0.48, blue: 0.94, alpha: 0.30)
        }
    }
    #endif
}

public struct HighlightRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum AnnotationKind: String, Codable, Hashable, Sendable {
    case highlight
    case pageNote
}

public struct AnnotationItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let documentHash: String
    public let pageIndex: Int
    public let kind: AnnotationKind
    public var color: HighlightColor
    public var quote: String
    public var note: String
    public var rects: [HighlightRect]
    public var tags: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        documentHash: String,
        pageIndex: Int,
        kind: AnnotationKind,
        color: HighlightColor = .yellow,
        quote: String = "",
        note: String = "",
        rects: [HighlightRect] = [],
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentHash = documentHash
        self.pageIndex = pageIndex
        self.kind = kind
        self.color = color
        self.quote = quote
        self.note = note
        self.rects = rects
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SelectionCapture: Equatable, Sendable {
    public let pageIndex: Int
    public let text: String
    public let rects: [HighlightRect]

    public init(pageIndex: Int, text: String, rects: [HighlightRect]) {
        self.pageIndex = pageIndex
        self.text = text
        self.rects = rects
    }
}

public struct LibraryDocumentRecord: Identifiable, Codable, Hashable, Sendable {
    public let hash: String
    public var path: String
    public var title: String
    public var author: String?
    public var year: Int?
    public var publisher: String?
    public var isbn: String?
    public var doi: String?
    public var pageCount: Int
    public var tags: [String]
    public var isIndexed: Bool
    public var lastOpenedAt: Date
    public let addedAt: Date

    public var id: String { hash }
    public var url: URL { URL(fileURLWithPath: path) }

    public init(
        hash: String,
        path: String,
        title: String,
        author: String? = nil,
        year: Int? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        doi: String? = nil,
        pageCount: Int = 0,
        tags: [String] = [],
        isIndexed: Bool = false,
        lastOpenedAt: Date = Date(),
        addedAt: Date = Date()
    ) {
        self.hash = hash
        self.path = path
        self.title = title
        self.author = author
        self.year = year
        self.publisher = publisher
        self.isbn = isbn
        self.doi = doi
        self.pageCount = pageCount
        self.tags = tags
        self.isIndexed = isIndexed
        self.lastOpenedAt = lastOpenedAt
        self.addedAt = addedAt
    }
}

public enum GlobalSearchResultKind: String, Hashable, Sendable {
    case highlight
    case pageNote
    case notebookNote
    case documentText

    public var displayBadge: String {
        switch self {
        case .highlight: return "Vurgu"
        case .pageNote: return "Not"
        case .notebookNote: return "Defter"
        case .documentText: return "Metin"
        }
    }
}

public struct GlobalSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: GlobalSearchResultKind
    public let documentHash: String
    public let documentTitle: String
    public let documentPath: String
    public let pageIndex: Int
    public let snippet: String
    public let highlightColor: HighlightColor?
    public let notebookPageID: UUID?

    public init(
        id: String,
        kind: GlobalSearchResultKind,
        documentHash: String,
        documentTitle: String,
        documentPath: String,
        pageIndex: Int,
        snippet: String,
        highlightColor: HighlightColor? = nil,
        notebookPageID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.documentHash = documentHash
        self.documentTitle = documentTitle
        self.documentPath = documentPath
        self.pageIndex = pageIndex
        self.snippet = snippet
        self.highlightColor = highlightColor
        self.notebookPageID = notebookPageID
    }
}

public struct BookmarkItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let documentHash: String
    public let pageIndex: Int
    public var label: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        documentHash: String,
        pageIndex: Int,
        label: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentHash = documentHash
        self.pageIndex = pageIndex
        self.label = label
        self.createdAt = createdAt
    }
}
