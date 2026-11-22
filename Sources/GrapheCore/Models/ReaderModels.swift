import Foundation
import PDFKit

public struct OutlineItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let pageIndex: Int
    public let children: [OutlineItem]

    public init(id: UUID = UUID(), title: String, pageIndex: Int, children: [OutlineItem] = []) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

public struct DocumentMetadata: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let author: String?
    public let pageCount: Int
    public let outline: [OutlineItem]

    public init(url: URL, title: String, author: String?, pageCount: Int, outline: [OutlineItem]) {
        self.url = url
        self.title = title
        self.author = author
        self.pageCount = pageCount
        self.outline = outline
    }
}

public struct ReadingPosition: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let scaleFactor: Double
    public let lastOpenedAt: Date

    public init(pageIndex: Int, scaleFactor: Double, lastOpenedAt: Date = Date()) {
        self.pageIndex = pageIndex
        self.scaleFactor = scaleFactor
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct RecentFileItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let lastOpenedAt: Date

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, title: String, lastOpenedAt: Date = Date()) {
        self.path = path
        self.title = title
        self.lastOpenedAt = lastOpenedAt
    }
}

public enum PaneSide: String, Sendable, Equatable {
    case primary
    case secondary
}

public struct SavedTabSession: Codable, Equatable, Sendable {
    public let primaryPath: String
    public let secondaryPath: String?
    public let primaryPageIndex: Int
    public let secondaryPageIndex: Int?
    public let syncScrollEnabled: Bool

    public init(
        primaryPath: String,
        secondaryPath: String?,
        primaryPageIndex: Int,
        secondaryPageIndex: Int?,
        syncScrollEnabled: Bool
    ) {
        self.primaryPath = primaryPath
        self.secondaryPath = secondaryPath
        self.primaryPageIndex = primaryPageIndex
        self.secondaryPageIndex = secondaryPageIndex
        self.syncScrollEnabled = syncScrollEnabled
    }
}

public struct SavedWorkspaceSession: Codable, Equatable, Sendable {
    public let tabs: [SavedTabSession]
    public let activeTabIndex: Int
    public let showLeftSidebar: Bool
    public let showRightInspector: Bool

    public init(
        tabs: [SavedTabSession],
        activeTabIndex: Int,
        showLeftSidebar: Bool,
        showRightInspector: Bool
    ) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.showLeftSidebar = showLeftSidebar
        self.showRightInspector = showRightInspector
    }
}

public struct SearchHighlightState: Equatable {
    public let requestID: UUID
    public let allMatches: [PDFSelection]
    public let activeMatch: PDFSelection?

    public init(requestID: UUID = UUID(), allMatches: [PDFSelection], activeMatch: PDFSelection?) {
        self.requestID = requestID
        self.allMatches = allMatches
        self.activeMatch = activeMatch
    }

    public static func == (lhs: SearchHighlightState, rhs: SearchHighlightState) -> Bool {
        lhs.requestID == rhs.requestID
    }
}

public struct ReaderPaneState: Identifiable {
    public let id: UUID
    public var url: URL
    public let documentHash: String
    public var metadata: DocumentMetadata
    public let document: PDFDocument
    public var currentPageIndex: Int
    public var scaleFactor: Double
    public var shouldAutoFitWidth: Bool
    public var targetPageRequest: PageJumpRequest?
    public var zoomRequest: ZoomRequest?
    public var searchHighlight: SearchHighlightState?
    public var backHistory: [Int] = []
    public var forwardHistory: [Int] = []

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    public init(
        id: UUID = UUID(),
        url: URL,
        documentHash: String = "",
        metadata: DocumentMetadata,
        document: PDFDocument,
        currentPageIndex: Int = 0,
        scaleFactor: Double = 1.0,
        shouldAutoFitWidth: Bool = false
    ) {
        self.id = id
        self.url = url
        self.documentHash = documentHash
        self.metadata = metadata
        self.document = document
        self.currentPageIndex = max(0, min(currentPageIndex, max(0, metadata.pageCount - 1)))
        self.scaleFactor = scaleFactor
        self.shouldAutoFitWidth = shouldAutoFitWidth
    }
}

public struct PageJumpRequest: Equatable, Sendable {
    public let id: UUID
    public let pageIndex: Int

    public init(id: UUID = UUID(), pageIndex: Int) {
        self.id = id
        self.pageIndex = pageIndex
    }
}

public enum ZoomAction: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case fitWidth
    case actualSize
}

public struct ZoomRequest: Equatable, Sendable {
    public let id: UUID
    public let action: ZoomAction

    public init(id: UUID = UUID(), action: ZoomAction) {
        self.id = id
        self.action = action
    }
}

public struct TabSession: Identifiable {
    public let id: UUID
    public var primaryPane: ReaderPaneState
    public var secondaryPane: ReaderPaneState?
    public var syncScrollEnabled: Bool
    public var activeSide: PaneSide

    public init(
        id: UUID = UUID(),
        primaryPane: ReaderPaneState,
        secondaryPane: ReaderPaneState? = nil,
        syncScrollEnabled: Bool = false,
        activeSide: PaneSide = .primary
    ) {
        self.id = id
        self.primaryPane = primaryPane
        self.secondaryPane = secondaryPane
        self.syncScrollEnabled = syncScrollEnabled
        self.activeSide = activeSide
    }

    public var isSplit: Bool { secondaryPane != nil }

    public var displayTitle: String {
        if let secondary = secondaryPane {
            if secondary.url == primaryPane.url {
                return "\(primaryPane.metadata.title) (Bölünmüş)"
            }
            return "\(primaryPane.metadata.title) | \(secondary.metadata.title)"
        }
        return primaryPane.metadata.title
    }

    public var activePane: ReaderPaneState {
        if activeSide == .secondary, let secondary = secondaryPane {
            return secondary
        }
        return primaryPane
    }
}
