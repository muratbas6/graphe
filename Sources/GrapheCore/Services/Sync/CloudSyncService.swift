import Foundation

public struct CloudSyncSnapshot: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var updatedAt: Date
    public var documents: [SyncedDocumentMeta]
    public var annotations: [AnnotationItem]
    public var bookmarks: [BookmarkItem]
    public var standaloneNotebooks: [StandaloneNotebook]
    public var sections: [NotebookSection]
    public var pages: [NotebookPage]
    public var containers: [SyncedNoteContainer]

    public init(
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        documents: [SyncedDocumentMeta] = [],
        annotations: [AnnotationItem] = [],
        bookmarks: [BookmarkItem] = [],
        standaloneNotebooks: [StandaloneNotebook] = [],
        sections: [NotebookSection] = [],
        pages: [NotebookPage] = [],
        containers: [SyncedNoteContainer] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.documents = documents
        self.annotations = annotations
        self.bookmarks = bookmarks
        self.standaloneNotebooks = standaloneNotebooks
        self.sections = sections
        self.pages = pages
        self.containers = containers
    }
}

public struct SyncedDocumentMeta: Codable, Hashable, Sendable {
    public let hash: String
    public var relativePath: String?
    public var title: String
    public var author: String?
    public var year: Int?
    public var publisher: String?
    public var isbn: String?
    public var doi: String?
    public var pageCount: Int
    public var tags: [String]
    public var lastOpenedAt: Date
    public var addedAt: Date
}

public struct SyncedNoteContainer: Codable, Hashable, Sendable {
    public var container: NoteContainer
    /// Relative filename inside `.graphe-sync/Assets/` when `container.imagePath != nil`
    public var assetFilename: String?
}

public struct CloudSyncResult: Sendable {
    public let discoveredPDFCount: Int
    public let mergedAnnotations: Int
    public let mergedNotebookCount: Int
    public let syncedAt: Date
}

/// Coordinates bidirectional synchronization of PDFs, highlights, bookmarks, book notebooks,
/// and standalone notebooks through a shared iCloud Drive (or local) folder.
public final class CloudSyncService: @unchecked Sendable {
    /// Non-hidden folder name so iOS iCloud Drive / Files.app syncs it immediately across devices.
    public static let syncDirectoryName = "GrapheSync"
    public static let legacyHiddenSyncDirectoryName = ".graphe-sync"
    public static let syncSnapshotFilename = "graphe_sync_v1.json"
    public static let syncAssetsDirName = "Assets"

    private let bookmarkDefaultsKey = "graphe.cloudSync.folderBookmark.v1"
    private let pathFallbackDefaultsKey = "graphe.cloudSync.folderPath.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Security-Scoped Folder Bookmark Persistence

    public func saveSyncFolder(_ url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkDefaultsKey)
        }
        defaults.set(url.standardizedFileURL.path, forKey: pathFallbackDefaultsKey)
    }

    public func clearSyncFolder() {
        defaults.removeObject(forKey: bookmarkDefaultsKey)
        defaults.removeObject(forKey: pathFallbackDefaultsKey)
    }

    public func resolveSavedSyncFolder() -> URL? {
        if let data = defaults.data(forKey: bookmarkDefaultsKey) {
            var isStale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    try? saveSyncFolder(resolved)
                }
                return resolved
            }
        }
        if let path = defaults.string(forKey: pathFallbackDefaultsKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Bidirectional Merge & Export

    @discardableResult
    public func synchronize(
        folder syncRootURL: URL,
        database: LibraryDatabase,
        localAssetsDirectory: URL? = nil
    ) throws -> CloudSyncResult {
        let didStart = syncRootURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { syncRootURL.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        let rootStd = syncRootURL.standardizedFileURL
        let syncMetaDir = rootStd.appendingPathComponent(Self.syncDirectoryName, isDirectory: true)
        let syncAssetsDir = syncMetaDir.appendingPathComponent(Self.syncAssetsDirName, isDirectory: true)
        let snapshotURL = syncMetaDir.appendingPathComponent(Self.syncSnapshotFilename)
        let localAssetsDir = localAssetsDirectory ?? BackupService.defaultAssetsDirectory()

        try fm.createDirectory(at: syncAssetsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: localAssetsDir, withIntermediateDirectories: true)

        // 1. Trigger iCloud download for any unmaterialized `.icloud` placeholders & discover PDFs
        let pdfFiles = discoverAndRequestDownloadOfPDFs(in: rootStd, fileManager: fm)
        var hashByRelPath: [String: String] = [:]
        var relPathByHash: [String: String] = [:]

        for pdfURL in pdfFiles {
            let hash = LibraryDatabase.computeFileHash(for: pdfURL)
            let rel = relativePath(of: pdfURL, from: rootStd)
            hashByRelPath[rel] = hash
            relPathByHash[hash] = rel

            let existing = database.fetchDocument(hash: hash)
            let stem = pdfURL.deletingPathExtension().lastPathComponent
            _ = database.upsertDocument(
                hash: hash,
                path: pdfURL.path,
                title: existing?.title ?? stem,
                author: existing?.author,
                pageCount: existing?.pageCount ?? 0,
                touchLastOpened: false
            )
            if let existing, existing.path != pdfURL.path {
                database.updateDocumentPaths(oldPrefix: existing.path, newPrefix: pdfURL.path)
            }
        }

        // 2. Read remote snapshot if present (also migrate from legacy `.graphe-sync` if present)
        let legacySnapshotURL = rootStd
            .appendingPathComponent(Self.legacyHiddenSyncDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.syncSnapshotFilename)
        if let legacyRemote = readCoordinatedSnapshot(at: legacySnapshotURL, fileManager: fm) {
            mergeRemoteSnapshot(
                legacyRemote,
                into: database,
                syncRoot: rootStd,
                syncAssetsDir: syncAssetsDir,
                localAssetsDir: localAssetsDir,
                fileManager: fm
            )
        }
        if let remote = readCoordinatedSnapshot(at: snapshotURL, fileManager: fm) {
            mergeRemoteSnapshot(
                remote,
                into: database,
                syncRoot: rootStd,
                syncAssetsDir: syncAssetsDir,
                localAssetsDir: localAssetsDir,
                fileManager: fm
            )
        }

        // 3. Build unified snapshot from local database and write atomically back to `.graphe-sync/`
        let unified = buildSnapshot(
            from: database,
            relPathByHash: relPathByHash,
            syncAssetsDir: syncAssetsDir,
            fileManager: fm
        )
        try writeCoordinatedSnapshot(unified, to: snapshotURL)

        return CloudSyncResult(
            discoveredPDFCount: pdfFiles.count,
            mergedAnnotations: unified.annotations.count,
            mergedNotebookCount: unified.standaloneNotebooks.count,
            syncedAt: unified.updatedAt
        )
    }

    // MARK: - Helpers

    private func discoverAndRequestDownloadOfPDFs(in root: URL, fileManager fm: FileManager) -> [URL] {
        // Trigger download on the sync metadata file itself if ubiquitous
        let remoteMetaFile = root
            .appendingPathComponent(Self.syncDirectoryName, isDirectory: true)
            .appendingPathComponent(".\(Self.syncSnapshotFilename).icloud")
        if fm.fileExists(atPath: remoteMetaFile.path) {
            try? fm.startDownloadingUbiquitousItem(at: remoteMetaFile)
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        ) else {
            return []
        }

        var pdfs: [URL] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name == Self.syncDirectoryName || name == Self.legacyHiddenSyncDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            // Handle `.Book.pdf.icloud` evicted iCloud Drive placeholders
            if name.hasPrefix(".") && name.lowercased().hasSuffix(".pdf.icloud") {
                try? fm.startDownloadingUbiquitousItem(at: fileURL)
                continue
            }
            if name.hasPrefix(".") {
                continue
            }
            if fileURL.pathExtension.lowercased() == "pdf" {
                try? fm.startDownloadingUbiquitousItem(at: fileURL)
                if fm.fileExists(atPath: fileURL.path) {
                    pdfs.append(fileURL.standardizedFileURL)
                }
            }
        }
        return pdfs.sorted { $0.path < $1.path }
    }

    private func relativePath(of fileURL: URL, from rootURL: URL) -> String {
        let rootPrefix = rootURL.standardizedFileURL.path.hasSuffix("/")
            ? rootURL.standardizedFileURL.path
            : rootURL.standardizedFileURL.path + "/"
        let full = fileURL.standardizedFileURL.path
        if full.hasPrefix(rootPrefix) {
            return String(full.dropFirst(rootPrefix.count))
        }
        return fileURL.lastPathComponent
    }

    private func mergeRemoteSnapshot(
        _ remote: CloudSyncSnapshot,
        into db: LibraryDatabase,
        syncRoot: URL,
        syncAssetsDir: URL,
        localAssetsDir: URL,
        fileManager fm: FileManager
    ) {
        // 1) Documents metadata & tags
        for rDoc in remote.documents {
            let resolvedPath: String
            if let rel = rDoc.relativePath {
                let candidate = syncRoot.appendingPathComponent(rel).standardizedFileURL
                if fm.fileExists(atPath: candidate.path) {
                    resolvedPath = candidate.path
                } else if let local = db.fetchDocument(hash: rDoc.hash) {
                    resolvedPath = local.path
                } else {
                    resolvedPath = candidate.path
                }
            } else if let local = db.fetchDocument(hash: rDoc.hash) {
                resolvedPath = local.path
            } else {
                continue
            }

            let local = db.fetchDocument(hash: rDoc.hash)
            _ = db.upsertDocument(
                hash: rDoc.hash,
                path: resolvedPath,
                title: local?.title ?? rDoc.title,
                author: local?.author ?? rDoc.author,
                pageCount: max(local?.pageCount ?? 0, rDoc.pageCount),
                touchLastOpened: false
            )
            db.updateDocumentMetadata(
                hash: rDoc.hash,
                title: preferredString(local?.title, rDoc.title) ?? rDoc.title,
                author: preferredString(local?.author, rDoc.author),
                year: local?.year ?? rDoc.year,
                publisher: preferredString(local?.publisher, rDoc.publisher),
                isbn: preferredString(local?.isbn, rDoc.isbn),
                doi: preferredString(local?.doi, rDoc.doi)
            )
            let mergedTags = Array(Set((local?.tags ?? []) + rDoc.tags)).sorted()
            if !mergedTags.isEmpty {
                db.updateDocumentTags(hash: rDoc.hash, tags: mergedTags)
            }
        }

        // 2) Annotations (last-writer-wins by updatedAt)
        var localAnnotationsByID: [UUID: AnnotationItem] = [:]
        let allKnownDocHashes = Set(db.fetchAllDocuments().map(\.hash)).union(remote.annotations.map(\.documentHash))
        for docHash in allKnownDocHashes {
            for ann in db.fetchAnnotations(forDocumentHash: docHash) {
                localAnnotationsByID[ann.id] = ann
            }
        }
        for rAnn in remote.annotations {
            if let lAnn = localAnnotationsByID[rAnn.id] {
                if rAnn.updatedAt > lAnn.updatedAt {
                    db.upsertAnnotation(rAnn)
                }
            } else {
                db.upsertAnnotation(rAnn)
            }
        }

        // 3) Bookmarks
        for rBm in remote.bookmarks {
            let existing = db.fetchBookmarks(forDocumentHash: rBm.documentHash)
            if !existing.contains(where: { $0.pageIndex == rBm.pageIndex }) {
                db.upsertBookmark(rBm)
            }
        }

        // 4) Standalone Notebooks
        let localNotebooks = Dictionary(uniqueKeysWithValues: db.fetchAllStandaloneNotebooks().map { ($0.id, $0) })
        for rNb in remote.standaloneNotebooks {
            if let lNb = localNotebooks[rNb.id] {
                if rNb.updatedAt > lNb.updatedAt {
                    db.upsertStandaloneNotebook(rNb)
                }
            } else {
                db.upsertStandaloneNotebook(rNb)
            }
        }

        // 5) Notebook Sections
        let allOwnerHashes = Set(remote.sections.map(\.documentHash))
            .union(remote.pages.map(\.documentHash))
            .union(remote.containers.map { $0.container.documentHash })
        var localSectionsByID: [UUID: NotebookSection] = [:]
        var localPagesByID: [UUID: NotebookPage] = [:]
        for owner in allOwnerHashes {
            for sec in db.fetchNotebookSections(forDocumentHash: owner) {
                localSectionsByID[sec.id] = sec
            }
            for pg in db.fetchAllNotebookPages(forDocumentHash: owner) {
                localPagesByID[pg.id] = pg
            }
        }
        for rSec in remote.sections where localSectionsByID[rSec.id] == nil {
            db.upsertNotebookSection(rSec)
        }

        // 6) Notebook Pages (last-writer-wins by updatedAt)
        for rPage in remote.pages {
            if let lPage = localPagesByID[rPage.id] {
                if rPage.updatedAt > lPage.updatedAt {
                    db.upsertNotebookPage(rPage)
                }
            } else {
                db.upsertNotebookPage(rPage)
            }
        }

        // 7) Note Containers + Image Assets
        var localContainersByID: [UUID: NoteContainer] = [:]
        let allPageIDs = Set(localPagesByID.keys).union(remote.pages.map(\.id))
        for pageID in allPageIDs {
            for c in db.fetchNoteContainers(forPageID: pageID) {
                localContainersByID[c.id] = c
            }
        }
        for rSynced in remote.containers {
            var incoming = rSynced.container
            if let assetName = rSynced.assetFilename {
                let srcAsset = syncAssetsDir.appendingPathComponent(assetName)
                let dstAsset = localAssetsDir.appendingPathComponent(assetName)
                if fm.fileExists(atPath: srcAsset.path) && !fm.fileExists(atPath: dstAsset.path) {
                    try? fm.copyItem(at: srcAsset, to: dstAsset)
                }
                if fm.fileExists(atPath: dstAsset.path) {
                    incoming.imagePath = dstAsset.path
                }
            }

            let pageTitle = db.fetchNotebookPageTitle(id: incoming.pageID) ?? ""
            if let localC = localContainersByID[incoming.id] {
                if incoming.updatedAt > localC.updatedAt {
                    db.upsertNoteContainer(incoming, pageTitle: pageTitle)
                }
            } else {
                db.upsertNoteContainer(incoming, pageTitle: pageTitle)
            }
        }
    }

    private func buildSnapshot(
        from db: LibraryDatabase,
        relPathByHash: [String: String],
        syncAssetsDir: URL,
        fileManager fm: FileManager
    ) -> CloudSyncSnapshot {
        let docs = db.fetchAllDocuments()
        let standaloneNbs = db.fetchAllStandaloneNotebooks()

        var syncedDocs: [SyncedDocumentMeta] = []
        var annotations: [AnnotationItem] = []
        var bookmarks: [BookmarkItem] = []
        var sections: [NotebookSection] = []
        var pages: [NotebookPage] = []
        var containers: [SyncedNoteContainer] = []

        for doc in docs {
            syncedDocs.append(SyncedDocumentMeta(
                hash: doc.hash,
                relativePath: relPathByHash[doc.hash] ?? URL(fileURLWithPath: doc.path).lastPathComponent,
                title: doc.title,
                author: doc.author,
                year: doc.year,
                publisher: doc.publisher,
                isbn: doc.isbn,
                doi: doc.doi,
                pageCount: doc.pageCount,
                tags: doc.tags,
                lastOpenedAt: doc.lastOpenedAt,
                addedAt: doc.addedAt
            ))
            annotations.append(contentsOf: db.fetchAnnotations(forDocumentHash: doc.hash))
            bookmarks.append(contentsOf: db.fetchBookmarks(forDocumentHash: doc.hash))
        }

        let ownerHashes = Set(docs.map(\.hash)).union(standaloneNbs.map(\.storageHash))
        for owner in ownerHashes.sorted() {
            let secs = db.fetchNotebookSections(forDocumentHash: owner)
            sections.append(contentsOf: secs)
            let pgs = db.fetchAllNotebookPages(forDocumentHash: owner)
            pages.append(contentsOf: pgs)
            for pg in pgs {
                for c in db.fetchNoteContainers(forPageID: pg.id) {
                    var assetName: String? = nil
                    if let imgPath = c.imagePath, fm.fileExists(atPath: imgPath) {
                        let name = URL(fileURLWithPath: imgPath).lastPathComponent
                        assetName = name
                        let dst = syncAssetsDir.appendingPathComponent(name)
                        if !fm.fileExists(atPath: dst.path) {
                            try? fm.copyItem(atPath: imgPath, toPath: dst.path)
                        }
                    }
                    containers.append(SyncedNoteContainer(container: c, assetFilename: assetName))
                }
            }
        }

        return CloudSyncSnapshot(
            schemaVersion: 1,
            updatedAt: Date(),
            documents: syncedDocs,
            annotations: annotations,
            bookmarks: bookmarks,
            standaloneNotebooks: standaloneNbs,
            sections: sections,
            pages: pages,
            containers: containers
        )
    }

    private func preferredString(_ a: String?, _ b: String?) -> String? {
        let ta = a?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tb = b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ta.isEmpty { return ta }
        if !tb.isEmpty { return tb }
        return nil
    }

    private func readCoordinatedSnapshot(at url: URL, fileManager fm: FileManager) -> CloudSyncSnapshot? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        var readData: Data?
        let isUbiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        if isUbiquitous {
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordinatedURL in
                readData = try? Data(contentsOf: coordinatedURL)
            }
        }
        if readData == nil {
            readData = try? Data(contentsOf: url)
        }
        guard let data = readData else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CloudSyncSnapshot.self, from: data)
    }

    private func writeCoordinatedSnapshot(_ snapshot: CloudSyncSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let isUbiquitous = (try? parent.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        if isUbiquitous {
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var wrote = false
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { coordinatedURL in
                if (try? data.write(to: coordinatedURL, options: .atomic)) != nil {
                    wrote = true
                }
            }
            if wrote { return }
        }
        try data.write(to: url, options: .atomic)
    }
}
