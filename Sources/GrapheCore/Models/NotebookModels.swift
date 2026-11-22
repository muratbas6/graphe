import AppKit
import Foundation
import SwiftUI

public enum SectionColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue
    case green
    case yellow
    case pink
    case purple
    case orange

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blue: return "Mavi"
        case .green: return "Yeşil"
        case .yellow: return "Sarı"
        case .pink: return "Pembe"
        case .purple: return "Mor"
        case .orange: return "Turuncu"
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .blue: return Color(red: 0.24, green: 0.56, blue: 0.92)
        case .green: return Color(red: 0.28, green: 0.72, blue: 0.44)
        case .yellow: return Color(red: 0.92, green: 0.74, blue: 0.16)
        case .pink: return Color(red: 0.90, green: 0.36, blue: 0.54)
        case .purple: return Color(red: 0.58, green: 0.38, blue: 0.88)
        case .orange: return Color(red: 0.94, green: 0.54, blue: 0.22)
        }
    }
}

public enum PaperStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case plain
    case dotted
    case lined
    case grid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plain: return "Düz"
        case .dotted: return "Noktalı"
        case .lined: return "Çizgili"
        case .grid: return "Kareli"
        }
    }

    public var systemImage: String {
        switch self {
        case .plain: return "doc"
        case .dotted: return "circle.grid.3x3"
        case .lined: return "text.alignleft"
        case .grid: return "grid"
        }
    }
}

public enum NoteContainerKind: String, Codable, Hashable, Sendable {
    case richText
    case pdfQuote
    case image
}

public struct NotebookSection: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let documentHash: String
    public var title: String
    public var color: SectionColor
    public var sortOrder: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        documentHash: String,
        title: String,
        color: SectionColor = .purple,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentHash = documentHash
        self.title = title
        self.color = color
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct NotebookPage: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let sectionID: UUID
    public let documentHash: String
    public var title: String
    public var paperStyle: PaperStyle
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sectionID: UUID,
        documentHash: String,
        title: String,
        paperStyle: PaperStyle = .dotted,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sectionID = sectionID
        self.documentHash = documentHash
        self.title = title
        self.paperStyle = paperStyle
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NoteContainer: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let pageID: UUID
    public let documentHash: String
    public var kind: NoteContainerKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rtfData: Data?
    public var plainText: String
    public var quoteText: String?
    public var sourcePageIndex: Int?
    public var accentColor: HighlightColor?
    public var imagePath: String?
    public var zIndex: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        pageID: UUID,
        documentHash: String,
        kind: NoteContainerKind = .richText,
        x: Double = 24,
        y: Double = 24,
        width: Double = 300,
        height: Double = 140,
        rtfData: Data? = nil,
        plainText: String = "",
        quoteText: String? = nil,
        sourcePageIndex: Int? = nil,
        accentColor: HighlightColor? = nil,
        imagePath: String? = nil,
        zIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.pageID = pageID
        self.documentHash = documentHash
        self.kind = kind
        self.x = x
        self.y = y
        self.width = max(160, width)
        self.height = max(72, height)
        self.rtfData = rtfData
        self.plainText = plainText
        self.quoteText = quoteText
        self.sourcePageIndex = sourcePageIndex
        self.accentColor = accentColor
        self.imagePath = imagePath
        self.zIndex = zIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StandaloneNotebook: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var color: SectionColor
    public let createdAt: Date
    public var updatedAt: Date

    /// Virtual documentHash used across `notebook_sections`, `notebook_pages`, `notebook_containers`, and `notebook_fts`.
    public var storageHash: String {
        "notebook:\(id.uuidString)"
    }

    public init(
        id: UUID = UUID(),
        title: String,
        color: SectionColor = .blue,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
