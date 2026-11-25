#if os(macOS)
import Foundation
import Observation
import PDFKit

public struct OCRProgressState: Equatable, Sendable {
    public let documentHash: String
    public let documentTitle: String
    public let completedPages: Int
    public let totalPages: Int

    public var fraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(1.0, Double(completedPages) / Double(totalPages))
    }

    public init(documentHash: String, documentTitle: String, completedPages: Int, totalPages: Int) {
        self.documentHash = documentHash
        self.documentTitle = documentTitle
        self.completedPages = completedPages
        self.totalPages = totalPages
    }
}

public struct SyncScrollSignal: Equatable, Sendable {
    public let id: UUID
    public let sourceSide: PaneSide
    public let normalizedY: Double

    public init(id: UUID = UUID(), sourceSide: PaneSide, normalizedY: Double) {
        self.id = id
        self.sourceSide = sourceSide
        self.normalizedY = max(0.0, min(1.0, normalizedY))
    }
}

public enum LeftPanelTab: String, CaseIterable, Identifiable, Sendable {
    case library = "Kütüphane"
    case notebooks = "Defterler"
    case outline = "İçindekiler"

    public var id: String { rawValue }
}

public enum LibraryViewMode: String, CaseIterable, Identifiable, Sendable {
    case folders = "Klasörler"
    case all = "Tümü"

    public var id: String { rawValue }
}

public enum RightPanelTab: String, CaseIterable, Identifiable, Sendable {
    case dictionary = "Sözlük"
    case notes = "Notlar"
    case footnotes = "Dipnot"

    public var id: String { rawValue }
}

public enum NotesSubTab: String, CaseIterable, Identifiable, Sendable {
    case notebook = "Defter"
    case highlights = "Vurgular"

    public var id: String { rawValue }
}

@Observable
@MainActor
public final class WorkspaceState {
    public var tabs: [TabSession] = []
    public var activeTabID: UUID?
    public var recentFiles: [RecentFileItem] = []
    public var theme: ReadingTheme
    public var selectedText: String = ""
    public var multiDictionaryResult: MultiDictionaryLookupResult?
    public var targetLanguage: TargetLanguage = .turkish
    public var translatedText: String = ""
    public var translationError: String?
    public var isTranslating: Bool = false
    public var vocabulary: [VocabularyItem] = []
    public let dictionaryManager: DictionaryManager
    public var currentPageFootnotes: [PageFootnoteItem] = []
    public var pinnedFootnotes: [FootnotePreview] = []
    public var libraryDocuments: [LibraryDocumentRecord] = []
    public var allTags: [String] = []
    public var selectedTagFilter: String? = nil
    public var globalSearchQuery: String = ""
    public var globalSearchResults: [GlobalSearchResult] = []
    public var activeSelection: SelectionCapture?
    public var annotationsByDocument: [String: [AnnotationItem]] = [:]
    public var indexingDocumentHashes: Set<String> = []
    private var autoEnrichedMetadataHashes: Set<String> = []
    public var autoCroppedDocumentIDs: Set<ObjectIdentifier> = []
    public var layoutRefreshToken: UUID = UUID()
    public var ocrProgress: OCRProgressState? = nil
    public var currentPageOCRResult: OCRPageResult? = nil
    public var activeDocumentOCRCount: Int = 0
    public var showOCRTextSheet: Bool = false
    public var notesSubTab: NotesSubTab = .notebook
    public var notebookSections: [NotebookSection] = []
    public var activeNotebookSectionID: UUID?
    public var notebookPages: [NotebookPage] = []
    public var activeNotebookPageID: UUID?
    public var activePageContainers: [NoteContainer] = []
    public var activeDocumentBookmarks: [BookmarkItem] = []
    public var isTwoUpBookMode: Bool = false
    public var editingMetadataDocument: LibraryDocumentRecord? = nil
    public var movingPDFRequest: MovePDFRequest? = nil
    public var leftPanelTab: LeftPanelTab = .library
    public var libraryViewMode: LibraryViewMode = .folders
    public var watchedFolders: [WatchedRootFolder] = []
    public var folderTrees: [FileTreeNode] = []
    public var rightPanelTab: RightPanelTab = .dictionary
    public var showLeftSidebar: Bool = true
    public var showRightInspector: Bool = true
    public var isSearchVisible: Bool = false
    public var searchQuery: String = ""
    public var searchMatches: [PDFSelection] = []
    public var currentMatchIndex: Int = 0
    public var syncScrollSignal: SyncScrollSignal?
    public var errorMessage: String?

    private let engine: PDFEngineProtocol
    private let store: ReadingPositionStoring
    private let vocabularyStore: VocabularyStoring
    public private(set) var libraryDatabase: LibraryDatabase
    public let folderExplorer: FolderExplorerService
    public let cloudSyncService = CloudSyncService()
    private var autoCloudSyncTask: Task<Void, Never>?
    public let footnoteResolver = FootnoteResolver()
    public let ocrService = VisionOCRService()
    public let autoCropService = AutoCropService()
    public let metadataService = BookMetadataService()
    public let citationFormatter = CitationFormatter()
    public let backupService = BackupService()
    private let markdownExporter = MarkdownExporter()
    public let latexExporter = LatexPDFExporter()
    public let spotify = SpotifyController()
    public var isExportingLatexPDF: Bool = false
    public var isSnapshotMode: Bool = false
    public var showCommandPalette: Bool = false
    public var isReadingRulerEnabled: Bool = false
    public var highlightedContainerID: UUID?
    public var standaloneNotebooks: [StandaloneNotebook] = []
    public var openStandaloneNotebookIDs: [UUID] = []
    public var activeStandaloneNotebookID: UUID?
    public var notebookFontFamily: String = NotebookFontCatalog.systemKey
    private let notebookFontDefaultsKey = "graphe.notebook.fontFamily.v1"
    private var highlightPulseTask: Task<Void, Never>?
    private var activeOCRTask: Task<Void, Never>?
    private var activeOCRRunID: UUID?
    private var inDocSearchTask: Task<Void, Never>?
    private var globalSearchTask: Task<Void, Never>?
    private var persistSessionTask: Task<Void, Never>?
    private var footnoteRefreshTask: Task<Void, Never>?
    private var lastLoadedDocumentMetaHash: String?
    private let backgroundDocPrepQueue = DispatchQueue(label: "com.graphe.docprep", qos: .utility)
    private var documentHashesByTag: [String: Set<String>] = [:]
    private var folderRefreshGeneration: Int = 0
    private var undoStack: [UndoableAction] = []
    private var redoStack: [UndoableAction] = []
    private let maxUndoDepth: Int = 50

    private enum UndoableAction {
        case createdHighlight(annotation: AnnotationItem, linkedContainer: NoteContainer?, pageTitle: String)
        case deletedAnnotation(annotation: AnnotationItem)
        case createdContainer(container: NoteContainer, pageTitle: String)
        case deletedContainer(container: NoteContainer, pageTitle: String)
        case movedOrResizedContainer(
            before: NoteContainer,
            after: NoteContainer,
            displaced: [(before: NoteContainer, after: NoteContainer)],
            pageTitle: String
        )
    }

    public init(
        engine: PDFEngineProtocol = PDFKitEngine(),
        store: ReadingPositionStoring = UserDefaultsPositionStore(),
        dictionaryManager: DictionaryManager? = nil,
        vocabularyStore: VocabularyStoring = UserDefaultsVocabularyStore(),
        libraryDatabase: LibraryDatabase? = nil,
        folderExplorer: FolderExplorerService = FolderExplorerService(),
        restoreSession: Bool = true
    ) {
        self.engine = engine
        self.store = store
        self.dictionaryManager = dictionaryManager ?? DictionaryManager()
        self.vocabularyStore = vocabularyStore
        self.folderExplorer = folderExplorer
        if let providedDB = libraryDatabase {
            self.libraryDatabase = providedDB
        } else {
            self.libraryDatabase = (try? LibraryDatabase()) ?? (try! LibraryDatabase(path: ":memory:"))
        }
        self.theme = store.loadTheme()
        self.recentFiles = store.loadRecentFiles()
        self.vocabulary = vocabularyStore.loadItems()
        self.libraryDocuments = self.libraryDatabase.fetchAllDocuments()
        self.standaloneNotebooks = self.libraryDatabase.fetchAllStandaloneNotebooks()
        if let savedFont = UserDefaults.standard.string(forKey: notebookFontDefaultsKey), !savedFont.isEmpty {
            self.notebookFontFamily = savedFont
        }
        self.refreshTagIndex()
        self.watchedFolders = self.folderExplorer.loadWatchedFolders()
        if !self.watchedFolders.isEmpty {
            self.refreshFolderTrees()
        }
        if restoreSession {
            restoreSavedSession()
        }
        refreshCurrentPageFootnotes()
        if !ProcessInfo.processInfo.processName.contains("GrapheSelfTest") && !self.watchedFolders.isEmpty {
            syncWatchedFoldersWithCloud(showToast: false)
        }
    }

    public var activeTab: TabSession? {
        guard let id = activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == id }) ?? tabs.first
    }

    public var activeTabIndex: Int? {
        guard let id = activeTabID else { return tabs.isEmpty ? nil : 0 }
        return tabs.firstIndex(where: { $0.id == id })
    }

    public var activeStandaloneNotebook: StandaloneNotebook? {
        guard let id = activeStandaloneNotebookID else { return nil }
        return standaloneNotebooks.first(where: { $0.id == id })
    }

    public var openStandaloneNotebooks: [StandaloneNotebook] {
        openStandaloneNotebookIDs.compactMap { id in
            standaloneNotebooks.first(where: { $0.id == id })
        }
    }

    public var activeNotebookOwnerHash: String? {
        if let nb = activeStandaloneNotebook {
            return nb.storageHash
        }
        return activeTab?.activePane.documentHash
    }

    public var activeNotebookOwnerTitle: String? {
        if let nb = activeStandaloneNotebook {
            return nb.title
        }
        return activeTab?.activePane.metadata.title
    }

    public func setTheme(_ newTheme: ReadingTheme) {
        theme = newTheme
        store.saveTheme(newTheme)
    }

    public func setNotebookFontFamily(_ family: String) {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? NotebookFontCatalog.systemKey : trimmed
        notebookFontFamily = resolved
        UserDefaults.standard.set(resolved, forKey: notebookFontDefaultsKey)
    }

    public func toggleLeftSidebar() {
        showLeftSidebar.toggle()
        persistSession()
    }

    public func toggleRightInspector() {
        showRightInspector.toggle()
        persistSession()
    }

    public func toggleFocusMode() {
        if showLeftSidebar || showRightInspector {
            showLeftSidebar = false
            showRightInspector = false
        } else {
            showLeftSidebar = true
            showRightInspector = true
        }
        persistSession()
    }

    public func selectTab(id: UUID) {
        activeSelection = nil
        activeStandaloneNotebookID = nil
        activeTabID = id
        persistSession()
        refreshCurrentPageFootnotes()
        if isSearchVisible, !searchQuery.isEmpty {
            performSearch(searchQuery)
        }
    }

    public func openDocument(at url: URL, inNewTab: Bool = true) {
        let standardized = url.standardizedFileURL

        if !inNewTab, let existing = tabs.first(where: { $0.primaryPane.url == standardized && !$0.isSplit }) {
            selectTab(id: existing.id)
            return
        }

        do {
            let pane = try makePane(for: standardized)
            let tab = TabSession(primaryPane: pane)
            activeSelection = nil
            activeStandaloneNotebookID = nil
            tabs.append(tab)
            activeTabID = tab.id
            recordRecent(url: standardized, title: pane.metadata.title)
            persistSession()
            refreshCurrentPageFootnotes()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func openInSecondarySplit(url: URL) {
        guard let idx = activeTabIndex else {
            openDocument(at: url, inNewTab: true)
            return
        }

        let standardized = url.standardizedFileURL
        do {
            let pane = try makePane(for: standardized)
            activeSelection = nil
            tabs[idx].secondaryPane = pane
            tabs[idx].activeSide = .secondary
            recordRecent(url: standardized, title: pane.metadata.title)
            persistSession()
            refreshCurrentPageFootnotes()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func splitCurrentDocumentSelf() {
        guard let idx = activeTabIndex else { return }
        let primary = tabs[idx].primaryPane
        // Reuse the same PDFDocument instance for zero extra memory overhead
        let secondary = ReaderPaneState(
            url: primary.url,
            documentHash: primary.documentHash,
            metadata: primary.metadata,
            document: primary.document,
            currentPageIndex: primary.currentPageIndex,
            scaleFactor: primary.scaleFactor,
            shouldAutoFitWidth: primary.shouldAutoFitWidth
        )
        activeSelection = nil
        tabs[idx].secondaryPane = secondary
        tabs[idx].activeSide = .secondary
        persistSession()
        refreshCurrentPageFootnotes()
    }

    public func closeSecondarySplit() {
        guard let idx = activeTabIndex else { return }
        activeSelection = nil
        tabs[idx].secondaryPane = nil
        tabs[idx].syncScrollEnabled = false
        tabs[idx].activeSide = .primary
        persistSession()
        refreshCurrentPageFootnotes()
    }

    public func toggleSyncScroll() {
        guard let idx = activeTabIndex, tabs[idx].isSplit else { return }
        tabs[idx].syncScrollEnabled.toggle()
        persistSession()
    }

    public func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        activeSelection = nil
        let removedTab = tabs.remove(at: idx)
        if activeTabID == id {
            if tabs.isEmpty {
                activeTabID = nil
                closeSearch()
            } else {
                let nextIdx = min(idx, tabs.count - 1)
                activeTabID = tabs[nextIdx].id
            }
        }
        evictUnusedDocumentCaches(from: removedTab)
        persistSession()
        refreshCurrentPageFootnotes()
    }

    private func evictUnusedDocumentCaches(from removedTab: TabSession) {
        var remainingDocs = Set<ObjectIdentifier>()
        for tab in tabs {
            remainingDocs.insert(ObjectIdentifier(tab.primaryPane.document))
            if let sec = tab.secondaryPane {
                remainingDocs.insert(ObjectIdentifier(sec.document))
            }
        }
        let candidates = [removedTab.primaryPane.document, removedTab.secondaryPane?.document].compactMap { $0 }
        for doc in candidates where !remainingDocs.contains(ObjectIdentifier(doc)) {
            footnoteResolver.evictCache(for: doc)
            autoCropService.evictCache(for: doc)
            autoCroppedDocumentIDs.remove(ObjectIdentifier(doc))
        }
    }

    public func setActiveSide(_ side: PaneSide) {
        guard let idx = activeTabIndex else { return }
        if side == .secondary && !tabs[idx].isSplit { return }
        if tabs[idx].activeSide != side {
            activeSelection = nil
        }
        tabs[idx].activeSide = side
        refreshCurrentPageFootnotes()
    }

    public func updatePosition(side: PaneSide, pageIndex: Int, scaleFactor: Double) {
        guard let idx = activeTabIndex else { return }
        switch side {
        case .primary:
            let pageChanged = tabs[idx].primaryPane.currentPageIndex != pageIndex
            let scaleChanged = abs(tabs[idx].primaryPane.scaleFactor - scaleFactor) > 0.0001
            guard pageChanged || scaleChanged else { return }
            if pageChanged {
                tabs[idx].primaryPane.currentPageIndex = pageIndex
            }
            if scaleChanged {
                tabs[idx].primaryPane.scaleFactor = scaleFactor
            }
            store.savePosition(
                ReadingPosition(pageIndex: pageIndex, scaleFactor: scaleFactor),
                for: tabs[idx].primaryPane.url
            )
            if pageChanged {
                schedulePersistSession()
                if tabs[idx].activeSide == .primary {
                    scheduleRefreshCurrentPageFootnotes()
                }
            }
        case .secondary:
            guard var secondary = tabs[idx].secondaryPane else { return }
            let pageChanged = secondary.currentPageIndex != pageIndex
            let scaleChanged = abs(secondary.scaleFactor - scaleFactor) > 0.0001
            guard pageChanged || scaleChanged else { return }
            secondary.currentPageIndex = pageIndex
            secondary.scaleFactor = scaleFactor
            tabs[idx].secondaryPane = secondary
            if secondary.url != tabs[idx].primaryPane.url {
                store.savePosition(
                    ReadingPosition(pageIndex: pageIndex, scaleFactor: scaleFactor),
                    for: secondary.url
                )
            }
            if pageChanged {
                schedulePersistSession()
                if tabs[idx].activeSide == .secondary {
                    scheduleRefreshCurrentPageFootnotes()
                }
            }
        }
    }

    private func scheduleRefreshCurrentPageFootnotes() {
        footnoteRefreshTask?.cancel()
        footnoteRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshCurrentPageFootnotes()
        }
    }

    public func jumpToPage(_ pageIndex: Int, side: PaneSide? = nil, recordHistory: Bool = true) {
        guard let idx = activeTabIndex else { return }
        let targetSide = side ?? tabs[idx].activeSide
        switch targetSide {
        case .primary:
            let previousPage = tabs[idx].primaryPane.currentPageIndex
            let clamped = max(0, min(pageIndex, max(0, tabs[idx].primaryPane.metadata.pageCount - 1)))
            if recordHistory && clamped != previousPage {
                tabs[idx].primaryPane.backHistory.append(previousPage)
                tabs[idx].primaryPane.forwardHistory.removeAll()
            }
            tabs[idx].primaryPane.targetPageRequest = PageJumpRequest(pageIndex: clamped)
            tabs[idx].primaryPane.currentPageIndex = clamped
        case .secondary:
            guard let secondary = tabs[idx].secondaryPane else { return }
            let previousPage = secondary.currentPageIndex
            let clamped = max(0, min(pageIndex, max(0, secondary.metadata.pageCount - 1)))
            if recordHistory && clamped != previousPage {
                tabs[idx].secondaryPane?.backHistory.append(previousPage)
                tabs[idx].secondaryPane?.forwardHistory.removeAll()
            }
            tabs[idx].secondaryPane?.targetPageRequest = PageJumpRequest(pageIndex: clamped)
            tabs[idx].secondaryPane?.currentPageIndex = clamped
        }
        refreshCurrentPageFootnotes()
    }

    public func goBack(side: PaneSide? = nil) {
        guard let idx = activeTabIndex else { return }
        let targetSide = side ?? tabs[idx].activeSide
        switch targetSide {
        case .primary:
            guard let destination = tabs[idx].primaryPane.backHistory.popLast() else { return }
            tabs[idx].primaryPane.forwardHistory.append(tabs[idx].primaryPane.currentPageIndex)
            jumpToPage(destination, side: .primary, recordHistory: false)
        case .secondary:
            guard var secondary = tabs[idx].secondaryPane,
                  let destination = secondary.backHistory.popLast() else { return }
            secondary.forwardHistory.append(secondary.currentPageIndex)
            tabs[idx].secondaryPane = secondary
            jumpToPage(destination, side: .secondary, recordHistory: false)
        }
    }

    public func goForward(side: PaneSide? = nil) {
        guard let idx = activeTabIndex else { return }
        let targetSide = side ?? tabs[idx].activeSide
        switch targetSide {
        case .primary:
            guard let destination = tabs[idx].primaryPane.forwardHistory.popLast() else { return }
            tabs[idx].primaryPane.backHistory.append(tabs[idx].primaryPane.currentPageIndex)
            jumpToPage(destination, side: .primary, recordHistory: false)
        case .secondary:
            guard var secondary = tabs[idx].secondaryPane,
                  let destination = secondary.forwardHistory.popLast() else { return }
            secondary.backHistory.append(secondary.currentPageIndex)
            tabs[idx].secondaryPane = secondary
            jumpToPage(destination, side: .secondary, recordHistory: false)
        }
    }

    public func refreshCurrentPageFootnotes() {
        footnoteRefreshTask?.cancel()
        footnoteRefreshTask = nil
        guard let pane = activeTab?.activePane,
              let page = pane.document.page(at: pane.currentPageIndex) else {
            if !currentPageFootnotes.isEmpty {
                currentPageFootnotes = []
            }
            if currentPageOCRResult != nil {
                currentPageOCRResult = nil
            }
            if activeDocumentOCRCount != 0 {
                activeDocumentOCRCount = 0
            }
            if !activeDocumentBookmarks.isEmpty {
                activeDocumentBookmarks = []
            }
            lastLoadedDocumentMetaHash = nil
            clearActiveNotebookState()
            return
        }
        let newFootnotes = footnoteResolver.extractPageFootnotes(
            from: page,
            pageIndex: pane.currentPageIndex
        )
        if currentPageFootnotes != newFootnotes {
            currentPageFootnotes = newFootnotes
        }
        if !pane.documentHash.isEmpty {
            let newOCR = libraryDatabase.fetchOCRPage(
                docHash: pane.documentHash,
                pageIndex: pane.currentPageIndex
            )
            if currentPageOCRResult != newOCR {
                currentPageOCRResult = newOCR
            }
            if lastLoadedDocumentMetaHash != pane.documentHash {
                lastLoadedDocumentMetaHash = pane.documentHash
                let ocrCount = libraryDatabase.countOCRPages(docHash: pane.documentHash)
                if activeDocumentOCRCount != ocrCount {
                    activeDocumentOCRCount = ocrCount
                }
                let bookmarks = libraryDatabase.fetchBookmarks(forDocumentHash: pane.documentHash)
                if activeDocumentBookmarks != bookmarks {
                    activeDocumentBookmarks = bookmarks
                }
            }
            if notebookSections.first?.documentHash != pane.documentHash {
                loadNotebookForActiveDocument()
            }
        } else {
            if currentPageOCRResult != nil {
                currentPageOCRResult = nil
            }
            if activeDocumentOCRCount != 0 {
                activeDocumentOCRCount = 0
            }
            if !activeDocumentBookmarks.isEmpty {
                activeDocumentBookmarks = []
            }
            lastLoadedDocumentMetaHash = nil
            clearActiveNotebookState()
        }
    }

    public func pinFootnote(_ preview: FootnotePreview) {
        pinnedFootnotes.removeAll {
            $0.documentTitle == preview.documentTitle &&
            $0.targetPageIndex == preview.targetPageIndex &&
            $0.marker == preview.marker
        }
        pinnedFootnotes.insert(preview, at: 0)
    }

    public func pinPageFootnote(_ item: PageFootnoteItem) {
        guard let pane = activeTab?.activePane else { return }
        let preview = FootnotePreview(
            marker: item.marker,
            sourcePageIndex: item.pageIndex,
            targetPageIndex: item.pageIndex,
            targetRect: nil,
            extractedText: item.text,
            snapshotImage: pane.document.page(at: item.pageIndex).flatMap { page in
                let box = page.bounds(for: .mediaBox)
                let rect = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.48)
                return footnoteResolver.renderSnapshot(of: page, cropRect: rect)
            },
            origin: .pageBottomHeuristic,
            documentTitle: pane.metadata.title
        )
        pinFootnote(preview)
    }

    public func unpinFootnote(id: UUID) {
        pinnedFootnotes.removeAll { $0.id == id }
    }

    public func openFootnoteInSecondarySplit(targetPageIndex: Int) {
        guard let idx = activeTabIndex else { return }
        if tabs[idx].secondaryPane?.url != tabs[idx].primaryPane.url {
            splitCurrentDocumentSelf()
        } else {
            tabs[idx].activeSide = .secondary
        }
        jumpToPage(targetPageIndex, side: .secondary, recordHistory: true)
    }

    public func sendZoom(_ action: ZoomAction, side: PaneSide? = nil) {
        guard let idx = activeTabIndex else { return }
        let targetSide = side ?? tabs[idx].activeSide
        switch targetSide {
        case .primary:
            tabs[idx].primaryPane.zoomRequest = ZoomRequest(action: action)
        case .secondary:
            tabs[idx].secondaryPane?.zoomRequest = ZoomRequest(action: action)
        }
    }

    public func broadcastScroll(from side: PaneSide, normalizedY: Double) {
        guard let tab = activeTab, tab.isSplit, tab.syncScrollEnabled else { return }
        syncScrollSignal = SyncScrollSignal(sourceSide: side, normalizedY: normalizedY)
    }

    public func updateSelectedText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        selectedText = cleaned
        translatedText = ""
        translationError = nil
        multiDictionaryResult = dictionaryManager.lookup(cleaned)
    }

    public func refreshCurrentLookup() {
        guard !selectedText.isEmpty else { return }
        multiDictionaryResult = dictionaryManager.lookup(selectedText)
    }

    public func lookupManualTerm(_ term: String) {
        updateSelectedText(term)
        rightPanelTab = .dictionary
    }

    public func saveCurrentLookupToVocabulary() {
        let firstCard = multiDictionaryResult?.cards.first
        let term = firstCard?.matchedHeadword.isEmpty == false
            ? firstCard!.matchedHeadword
            : (multiDictionaryResult?.primaryWord.isEmpty == false ? multiDictionaryResult!.primaryWord : selectedText)
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Avoid exact duplicate at top
        vocabulary.removeAll { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }

        let activePane = activeTab?.activePane
        let item = VocabularyItem(
            term: trimmed,
            definition: firstCard?.plainText,
            translation: translatedText.isEmpty ? nil : translatedText,
            languageCode: multiDictionaryResult?.detectedLanguageCode,
            sourceDocumentTitle: activePane?.metadata.title,
            pageIndex: activePane?.currentPageIndex
        )
        vocabulary.insert(item, at: 0)
        vocabularyStore.saveItems(vocabulary)
    }

    public func removeVocabularyItem(id: UUID) {
        vocabulary.removeAll { $0.id == id }
        vocabularyStore.saveItems(vocabulary)
    }

    public func exportVocabularyMarkdown() -> String {
        var lines: [String] = ["# Graphe Kelime Defteri", ""]
        for item in vocabulary {
            var header = "## \(item.term)"
            if let lang = item.languageCode {
                header += " (`\(lang)`)"
            }
            lines.append(header)
            if let tr = item.translation, !tr.isEmpty {
                lines.append("- **Çeviri:** \(tr)")
            }
            if let def = item.definition, !def.isEmpty {
                lines.append("- **Tanım:** \(def)")
            }
            if let doc = item.sourceDocumentTitle {
                let pageText = item.pageIndex.map { " (s. \($0 + 1))" } ?? ""
                lines.append("- **Kaynak:** \(doc)\(pageText)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func removeRecentFile(path: String) {
        recentFiles.removeAll { $0.path == path }
        store.saveRecentFiles(recentFiles)
    }

    public func openSearch() {
        guard activeTab != nil else { return }
        isSearchVisible = true
    }

    public func closeSearch() {
        inDocSearchTask?.cancel()
        inDocSearchTask = nil
        isSearchVisible = false
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = 0
        clearSearchHighlightsOnActiveTab()
    }

    /// Debounced search for interactive typing in the search bar (prevents stuttering on 350+ page PDFs).
    public func scheduleSearch(_ query: String) {
        searchQuery = query
        inDocSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchMatches = []
            currentMatchIndex = 0
            clearSearchHighlightsOnActiveTab()
            return
        }
        inDocSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.performSearch(query)
        }
    }

    public func performSearch(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = activeTabIndex else {
            searchMatches = []
            currentMatchIndex = 0
            clearSearchHighlightsOnActiveTab()
            return
        }

        let side = tabs[idx].activeSide
        let doc = (side == .secondary ? tabs[idx].secondaryPane?.document : tabs[idx].primaryPane.document)
            ?? tabs[idx].primaryPane.document

        let matches = doc.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searchMatches = matches
        currentMatchIndex = 0
        applySearchHighlight(matches: matches, activeIndex: 0, side: side, tabIndex: idx)
    }

    public func nextSearchMatch() {
        guard !searchMatches.isEmpty, let idx = activeTabIndex else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        applySearchHighlight(
            matches: searchMatches,
            activeIndex: currentMatchIndex,
            side: tabs[idx].activeSide,
            tabIndex: idx
        )
    }

    public func previousSearchMatch() {
        guard !searchMatches.isEmpty, let idx = activeTabIndex else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        applySearchHighlight(
            matches: searchMatches,
            activeIndex: currentMatchIndex,
            side: tabs[idx].activeSide,
            tabIndex: idx
        )
    }

    private func applySearchHighlight(
        matches: [PDFSelection],
        activeIndex: Int,
        side: PaneSide,
        tabIndex: Int
    ) {
        let activeMatch = matches.indices.contains(activeIndex) ? matches[activeIndex] : nil
        let highlight = SearchHighlightState(allMatches: matches, activeMatch: activeMatch)
        switch side {
        case .primary:
            tabs[tabIndex].primaryPane.searchHighlight = highlight
        case .secondary:
            tabs[tabIndex].secondaryPane?.searchHighlight = highlight
        }
    }

    private func clearSearchHighlightsOnActiveTab() {
        guard let idx = activeTabIndex else { return }
        let empty = SearchHighlightState(allMatches: [], activeMatch: nil)
        tabs[idx].primaryPane.searchHighlight = empty
        tabs[idx].secondaryPane?.searchHighlight = empty
    }

    // MARK: - Faz 5: Offline Apple Vision OCR & Auto-Crop Margins

    public var isActiveDocumentAutoCropped: Bool {
        guard let doc = activeTab?.activePane.document else {
            return false
        }
        return autoCroppedDocumentIDs.contains(ObjectIdentifier(doc))
    }

    public func toggleAutoCropForActiveDocument() {
        guard let pane = activeTab?.activePane else { return }
        let docID = ObjectIdentifier(pane.document)
        if autoCroppedDocumentIDs.contains(docID) {
            autoCropService.restoreOriginalMargins(for: pane.document)
            autoCroppedDocumentIDs.remove(docID)
        } else {
            if autoCropService.applyAutoCrop(to: pane.document) {
                autoCroppedDocumentIDs.insert(docID)
            }
        }
        layoutRefreshToken = UUID()
        sendZoom(.fitWidth)
    }

    public func runOCROnCurrentPage() {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return }
        cancelOCR()

        let runID = UUID()
        activeOCRRunID = runID

        let docHash = pane.documentHash
        let docTitle = pane.metadata.title
        let docURL = pane.url
        let pageIndex = pane.currentPageIndex
        let ocr = ocrService
        let db = libraryDatabase

        ocrProgress = OCRProgressState(
            documentHash: docHash,
            documentTitle: docTitle,
            completedPages: 0,
            totalPages: 1
        )

        activeOCRTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.activeOCRRunID == runID else { return }
                    self.ocrProgress = nil
                    self.activeOCRRunID = nil
                }
            }
            guard !Task.isCancelled,
                  let bgDoc = PDFDocument(url: docURL),
                  let page = bgDoc.page(at: pageIndex) else {
                return
            }
            do {
                let result = try ocr.recognizeText(on: page, pageIndex: pageIndex)
                guard !Task.isCancelled else { return }
                db.upsertOCRPage(docHash: docHash, result: result)
                await MainActor.run { [weak self] in
                    guard let self, self.activeOCRRunID == runID else { return }
                    if self.activeTab?.activePane.documentHash == docHash {
                        if self.activeTab?.activePane.currentPageIndex == pageIndex {
                            self.currentPageOCRResult = result
                        }
                        self.activeDocumentOCRCount = db.countOCRPages(docHash: docHash)
                    }
                    self.refreshLibrary()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.activeOCRRunID == runID else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func runOCROnEntireDocument() {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return }
        cancelOCR()

        let runID = UUID()
        activeOCRRunID = runID

        let docHash = pane.documentHash
        let docTitle = pane.metadata.title
        let docURL = pane.url
        let totalPages = pane.metadata.pageCount
        let ocr = ocrService
        let db = libraryDatabase

        ocrProgress = OCRProgressState(
            documentHash: docHash,
            documentTitle: docTitle,
            completedPages: 0,
            totalPages: totalPages
        )

        activeOCRTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.activeOCRRunID == runID else { return }
                    self.ocrProgress = nil
                    self.activeOCRRunID = nil
                }
            }
            guard !Task.isCancelled, let bgDoc = PDFDocument(url: docURL) else { return }
            let count = bgDoc.pageCount

            for idx in 0..<count {
                if Task.isCancelled { break }
                guard let page = bgDoc.page(at: idx) else { continue }
                if let result = try? ocr.recognizeText(on: page, pageIndex: idx) {
                    if Task.isCancelled { break }
                    db.upsertOCRPage(docHash: docHash, result: result)
                    await MainActor.run { [weak self] in
                        guard let self, self.activeOCRRunID == runID else { return }
                        self.ocrProgress = OCRProgressState(
                            documentHash: docHash,
                            documentTitle: docTitle,
                            completedPages: idx + 1,
                            totalPages: count
                        )
                        if self.activeTab?.activePane.documentHash == docHash {
                            if self.activeTab?.activePane.currentPageIndex == idx {
                                self.currentPageOCRResult = result
                            }
                            self.activeDocumentOCRCount = db.countOCRPages(docHash: docHash)
                        }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.activeOCRRunID == runID else { return }
                self.refreshLibrary()
            }
        }
    }

    public func cancelOCR() {
        activeOCRRunID = nil
        activeOCRTask?.cancel()
        activeOCRTask = nil
        ocrProgress = nil
    }

    public func exportActiveDocumentSearchablePDF(to destinationURL: URL) throws {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else {
            throw VisionOCRError.documentOpenFailed
        }
        let ocrPages = libraryDatabase.fetchAllOCRPages(docHash: pane.documentHash)
        try ocrService.exportSearchablePDF(
            sourceURL: pane.url,
            ocrPages: ocrPages,
            destinationURL: destinationURL
        )
    }

    public func activeDocumentOCRPageCount() -> Int {
        guard let hash = activeTab?.activePane.documentHash, !hash.isEmpty else {
            return 0
        }
        return libraryDatabase.countOCRPages(docHash: hash)
    }

    // MARK: - Library, Highlights, Notes & Global FTS5 Search

    public var activeDocumentAnnotations: [AnnotationItem] {
        guard let hash = activeTab?.activePane.documentHash, !hash.isEmpty else {
            return []
        }
        return annotationsByDocument[hash] ?? []
    }

    public var filteredLibraryDocuments: [LibraryDocumentRecord] {
        guard let tag = selectedTagFilter, !tag.isEmpty else {
            return libraryDocuments
        }
        let matchingHashes = documentHashesByTag[tag] ?? []
        return libraryDocuments.filter { $0.tags.contains(tag) || matchingHashes.contains($0.hash) }
    }

    public func readingProgress(for doc: LibraryDocumentRecord) -> (page: Int, fraction: Double)? {
        guard doc.pageCount > 0 else { return nil }
        if let openPane = tabs.flatMap({ [$0.primaryPane, $0.secondaryPane].compactMap { $0 } })
            .first(where: { $0.documentHash == doc.hash }) {
            let p = openPane.currentPageIndex + 1
            return (p, min(1.0, max(0.0, Double(p) / Double(doc.pageCount))))
        }
        if let saved = store.loadPosition(for: doc.url) {
            let p = min(doc.pageCount, max(1, saved.pageIndex + 1))
            return (p, min(1.0, max(0.0, Double(p) / Double(doc.pageCount))))
        }
        return nil
    }

    public func annotations(forDocumentHash hash: String) -> [AnnotationItem] {
        annotationsByDocument[hash] ?? []
    }

    public func refreshLibrary() {
        libraryDocuments = libraryDatabase.fetchAllDocuments()
        refreshTagIndex()
    }

    private func refreshTagIndex() {
        let map = libraryDatabase.tagDocumentHashMap()
        documentHashesByTag = map
        allTags = map.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if let selected = selectedTagFilter, !allTags.contains(selected) {
            selectedTagFilter = nil
        }
    }

    public func updateSelectionCapture(_ capture: SelectionCapture?) {
        activeSelection = capture
        if let capture, !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateSelectedText(capture.text)
        }
    }

    @discardableResult
    public func createHighlightFromActiveSelection(
        color: HighlightColor = .yellow,
        note: String = "",
        tags: [String] = []
    ) -> AnnotationItem? {
        guard let pane = activeTab?.activePane,
              !pane.documentHash.isEmpty,
              let capture = activeSelection,
              !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let item = createHighlight(
            capture: capture,
            color: color,
            note: note,
            tags: tags,
            forDocumentHash: pane.documentHash
        )
        activeSelection = nil
        return item
    }

    @discardableResult
    public func createHighlight(
        capture: SelectionCapture,
        color: HighlightColor = .yellow,
        note: String = "",
        tags: [String] = [],
        forDocumentHash hash: String,
        alsoSendToNotebook: Bool = true
    ) -> AnnotationItem {
        let item = AnnotationItem(
            documentHash: hash,
            pageIndex: capture.pageIndex,
            kind: .highlight,
            color: color,
            quote: capture.text,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            rects: capture.rects,
            tags: tags
        )
        libraryDatabase.upsertAnnotation(item)
        reloadAnnotations(forDocumentHash: hash)
        refreshTagIndex()
        var linkedContainer: NoteContainer?
        if alsoSendToNotebook {
            linkedContainer = sendQuoteToNotebook(
                quote: capture.text,
                sourcePageIndex: capture.pageIndex,
                color: color,
                initialNote: item.note,
                forDocumentHash: hash,
                recordUndoAction: false
            )
        }
        let linkedPageTitle: String
        if let container = linkedContainer {
            linkedPageTitle = notebookPages.first(where: { $0.id == container.pageID })?.title
                ?? libraryDatabase.fetchNotebookPageTitle(id: container.pageID)
                ?? ""
        } else {
            linkedPageTitle = ""
        }
        recordUndo(.createdHighlight(
            annotation: item,
            linkedContainer: linkedContainer,
            pageTitle: linkedPageTitle
        ))
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
        return item
    }

    @discardableResult
    public func addPageNote(
        note: String,
        color: HighlightColor = .purple,
        tags: [String] = []
    ) -> AnnotationItem? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pane = activeTab?.activePane,
              !pane.documentHash.isEmpty else {
            return nil
        }

        let item = AnnotationItem(
            documentHash: pane.documentHash,
            pageIndex: pane.currentPageIndex,
            kind: .pageNote,
            color: color,
            quote: "",
            note: trimmed,
            rects: [],
            tags: tags
        )
        libraryDatabase.upsertAnnotation(item)
        reloadAnnotations(forDocumentHash: pane.documentHash)
        refreshTagIndex()
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
        return item
    }

    public func updateAnnotation(_ updated: AnnotationItem) {
        var copy = updated
        copy.updatedAt = Date()
        libraryDatabase.upsertAnnotation(copy)
        reloadAnnotations(forDocumentHash: copy.documentHash)
        refreshTagIndex()
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
    }

    public func deleteAnnotation(id: UUID, documentHash: String) {
        if let existing = annotationsByDocument[documentHash]?.first(where: { $0.id == id }) {
            recordUndo(.deletedAnnotation(annotation: existing))
        }
        libraryDatabase.deleteAnnotation(id: id)
        reloadAnnotations(forDocumentHash: documentHash)
        refreshTagIndex()
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
    }

    public func updateDocumentTags(hash: String, tags: [String]) {
        libraryDatabase.updateDocumentTags(hash: hash, tags: tags)
        refreshLibrary()
        refreshStandaloneNotebooks()
    }

    public func removeLibraryDocument(hash: String) {
        libraryDatabase.removeDocument(hash: hash)
        annotationsByDocument.removeValue(forKey: hash)
        pruneUndoRedo(forDocumentHash: hash)
        if editingMetadataDocument?.hash == hash {
            editingMetadataDocument = nil
        }
        if activeTab?.activePane.documentHash == hash || notebookSections.first?.documentHash == hash {
            currentPageOCRResult = nil
            activeDocumentOCRCount = 0
            activeDocumentBookmarks = []
            lastLoadedDocumentMetaHash = nil
            clearActiveNotebookState()
        }
        refreshLibrary()
        refreshStandaloneNotebooks()
    }

    public func performGlobalSearch(_ query: String) {
        globalSearchTask?.cancel()
        globalSearchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            globalSearchResults = []
            return
        }
        globalSearchResults = libraryDatabase.globalSearch(query: trimmed, limit: 60)
    }

    /// Debounced global FTS5 search for interactive typing in the sidebar.
    public func scheduleGlobalSearch(_ query: String) {
        globalSearchQuery = query
        globalSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            globalSearchResults = []
            return
        }
        globalSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            self?.performGlobalSearch(query)
        }
    }

    public func openGlobalSearchResult(_ result: GlobalSearchResult) {
        if result.documentHash.hasPrefix("notebook:"),
           let nbID = UUID(uuidString: String(result.documentHash.dropFirst("notebook:".count))) {
            openStandaloneNotebook(id: nbID)
            if let targetPageID = result.notebookPageID {
                loadNotebookForActiveDocument(selectingPageID: targetPageID)
            }
            return
        }
        let url = URL(fileURLWithPath: result.documentPath).standardizedFileURL
        openDocument(at: url, inNewTab: false)
        guard activeTab?.activePane.url == url else { return }
        if result.kind == .notebookNote, let targetPageID = result.notebookPageID {
            rightPanelTab = .notes
            notesSubTab = .notebook
            showRightInspector = true
            loadNotebookForActiveDocument(selectingPageID: targetPageID)
            if result.pageIndex >= 0 {
                jumpToPage(result.pageIndex)
            }
        } else {
            jumpToPage(result.pageIndex)
        }
    }

    // MARK: - v1.1: Metadata & Rename, Citations, 2-Up Book View, Backup/Restore

    public func toggleTwoUpBookMode() {
        isTwoUpBookMode.toggle()
        layoutRefreshToken = UUID()
    }

    public func openMetadataEditorForActiveDocument() {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return }
        editingMetadataDocument = libraryDatabase.fetchDocument(hash: pane.documentHash)
            ?? LibraryDocumentRecord(
                hash: pane.documentHash,
                path: pane.url.path,
                title: pane.metadata.title,
                author: pane.metadata.author,
                pageCount: pane.metadata.pageCount
            )
    }

    public func openMetadataEditor(forURL url: URL) {
        let std = url.standardizedFileURL
        if let existing = libraryDocuments.first(where: { $0.url.path == std.path }) {
            editingMetadataDocument = existing
            return
        }
        let hash = LibraryDatabase.computeFileHash(for: std)
        if let existing = libraryDatabase.fetchDocument(hash: hash) {
            editingMetadataDocument = existing
            return
        }
        let pageCount = PDFDocument(url: std)?.pageCount ?? 0
        let created = libraryDatabase.upsertDocument(
            hash: hash,
            path: std.path,
            title: std.deletingPathExtension().lastPathComponent,
            author: nil,
            pageCount: pageCount,
            touchLastOpened: false
        )
        refreshLibrary()
        refreshStandaloneNotebooks()
        editingMetadataDocument = created
    }

    public func saveDocumentMetadata(hash: String, draft: BookMetadataDraft, alsoRenameFile: Bool) {
        let cleanedAuthor = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAuthor: String? = cleanedAuthor.isEmpty ? nil : cleanedAuthor

        libraryDatabase.updateDocumentMetadata(
            hash: hash,
            title: draft.title,
            author: resolvedAuthor,
            year: draft.year,
            publisher: draft.publisher.isEmpty ? nil : draft.publisher,
            isbn: draft.isbn.isEmpty ? nil : draft.isbn,
            doi: draft.doi.isEmpty ? nil : draft.doi
        )

        syncOpenPaneMetadata(hash: hash, title: draft.title, author: resolvedAuthor)

        if alsoRenameFile, let record = libraryDatabase.fetchDocument(hash: hash) {
            let newStem = draft.suggestedFileStem()
            renameFileItem(at: record.url, to: newStem)
            // Keep the rich title in DB and open panes even if filename had characters sanitized
            libraryDatabase.updateDocumentMetadata(
                hash: hash,
                title: draft.title,
                author: resolvedAuthor,
                year: draft.year,
                publisher: draft.publisher.isEmpty ? nil : draft.publisher,
                isbn: draft.isbn.isEmpty ? nil : draft.isbn,
                doi: draft.doi.isEmpty ? nil : draft.doi
            )
            syncOpenPaneMetadata(hash: hash, title: draft.title, author: resolvedAuthor)
        }

        refreshLibrary()
        refreshStandaloneNotebooks()
    }

    private func syncOpenPaneMetadata(hash: String, title: String, author: String?) {
        for idx in tabs.indices {
            if tabs[idx].primaryPane.documentHash == hash {
                let m = tabs[idx].primaryPane.metadata
                tabs[idx].primaryPane.metadata = DocumentMetadata(
                    url: m.url,
                    title: title,
                    author: author,
                    pageCount: m.pageCount,
                    outline: m.outline
                )
            }
            if let sec = tabs[idx].secondaryPane, sec.documentHash == hash {
                let m = sec.metadata
                tabs[idx].secondaryPane?.metadata = DocumentMetadata(
                    url: m.url,
                    title: title,
                    author: author,
                    pageCount: m.pageCount,
                    outline: m.outline
                )
            }
        }
    }

    @discardableResult
    public func formatCitation(
        forDocumentHash hash: String,
        pageIndex: Int? = nil,
        quote: String? = nil,
        style: CitationStyle = .chicago
    ) -> String? {
        guard let record = libraryDatabase.fetchDocument(hash: hash) else { return nil }
        return citationFormatter.format(
            document: record,
            pageNumber: pageIndex.map { $0 + 1 },
            quote: quote,
            style: style
        )
    }

    public func copyCitationToPasteboard(
        forDocumentHash hash: String,
        pageIndex: Int? = nil,
        quote: String? = nil,
        style: CitationStyle = .chicago
    ) {
        guard let text = formatCitation(
            forDocumentHash: hash,
            pageIndex: pageIndex,
            quote: quote,
            style: style
        ) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public func copyActiveDocumentCitation(style: CitationStyle = .chicago, includeQuote: Bool = false) {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return }
        let quote = includeQuote ? activeSelection?.text : nil
        copyCitationToPasteboard(
            forDocumentHash: pane.documentHash,
            pageIndex: pane.currentPageIndex,
            quote: quote,
            style: style
        )
    }

    public func createBackupArchive(to destinationURL: URL) throws {
        try backupService.createBackup(
            database: libraryDatabase,
            vocabulary: vocabulary,
            destinationURL: destinationURL
        )
    }

    public func restoreBackupArchive(from archiveURL: URL) throws {
        let dbPath = libraryDatabase.databasePath
        guard dbPath != ":memory:" else { return }
        cancelOCR()
        libraryDatabase.close()
        let restored = try backupService.restoreBackup(
            from: archiveURL,
            targetDatabasePath: dbPath
        )
        libraryDatabase = try LibraryDatabase(path: dbPath)
        undoStack.removeAll()
        redoStack.removeAll()
        activeDocumentBookmarks = []
        lastLoadedDocumentMetaHash = nil
        editingMetadataDocument = nil
        if let vocab = restored.vocabulary {
            vocabulary = vocab
            vocabularyStore.saveItems(vocab)
        }
        refreshLibrary()
        refreshStandaloneNotebooks()
        for tab in tabs {
            if !tab.primaryPane.documentHash.isEmpty {
                reloadAnnotations(forDocumentHash: tab.primaryPane.documentHash)
            }
            if let sec = tab.secondaryPane, !sec.documentHash.isEmpty {
                reloadAnnotations(forDocumentHash: sec.documentHash)
            }
        }
        loadNotebookForActiveDocument()
        refreshCurrentPageFootnotes()
    }

    // MARK: - Bookmarks (⌘D)

    public var isCurrentPageBookmarked: Bool {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return false }
        return activeDocumentBookmarks.contains(where: { $0.pageIndex == pane.currentPageIndex })
    }

    public func isPageBookmarked(_ pageIndex: Int, forDocumentHash hash: String) -> Bool {
        guard !hash.isEmpty else { return false }
        if activeTab?.activePane.documentHash == hash {
            return activeDocumentBookmarks.contains(where: { $0.pageIndex == pageIndex })
        }
        return libraryDatabase.fetchBookmarks(forDocumentHash: hash).contains(where: { $0.pageIndex == pageIndex })
    }

    public func toggleBookmarkForCurrentPage(label: String = "") {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else { return }
        toggleBookmark(pageIndex: pane.currentPageIndex, forDocumentHash: pane.documentHash, label: label)
    }

    public func toggleBookmark(pageIndex: Int, forDocumentHash hash: String, label: String = "") {
        guard !hash.isEmpty else { return }
        let existing = libraryDatabase.fetchBookmarks(forDocumentHash: hash)
        if existing.contains(where: { $0.pageIndex == pageIndex }) {
            libraryDatabase.deleteBookmark(docHash: hash, pageIndex: pageIndex)
        } else {
            let item = BookmarkItem(documentHash: hash, pageIndex: pageIndex, label: label)
            libraryDatabase.upsertBookmark(item)
        }
        if activeTab?.activePane.documentHash == hash {
            activeDocumentBookmarks = libraryDatabase.fetchBookmarks(forDocumentHash: hash)
        }
    }

    public func removeBookmark(_ item: BookmarkItem) {
        libraryDatabase.deleteBookmark(docHash: item.documentHash, pageIndex: item.pageIndex)
        if activeTab?.activePane.documentHash == item.documentHash {
            activeDocumentBookmarks = libraryDatabase.fetchBookmarks(forDocumentHash: item.documentHash)
        }
    }

    // MARK: - Faz 7: Vault / Folder File Manager

    public var allFolderDirectories: [FileTreeNode] {
        folderExplorer.collectAllDirectories(from: folderTrees)
    }

    public func addWatchedFolder(url: URL) {
        let std = url.standardizedFileURL
        guard !watchedFolders.contains(where: { $0.path == std.path }) else {
            libraryViewMode = .folders
            refreshFolderTrees()
            return
        }
        watchedFolders.append(WatchedRootFolder(path: std.path))
        folderExplorer.saveWatchedFolders(watchedFolders)
        libraryViewMode = .folders
        refreshFolderTrees()
        importFolderToLibrary(folderURL: std)
    }

    public func removeWatchedFolder(path: String) {
        watchedFolders.removeAll { $0.path == path }
        folderExplorer.saveWatchedFolders(watchedFolders)
        refreshFolderTrees()
    }

    public func refreshFolderTrees() {
        folderRefreshGeneration += 1
        let generation = folderRefreshGeneration
        let roots = watchedFolders
        let explorer = folderExplorer
        if roots.isEmpty {
            explorer.stopWatching()
            folderTrees = []
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built = roots.map { explorer.buildTree(for: $0) }
            let allDirURLs = explorer.collectAllDirectories(from: built).map(\.url)
            Task { @MainActor [weak self] in
                guard let self, self.folderRefreshGeneration == generation else { return }
                self.folderTrees = built
                explorer.startWatching(directories: allDirURLs) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshFolderTrees()
                    }
                }
            }
        }
    }

    public func createSubfolder(named name: String, inside parentURL: URL) {
        _ = createSubfolderAndReturnURL(named: name, inside: parentURL)
    }

    public func createSubfolderAndReturnURL(named name: String, inside parentURL: URL) -> URL? {
        do {
            let created = try folderExplorer.createSubfolder(named: name, inside: parentURL)
            refreshFolderTrees()
            return created.standardizedFileURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func presentMoveToFolder(url: URL? = nil) {
        let targetURL = url ?? activeTab?.activePane.url
        guard let targetURL else { return }
        refreshFolderTrees()
        movingPDFRequest = MovePDFRequest(url: targetURL)
    }

    public func allDestinationFolderTargets() -> [MoveFolderTarget] {
        var result: [MoveFolderTarget] = []
        func collect(_ node: FileTreeNode, prefix: String, depth: Int) {
            guard node.isDirectory else { return }
            let crumb = prefix.isEmpty ? node.name : "\(prefix) / \(node.name)"
            result.append(MoveFolderTarget(
                url: node.url,
                name: node.name,
                breadcrumb: crumb,
                depth: depth,
                pdfCount: node.pdfCount
            ))
            for child in node.children where child.isDirectory {
                collect(child, prefix: crumb, depth: depth + 1)
            }
        }
        for rootTree in folderTrees {
            collect(rootTree, prefix: "", depth: 0)
        }
        return result
    }

    public func renameFileItem(at sourceURL: URL, to newName: String) {
        let stdOld = sourceURL.standardizedFileURL
        let isDir = (try? stdOld.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        do {
            let newURL = try folderExplorer.renameItem(at: stdOld, toNewName: newName)
            let singleTitle = isDir ? nil : newURL.deletingPathExtension().lastPathComponent
            libraryDatabase.updateDocumentPaths(
                oldPrefix: stdOld.path,
                newPrefix: newURL.path,
                renamedSingleFileTitle: singleTitle
            )
            migrateOpenStateForPathChange(
                oldPrefix: stdOld.path,
                newPrefix: newURL.path,
                renamedSingleFileTitle: singleTitle
            )
            refreshLibrary()
        refreshStandaloneNotebooks()
            refreshFolderTrees()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func moveFileItem(at sourceURL: URL, toFolder targetFolderURL: URL) {
        if let err = moveFileItemReturningError(at: sourceURL, toFolder: targetFolderURL) {
            errorMessage = err
        }
    }

    public func moveFileItemReturningError(at sourceURL: URL, toFolder targetFolderURL: URL) -> String? {
        let stdOld = sourceURL.standardizedFileURL
        do {
            let newURL = try folderExplorer.moveItem(at: stdOld, toFolder: targetFolderURL)
            libraryDatabase.updateDocumentPaths(oldPrefix: stdOld.path, newPrefix: newURL.path)
            migrateOpenStateForPathChange(
                oldPrefix: stdOld.path,
                newPrefix: newURL.path,
                renamedSingleFileTitle: nil
            )
            refreshLibrary()
            refreshStandaloneNotebooks()
            refreshFolderTrees()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Moves (or falls back to copying if source cannot be moved across volumes/permissions) one or more PDF files
    /// into the target folder, updates open tabs & library paths, and triggers automatic background metadata enrichment.
    @discardableResult
    public func importPDFs(from sourceURLs: [URL], into targetFolderURL: URL, openFirst: Bool = false) -> Int {
        let stdTarget = targetFolderURL.standardizedFileURL
        let pdfURLs = sourceURLs
            .map(\.standardizedFileURL)
            .filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else { return 0 }

        var importedURLs: [URL] = []
        let fm = FileManager.default

        for src in pdfURLs {
            let finalURL: URL
            if src.deletingLastPathComponent().standardizedFileURL.path == stdTarget.path {
                finalURL = src
            } else {
                do {
                    finalURL = try folderExplorer.moveItem(at: src, toFolder: stdTarget)
                    libraryDatabase.updateDocumentPaths(oldPrefix: src.path, newPrefix: finalURL.path)
                    migrateOpenStateForPathChange(
                        oldPrefix: src.path,
                        newPrefix: finalURL.path,
                        renamedSingleFileTitle: nil
                    )
                } catch {
                    // Fallback to copy if source cannot be moved (e.g. read-only volume)
                    let candidate = stdTarget.appendingPathComponent(src.lastPathComponent)
                    guard !fm.fileExists(atPath: candidate.path) else {
                        errorMessage = FolderExplorerError.destinationExists.localizedDescription
                        continue
                    }
                    do {
                        try fm.copyItem(at: src, to: candidate)
                        finalURL = candidate.standardizedFileURL
                    } catch {
                        errorMessage = error.localizedDescription
                        continue
                    }
                }
            }

            importedURLs.append(finalURL)

            // Register in library & trigger background metadata enrichment even if not opened immediately
            let hash = LibraryDatabase.computeFileHash(for: finalURL)
            let stem = finalURL.deletingPathExtension().lastPathComponent
            let record = libraryDatabase.upsertDocument(
                hash: hash,
                path: finalURL.path,
                title: stem,
                author: nil,
                pageCount: 0,
                touchLastOpened: false
            )
            scheduleAutomaticMetadataEnrichmentIfNeeded(for: record, url: finalURL)
        }

        refreshLibrary()
        refreshStandaloneNotebooks()
        refreshFolderTrees()

        if openFirst, let first = importedURLs.first {
            openDocument(at: first, inNewTab: false)
        }

        if !importedURLs.isEmpty {
            let folderName = stdTarget.lastPathComponent
            let msg = importedURLs.count == 1
                ? "‘\(importedURLs[0].lastPathComponent)’ → ‘\(folderName)’ klasörüne eklendi."
                : "\(importedURLs.count) PDF → ‘\(folderName)’ klasörüne eklendi."
            NotificationCenter.default.post(
                name: .grapheShowToast,
                object: nil,
                userInfo: ["message": msg]
            )
        }

        return importedURLs.count
    }

    public func trashFileItem(at url: URL) {
        let stdPath = url.standardizedFileURL.path
        let prefixWithSlash = stdPath + "/"
        func matchesTrashed(_ path: String) -> Bool {
            path == stdPath || path.hasPrefix(prefixWithSlash)
        }

        do {
            try folderExplorer.trashItem(at: url)

            // 1. Remove matching documents from LibraryDatabase (also cleans NotebookAssets PNGs)
            let matchingDocs = libraryDatabase.fetchAllDocuments().filter { matchesTrashed($0.path) }
            for doc in matchingDocs {
                libraryDatabase.removeDocument(hash: doc.hash)
                annotationsByDocument.removeValue(forKey: doc.hash)
                pruneUndoRedo(forDocumentHash: doc.hash)
                if editingMetadataDocument?.hash == doc.hash {
                    editingMetadataDocument = nil
                }
                if activeTab?.activePane.documentHash == doc.hash || notebookSections.first?.documentHash == doc.hash {
                    currentPageOCRResult = nil
                    activeDocumentOCRCount = 0
                    activeDocumentBookmarks = []
                    lastLoadedDocumentMetaHash = nil
                    clearActiveNotebookState()
                }
            }

            // 2. Close or update any open tabs referencing the trashed path
            let tabIDs = tabs.map(\.id)
            for tabID in tabIDs {
                guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { continue }
                let primaryMatches = matchesTrashed(tabs[idx].primaryPane.url.path)
                let secondaryMatches = tabs[idx].secondaryPane.map { matchesTrashed($0.url.path) } ?? false

                if primaryMatches && secondaryMatches {
                    closeTab(id: tabID)
                } else if primaryMatches {
                    if let survivingSecondary = tabs[idx].secondaryPane {
                        let oldPrimary = tabs[idx].primaryPane.document
                        tabs[idx].primaryPane = survivingSecondary
                        tabs[idx].secondaryPane = nil
                        tabs[idx].syncScrollEnabled = false
                        tabs[idx].activeSide = .primary
                        activeSelection = nil
                        evictDocumentCacheIfUnused(oldPrimary)
                    } else {
                        closeTab(id: tabID)
                    }
                } else if secondaryMatches {
                    if let oldSecondary = tabs[idx].secondaryPane?.document {
                        tabs[idx].secondaryPane = nil
                        tabs[idx].syncScrollEnabled = false
                        tabs[idx].activeSide = .primary
                        activeSelection = nil
                        evictDocumentCacheIfUnused(oldSecondary)
                    }
                }
            }

            // 3. Remove trashed entries from recentFiles and watchedFolders
            let oldRecentCount = recentFiles.count
            recentFiles.removeAll { matchesTrashed($0.path) }
            if recentFiles.count != oldRecentCount {
                store.saveRecentFiles(recentFiles)
            }

            let oldWatchedCount = watchedFolders.count
            watchedFolders.removeAll { matchesTrashed($0.path) }
            if watchedFolders.count != oldWatchedCount {
                folderExplorer.saveWatchedFolders(watchedFolders)
            }

            persistSession()
            refreshCurrentPageFootnotes()
            refreshLibrary()
        refreshStandaloneNotebooks()
            refreshFolderTrees()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func migrateOpenStateForPathChange(
        oldPrefix: String,
        newPrefix: String,
        renamedSingleFileTitle: String?
    ) {
        guard oldPrefix != newPrefix else { return }
        let prefixWithSlash = oldPrefix + "/"

        func rewrite(_ path: String) -> (newPath: String, isExact: Bool)? {
            if path == oldPrefix {
                return (newPrefix, true)
            }
            if path.hasPrefix(prefixWithSlash) {
                let suffix = String(path.dropFirst(oldPrefix.count))
                return (newPrefix + suffix, false)
            }
            return nil
        }

        // 1. Update open tabs (primary & secondary panes) in-place without reloading PDFDocument
        for i in tabs.indices {
            if let (newPath, isExact) = rewrite(tabs[i].primaryPane.url.path) {
                let newURL = URL(fileURLWithPath: newPath).standardizedFileURL
                let oldMeta = tabs[i].primaryPane.metadata
                let newTitle = (isExact ? renamedSingleFileTitle : nil) ?? oldMeta.title
                tabs[i].primaryPane.url = newURL
                tabs[i].primaryPane.metadata = DocumentMetadata(
                    url: newURL,
                    title: newTitle,
                    author: oldMeta.author,
                    pageCount: oldMeta.pageCount,
                    outline: oldMeta.outline
                )
            }
            if var sec = tabs[i].secondaryPane, let (newPath, isExact) = rewrite(sec.url.path) {
                let newURL = URL(fileURLWithPath: newPath).standardizedFileURL
                let oldMeta = sec.metadata
                let newTitle = (isExact ? renamedSingleFileTitle : nil) ?? oldMeta.title
                sec.url = newURL
                sec.metadata = DocumentMetadata(
                    url: newURL,
                    title: newTitle,
                    author: oldMeta.author,
                    pageCount: oldMeta.pageCount,
                    outline: oldMeta.outline
                )
                tabs[i].secondaryPane = sec
            }
        }

        // 2. Update recentFiles
        var recentsChanged = false
        for i in recentFiles.indices {
            if let (newPath, isExact) = rewrite(recentFiles[i].path) {
                let newTitle = (isExact ? renamedSingleFileTitle : nil) ?? recentFiles[i].title
                recentFiles[i] = RecentFileItem(
                    path: newPath,
                    title: newTitle,
                    lastOpenedAt: recentFiles[i].lastOpenedAt
                )
                recentsChanged = true
            }
        }
        if recentsChanged {
            store.saveRecentFiles(recentFiles)
        }

        // 3. Migrate ReadingPositionStore keys
        store.migratePath(oldPrefix: oldPrefix, newPrefix: newPrefix)

        // 4. Update watchedFolders if a watched root (or ancestor) was renamed/moved
        var watchedChanged = false
        for i in watchedFolders.indices {
            if let (newPath, _) = rewrite(watchedFolders[i].path) {
                watchedFolders[i] = WatchedRootFolder(path: newPath)
                watchedChanged = true
            }
        }
        if watchedChanged {
            folderExplorer.saveWatchedFolders(watchedFolders)
        }

        // 5. Persist updated session
        persistSession()
    }

    private func evictDocumentCacheIfUnused(_ document: PDFDocument) {
        let targetID = ObjectIdentifier(document)
        for tab in tabs {
            if ObjectIdentifier(tab.primaryPane.document) == targetID { return }
            if let sec = tab.secondaryPane, ObjectIdentifier(sec.document) == targetID { return }
        }
        footnoteResolver.evictCache(for: document)
        autoCropService.evictCache(for: document)
        autoCroppedDocumentIDs.remove(targetID)
    }

    public func revealInFinder(at url: URL) {
        folderExplorer.revealInFinder(at: url)
    }

    // MARK: - Faz 6: OneNote-Style Book Notebook

    public var activeNotebookPage: NotebookPage? {
        guard let id = activeNotebookPageID else { return notebookPages.first }
        return notebookPages.first(where: { $0.id == id }) ?? notebookPages.first
    }

    private func clearActiveNotebookState() {
        notebookSections = []
        notebookPages = []
        activePageContainers = []
        activeNotebookSectionID = nil
        activeNotebookPageID = nil
    }

    // MARK: - Standalone Notebooks (PDF-Free Notes)

    public func refreshStandaloneNotebooks() {
        standaloneNotebooks = libraryDatabase.fetchAllStandaloneNotebooks()
        openStandaloneNotebookIDs.removeAll { openID in
            !standaloneNotebooks.contains(where: { $0.id == openID })
        }
        if let activeID = activeStandaloneNotebookID,
           !standaloneNotebooks.contains(where: { $0.id == activeID }) {
            activeStandaloneNotebookID = openStandaloneNotebookIDs.last
        }
    }

    @discardableResult
    public func createStandaloneNotebook(title: String = "", color: SectionColor? = nil) -> StandaloneNotebook {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Defter \(standaloneNotebooks.count + 1)" : trimmed
        let palette = SectionColor.allCases
        let chosenColor = color ?? palette[standaloneNotebooks.count % palette.count]
        let notebook = StandaloneNotebook(title: finalTitle, color: chosenColor)
        libraryDatabase.upsertStandaloneNotebook(notebook)
        _ = libraryDatabase.ensureDefaultNotebook(forDocumentHash: notebook.storageHash)
        standaloneNotebooks = libraryDatabase.fetchAllStandaloneNotebooks()
        openStandaloneNotebook(id: notebook.id)
        return notebook
    }

    public func openStandaloneNotebook(id: UUID) {
        guard standaloneNotebooks.contains(where: { $0.id == id }) else { return }
        if !openStandaloneNotebookIDs.contains(id) {
            openStandaloneNotebookIDs.append(id)
        }
        activeStandaloneNotebookID = id
        isSnapshotMode = false
        loadNotebookForActiveDocument()
    }

    public func closeStandaloneNotebookTab(id: UUID) {
        openStandaloneNotebookIDs.removeAll { $0 == id }
        if activeStandaloneNotebookID == id {
            if let nextNB = openStandaloneNotebookIDs.last {
                activeStandaloneNotebookID = nextNB
                loadNotebookForActiveDocument()
            } else {
                activeStandaloneNotebookID = nil
                loadNotebookForActiveDocument()
            }
        }
    }

    public func renameStandaloneNotebook(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var nb = standaloneNotebooks.first(where: { $0.id == id }) else { return }
        nb.title = trimmed
        nb.updatedAt = Date()
        libraryDatabase.upsertStandaloneNotebook(nb)
        standaloneNotebooks = libraryDatabase.fetchAllStandaloneNotebooks()
    }

    public func updateStandaloneNotebookColor(id: UUID, color: SectionColor) {
        guard var nb = standaloneNotebooks.first(where: { $0.id == id }) else { return }
        nb.color = color
        nb.updatedAt = Date()
        libraryDatabase.upsertStandaloneNotebook(nb)
        standaloneNotebooks = libraryDatabase.fetchAllStandaloneNotebooks()
    }

    public func deleteStandaloneNotebook(id: UUID) {
        let storageHash = "notebook:\(id.uuidString)"
        libraryDatabase.deleteStandaloneNotebook(id: id)
        pruneUndoRedo(forDocumentHash: storageHash)
        openStandaloneNotebookIDs.removeAll { $0 == id }
        standaloneNotebooks = libraryDatabase.fetchAllStandaloneNotebooks()
        if activeStandaloneNotebookID == id {
            activeStandaloneNotebookID = openStandaloneNotebookIDs.last
            loadNotebookForActiveDocument()
        }
    }

    public func loadNotebookForActiveDocument(selectingPageID: UUID? = nil) {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else {
            clearActiveNotebookState()
            return
        }

        let (defaultSection, defaultPage) = libraryDatabase.ensureDefaultNotebook(forDocumentHash: docHash)
        let sections = libraryDatabase.fetchNotebookSections(forDocumentHash: docHash)
        notebookSections = sections

        if let selectingPageID {
            let allPages = libraryDatabase.fetchAllNotebookPages(forDocumentHash: docHash)
            if let foundPage = allPages.first(where: { $0.id == selectingPageID }) {
                activeNotebookSectionID = foundPage.sectionID
                notebookPages = libraryDatabase.fetchNotebookPages(forSectionID: foundPage.sectionID)
                activeNotebookPageID = foundPage.id
                activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: foundPage.id)
                resolveOverlapsOnActivePage()
                return
            }
        }

        let targetSectionID: UUID
        if let currentSec = activeNotebookSectionID, sections.contains(where: { $0.id == currentSec }) {
            targetSectionID = currentSec
        } else {
            targetSectionID = sections.first?.id ?? defaultSection.id
        }
        activeNotebookSectionID = targetSectionID

        let pages = libraryDatabase.fetchNotebookPages(forSectionID: targetSectionID)
        notebookPages = pages

        let targetPageID: UUID
        if let currentPage = activeNotebookPageID, pages.contains(where: { $0.id == currentPage }) {
            targetPageID = currentPage
        } else {
            targetPageID = pages.first?.id ?? defaultPage.id
        }
        activeNotebookPageID = targetPageID
        activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: targetPageID)
        resolveOverlapsOnActivePage()
    }

    public func selectNotebookSection(id: UUID) {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return }
        activeNotebookSectionID = id
        var pages = libraryDatabase.fetchNotebookPages(forSectionID: id)
        if pages.isEmpty {
            let fresh = NotebookPage(sectionID: id, documentHash: docHash, title: "Sayfa 1", sortOrder: 0)
            libraryDatabase.upsertNotebookPage(fresh)
            pages = [fresh]
        }
        notebookPages = pages
        activeNotebookPageID = pages.first?.id
        if let pageID = activeNotebookPageID {
            activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: pageID)
            resolveOverlapsOnActivePage()
        } else {
            activePageContainers = []
        }
    }

    @discardableResult
    public func addNotebookSection(title: String, color: SectionColor? = nil) -> NotebookSection? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Bölüm \(notebookSections.count + 1)" : trimmed
        let palette = SectionColor.allCases
        let chosenColor = color ?? palette[notebookSections.count % palette.count]
        let section = NotebookSection(
            documentHash: docHash,
            title: finalTitle,
            color: chosenColor,
            sortOrder: notebookSections.count
        )
        libraryDatabase.upsertNotebookSection(section)
        let firstPage = NotebookPage(
            sectionID: section.id,
            documentHash: docHash,
            title: "Sayfa 1",
            sortOrder: 0
        )
        libraryDatabase.upsertNotebookPage(firstPage)
        notebookSections = libraryDatabase.fetchNotebookSections(forDocumentHash: docHash)
        selectNotebookSection(id: section.id)
        return section
    }

    public func updateNotebookSection(_ section: NotebookSection) {
        libraryDatabase.upsertNotebookSection(section)
        notebookSections = libraryDatabase.fetchNotebookSections(forDocumentHash: section.documentHash)
    }

    public func deleteNotebookSection(id: UUID) {
        guard notebookSections.count > 1 else { return }
        let removedPageIDs = Set(libraryDatabase.fetchNotebookPages(forSectionID: id).map(\.id))
        libraryDatabase.deleteNotebookSection(id: id)
        pruneUndoRedo(forPageIDs: removedPageIDs)
        loadNotebookForActiveDocument()
    }

    public func selectNotebookPage(id: UUID) {
        activeNotebookPageID = id
        activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: id)
        resolveOverlapsOnActivePage()
    }

    @discardableResult
    public func addNotebookPage(title: String = "") -> NotebookPage? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        let sectionID = activeNotebookSectionID
            ?? notebookSections.first?.id
            ?? libraryDatabase.ensureDefaultNotebook(forDocumentHash: docHash).section.id
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Sayfa \(notebookPages.count + 1)" : trimmed
        let currentStyle = activeNotebookPage?.paperStyle ?? .dotted
        let page = NotebookPage(
            sectionID: sectionID,
            documentHash: docHash,
            title: finalTitle,
            paperStyle: currentStyle,
            sortOrder: notebookPages.count
        )
        libraryDatabase.upsertNotebookPage(page)
        notebookPages = libraryDatabase.fetchNotebookPages(forSectionID: sectionID)
        selectNotebookPage(id: page.id)
        return page
    }

    public func updateNotebookPage(_ page: NotebookPage) {
        var copy = page
        copy.updatedAt = Date()
        libraryDatabase.upsertNotebookPage(copy)
        notebookPages = libraryDatabase.fetchNotebookPages(forSectionID: copy.sectionID)
    }

    public func deleteNotebookPage(id: UUID) {
        guard notebookPages.count > 1 else { return }
        libraryDatabase.deleteNotebookPage(id: id)
        pruneUndoRedo(forPageIDs: [id])
        if let secID = activeNotebookSectionID {
            selectNotebookSection(id: secID)
        } else {
            loadNotebookForActiveDocument()
        }
    }

    @discardableResult
    public func addTextContainer(at point: CGPoint, width: Double = 320, height: Double = 140) -> NoteContainer? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        if activeNotebookPage?.documentHash != docHash {
            loadNotebookForActiveDocument()
        }
        guard let page = activeNotebookPage, page.documentHash == docHash else { return nil }

        let targetX = max(12, Double(point.x))
        let targetY = resolveNonOverlappingY(
            x: targetX,
            preferredY: max(Self.minContainerTopY, Double(point.y)),
            width: width,
            height: height,
            excludingID: nil,
            in: activePageContainers
        )
        let nextZ = (activePageContainers.map(\.zIndex).max() ?? 0) + 1
        let container = NoteContainer(
            pageID: page.id,
            documentHash: docHash,
            kind: .richText,
            x: targetX,
            y: targetY,
            width: width,
            height: height,
            zIndex: nextZ
        )
        libraryDatabase.upsertNoteContainer(container, pageTitle: page.title)
        activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: page.id)
        recordUndo(.createdContainer(container: container, pageTitle: page.title))
        return container
    }

    @discardableResult
    public func sendQuoteToNotebook(
        quote: String,
        sourcePageIndex: Int,
        color: HighlightColor = .yellow,
        initialNote: String = "",
        forDocumentHash targetHash: String? = nil,
        recordUndoAction: Bool = true
    ) -> NoteContainer? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolvedHash = targetHash ?? activeTab?.activePane.documentHash
        guard let docHash = resolvedHash, !docHash.isEmpty else { return nil }

        let isActiveDoc = (activeTab?.activePane.documentHash == docHash)
        let targetPage: NotebookPage
        let existingContainers: [NoteContainer]

        if isActiveDoc {
            if activeNotebookPage?.documentHash != docHash {
                loadNotebookForActiveDocument()
            }
            guard let page = activeNotebookPage, page.documentHash == docHash else { return nil }
            targetPage = page
            existingContainers = activePageContainers
        } else {
            let (_, defaultPage) = libraryDatabase.ensureDefaultNotebook(forDocumentHash: docHash)
            targetPage = defaultPage
            existingContainers = libraryDatabase.fetchNoteContainers(forPageID: defaultPage.id)
        }

        let preferredY = (existingContainers.map { $0.y + $0.height }.max() ?? 78) + Self.containerSpacing
        let targetY = resolveNonOverlappingY(
            x: 24,
            preferredY: max(96, preferredY),
            width: 340,
            height: 185,
            excludingID: nil,
            in: existingContainers
        )
        let nextZ = (existingContainers.map(\.zIndex).max() ?? 0) + 1
        let container = NoteContainer(
            pageID: targetPage.id,
            documentHash: docHash,
            kind: .pdfQuote,
            x: 24,
            y: targetY,
            width: 340,
            height: 185,
            plainText: initialNote,
            quoteText: trimmed,
            sourcePageIndex: sourcePageIndex,
            accentColor: color,
            zIndex: nextZ
        )
        libraryDatabase.upsertNoteContainer(container, pageTitle: targetPage.title)
        if isActiveDoc {
            activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: targetPage.id)
            rightPanelTab = .notes
            notesSubTab = .notebook
            showRightInspector = true
        }
        if recordUndoAction {
            recordUndo(.createdContainer(container: container, pageTitle: targetPage.title))
        }
        return container
    }

    @discardableResult
    public func addImageContainer(image: NSImage, at point: CGPoint? = nil) -> NoteContainer? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        if activeNotebookPage?.documentHash != docHash {
            loadNotebookForActiveDocument()
        }
        guard let page = activeNotebookPage, page.documentHash == docHash else { return nil }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let assetsDir = appSupport.appendingPathComponent("Graphe/NotebookAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let imageURL = assetsDir.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try pngData.write(to: imageURL, options: .atomic)
        } catch {
            errorMessage = "Görsel kaydedilemedi: \(error.localizedDescription)"
            return nil
        }

        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.33
        let targetW = min(360.0, max(180.0, Double(image.size.width)))
        let targetH = max(120.0, min(420.0, targetW / max(0.3, Double(aspect)) + 34))

        let targetX = point.map { max(12, Double($0.x)) } ?? 24.0
        let rawY = point.map { max(96, Double($0.y)) } ?? ((activePageContainers.map { $0.y + $0.height }.max() ?? 78) + Self.containerSpacing)
        let targetY = resolveNonOverlappingY(
            x: targetX,
            preferredY: max(96, rawY),
            width: targetW,
            height: targetH,
            excludingID: nil,
            in: activePageContainers
        )
        let nextZ = (activePageContainers.map(\.zIndex).max() ?? 0) + 1

        let container = NoteContainer(
            pageID: page.id,
            documentHash: docHash,
            kind: .image,
            x: targetX,
            y: targetY,
            width: targetW,
            height: targetH,
            imagePath: imageURL.path,
            zIndex: nextZ
        )
        libraryDatabase.upsertNoteContainer(container, pageTitle: page.title)
        activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: page.id)
        recordUndo(.createdContainer(container: container, pageTitle: page.title))
        return container
    }

    public func updateNoteContainer(_ container: NoteContainer, recordGeometryUndo: Bool = true) {
        // Eğer kutu aktif sayfaya aitse ama activePageContainers içinde yoksa (veya farklı sayfaya
        // geçildiyse DB'de artık yoksa), az önce silinmiş veya ⌘Z ile geri alınmış demektir;
        // textDidEndEditing / debounce ile veritabanına "zombi" olarak geri yazılmasını engelle.
        if container.pageID == activeNotebookPage?.id {
            guard activePageContainers.contains(where: { $0.id == container.id }) else {
                return
            }
        } else {
            guard libraryDatabase.noteContainerExists(id: container.id) else {
                return
            }
        }
        let previous = activePageContainers.first(where: { $0.id == container.id })
        var copy = container
        copy.x = max(12, copy.x)
        copy.y = max(Self.minContainerTopY, copy.y)
        copy.updatedAt = Date()
        let title = notebookPages.first(where: { $0.id == copy.pageID })?.title
            ?? libraryDatabase.fetchNotebookPageTitle(id: copy.pageID)
            ?? ""
        var didChangeGeometry = false
        if let prev = previous {
            let geometryChanged =
                abs(prev.x - copy.x) > 0.5 ||
                abs(prev.y - copy.y) > 0.5 ||
                abs(prev.width - copy.width) > 0.5 ||
                abs(prev.height - copy.height) > 0.5
            if geometryChanged {
                didChangeGeometry = true
            }
        }
        let beforeByID = (didChangeGeometry && copy.pageID == activeNotebookPage?.id)
            ? Dictionary(uniqueKeysWithValues: activePageContainers.map { ($0.id, $0) })
            : [:]
        libraryDatabase.upsertNoteContainer(copy, pageTitle: title)
        scheduleAutoCloudSync()
        if let idx = activePageContainers.firstIndex(where: { $0.id == copy.id }) {
            activePageContainers[idx] = copy
        }
        var displaced: [(before: NoteContainer, after: NoteContainer)] = []
        if didChangeGeometry && copy.pageID == activeNotebookPage?.id {
            let modified = resolveOverlapsOnActivePage(prioritizingID: copy.id)
            for mod in modified where mod.id != copy.id {
                if let beforeMod = beforeByID[mod.id] {
                    displaced.append((before: beforeMod, after: mod))
                }
            }
        }
        if didChangeGeometry, recordGeometryUndo, let prev = previous {
            recordUndo(.movedOrResizedContainer(before: prev, after: copy, displaced: displaced, pageTitle: title))
        }
    }

    // MARK: - Container Collision & Overlap Resolution

    private static let containerSpacing: Double = 14.0
    private static let minContainerTopY: Double = 92.0

    private static func framesOverlap(
        _ a: (x: Double, y: Double, width: Double, height: Double),
        _ b: (x: Double, y: Double, width: Double, height: Double),
        horizontalGap: Double = 8.0,
        verticalGap: Double = containerSpacing
    ) -> Bool {
        let overlapX = (a.x < b.x + b.width + horizontalGap) && (a.x + a.width + horizontalGap > b.x)
        let overlapY = (a.y < b.y + b.height + verticalGap) && (a.y + a.height + verticalGap > b.y)
        return overlapX && overlapY
    }

    private func resolveNonOverlappingY(
        x: Double,
        preferredY: Double,
        width: Double,
        height: Double,
        excludingID: UUID?,
        in containers: [NoteContainer]
    ) -> Double {
        var candidateY = max(Self.minContainerTopY, preferredY)
        let others = containers
            .filter { $0.id != excludingID }
            .sorted { $0.y < $1.y }

        var didShift = true
        var safetyCounter = 0
        while didShift && safetyCounter < 100 {
            didShift = false
            safetyCounter += 1
            for other in others {
                let candidateFrame = (x: x, y: candidateY, width: width, height: height)
                let otherFrame = (x: other.x, y: other.y, width: other.width, height: other.height)
                if Self.framesOverlap(candidateFrame, otherFrame) {
                    candidateY = other.y + other.height + Self.containerSpacing
                    didShift = true
                }
            }
        }
        return candidateY
    }

    /// Ensures no two containers on the active page overlap by pushing lower/colliding containers down.
    /// When `prioritizingID` is provided (e.g., user just dragged or resized a box), that box keeps its
    /// position and any box it collides with is pushed below it (cascading downwards).
    @discardableResult
    public func resolveOverlapsOnActivePage(prioritizingID: UUID? = nil) -> [NoteContainer] {
        guard activePageContainers.count > 1 else { return [] }
        let pageTitle = activeNotebookPage?.title ?? ""

        // Sort top-to-bottom, but if prioritizingID collides with another box, keep prioritizingID anchored
        // and push colliding boxes down below it.
        var ordered = activePageContainers.sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) > 0.5 {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }

        if let anchorID = prioritizingID,
           let anchorIdx = ordered.firstIndex(where: { $0.id == anchorID }) {
            let anchor = ordered.remove(at: anchorIdx)
            ordered.insert(anchor, at: 0)
        }

        var placed: [NoteContainer] = []
        var modified: [NoteContainer] = []

        for var item in ordered {
            var newY = max(Self.minContainerTopY, item.y)
            if item.id != prioritizingID {
                newY = resolveNonOverlappingY(
                    x: item.x,
                    preferredY: newY,
                    width: item.width,
                    height: item.height,
                    excludingID: item.id,
                    in: placed
                )
            }
            if abs(newY - item.y) > 0.5 {
                item.y = newY
                item.updatedAt = Date()
                modified.append(item)
            }
            placed.append(item)
        }

        guard !modified.isEmpty else { return [] }
        for mod in modified {
            libraryDatabase.upsertNoteContainer(mod, pageTitle: pageTitle)
            if let idx = activePageContainers.firstIndex(where: { $0.id == mod.id }) {
                activePageContainers[idx] = mod
            }
        }
        return modified
    }

    public func bringContainerToFront(id: UUID) {
        guard let idx = activePageContainers.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = activePageContainers.map(\.zIndex).max() ?? 0
        if activePageContainers[idx].zIndex <= maxZ {
            var copy = activePageContainers[idx]
            copy.zIndex = maxZ + 1
            updateNoteContainer(copy)
            activePageContainers.sort { $0.zIndex < $1.zIndex }
        }
    }

    public func deleteNoteContainer(id: UUID, recordUndo: Bool = true) {
        let existing = activePageContainers.first(where: { $0.id == id })
        if let existing, recordUndo {
            let title = notebookPages.first(where: { $0.id == existing.pageID })?.title
                ?? libraryDatabase.fetchNotebookPageTitle(id: existing.pageID)
                ?? ""
            self.recordUndo(.deletedContainer(container: existing, pageTitle: title))
        }
        libraryDatabase.deleteNoteContainer(id: id)
        activePageContainers.removeAll { $0.id == id }
        if !recordUndo, let imgPath = existing?.imagePath, !imgPath.isEmpty {
            try? FileManager.default.removeItem(atPath: imgPath)
        }
    }

    public func exportActiveNotebookMarkdown() -> String? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        let docRecord: LibraryDocumentRecord
        if let nb = activeStandaloneNotebook {
            docRecord = LibraryDocumentRecord(
                hash: nb.storageHash,
                path: "",
                title: nb.title,
                author: nil,
                pageCount: 0
            )
        } else if let pane = activeTab?.activePane {
            docRecord = libraryDatabase.fetchDocument(hash: docHash)
                ?? LibraryDocumentRecord(
                    hash: docHash,
                    path: pane.url.path,
                    title: pane.metadata.title,
                    author: pane.metadata.author,
                    pageCount: pane.metadata.pageCount
                )
        } else {
            return nil
        }
        let sections = libraryDatabase.fetchNotebookSections(forDocumentHash: docHash)
        var pagesBySection: [UUID: [NotebookPage]] = [:]
        var containersByPage: [UUID: [NoteContainer]] = [:]
        for sec in sections {
            let pages = libraryDatabase.fetchNotebookPages(forSectionID: sec.id)
            pagesBySection[sec.id] = pages
            for p in pages {
                containersByPage[p.id] = libraryDatabase.fetchNoteContainers(forPageID: p.id)
            }
        }
        return markdownExporter.exportNotebook(
            document: docRecord,
            sections: sections,
            pagesBySection: pagesBySection,
            containersByPage: containersByPage
        )
    }

    public func buildActiveLatexArtifact(scope: LatexExportScope = .fullNotebook) -> LatexBuildArtifact? {
        guard let docHash = activeNotebookOwnerHash, !docHash.isEmpty else { return nil }
        let docRecord: LibraryDocumentRecord
        let fallbackAnnotations: [AnnotationItem]
        if let nb = activeStandaloneNotebook {
            docRecord = LibraryDocumentRecord(
                hash: nb.storageHash,
                path: "",
                title: nb.title,
                author: nil,
                pageCount: 0
            )
            fallbackAnnotations = []
        } else if let pane = activeTab?.activePane {
            docRecord = libraryDatabase.fetchDocument(hash: docHash)
                ?? LibraryDocumentRecord(
                    hash: docHash,
                    path: pane.url.path,
                    title: pane.metadata.title,
                    author: pane.metadata.author,
                    pageCount: pane.metadata.pageCount
                )
            fallbackAnnotations = annotationsByDocument[docHash]
                ?? libraryDatabase.fetchAnnotations(forDocumentHash: docHash)
        } else {
            return nil
        }
        let sections = libraryDatabase.fetchNotebookSections(forDocumentHash: docHash)
        var pagesBySection: [UUID: [NotebookPage]] = [:]
        var containersByPage: [UUID: [NoteContainer]] = [:]
        for sec in sections {
            let pages = libraryDatabase.fetchNotebookPages(forSectionID: sec.id)
            pagesBySection[sec.id] = pages
            for p in pages {
                containersByPage[p.id] = libraryDatabase.fetchNoteContainers(forPageID: p.id)
            }
        }

        return latexExporter.generateLatex(
            document: docRecord,
            sections: sections,
            pagesBySection: pagesBySection,
            containersByPage: containersByPage,
            fallbackAnnotations: fallbackAnnotations,
            scope: scope,
            preferredFontFamily: notebookFontFamily == NotebookFontCatalog.systemKey ? nil : notebookFontFamily
        )
    }

    public func exportActiveNotesLatexPDF(to url: URL, scope: LatexExportScope = .fullNotebook) async throws {
        guard let artifact = buildActiveLatexArtifact(scope: scope) else {
            throw LatexExportError.emptyDocument
        }
        isExportingLatexPDF = true
        defer { isExportingLatexPDF = false }
        try await latexExporter.compileToPDF(artifact: artifact, outputPDFURL: url)
    }

    public func toggleSnapshotMode() {
        guard activeTab != nil else {
            isSnapshotMode = false
            return
        }
        isSnapshotMode.toggle()
    }

    public func toggleReadingRuler() {
        isReadingRulerEnabled.toggle()
    }

    /// Two-way PDF -> OneNote link: clicking a highlight in the PDF jumps straight to its linked card in the notebook.
    public func focusNotebookCard(for annotation: AnnotationItem) {
        let docHash = annotation.documentHash
        guard !docHash.isEmpty else { return }

        let sections = libraryDatabase.fetchNotebookSections(forDocumentHash: docHash)
        let normQuote = annotation.quote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var matchedLocation: (sectionID: UUID, pageID: UUID, containerID: UUID)?
        for sec in sections {
            let pages = libraryDatabase.fetchNotebookPages(forSectionID: sec.id)
            for page in pages {
                let containers = libraryDatabase.fetchNoteContainers(forPageID: page.id)
                if let hit = containers.first(where: { c in
                    guard c.kind == .pdfQuote, c.sourcePageIndex == annotation.pageIndex else { return false }
                    let cq = (c.quoteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if cq.isEmpty || normQuote.isEmpty { return false }
                    return cq == normQuote || cq.contains(normQuote) || normQuote.contains(cq)
                }) {
                    matchedLocation = (sec.id, page.id, hit.id)
                    break
                }
            }
            if matchedLocation != nil { break }
        }

        rightPanelTab = .notes
        showRightInspector = true

        if let loc = matchedLocation {
            notesSubTab = .notebook
            if activeNotebookSectionID != loc.sectionID {
                selectNotebookSection(id: loc.sectionID)
            }
            if activeNotebookPageID != loc.pageID {
                selectNotebookPage(id: loc.pageID)
            }
            highlightedContainerID = loc.containerID
            highlightPulseTask?.cancel()
            highlightPulseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                if self?.highlightedContainerID == loc.containerID {
                    self?.highlightedContainerID = nil
                }
            }
        } else {
            notesSubTab = .highlights
        }
    }

    public func handleCapturedSnapshot(_ image: NSImage) {
        isSnapshotMode = false
        // Copy crisp Retina PNG + TIFF to clipboard so every macOS app can paste it cleanly
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiffData = image.tiffRepresentation {
            pb.setData(tiffData, forType: .tiff)
            if let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                pb.setData(pngData, forType: .png)
            }
        } else {
            pb.writeObjects([image])
        }

        // Add directly to the active book's OneNote notebook and reveal the notebook pane
        _ = addImageContainer(image: image)
        rightPanelTab = .notes
        notesSubTab = .notebook
        showRightInspector = true

        NotificationCenter.default.post(
            name: .grapheShowToast,
            object: nil,
            userInfo: ["message": "Bölge kırpıldı, deftere eklendi ve panoya kopyalandı."]
        )
    }

    public func importFolderToLibrary(folderURL: URL) {
        let db = libraryDatabase
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let alreadyIndexedPaths = db.fetchIndexedPaths()
            var pdfURLs: [URL] = []
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "pdf" {
                    let std = fileURL.standardizedFileURL
                    if !alreadyIndexedPaths.contains(std.path) {
                        pdfURLs.append(std)
                    }
                }
            }

            guard !pdfURLs.isEmpty else { return }

            var processedSinceRefresh = 0
            for url in pdfURLs {
                let hash = LibraryDatabase.computeFileHash(for: url)
                let pdf = PDFDocument(url: url)
                let title = (pdf?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ?? url.deletingPathExtension().lastPathComponent
                let author = pdf?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
                let pageCount = pdf?.pageCount ?? 0

                db.upsertDocument(
                    hash: hash,
                    path: url.path,
                    title: title,
                    author: author,
                    pageCount: pageCount,
                    touchLastOpened: false
                )

                if !db.isDocumentIndexed(hash: hash), let pdf {
                    var pages: [(pageIndex: Int, text: String)] = []
                    pages.reserveCapacity(pdf.pageCount)
                    for i in 0..<pdf.pageCount {
                        if let text = pdf.page(at: i)?.string, !text.isEmpty {
                            pages.append((i, text))
                        }
                    }
                    db.indexDocumentPages(hash: hash, pages: pages)
                }

                processedSinceRefresh += 1
                if processedSinceRefresh >= 10 {
                    processedSinceRefresh = 0
                    Task { @MainActor [weak self] in
                        self?.refreshLibrary()
                    }
                }
            }

            if processedSinceRefresh > 0 {
                Task { @MainActor [weak self] in
                    self?.refreshLibrary()
                }
            }
        }
    }

    public func exportActiveDocumentMarkdown() -> String? {
        guard let pane = activeTab?.activePane, !pane.documentHash.isEmpty else {
            return nil
        }
        let docRecord = libraryDatabase.fetchDocument(hash: pane.documentHash)
            ?? LibraryDocumentRecord(
                hash: pane.documentHash,
                path: pane.url.path,
                title: pane.metadata.title,
                author: pane.metadata.author,
                pageCount: pane.metadata.pageCount
            )
        let items = annotations(forDocumentHash: pane.documentHash)
        return markdownExporter.export(document: docRecord, annotations: items)
    }

    private func reloadAnnotations(forDocumentHash hash: String) {
        annotationsByDocument[hash] = libraryDatabase.fetchAnnotations(forDocumentHash: hash)
        scheduleAutoCloudSync()
    }

    public func scheduleAutoCloudSync() {
        guard !ProcessInfo.processInfo.processName.contains("GrapheSelfTest"),
              !watchedFolders.isEmpty else { return }
        autoCloudSyncTask?.cancel()
        autoCloudSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.syncWatchedFoldersWithCloud(showToast: false)
        }
    }

    private func scheduleBackgroundDocumentPrep(document: PDFDocument, hash: String, url: URL) {
        let needsFTSIndex = !libraryDatabase.isDocumentIndexed(hash: hash) && !indexingDocumentHashes.contains(hash)
        if needsFTSIndex {
            indexingDocumentHashes.insert(hash)
        }
        let db = libraryDatabase
        let resolver = footnoteResolver
        let docKey = ObjectIdentifier(document)

        // Delay slightly so the window and first page paint at 120fps before background disk/CPU work begins;
        // serialize on backgroundDocPrepQueue so restoring multiple tabs never opens N duplicate PDFDocuments at once.
        backgroundDocPrepQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if let bgDoc = PDFDocument(url: url) {
                if needsFTSIndex && !db.isDocumentIndexed(hash: hash) {
                    var pages: [(pageIndex: Int, text: String)] = []
                    pages.reserveCapacity(bgDoc.pageCount)
                    for idx in 0..<bgDoc.pageCount {
                        if let text = bgDoc.page(at: idx)?.string, !text.isEmpty {
                            pages.append((idx, text))
                        }
                    }
                    db.indexDocumentPages(hash: hash, pages: pages)
                }
                resolver.prewarmNotesIndex(forDocumentKey: docKey, usingBackgroundDocument: bgDoc)
            }
            if needsFTSIndex {
                Task { @MainActor [weak self] in
                    self?.indexingDocumentHashes.remove(hash)
                    self?.refreshLibrary()
                }
            }
        }
    }

    private func makePane(for url: URL, fallbackPageIndex: Int? = nil, deferLibraryRefresh: Bool = false) throws -> ReaderPaneState {
        let (document, metadata) = try engine.loadDocument(from: url)
        let hash = LibraryDatabase.computeFileHash(for: url)
        let record = libraryDatabase.upsertDocument(
            hash: hash,
            path: url.path,
            title: metadata.title,
            author: metadata.author,
            pageCount: metadata.pageCount,
            touchLastOpened: true
        )
        let resolvedMetadata = DocumentMetadata(
            url: metadata.url,
            title: record.title,
            author: record.author ?? metadata.author,
            pageCount: metadata.pageCount,
            outline: metadata.outline
        )
        reloadAnnotations(forDocumentHash: hash)
        if !deferLibraryRefresh {
            refreshLibrary()
            refreshStandaloneNotebooks()
        }
        scheduleBackgroundDocumentPrep(document: document, hash: hash, url: url)
        scheduleAutomaticMetadataEnrichmentIfNeeded(for: record, url: url)

        let saved = store.loadPosition(for: url)
        let resolvedPage = saved?.pageIndex ?? fallbackPageIndex ?? 0
        let clampedPage = max(0, min(resolvedPage, max(0, resolvedMetadata.pageCount - 1)))
        return ReaderPaneState(
            url: url,
            documentHash: hash,
            metadata: resolvedMetadata,
            document: document,
            currentPageIndex: clampedPage,
            scaleFactor: saved?.scaleFactor ?? 1.0,
            shouldAutoFitWidth: saved == nil
        )
    }

    private func scheduleAutomaticMetadataEnrichmentIfNeeded(for record: LibraryDocumentRecord, url: URL) {
        guard !ProcessInfo.processInfo.processName.contains("GrapheSelfTest") else { return }
        guard !autoEnrichedMetadataHashes.contains(record.hash) else { return }

        let hasYear = record.year != nil
        let hasPublisher = !(record.publisher?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasISBN = !(record.isbn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAuthor = !(record.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasYear && hasPublisher && hasISBN && hasAuthor {
            return
        }

        autoEnrichedMetadataHashes.insert(record.hash)
        let service = metadataService
        let db = libraryDatabase
        let hash = record.hash

        Task.detached(priority: .utility) { [weak self] in
            // 1) Local PDF inspection (title page / colophon / ISBN / DOI / filename)
            let localDraft = service.extractOfflineMetadata(from: url, existing: record)

            let needsOnline = localDraft.year == nil
                || localDraft.publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || localDraft.isbn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || localDraft.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            var finalDraft = localDraft
            if needsOnline, let onlineDraft = try? await service.enrichOnline(draft: localDraft) {
                // Keep any existing user-populated fields intact; fill only what was missing
                let mergedTitle = (record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || record.title == url.deletingPathExtension().lastPathComponent)
                    ? onlineDraft.title
                    : record.title
                let mergedAuthor = hasAuthor ? (record.author ?? onlineDraft.author) : onlineDraft.author
                let mergedYear = record.year ?? onlineDraft.year
                let mergedPublisher = hasPublisher ? (record.publisher ?? onlineDraft.publisher) : onlineDraft.publisher
                let mergedISBN = hasISBN ? (record.isbn ?? onlineDraft.isbn) : onlineDraft.isbn
                let existingDOI = record.doi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let mergedDOI = existingDOI.isEmpty ? onlineDraft.doi : existingDOI

                finalDraft = BookMetadataDraft(
                    title: mergedTitle,
                    author: mergedAuthor,
                    year: mergedYear,
                    publisher: mergedPublisher,
                    isbn: mergedISBN,
                    doi: mergedDOI
                )
            }

            let changed = finalDraft.title != record.title
                || finalDraft.author != (record.author ?? "")
                || finalDraft.year != record.year
                || finalDraft.publisher != (record.publisher ?? "")
                || finalDraft.isbn != (record.isbn ?? "")
                || finalDraft.doi != (record.doi ?? "")

            guard changed else { return }

            let cleanAuthor = finalDraft.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPub = finalDraft.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanISBN = finalDraft.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDOI = finalDraft.doi.trimmingCharacters(in: .whitespacesAndNewlines)

            db.updateDocumentMetadata(
                hash: hash,
                title: finalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? record.title : finalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                author: cleanAuthor.isEmpty ? nil : cleanAuthor,
                year: finalDraft.year,
                publisher: cleanPub.isEmpty ? nil : cleanPub,
                isbn: cleanISBN.isEmpty ? nil : cleanISBN,
                doi: cleanDOI.isEmpty ? nil : cleanDOI
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshLibrary()
            }
        }
    }

    private func recordRecent(url: URL, title: String) {
        recentFiles.removeAll { $0.path == url.path }
        recentFiles.insert(RecentFileItem(path: url.path, title: title), at: 0)
        store.saveRecentFiles(recentFiles)
    }

    private func schedulePersistSession() {
        persistSessionTask?.cancel()
        persistSessionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
    }

    public func flushPendingPersistence() {
        persistSession()
        store.flush()
        for root in watchedFolders {
            _ = try? cloudSyncService.synchronize(folder: root.url, database: libraryDatabase)
        }
    }

    public func syncWatchedFoldersWithCloud(showToast: Bool = true) {
        let folders = watchedFolders
        guard !folders.isEmpty else { return }
        let db = libraryDatabase
        let sync = cloudSyncService
        Task.detached(priority: .utility) { [weak self] in
            var syncedAny = false
            for root in folders {
                if (try? sync.synchronize(folder: root.url, database: db)) != nil {
                    syncedAny = true
                }
            }
            guard syncedAny else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshLibrary()
                self.refreshStandaloneNotebooks()
                self.refreshFolderTrees()
                if showToast {
                    NotificationCenter.default.post(
                        name: .grapheShowToast,
                        object: nil,
                        userInfo: ["message": "Klasör & iCloud verileri eşitlendi."]
                    )
                }
            }
        }
    }

    private func persistSession() {
        persistSessionTask?.cancel()
        persistSessionTask = nil
        let savedTabs = tabs.map { tab in
            SavedTabSession(
                primaryPath: tab.primaryPane.url.path,
                secondaryPath: tab.secondaryPane?.url.path,
                primaryPageIndex: tab.primaryPane.currentPageIndex,
                secondaryPageIndex: tab.secondaryPane?.currentPageIndex,
                syncScrollEnabled: tab.syncScrollEnabled
            )
        }
        let session = SavedWorkspaceSession(
            tabs: savedTabs,
            activeTabIndex: activeTabIndex ?? 0,
            showLeftSidebar: showLeftSidebar,
            showRightInspector: showRightInspector
        )
        store.saveSession(session)
    }

    private func restoreSavedSession() {
        guard let session = store.loadSession() else { return }
        showLeftSidebar = session.showLeftSidebar
        showRightInspector = session.showRightInspector

        var restoredTabs: [TabSession] = []
        for savedTab in session.tabs {
            let primaryURL = URL(fileURLWithPath: savedTab.primaryPath).standardizedFileURL
            guard let primaryPane = try? makePane(
                for: primaryURL,
                fallbackPageIndex: savedTab.primaryPageIndex,
                deferLibraryRefresh: true
            ) else {
                continue
            }

            var secondaryPane: ReaderPaneState?
            if let secondaryPath = savedTab.secondaryPath {
                let secondaryURL = URL(fileURLWithPath: secondaryPath).standardizedFileURL
                if secondaryURL == primaryURL {
                    secondaryPane = ReaderPaneState(
                        url: primaryPane.url,
                        documentHash: primaryPane.documentHash,
                        metadata: primaryPane.metadata,
                        document: primaryPane.document,
                        currentPageIndex: savedTab.secondaryPageIndex ?? primaryPane.currentPageIndex,
                        scaleFactor: primaryPane.scaleFactor,
                        shouldAutoFitWidth: primaryPane.shouldAutoFitWidth
                    )
                } else {
                    secondaryPane = try? makePane(
                        for: secondaryURL,
                        fallbackPageIndex: savedTab.secondaryPageIndex,
                        deferLibraryRefresh: true
                    )
                }
            }

            restoredTabs.append(
                TabSession(
                    primaryPane: primaryPane,
                    secondaryPane: secondaryPane,
                    syncScrollEnabled: secondaryPane != nil ? savedTab.syncScrollEnabled : false
                )
            )
        }

        if !restoredTabs.isEmpty {
            refreshLibrary()
            refreshStandaloneNotebooks()
        }

        tabs = restoredTabs
        if restoredTabs.indices.contains(session.activeTabIndex) {
            activeTabID = restoredTabs[session.activeTabIndex].id
        } else {
            activeTabID = restoredTabs.first?.id
        }
    }

    // MARK: - Undo / Redo (⌘Z / ⇧⌘Z)

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func recordUndo(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > maxUndoDepth {
            let overflowCount = undoStack.count - maxUndoDepth
            let evicted = Array(undoStack.prefix(overflowCount))
            undoStack.removeFirst(overflowCount)
            for item in evicted {
                cleanupOrphanedAssets(for: item)
            }
        }
        let droppedRedo = redoStack
        redoStack.removeAll()
        for item in droppedRedo {
            cleanupOrphanedAssets(for: item)
        }
    }

    private func cleanupOrphanedAssets(for action: UndoableAction) {
        let candidateContainer: NoteContainer?
        switch action {
        case .deletedContainer(let container, _):
            candidateContainer = container
        case .createdContainer(let container, _):
            candidateContainer = container
        case .createdHighlight(_, let linkedContainer, _):
            candidateContainer = linkedContainer
        case .deletedAnnotation, .movedOrResizedContainer:
            candidateContainer = nil
        }
        if let container = candidateContainer,
           let imgPath = container.imagePath,
           !imgPath.isEmpty,
           !libraryDatabase.noteContainerExists(id: container.id) {
            try? FileManager.default.removeItem(atPath: imgPath)
        }
    }

    private func pruneUndoRedo(forDocumentHash docHash: String) {
        func matches(_ action: UndoableAction) -> Bool {
            switch action {
            case .createdHighlight(let ann, let linked, _):
                return ann.documentHash == docHash || linked?.documentHash == docHash
            case .deletedAnnotation(let ann):
                return ann.documentHash == docHash
            case .createdContainer(let c, _), .deletedContainer(let c, _):
                return c.documentHash == docHash
            case .movedOrResizedContainer(let before, _, _, _):
                return before.documentHash == docHash
            }
        }
        let droppedUndo = undoStack.filter(matches)
        let droppedRedo = redoStack.filter(matches)
        undoStack.removeAll(where: matches)
        redoStack.removeAll(where: matches)
        for item in droppedUndo + droppedRedo {
            cleanupOrphanedAssets(for: item)
        }
    }

    private func pruneUndoRedo(forPageIDs pageIDs: Set<UUID>) {
        guard !pageIDs.isEmpty else { return }
        func matches(_ action: UndoableAction) -> Bool {
            switch action {
            case .createdHighlight(_, let linked, _):
                return linked.map { pageIDs.contains($0.pageID) } ?? false
            case .deletedAnnotation:
                return false
            case .createdContainer(let c, _), .deletedContainer(let c, _):
                return pageIDs.contains(c.pageID)
            case .movedOrResizedContainer(let before, _, _, _):
                return pageIDs.contains(before.pageID)
            }
        }
        let droppedUndo = undoStack.filter(matches)
        let droppedRedo = redoStack.filter(matches)
        undoStack.removeAll(where: matches)
        redoStack.removeAll(where: matches)
        for item in droppedUndo + droppedRedo {
            cleanupOrphanedAssets(for: item)
        }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let action = undoStack.popLast() else { return false }
        switch action {
        case .createdHighlight(let annotation, let linkedContainer, _):
            libraryDatabase.deleteAnnotation(id: annotation.id)
            reloadAnnotations(forDocumentHash: annotation.documentHash)
            refreshTagIndex()
            if let container = linkedContainer {
                libraryDatabase.deleteNoteContainer(id: container.id)
                activePageContainers.removeAll { $0.id == container.id }
            }

        case .deletedAnnotation(let annotation):
            guard libraryDatabase.documentExists(hash: annotation.documentHash) else {
                return undo()
            }
            libraryDatabase.upsertAnnotation(annotation)
            reloadAnnotations(forDocumentHash: annotation.documentHash)
            refreshTagIndex()

        case .createdContainer(let container, _):
            libraryDatabase.deleteNoteContainer(id: container.id)
            activePageContainers.removeAll { $0.id == container.id }

        case .deletedContainer(let container, let pageTitle):
            guard libraryDatabase.documentExists(hash: container.documentHash),
                  libraryDatabase.notebookPageExists(id: container.pageID) else {
                cleanupOrphanedAssets(for: action)
                return undo()
            }
            libraryDatabase.upsertNoteContainer(container, pageTitle: pageTitle)
            if activeNotebookPage?.id == container.pageID {
                activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: container.pageID)
            }

        case .movedOrResizedContainer(let before, _, let displaced, let pageTitle):
            guard libraryDatabase.documentExists(hash: before.documentHash),
                  libraryDatabase.notebookPageExists(id: before.pageID) else {
                return undo()
            }
            libraryDatabase.upsertNoteContainer(before, pageTitle: pageTitle)
            if let idx = activePageContainers.firstIndex(where: { $0.id == before.id }) {
                activePageContainers[idx] = before
            }
            for item in displaced {
                libraryDatabase.upsertNoteContainer(item.before, pageTitle: pageTitle)
                if let idx = activePageContainers.firstIndex(where: { $0.id == item.before.id }) {
                    activePageContainers[idx] = item.before
                }
            }
        }
        redoStack.append(action)
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let action = redoStack.popLast() else { return false }
        switch action {
        case .createdHighlight(let annotation, let linkedContainer, let pageTitle):
            guard libraryDatabase.documentExists(hash: annotation.documentHash) else {
                cleanupOrphanedAssets(for: action)
                return redo()
            }
            libraryDatabase.upsertAnnotation(annotation)
            reloadAnnotations(forDocumentHash: annotation.documentHash)
            refreshTagIndex()
            if let container = linkedContainer,
               libraryDatabase.notebookPageExists(id: container.pageID) {
                libraryDatabase.upsertNoteContainer(container, pageTitle: pageTitle)
                if activeNotebookPage?.id == container.pageID {
                    activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: container.pageID)
                }
            }

        case .deletedAnnotation(let annotation):
            libraryDatabase.deleteAnnotation(id: annotation.id)
            reloadAnnotations(forDocumentHash: annotation.documentHash)
            refreshTagIndex()

        case .createdContainer(let container, let pageTitle):
            guard libraryDatabase.documentExists(hash: container.documentHash),
                  libraryDatabase.notebookPageExists(id: container.pageID) else {
                cleanupOrphanedAssets(for: action)
                return redo()
            }
            libraryDatabase.upsertNoteContainer(container, pageTitle: pageTitle)
            if activeNotebookPage?.id == container.pageID {
                activePageContainers = libraryDatabase.fetchNoteContainers(forPageID: container.pageID)
            }

        case .deletedContainer(let container, _):
            libraryDatabase.deleteNoteContainer(id: container.id)
            activePageContainers.removeAll { $0.id == container.id }

        case .movedOrResizedContainer(_, let after, let displaced, let pageTitle):
            guard libraryDatabase.documentExists(hash: after.documentHash),
                  libraryDatabase.notebookPageExists(id: after.pageID) else {
                return redo()
            }
            libraryDatabase.upsertNoteContainer(after, pageTitle: pageTitle)
            if let idx = activePageContainers.firstIndex(where: { $0.id == after.id }) {
                activePageContainers[idx] = after
            }
            for item in displaced {
                libraryDatabase.upsertNoteContainer(item.after, pageTitle: pageTitle)
                if let idx = activePageContainers.firstIndex(where: { $0.id == item.after.id }) {
                    activePageContainers[idx] = item.after
                }
            }
        }
        undoStack.append(action)
        if !globalSearchQuery.isEmpty {
            performGlobalSearch(globalSearchQuery)
        }
        return true
    }
}
#endif
