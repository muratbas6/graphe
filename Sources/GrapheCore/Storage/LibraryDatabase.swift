import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum LibraryDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case executeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Kütüphane veritabanı açılamadı: \(msg)"
        case .executeFailed(let msg): return "Veritabanı işlemi başarısız: \(msg)"
        }
    }
}

public final class LibraryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let databasePath: String

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent("Graphe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("graphe_library.sqlite")
    }

    public init(path: String? = nil) throws {
        let targetPath = path ?? Self.defaultDatabaseURL().path
        self.databasePath = targetPath

        if targetPath != ":memory:" {
            let parent = URL(fileURLWithPath: targetPath).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(targetPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let err = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Bilinmeyen SQLite hatası"
            if let handle { sqlite3_close(handle) }
            throw LibraryDatabaseError.openFailed(err)
        }

        self.db = opened
        sqlite3_busy_timeout(opened, 3000)
        try configureSchema()
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    /// Exports a transactionally consistent copy of the live database using the SQLite Online Backup API.
    public func exportConsistentCopy(to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let sourceDB = db else {
            throw LibraryDatabaseError.executeFailed("Veritabanı bağlantısı kapalı.")
        }
        var destHandle: OpaquePointer?
        let rc = sqlite3_open_v2(
            destinationURL.path,
            &destHandle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let destDB = destHandle else {
            let err = destHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(rc)"
            if let destHandle { sqlite3_close_v2(destHandle) }
            throw LibraryDatabaseError.openFailed(err)
        }
        defer { sqlite3_close_v2(destDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            let err = String(cString: sqlite3_errmsg(destDB))
            throw LibraryDatabaseError.executeFailed(err)
        }
        let stepRC = sqlite3_backup_step(backup, -1)
        let finishRC = sqlite3_backup_finish(backup)
        if stepRC != SQLITE_DONE || finishRC != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(destDB))
            throw LibraryDatabaseError.executeFailed(err)
        }
    }

    // MARK: - SHA-256 File Identity

    public static func computeFileHash(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Fallback deterministic hash from path if file handle fails
            let data = Data(url.standardizedFileURL.path.utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Schema Setup

    private func configureSchema() throws {
        try exec("""
            PRAGMA busy_timeout = 3000;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS documents (
                hash TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT,
                page_count INTEGER NOT NULL DEFAULT 0,
                tags_json TEXT NOT NULL DEFAULT '[]',
                is_indexed INTEGER NOT NULL DEFAULT 0,
                last_opened_at REAL NOT NULL,
                added_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY,
                doc_hash TEXT NOT NULL,
                page_index INTEGER NOT NULL,
                kind TEXT NOT NULL,
                color TEXT NOT NULL,
                quote TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                rects_json TEXT NOT NULL DEFAULT '[]',
                tags_json TEXT NOT NULL DEFAULT '[]',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_annotations_doc_page
            ON annotations(doc_hash, page_index);

            CREATE VIRTUAL TABLE IF NOT EXISTS annotations_fts USING fts5(
                ann_id UNINDEXED,
                doc_hash UNINDEXED,
                page_index UNINDEXED,
                quote,
                note,
                tags,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(
                doc_hash UNINDEXED,
                page_index UNINDEXED,
                content,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TABLE IF NOT EXISTS ocr_pages (
                doc_hash TEXT NOT NULL,
                page_index INTEGER NOT NULL,
                full_text TEXT NOT NULL DEFAULT '',
                blocks_json TEXT NOT NULL DEFAULT '[]',
                updated_at REAL NOT NULL,
                PRIMARY KEY (doc_hash, page_index)
            );

            CREATE TABLE IF NOT EXISTS standalone_notebooks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                color TEXT NOT NULL DEFAULT 'blue',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS notebook_sections (
                id TEXT PRIMARY KEY,
                doc_hash TEXT NOT NULL,
                title TEXT NOT NULL,
                color TEXT NOT NULL DEFAULT 'purple',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_notebook_sections_doc
            ON notebook_sections(doc_hash, sort_order);

            CREATE TABLE IF NOT EXISTS notebook_pages (
                id TEXT PRIMARY KEY,
                section_id TEXT NOT NULL,
                doc_hash TEXT NOT NULL,
                title TEXT NOT NULL,
                paper_style TEXT NOT NULL DEFAULT 'dotted',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_notebook_pages_section
            ON notebook_pages(section_id, sort_order);

            CREATE TABLE IF NOT EXISTS notebook_containers (
                id TEXT PRIMARY KEY,
                page_id TEXT NOT NULL,
                doc_hash TEXT NOT NULL,
                kind TEXT NOT NULL,
                x REAL NOT NULL,
                y REAL NOT NULL,
                width REAL NOT NULL,
                height REAL NOT NULL,
                rtf_data BLOB,
                plain_text TEXT NOT NULL DEFAULT '',
                quote_text TEXT,
                source_page_index INTEGER,
                accent_color TEXT,
                image_path TEXT,
                z_index INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_notebook_containers_page
            ON notebook_containers(page_id, z_index);

            CREATE VIRTUAL TABLE IF NOT EXISTS notebook_fts USING fts5(
                container_id UNINDEXED,
                page_id UNINDEXED,
                doc_hash UNINDEXED,
                page_title,
                content,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TABLE IF NOT EXISTS bookmarks (
                id TEXT PRIMARY KEY,
                doc_hash TEXT NOT NULL,
                page_index INTEGER NOT NULL,
                label TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                UNIQUE(doc_hash, page_index)
            );

            CREATE INDEX IF NOT EXISTS idx_bookmarks_doc_page
            ON bookmarks(doc_hash, page_index);
        """)

        // Safe additive migrations for v1.1 bibliographic metadata columns
        let existingColumns = fetchTableColumns(named: "documents")
        let migrations: [(column: String, sql: String)] = [
            ("year", "ALTER TABLE documents ADD COLUMN year INTEGER;"),
            ("publisher", "ALTER TABLE documents ADD COLUMN publisher TEXT;"),
            ("isbn", "ALTER TABLE documents ADD COLUMN isbn TEXT;"),
            ("doi", "ALTER TABLE documents ADD COLUMN doi TEXT;")
        ]
        for migration in migrations where !existingColumns.contains(migration.column) {
            try exec(migration.sql)
        }
    }

    private func fetchTableColumns(named tableName: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var columns = Set<String>()
        guard let stmt = prepareUnlocked("PRAGMA table_info(\(tableName));") else {
            return columns
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            columns.insert(columnText(stmt, 1))
        }
        return columns
    }

    // MARK: - Documents

    @discardableResult
    public func upsertDocument(
        hash: String,
        path: String,
        title: String,
        author: String?,
        pageCount: Int,
        touchLastOpened: Bool = true
    ) -> LibraryDocumentRecord {
        lock.lock()
        defer { lock.unlock() }

        let now = Date().timeIntervalSince1970
        let existing = fetchDocumentUnlocked(hash: hash)
        let tags = existing?.tags ?? []
        let isIndexed = existing?.isIndexed ?? false
        let addedAt = existing?.addedAt.timeIntervalSince1970 ?? now
        let lastOpenedAt = touchLastOpened ? now : (existing?.lastOpenedAt.timeIntervalSince1970 ?? now)

        let sql = """
            INSERT INTO documents (hash, path, title, author, page_count, tags_json, is_indexed, last_opened_at, added_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                path = excluded.path,
                title = CASE WHEN TRIM(documents.title) != '' THEN documents.title ELSE excluded.title END,
                author = COALESCE(documents.author, excluded.author),
                page_count = CASE WHEN excluded.page_count > 0 THEN excluded.page_count ELSE documents.page_count END,
                last_opened_at = excluded.last_opened_at;
        """

        if let stmt = prepareUnlocked(sql) {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hash)
            bindText(stmt, 2, path)
            bindText(stmt, 3, title)
            if let author, !author.isEmpty {
                bindText(stmt, 4, author)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, Int32(pageCount))
            bindText(stmt, 6, encodeJSON(tags))
            sqlite3_bind_int(stmt, 7, isIndexed ? 1 : 0)
            sqlite3_bind_double(stmt, 8, lastOpenedAt)
            sqlite3_bind_double(stmt, 9, addedAt)
            sqlite3_step(stmt)
        }

        let resolvedTitle = (existing?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? existing!.title
            : title
        let resolvedAuthor = existing?.author ?? ((author?.isEmpty == false) ? author : nil)

        return LibraryDocumentRecord(
            hash: hash,
            path: path,
            title: resolvedTitle,
            author: resolvedAuthor,
            year: existing?.year,
            publisher: existing?.publisher,
            isbn: existing?.isbn,
            doi: existing?.doi,
            pageCount: pageCount > 0 ? pageCount : (existing?.pageCount ?? 0),
            tags: tags,
            isIndexed: isIndexed,
            lastOpenedAt: Date(timeIntervalSince1970: lastOpenedAt),
            addedAt: Date(timeIntervalSince1970: addedAt)
        )
    }

    public func fetchDocument(hash: String) -> LibraryDocumentRecord? {
        lock.lock()
        defer { lock.unlock() }
        return fetchDocumentUnlocked(hash: hash)
    }

    public func fetchAllDocuments() -> [LibraryDocumentRecord] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT hash, path, title, author, page_count, tags_json, is_indexed, last_opened_at, added_at,
                   year, publisher, isbn, doi
            FROM documents
            ORDER BY last_opened_at DESC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [LibraryDocumentRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readDocumentRow(stmt))
        }
        return results
    }

    public func updateDocumentMetadata(
        hash: String,
        title: String,
        author: String?,
        year: Int?,
        publisher: String?,
        isbn: String?,
        doi: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            UPDATE documents
            SET title = ?, author = ?, year = ?, publisher = ?, isbn = ?, doi = ?
            WHERE hash = ?;
        """
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, title)
        if let author, !author.isEmpty { bindText(stmt, 2, author) } else { sqlite3_bind_null(stmt, 2) }
        if let year { sqlite3_bind_int(stmt, 3, Int32(year)) } else { sqlite3_bind_null(stmt, 3) }
        if let publisher, !publisher.isEmpty { bindText(stmt, 4, publisher) } else { sqlite3_bind_null(stmt, 4) }
        if let isbn, !isbn.isEmpty { bindText(stmt, 5, isbn) } else { sqlite3_bind_null(stmt, 5) }
        if let doi, !doi.isEmpty { bindText(stmt, 6, doi) } else { sqlite3_bind_null(stmt, 6) }
        bindText(stmt, 7, hash)
        sqlite3_step(stmt)
    }

    /// Flushes WAL journal into the main SQLite file so backup copies are 100% consistent.
    public func checkpointWAL() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    public func updateDocumentTags(hash: String, tags: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let cleaned = normalizeTags(tags)
        let sql = "UPDATE documents SET tags_json = ? WHERE hash = ?;"
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, encodeJSON(cleaned))
        bindText(stmt, 2, hash)
        sqlite3_step(stmt)
    }

    public func updateDocumentPaths(oldPrefix: String, newPrefix: String, renamedSingleFileTitle: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let docsSQL = "SELECT hash, path, title FROM documents;"
        guard let stmt = prepareUnlocked(docsSQL) else { return }
        defer { sqlite3_finalize(stmt) }

        var updates: [(hash: String, newPath: String, newTitle: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hash = columnText(stmt, 0)
            let path = columnText(stmt, 1)
            let title = columnText(stmt, 2)
            if path == oldPrefix {
                updates.append((hash, newPrefix, renamedSingleFileTitle ?? title))
            } else if path.hasPrefix(oldPrefix + "/") {
                let suffix = String(path.dropFirst(oldPrefix.count))
                updates.append((hash, newPrefix + suffix, title))
            }
        }

        guard !updates.isEmpty else { return }
        runInTransactionUnlocked {
            guard let upd = prepareUnlocked("UPDATE documents SET path = ?, title = ? WHERE hash = ?;") else {
                return false
            }
            defer { sqlite3_finalize(upd) }
            for item in updates {
                sqlite3_reset(upd)
                sqlite3_clear_bindings(upd)
                bindText(upd, 1, item.newPath)
                bindText(upd, 2, item.newTitle)
                bindText(upd, 3, item.hash)
                guard sqlite3_step(upd) == SQLITE_DONE else { return false }
            }
            return true
        }
    }

    public func removeDocument(hash: String) {
        let imagePaths: [String]
        let removed: Bool
        do {
            lock.lock()
            defer { lock.unlock() }
            imagePaths = fetchImagePathsUnlocked(forDocumentHash: hash)
            removed = runInTransactionUnlocked {
                let r1 = deleteByHashUnlocked("DELETE FROM documents WHERE hash = ?;", hash: hash)
                let r2 = deleteByHashUnlocked("DELETE FROM pages_fts WHERE doc_hash = ?;", hash: hash)
                let r3 = deleteByHashUnlocked("DELETE FROM annotations WHERE doc_hash = ?;", hash: hash)
                let r4 = deleteByHashUnlocked("DELETE FROM annotations_fts WHERE doc_hash = ?;", hash: hash)
                let r5 = deleteByHashUnlocked("DELETE FROM ocr_pages WHERE doc_hash = ?;", hash: hash)
                let r6 = deleteByHashUnlocked("DELETE FROM notebook_sections WHERE doc_hash = ?;", hash: hash)
                let r7 = deleteByHashUnlocked("DELETE FROM notebook_pages WHERE doc_hash = ?;", hash: hash)
                let r8 = deleteByHashUnlocked("DELETE FROM notebook_containers WHERE doc_hash = ?;", hash: hash)
                let r9 = deleteByHashUnlocked("DELETE FROM notebook_fts WHERE doc_hash = ?;", hash: hash)
                let r10 = deleteByHashUnlocked("DELETE FROM bookmarks WHERE doc_hash = ?;", hash: hash)
                return r1 && r2 && r3 && r4 && r5 && r6 && r7 && r8 && r9 && r10
            }
        }
        if removed {
            removeImageFiles(imagePaths)
        }
    }

    public func fetchIndexedPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var paths = Set<String>()
        guard let stmt = prepareUnlocked("SELECT path FROM documents WHERE is_indexed = 1;") else {
            return paths
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.insert(columnText(stmt, 0))
        }
        return paths
    }

    public func isDocumentIndexed(hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fetchDocumentUnlocked(hash: hash)?.isIndexed ?? false
    }

    // MARK: - Full-Text Page Indexing (FTS5)

    public func indexDocumentPages(hash: String, pages: [(pageIndex: Int, text: String)]) {
        // Step 1: Collect pages that already have Vision OCR text and remove only non-OCR FTS rows
        let ocrPageIndices: Set<Int>
        do {
            lock.lock()
            defer { lock.unlock() }
            var existingOCR = Set<Int>()
            if let stmt = prepareUnlocked("SELECT page_index FROM ocr_pages WHERE doc_hash = ?;") {
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, hash)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    existingOCR.insert(Int(sqlite3_column_int(stmt, 0)))
                }
            }
            ocrPageIndices = existingOCR

            let deleted = runInTransactionUnlocked {
                guard let delStmt = prepareUnlocked("""
                    DELETE FROM pages_fts
                    WHERE doc_hash = ?
                      AND page_index NOT IN (SELECT page_index FROM ocr_pages WHERE doc_hash = ?);
                """) else { return false }
                defer { sqlite3_finalize(delStmt) }
                bindText(delStmt, 1, hash)
                bindText(delStmt, 2, hash)
                return sqlite3_step(delStmt) == SQLITE_DONE
            }
            guard deleted else { return }
        }

        // Step 2: Filter out OCR-backed and empty pages outside the DB lock
        let entriesToInsert: [(pageIndex: Int, text: String)] = pages.compactMap { entry in
            guard !ocrPageIndices.contains(entry.pageIndex) else { return nil }
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (entry.pageIndex, trimmed)
        }

        // Step 3: Insert in small batches so @MainActor reads never stall on lock
        let batchSize = 50
        let insertSQL = "INSERT INTO pages_fts (doc_hash, page_index, content) VALUES (?, ?, ?);"
        var start = 0
        while start < entriesToInsert.count {
            let end = min(start + batchSize, entriesToInsert.count)
            let slice = entriesToInsert[start..<end]
            lock.lock()
            let ok = runInTransactionUnlocked {
                guard let stmt = prepareUnlocked(insertSQL) else { return false }
                defer { sqlite3_finalize(stmt) }
                for entry in slice {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, hash)
                    sqlite3_bind_int(stmt, 2, Int32(entry.pageIndex))
                    bindText(stmt, 3, entry.text)
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        return false
                    }
                }
                return true
            }
            lock.unlock()
            if !ok { return }
            start = end
        }

        // Step 4: Mark document as indexed
        lock.lock()
        defer { lock.unlock() }
        runInTransactionUnlocked {
            guard let markStmt = prepareUnlocked("UPDATE documents SET is_indexed = 1 WHERE hash = ?;") else {
                return false
            }
            defer { sqlite3_finalize(markStmt) }
            bindText(markStmt, 1, hash)
            return sqlite3_step(markStmt) == SQLITE_DONE
        }
    }

    // MARK: - OCR Pages Storage (Non-Destructive + Live FTS5 Update)

    public func upsertOCRPage(docHash: String, result: OCRPageResult) {
        lock.lock()
        defer { lock.unlock() }

        runInTransactionUnlocked {
            let sql = """
                INSERT INTO ocr_pages (doc_hash, page_index, full_text, blocks_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(doc_hash, page_index) DO UPDATE SET
                    full_text = excluded.full_text,
                    blocks_json = excluded.blocks_json,
                    updated_at = excluded.updated_at;
            """
            guard let stmt = prepareUnlocked(sql) else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, docHash)
            sqlite3_bind_int(stmt, 2, Int32(result.pageIndex))
            bindText(stmt, 3, result.fullText)
            bindText(stmt, 4, encodeJSON(result.blocks))
            sqlite3_bind_double(stmt, 5, result.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

            // Replace this page's FTS5 entry with the fresh Vision OCR text
            guard let delStmt = prepareUnlocked("DELETE FROM pages_fts WHERE doc_hash = ? AND page_index = ?;") else {
                return false
            }
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, 1, docHash)
            sqlite3_bind_int(delStmt, 2, Int32(result.pageIndex))
            guard sqlite3_step(delStmt) == SQLITE_DONE else { return false }

            let trimmed = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let insStmt = prepareUnlocked("INSERT INTO pages_fts (doc_hash, page_index, content) VALUES (?, ?, ?);") else {
                    return false
                }
                defer { sqlite3_finalize(insStmt) }
                bindText(insStmt, 1, docHash)
                sqlite3_bind_int(insStmt, 2, Int32(result.pageIndex))
                bindText(insStmt, 3, trimmed)
                guard sqlite3_step(insStmt) == SQLITE_DONE else { return false }
            }

            guard let markStmt = prepareUnlocked("UPDATE documents SET is_indexed = 1 WHERE hash = ?;") else {
                return false
            }
            defer { sqlite3_finalize(markStmt) }
            bindText(markStmt, 1, docHash)
            return sqlite3_step(markStmt) == SQLITE_DONE
        }
    }

    public func fetchOCRPage(docHash: String, pageIndex: Int) -> OCRPageResult? {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT page_index, full_text, blocks_json, updated_at
            FROM ocr_pages
            WHERE doc_hash = ? AND page_index = ?;
        """
        guard let stmt = prepareUnlocked(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)
        sqlite3_bind_int(stmt, 2, Int32(pageIndex))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let idx = Int(sqlite3_column_int(stmt, 0))
        let text = columnText(stmt, 1)
        let blocks: [OCRTextBlock] = decodeJSON(columnText(stmt, 2)) ?? []
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        return OCRPageResult(pageIndex: idx, fullText: text, blocks: blocks, updatedAt: updatedAt)
    }

    public func fetchAllOCRPages(docHash: String) -> [Int: OCRPageResult] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT page_index, full_text, blocks_json, updated_at
            FROM ocr_pages
            WHERE doc_hash = ?
            ORDER BY page_index ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)

        var map: [Int: OCRPageResult] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(stmt, 0))
            let text = columnText(stmt, 1)
            let blocks: [OCRTextBlock] = decodeJSON(columnText(stmt, 2)) ?? []
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            map[idx] = OCRPageResult(pageIndex: idx, fullText: text, blocks: blocks, updatedAt: updatedAt)
        }
        return map
    }

    public func countOCRPages(docHash: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT COUNT(*) FROM ocr_pages WHERE doc_hash = ?;"
        guard let stmt = prepareUnlocked(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Annotations (Highlights & Page Notes)

    public func upsertAnnotation(_ item: AnnotationItem) {
        lock.lock()
        defer { lock.unlock() }

        let cleanedTags = normalizeTags(item.tags)
        let idStr = item.id.uuidString

        runInTransactionUnlocked {
            let sql = """
                INSERT INTO annotations (id, doc_hash, page_index, kind, color, quote, note, rects_json, tags_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    color = excluded.color,
                    quote = excluded.quote,
                    note = excluded.note,
                    rects_json = excluded.rects_json,
                    tags_json = excluded.tags_json,
                    updated_at = excluded.updated_at;
            """

            guard let stmt = prepareUnlocked(sql) else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, idStr)
            bindText(stmt, 2, item.documentHash)
            sqlite3_bind_int(stmt, 3, Int32(item.pageIndex))
            bindText(stmt, 4, item.kind.rawValue)
            bindText(stmt, 5, item.color.rawValue)
            bindText(stmt, 6, item.quote)
            bindText(stmt, 7, item.note)
            bindText(stmt, 8, encodeJSON(item.rects))
            bindText(stmt, 9, encodeJSON(cleanedTags))
            sqlite3_bind_double(stmt, 10, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 11, item.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

            guard let delFts = prepareUnlocked("DELETE FROM annotations_fts WHERE ann_id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(delFts) }
            bindText(delFts, 1, idStr)
            guard sqlite3_step(delFts) == SQLITE_DONE else { return false }

            guard let insFts = prepareUnlocked("""
                INSERT INTO annotations_fts (ann_id, doc_hash, page_index, quote, note, tags)
                VALUES (?, ?, ?, ?, ?, ?);
            """) else {
                return false
            }
            defer { sqlite3_finalize(insFts) }
            bindText(insFts, 1, idStr)
            bindText(insFts, 2, item.documentHash)
            sqlite3_bind_int(insFts, 3, Int32(item.pageIndex))
            bindText(insFts, 4, item.quote)
            bindText(insFts, 5, item.note)
            bindText(insFts, 6, cleanedTags.joined(separator: " "))
            return sqlite3_step(insFts) == SQLITE_DONE
        }
    }

    public func deleteAnnotation(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let idStr = id.uuidString
        runInTransactionUnlocked {
            guard let stmt = prepareUnlocked("DELETE FROM annotations WHERE id = ?;") else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, idStr)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

            guard let ftsStmt = prepareUnlocked("DELETE FROM annotations_fts WHERE ann_id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(ftsStmt) }
            bindText(ftsStmt, 1, idStr)
            return sqlite3_step(ftsStmt) == SQLITE_DONE
        }
    }

    public func fetchAnnotations(forDocumentHash hash: String) -> [AnnotationItem] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, doc_hash, page_index, kind, color, quote, note, rects_json, tags_json, created_at, updated_at
            FROM annotations
            WHERE doc_hash = ?
            ORDER BY page_index ASC, created_at ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)

        var items: [AnnotationItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = readAnnotationRow(stmt) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Global FTS5 Search (Annotations + Full Document Text)

    public func globalSearch(query: String, limit: Int = 50) -> [GlobalSearchResult] {
        lock.lock()
        defer { lock.unlock() }

        guard let ftsQuery = buildSafeFTSQuery(from: query) else {
            return []
        }

        var results: [GlobalSearchResult] = []
        let halfLimit = max(10, limit / 2)

        // 0) Search book bibliographic metadata (title, author, publisher, ISBN, DOI)
        let metaPattern = "%\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())%"
        let metaLimit = max(5, limit / 5)
        let metaSQL = """
            SELECT hash, path, title, author, year, publisher, isbn, doi
            FROM documents
            WHERE LOWER(COALESCE(title, '')) LIKE ?
               OR LOWER(COALESCE(author, '')) LIKE ?
               OR LOWER(COALESCE(publisher, '')) LIKE ?
               OR LOWER(COALESCE(isbn, '')) LIKE ?
               OR LOWER(COALESCE(doi, '')) LIKE ?
            ORDER BY last_opened_at DESC
            LIMIT ?;
        """
        if let stmt = prepareUnlocked(metaSQL) {
            defer { sqlite3_finalize(stmt) }
            for bindIdx in Int32(1)...Int32(5) {
                bindText(stmt, bindIdx, metaPattern)
            }
            sqlite3_bind_int(stmt, 6, Int32(metaLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let docHash = columnText(stmt, 0)
                let docPath = columnText(stmt, 1)
                let docTitle = columnText(stmt, 2)
                let author = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "" : columnText(stmt, 3)
                let yearStr = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? "" : String(sqlite3_column_int(stmt, 4))
                let publisher = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? "" : columnText(stmt, 5)
                let isbn = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? "" : columnText(stmt, 6)
                let doi = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? "" : columnText(stmt, 7)

                let metaParts = [author, yearStr, publisher, isbn.isEmpty ? "" : "ISBN: \(isbn)", doi.isEmpty ? "" : "DOI: \(doi)"]
                    .filter { !$0.isEmpty }
                let snippet = metaParts.isEmpty ? docTitle : metaParts.joined(separator: " · ")

                results.append(
                    GlobalSearchResult(
                        id: "doc-\(docHash)",
                        kind: .documentText,
                        documentHash: docHash,
                        documentTitle: docTitle,
                        documentPath: docPath,
                        pageIndex: 0,
                        snippet: snippet,
                        highlightColor: nil
                    )
                )
            }
        }

        // 1) Search user highlights & notes first (highest signal)
        let annSQL = """
            SELECT a.id, a.doc_hash, a.page_index, a.kind, a.color, a.quote, a.note,
                   d.title, d.path,
                   snippet(annotations_fts, 3, '', '', '…', 18),
                   snippet(annotations_fts, 4, '', '', '…', 18)
            FROM annotations_fts
            JOIN annotations a ON a.id = annotations_fts.ann_id
            JOIN documents d ON d.hash = a.doc_hash
            WHERE annotations_fts MATCH ?
            ORDER BY bm25(annotations_fts)
            LIMIT ?;
        """
        if let stmt = prepareUnlocked(annSQL) {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, ftsQuery)
            sqlite3_bind_int(stmt, 2, Int32(halfLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, 0)
                let docHash = columnText(stmt, 1)
                let pageIndex = Int(sqlite3_column_int(stmt, 2))
                let kindRaw = columnText(stmt, 3)
                let colorRaw = columnText(stmt, 4)
                let quote = columnText(stmt, 5)
                let note = columnText(stmt, 6)
                let docTitle = columnText(stmt, 7)
                let docPath = columnText(stmt, 8)
                let quoteSnip = columnText(stmt, 9)
                let noteSnip = columnText(stmt, 10)

                let snippet: String
                if !noteSnip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    snippet = noteSnip
                } else if !quoteSnip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    snippet = quoteSnip
                } else {
                    snippet = !note.isEmpty ? note : quote
                }

                let kind: GlobalSearchResultKind = kindRaw == AnnotationKind.pageNote.rawValue ? .pageNote : .highlight
                results.append(
                    GlobalSearchResult(
                        id: "ann-\(id)",
                        kind: kind,
                        documentHash: docHash,
                        documentTitle: docTitle,
                        documentPath: docPath,
                        pageIndex: pageIndex,
                        snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines),
                        highlightColor: HighlightColor(rawValue: colorRaw)
                    )
                )
            }
        }

        // 1b) Search OneNote notebook containers (FTS5)
        let nbLimit = max(10, limit / 3)
        let nbSQL = """
            SELECT c.id, c.page_id, c.doc_hash, COALESCE(c.source_page_index, -1),
                   c.accent_color, d.title, d.path, p.title,
                   snippet(notebook_fts, 4, '', '', '…', 20)
            FROM notebook_fts
            JOIN notebook_containers c ON c.id = notebook_fts.container_id
            JOIN notebook_pages p ON p.id = c.page_id
            JOIN documents d ON d.hash = c.doc_hash
            WHERE notebook_fts MATCH ?
            ORDER BY bm25(notebook_fts)
            LIMIT ?;
        """
        if let stmt = prepareUnlocked(nbSQL) {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, ftsQuery)
            sqlite3_bind_int(stmt, 2, Int32(nbLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let containerID = columnText(stmt, 0)
                let pageIDStr = columnText(stmt, 1)
                let docHash = columnText(stmt, 2)
                let sourcePage = Int(sqlite3_column_int(stmt, 3))
                let colorRaw = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnText(stmt, 4)
                let docTitle = columnText(stmt, 5)
                let docPath = columnText(stmt, 6)
                let pageTitle = columnText(stmt, 7)
                let snip = columnText(stmt, 8)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                results.append(
                    GlobalSearchResult(
                        id: "nb-\(containerID)",
                        kind: .notebookNote,
                        documentHash: docHash,
                        documentTitle: "\(docTitle) · \(pageTitle)",
                        documentPath: docPath,
                        pageIndex: sourcePage,
                        snippet: snip.isEmpty ? pageTitle : snip,
                        highlightColor: colorRaw.flatMap { HighlightColor(rawValue: $0) },
                        notebookPageID: UUID(uuidString: pageIDStr)
                    )
                )
            }
        }

        // 2) Search full text of all indexed PDF pages
        let remaining = max(10, limit - results.count)
        let pageSQL = """
            SELECT pages_fts.doc_hash, pages_fts.page_index,
                   d.title, d.path,
                   snippet(pages_fts, 2, '', '', '…', 20)
            FROM pages_fts
            JOIN documents d ON d.hash = pages_fts.doc_hash
            WHERE pages_fts MATCH ?
            ORDER BY bm25(pages_fts)
            LIMIT ?;
        """
        if let stmt = prepareUnlocked(pageSQL) {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, ftsQuery)
            sqlite3_bind_int(stmt, 2, Int32(remaining))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let docHash = columnText(stmt, 0)
                let pageIndex = Int(sqlite3_column_int(stmt, 1))
                let docTitle = columnText(stmt, 2)
                let docPath = columnText(stmt, 3)
                let snippet = columnText(stmt, 4)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                results.append(
                    GlobalSearchResult(
                        id: "page-\(docHash)-\(pageIndex)-\(results.count)",
                        kind: .documentText,
                        documentHash: docHash,
                        documentTitle: docTitle,
                        documentPath: docPath,
                        pageIndex: pageIndex,
                        snippet: snippet,
                        highlightColor: nil
                    )
                )
            }
        }

        return results
    }

    public func tagDocumentHashMap() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return tagDocumentHashMapUnlocked()
    }

    public func allTags() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tagDocumentHashMapUnlocked().keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func tagDocumentHashMapUnlocked() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        if let stmt = prepareUnlocked("SELECT hash, tags_json FROM documents;") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hash = columnText(stmt, 0)
                let tags: [String] = decodeJSON(columnText(stmt, 1)) ?? []
                for tag in tags {
                    map[tag, default: []].insert(hash)
                }
            }
        }
        if let stmt = prepareUnlocked("""
            SELECT a.doc_hash, a.tags_json
            FROM annotations a
            JOIN documents d ON d.hash = a.doc_hash;
        """) {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hash = columnText(stmt, 0)
                let tags: [String] = decodeJSON(columnText(stmt, 1)) ?? []
                for tag in tags {
                    map[tag, default: []].insert(hash)
                }
            }
        }
        return map
    }

    // MARK: - OneNote Notebook (Sections, Pages, Containers & FTS5)

    @discardableResult
    public func ensureDefaultNotebook(forDocumentHash docHash: String) -> (section: NotebookSection, page: NotebookPage) {
        let sections = fetchNotebookSections(forDocumentHash: docHash)
        if let firstSection = sections.first {
            let pages = fetchNotebookPages(forSectionID: firstSection.id)
            if let firstPage = pages.first {
                return (firstSection, firstPage)
            }
            let newPage = NotebookPage(
                sectionID: firstSection.id,
                documentHash: docHash,
                title: "Sayfa 1",
                paperStyle: .dotted,
                sortOrder: 0
            )
            upsertNotebookPage(newPage)
            return (firstSection, newPage)
        }

        let section = NotebookSection(
            documentHash: docHash,
            title: "Genel Notlar",
            color: .purple,
            sortOrder: 0
        )
        upsertNotebookSection(section)
        let page = NotebookPage(
            sectionID: section.id,
            documentHash: docHash,
            title: "Sayfa 1",
            paperStyle: .dotted,
            sortOrder: 0
        )
        upsertNotebookPage(page)
        return (section, page)
    }

    public func fetchNotebookSections(forDocumentHash docHash: String) -> [NotebookSection] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, doc_hash, title, color, sort_order, created_at
            FROM notebook_sections
            WHERE doc_hash = ?
            ORDER BY sort_order ASC, created_at ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)

        var results: [NotebookSection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            results.append(
                NotebookSection(
                    id: id,
                    documentHash: columnText(stmt, 1),
                    title: columnText(stmt, 2),
                    color: SectionColor(rawValue: columnText(stmt, 3)) ?? .purple,
                    sortOrder: Int(sqlite3_column_int(stmt, 4)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                )
            )
        }
        return results
    }

    public func upsertNotebookSection(_ section: NotebookSection) {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT INTO notebook_sections (id, doc_hash, title, color, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                color = excluded.color,
                sort_order = excluded.sort_order;
        """
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, section.id.uuidString)
        bindText(stmt, 2, section.documentHash)
        bindText(stmt, 3, section.title)
        bindText(stmt, 4, section.color.rawValue)
        sqlite3_bind_int(stmt, 5, Int32(section.sortOrder))
        sqlite3_bind_double(stmt, 6, section.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    public func fetchImagePaths(forPageID pageID: UUID) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchImagePathsUnlocked(forPageID: pageID)
    }

    public func fetchImagePaths(forSectionID sectionID: UUID) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchImagePathsUnlocked(forSectionID: sectionID)
    }

    public func fetchImagePaths(forDocumentHash docHash: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchImagePathsUnlocked(forDocumentHash: docHash)
    }

    public func fetchNotebookPageTitle(id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepareUnlocked("SELECT title FROM notebook_pages WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    public func documentExists(hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hash.hasPrefix("notebook:") {
            let nbID = String(hash.dropFirst("notebook:".count))
            guard let stmt = prepareUnlocked("SELECT 1 FROM standalone_notebooks WHERE id = ? LIMIT 1;") else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, nbID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        guard let stmt = prepareUnlocked("SELECT 1 FROM documents WHERE hash = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Standalone Notebooks (PDF-Free Notes)

    public func fetchAllStandaloneNotebooks() -> [StandaloneNotebook] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, title, color, created_at, updated_at FROM standalone_notebooks ORDER BY updated_at DESC, created_at DESC;"
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [StandaloneNotebook] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            let title = columnText(stmt, 1)
            let color = SectionColor(rawValue: columnText(stmt, 2)) ?? .blue
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            results.append(StandaloneNotebook(id: id, title: title, color: color, createdAt: createdAt, updatedAt: updatedAt))
        }
        return results
    }

    public func fetchStandaloneNotebook(id: UUID) -> StandaloneNotebook? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, title, color, created_at, updated_at FROM standalone_notebooks WHERE id = ? LIMIT 1;"
        guard let stmt = prepareUnlocked(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let title = columnText(stmt, 1)
        let color = SectionColor(rawValue: columnText(stmt, 2)) ?? .blue
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        return StandaloneNotebook(id: id, title: title, color: color, createdAt: createdAt, updatedAt: updatedAt)
    }

    public func upsertStandaloneNotebook(_ notebook: StandaloneNotebook) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO standalone_notebooks (id, title, color, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            color = excluded.color,
            updated_at = excluded.updated_at;
        """
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, notebook.id.uuidString)
        bindText(stmt, 2, notebook.title)
        bindText(stmt, 3, notebook.color.rawValue)
        sqlite3_bind_double(stmt, 4, notebook.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, notebook.updatedAt.timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    public func deleteStandaloneNotebook(id: UUID) {
        let storageHash = "notebook:\(id.uuidString)"
        let imagePaths = fetchImagePaths(forDocumentHash: storageHash)
        lock.lock()
        defer { lock.unlock() }

        _ = deleteByHashUnlocked("DELETE FROM notebook_fts WHERE doc_hash = ?;", hash: storageHash)
        _ = deleteByHashUnlocked("DELETE FROM notebook_containers WHERE doc_hash = ?;", hash: storageHash)
        _ = deleteByHashUnlocked("DELETE FROM notebook_pages WHERE doc_hash = ?;", hash: storageHash)
        _ = deleteByHashUnlocked("DELETE FROM notebook_sections WHERE doc_hash = ?;", hash: storageHash)
        _ = deleteByHashUnlocked("DELETE FROM standalone_notebooks WHERE id = ?;", hash: id.uuidString)

        for path in imagePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    public func notebookPageExists(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepareUnlocked("SELECT 1 FROM notebook_pages WHERE id = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func noteContainerExists(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepareUnlocked("SELECT 1 FROM notebook_containers WHERE id = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func fetchImagePathsUnlocked(forPageID pageID: UUID) -> [String] {
        let sql = "SELECT image_path FROM notebook_containers WHERE page_id = ? AND image_path IS NOT NULL;"
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, pageID.uuidString)
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let p = columnText(stmt, 0)
            if !p.isEmpty { paths.append(p) }
        }
        return paths
    }

    private func fetchImagePathsUnlocked(forSectionID sectionID: UUID) -> [String] {
        let sql = """
            SELECT c.image_path
            FROM notebook_containers c
            JOIN notebook_pages p ON p.id = c.page_id
            WHERE p.section_id = ? AND c.image_path IS NOT NULL;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sectionID.uuidString)
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let p = columnText(stmt, 0)
            if !p.isEmpty { paths.append(p) }
        }
        return paths
    }

    private func fetchImagePathsUnlocked(forDocumentHash docHash: String) -> [String] {
        let sql = "SELECT image_path FROM notebook_containers WHERE doc_hash = ? AND image_path IS NOT NULL;"
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let p = columnText(stmt, 0)
            if !p.isEmpty { paths.append(p) }
        }
        return paths
    }

    private func removeImageFiles(_ paths: [String]) {
        let fm = FileManager.default
        for path in paths where !path.isEmpty {
            try? fm.removeItem(atPath: path)
        }
    }

    public func deleteNotebookSection(id: UUID) {
        let imagePaths: [String]
        let deleted: Bool
        do {
            lock.lock()
            defer { lock.unlock() }

            imagePaths = fetchImagePathsUnlocked(forSectionID: id)
            let secID = id.uuidString
            deleted = runInTransactionUnlocked {
                // Collect page IDs to remove containers & FTS
                guard let q = prepareUnlocked("SELECT id FROM notebook_pages WHERE section_id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(q) }
                bindText(q, 1, secID)
                var pageIDs: [String] = []
                while sqlite3_step(q) == SQLITE_ROW {
                    pageIDs.append(columnText(q, 0))
                }

                for pid in pageIDs {
                    guard let s1 = prepareUnlocked("DELETE FROM notebook_containers WHERE page_id = ?;") else {
                        return false
                    }
                    defer { sqlite3_finalize(s1) }
                    bindText(s1, 1, pid)
                    guard sqlite3_step(s1) == SQLITE_DONE else { return false }

                    guard let s2 = prepareUnlocked("DELETE FROM notebook_fts WHERE page_id = ?;") else {
                        return false
                    }
                    defer { sqlite3_finalize(s2) }
                    bindText(s2, 1, pid)
                    guard sqlite3_step(s2) == SQLITE_DONE else { return false }
                }
                guard let s3 = prepareUnlocked("DELETE FROM notebook_pages WHERE section_id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(s3) }
                bindText(s3, 1, secID)
                guard sqlite3_step(s3) == SQLITE_DONE else { return false }

                guard let s4 = prepareUnlocked("DELETE FROM notebook_sections WHERE id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(s4) }
                bindText(s4, 1, secID)
                guard sqlite3_step(s4) == SQLITE_DONE else { return false }
                return true
            }
        }
        if deleted {
            removeImageFiles(imagePaths)
        }
    }

    public func fetchNotebookPages(forSectionID sectionID: UUID) -> [NotebookPage] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, section_id, doc_hash, title, paper_style, sort_order, created_at, updated_at
            FROM notebook_pages
            WHERE section_id = ?
            ORDER BY sort_order ASC, created_at ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sectionID.uuidString)

        var results: [NotebookPage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let page = readNotebookPageRow(stmt) {
                results.append(page)
            }
        }
        return results
    }

    public func fetchAllNotebookPages(forDocumentHash docHash: String) -> [NotebookPage] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, section_id, doc_hash, title, paper_style, sort_order, created_at, updated_at
            FROM notebook_pages
            WHERE doc_hash = ?
            ORDER BY sort_order ASC, created_at ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)

        var results: [NotebookPage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let page = readNotebookPageRow(stmt) {
                results.append(page)
            }
        }
        return results
    }

    public func upsertNotebookPage(_ page: NotebookPage) {
        lock.lock()
        defer { lock.unlock() }

        let pid = page.id.uuidString
        runInTransactionUnlocked {
            let sql = """
                INSERT INTO notebook_pages (id, section_id, doc_hash, title, paper_style, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    section_id = excluded.section_id,
                    title = excluded.title,
                    paper_style = excluded.paper_style,
                    sort_order = excluded.sort_order,
                    updated_at = excluded.updated_at;
            """
            guard let stmt = prepareUnlocked(sql) else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, pid)
            bindText(stmt, 2, page.sectionID.uuidString)
            bindText(stmt, 3, page.documentHash)
            bindText(stmt, 4, page.title)
            bindText(stmt, 5, page.paperStyle.rawValue)
            sqlite3_bind_int(stmt, 6, Int32(page.sortOrder))
            sqlite3_bind_double(stmt, 7, page.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, page.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

            // Re-sync notebook_fts rows for this page so renamed page titles are immediately searchable
            guard let delFts = prepareUnlocked("DELETE FROM notebook_fts WHERE page_id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(delFts) }
            bindText(delFts, 1, pid)
            guard sqlite3_step(delFts) == SQLITE_DONE else { return false }

            guard let sel = prepareUnlocked("""
                SELECT id, doc_hash, quote_text, plain_text
                FROM notebook_containers
                WHERE page_id = ?;
            """) else {
                return false
            }
            defer { sqlite3_finalize(sel) }
            bindText(sel, 1, pid)

            var rows: [(id: String, docHash: String, content: String)] = []
            while sqlite3_step(sel) == SQLITE_ROW {
                let cid = columnText(sel, 0)
                let docHash = columnText(sel, 1)
                let quote = sqlite3_column_type(sel, 2) == SQLITE_NULL ? "" : columnText(sel, 2)
                let plain = columnText(sel, 3)
                let searchable = [quote, plain]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !searchable.isEmpty {
                    rows.append((cid, docHash, searchable))
                }
            }

            if !rows.isEmpty {
                guard let insFts = prepareUnlocked("""
                    INSERT INTO notebook_fts (container_id, page_id, doc_hash, page_title, content)
                    VALUES (?, ?, ?, ?, ?);
                """) else {
                    return false
                }
                defer { sqlite3_finalize(insFts) }
                for row in rows {
                    sqlite3_reset(insFts)
                    sqlite3_clear_bindings(insFts)
                    bindText(insFts, 1, row.id)
                    bindText(insFts, 2, pid)
                    bindText(insFts, 3, row.docHash)
                    bindText(insFts, 4, page.title)
                    bindText(insFts, 5, row.content)
                    guard sqlite3_step(insFts) == SQLITE_DONE else { return false }
                }
            }
            return true
        }
    }

    public func deleteNotebookPage(id: UUID) {
        let imagePaths: [String]
        let deleted: Bool
        do {
            lock.lock()
            defer { lock.unlock() }

            imagePaths = fetchImagePathsUnlocked(forPageID: id)
            let pid = id.uuidString
            deleted = runInTransactionUnlocked {
                guard let s1 = prepareUnlocked("DELETE FROM notebook_containers WHERE page_id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(s1) }
                bindText(s1, 1, pid)
                guard sqlite3_step(s1) == SQLITE_DONE else { return false }

                guard let s2 = prepareUnlocked("DELETE FROM notebook_fts WHERE page_id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(s2) }
                bindText(s2, 1, pid)
                guard sqlite3_step(s2) == SQLITE_DONE else { return false }

                guard let s3 = prepareUnlocked("DELETE FROM notebook_pages WHERE id = ?;") else {
                    return false
                }
                defer { sqlite3_finalize(s3) }
                bindText(s3, 1, pid)
                guard sqlite3_step(s3) == SQLITE_DONE else { return false }
                return true
            }
        }
        if deleted {
            removeImageFiles(imagePaths)
        }
    }

    public func fetchNoteContainers(forPageID pageID: UUID) -> [NoteContainer] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, page_id, doc_hash, kind, x, y, width, height, rtf_data, plain_text,
                   quote_text, source_page_index, accent_color, image_path, z_index, created_at, updated_at
            FROM notebook_containers
            WHERE page_id = ?
            ORDER BY z_index ASC, created_at ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, pageID.uuidString)

        var results: [NoteContainer] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let container = readNoteContainerRow(stmt) {
                results.append(container)
            }
        }
        return results
    }

    public func upsertNoteContainer(_ container: NoteContainer, pageTitle: String = "") {
        lock.lock()
        defer { lock.unlock() }

        let idStr = container.id.uuidString
        let pageIDStr = container.pageID.uuidString

        runInTransactionUnlocked {
            let sql = """
                INSERT INTO notebook_containers (
                    id, page_id, doc_hash, kind, x, y, width, height, rtf_data, plain_text,
                    quote_text, source_page_index, accent_color, image_path, z_index, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    x = excluded.x,
                    y = excluded.y,
                    width = excluded.width,
                    height = excluded.height,
                    rtf_data = excluded.rtf_data,
                    plain_text = excluded.plain_text,
                    quote_text = excluded.quote_text,
                    source_page_index = excluded.source_page_index,
                    accent_color = excluded.accent_color,
                    image_path = excluded.image_path,
                    z_index = excluded.z_index,
                    updated_at = excluded.updated_at;
            """
            guard let stmt = prepareUnlocked(sql) else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, idStr)
            bindText(stmt, 2, pageIDStr)
            bindText(stmt, 3, container.documentHash)
            bindText(stmt, 4, container.kind.rawValue)
            sqlite3_bind_double(stmt, 5, container.x)
            sqlite3_bind_double(stmt, 6, container.y)
            sqlite3_bind_double(stmt, 7, container.width)
            sqlite3_bind_double(stmt, 8, container.height)
            if let rtf = container.rtfData, !rtf.isEmpty {
                _ = rtf.withUnsafeBytes { rawBuf in
                    sqlite3_bind_blob(stmt, 9, rawBuf.baseAddress, Int32(rtf.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            bindText(stmt, 10, container.plainText)
            if let quote = container.quoteText {
                bindText(stmt, 11, quote)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if let srcPage = container.sourcePageIndex {
                sqlite3_bind_int(stmt, 12, Int32(srcPage))
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            if let color = container.accentColor {
                bindText(stmt, 13, color.rawValue)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            if let imgPath = container.imagePath {
                bindText(stmt, 14, imgPath)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            sqlite3_bind_int(stmt, 15, Int32(container.zIndex))
            sqlite3_bind_double(stmt, 16, container.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 17, container.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

            // Update notebook_fts
            guard let delFts = prepareUnlocked("DELETE FROM notebook_fts WHERE container_id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(delFts) }
            bindText(delFts, 1, idStr)
            guard sqlite3_step(delFts) == SQLITE_DONE else { return false }

            let searchable = [container.quoteText ?? "", container.plainText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            if !searchable.isEmpty {
                guard let insFts = prepareUnlocked("""
                    INSERT INTO notebook_fts (container_id, page_id, doc_hash, page_title, content)
                    VALUES (?, ?, ?, ?, ?);
                """) else { return false }
                defer { sqlite3_finalize(insFts) }
                bindText(insFts, 1, idStr)
                bindText(insFts, 2, pageIDStr)
                bindText(insFts, 3, container.documentHash)
                bindText(insFts, 4, pageTitle)
                bindText(insFts, 5, searchable)
                guard sqlite3_step(insFts) == SQLITE_DONE else { return false }
            }
            return true
        }
    }

    public func deleteNoteContainer(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let idStr = id.uuidString
        runInTransactionUnlocked {
            guard let s1 = prepareUnlocked("DELETE FROM notebook_containers WHERE id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(s1) }
            bindText(s1, 1, idStr)
            guard sqlite3_step(s1) == SQLITE_DONE else { return false }

            guard let s2 = prepareUnlocked("DELETE FROM notebook_fts WHERE container_id = ?;") else {
                return false
            }
            defer { sqlite3_finalize(s2) }
            bindText(s2, 1, idStr)
            guard sqlite3_step(s2) == SQLITE_DONE else { return false }
            return true
        }
    }

    private func readNotebookPageRow(_ stmt: OpaquePointer) -> NotebookPage? {
        guard let id = UUID(uuidString: columnText(stmt, 0)),
              let sectionID = UUID(uuidString: columnText(stmt, 1)) else { return nil }
        return NotebookPage(
            id: id,
            sectionID: sectionID,
            documentHash: columnText(stmt, 2),
            title: columnText(stmt, 3),
            paperStyle: PaperStyle(rawValue: columnText(stmt, 4)) ?? .dotted,
            sortOrder: Int(sqlite3_column_int(stmt, 5)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        )
    }

    private func readNoteContainerRow(_ stmt: OpaquePointer) -> NoteContainer? {
        guard let id = UUID(uuidString: columnText(stmt, 0)),
              let pageID = UUID(uuidString: columnText(stmt, 1)) else { return nil }
        let docHash = columnText(stmt, 2)
        let kind = NoteContainerKind(rawValue: columnText(stmt, 3)) ?? .richText
        let x = sqlite3_column_double(stmt, 4)
        let y = sqlite3_column_double(stmt, 5)
        let width = sqlite3_column_double(stmt, 6)
        let height = sqlite3_column_double(stmt, 7)

        var rtfData: Data?
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL,
           let bytes = sqlite3_column_blob(stmt, 8) {
            let count = Int(sqlite3_column_bytes(stmt, 8))
            if count > 0 {
                rtfData = Data(bytes: bytes, count: count)
            }
        }

        let plainText = columnText(stmt, 9)
        let quoteText = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : columnText(stmt, 10)
        let sourcePageIndex = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 11))
        let accentColor = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : HighlightColor(rawValue: columnText(stmt, 12))
        let imagePath = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : columnText(stmt, 13)
        let zIndex = Int(sqlite3_column_int(stmt, 14))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))

        return NoteContainer(
            id: id,
            pageID: pageID,
            documentHash: docHash,
            kind: kind,
            x: x,
            y: y,
            width: width,
            height: height,
            rtfData: rtfData,
            plainText: plainText,
            quoteText: quoteText,
            sourcePageIndex: sourcePageIndex,
            accentColor: accentColor,
            imagePath: imagePath,
            zIndex: zIndex,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Bookmarks (⌘D)

    public func fetchBookmarks(forDocumentHash docHash: String) -> [BookmarkItem] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT id, doc_hash, page_index, label, created_at
            FROM bookmarks
            WHERE doc_hash = ?
            ORDER BY page_index ASC;
        """
        guard let stmt = prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)

        var items: [BookmarkItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            items.append(
                BookmarkItem(
                    id: id,
                    documentHash: columnText(stmt, 1),
                    pageIndex: Int(sqlite3_column_int(stmt, 2)),
                    label: columnText(stmt, 3),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                )
            )
        }
        return items
    }

    public func upsertBookmark(_ item: BookmarkItem) {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT INTO bookmarks (id, doc_hash, page_index, label, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(doc_hash, page_index) DO UPDATE SET
                label = excluded.label;
        """
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, item.id.uuidString)
        bindText(stmt, 2, item.documentHash)
        sqlite3_bind_int(stmt, 3, Int32(item.pageIndex))
        bindText(stmt, 4, item.label)
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    public func deleteBookmark(docHash: String, pageIndex: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard let stmt = prepareUnlocked("DELETE FROM bookmarks WHERE doc_hash = ? AND page_index = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, docHash)
        sqlite3_bind_int(stmt, 2, Int32(pageIndex))
        sqlite3_step(stmt)
    }

    // MARK: - Private SQLite Helpers

    private func fetchDocumentUnlocked(hash: String) -> LibraryDocumentRecord? {
        let sql = """
            SELECT hash, path, title, author, page_count, tags_json, is_indexed, last_opened_at, added_at,
                   year, publisher, isbn, doi
            FROM documents
            WHERE hash = ?;
        """
        guard let stmt = prepareUnlocked(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readDocumentRow(stmt)
    }

    private func readDocumentRow(_ stmt: OpaquePointer) -> LibraryDocumentRecord {
        let hash = columnText(stmt, 0)
        let path = columnText(stmt, 1)
        let title = columnText(stmt, 2)
        let author = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : columnText(stmt, 3)
        let pageCount = Int(sqlite3_column_int(stmt, 4))
        let tags: [String] = decodeJSON(columnText(stmt, 5)) ?? []
        let isIndexed = sqlite3_column_int(stmt, 6) != 0
        let lastOpenedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let addedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let year = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        let publisher = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : columnText(stmt, 10)
        let isbn = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : columnText(stmt, 11)
        let doi = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : columnText(stmt, 12)

        return LibraryDocumentRecord(
            hash: hash,
            path: path,
            title: title,
            author: author,
            year: year,
            publisher: publisher,
            isbn: isbn,
            doi: doi,
            pageCount: pageCount,
            tags: tags,
            isIndexed: isIndexed,
            lastOpenedAt: lastOpenedAt,
            addedAt: addedAt
        )
    }

    private func readAnnotationRow(_ stmt: OpaquePointer) -> AnnotationItem? {
        guard let uuid = UUID(uuidString: columnText(stmt, 0)) else { return nil }
        let docHash = columnText(stmt, 1)
        let pageIndex = Int(sqlite3_column_int(stmt, 2))
        let kind = AnnotationKind(rawValue: columnText(stmt, 3)) ?? .highlight
        let color = HighlightColor(rawValue: columnText(stmt, 4)) ?? .yellow
        let quote = columnText(stmt, 5)
        let note = columnText(stmt, 6)
        let rects: [HighlightRect] = decodeJSON(columnText(stmt, 7)) ?? []
        let tags: [String] = decodeJSON(columnText(stmt, 8)) ?? []
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        return AnnotationItem(
            id: uuid,
            documentHash: docHash,
            pageIndex: pageIndex,
            kind: kind,
            color: color,
            quote: quote,
            note: note,
            rects: rects,
            tags: tags,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func buildSafeFTSQuery(from raw: String) -> String? {
        let disallowed = CharacterSet(charactersIn: "\"*^:(){}[]")
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token -> String in
                token
                    .components(separatedBy: disallowed)
                    .joined()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#-"))
            }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .lowercased()
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            result.append(cleaned)
        }
        return result
    }

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw LibraryDatabaseError.executeFailed(msg)
        }
    }

    @discardableResult
    private func runInTransactionUnlocked(_ body: () -> Bool) -> Bool {
        guard execUnlocked("BEGIN IMMEDIATE TRANSACTION;") else {
            return false
        }
        if body(), execUnlocked("COMMIT;") {
            return true
        }
        _ = execUnlocked("ROLLBACK;")
        return false
    }

    @discardableResult
    private func execUnlocked(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepareUnlocked(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        return stmt
    }

    @discardableResult
    private func deleteByHashUnlocked(_ sql: String, hash: String) -> Bool {
        guard let stmt = prepareUnlocked(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    private func decodeJSON<T: Decodable>(_ raw: String) -> T? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
