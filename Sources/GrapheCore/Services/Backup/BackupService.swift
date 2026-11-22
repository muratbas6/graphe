import Foundation

public enum BackupServiceError: Error, LocalizedError {
    case zipFailed(String)
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let msg): return "Yedekleme işlemi başarısız: \(msg)"
        case .invalidArchive: return "Seçilen dosya geçerli bir Graphe yedeği (.graphebackup) değil."
        }
    }
}

public struct RestoredBackupPayload: Sendable {
    public let vocabulary: [VocabularyItem]?

    public init(vocabulary: [VocabularyItem]?) {
        self.vocabulary = vocabulary
    }
}

public final class BackupService: @unchecked Sendable {
    public init() {}

    public static func defaultAssetsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("Graphe/NotebookAssets", isDirectory: true)
    }

    /// Creates a self-contained `.graphebackup` zip archive with SQLite DB, NotebookAssets, and Vocabulary.
    public func createBackup(
        database: LibraryDatabase,
        vocabulary: [VocabularyItem],
        assetsDirectory: URL? = nil,
        destinationURL: URL
    ) throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("graphe-backup-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        // 1. Export transactionally consistent SQLite snapshot via Online Backup API
        if database.databasePath != ":memory:" {
            let dbCopy = stagingDir.appendingPathComponent("graphe_library.sqlite")
            try database.exportConsistentCopy(to: dbCopy)
        }

        // 2. Copy NotebookAssets if present
        let assetsDir = assetsDirectory ?? Self.defaultAssetsDirectory()
        if fm.fileExists(atPath: assetsDir.path) {
            let assetsCopy = stagingDir.appendingPathComponent("NotebookAssets", isDirectory: true)
            try fm.copyItem(at: assetsDir, to: assetsCopy)
        }

        // 3. Save Vocabulary Notebook JSON
        let vocabData = try JSONEncoder().encode(vocabulary)
        try vocabData.write(to: stagingDir.appendingPathComponent("vocabulary.json"), options: .atomic)

        // 4. Zip staging directory with native macOS /usr/bin/ditto
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", stagingDir.path, destinationURL.path])
    }

    /// Restores a `.graphebackup` archive into the target database path & assets directory.
    public func restoreBackup(
        from archiveURL: URL,
        targetDatabasePath: String,
        targetAssetsDirectory: URL? = nil
    ) throws -> RestoredBackupPayload {
        let fm = FileManager.default
        let unpackDir = fm.temporaryDirectory.appendingPathComponent("graphe-restore-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpackDir) }

        try runDitto(arguments: ["-x", "-k", archiveURL.path, unpackDir.path])

        let restoredDB = unpackDir.appendingPathComponent("graphe_library.sqlite")
        guard fm.fileExists(atPath: restoredDB.path) else {
            throw BackupServiceError.invalidArchive
        }

        // Replace target SQLite file safely (removing stale -wal / -shm sidecars)
        let targetDBURL = URL(fileURLWithPath: targetDatabasePath)
        try fm.createDirectory(at: targetDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let p = targetDatabasePath + suffix
            if fm.fileExists(atPath: p) {
                try? fm.removeItem(atPath: p)
            }
        }
        try fm.copyItem(at: restoredDB, to: targetDBURL)

        // Restore NotebookAssets (always clear stale assets even if backup had none)
        let restoredAssets = unpackDir.appendingPathComponent("NotebookAssets", isDirectory: true)
        let targetAssets = targetAssetsDirectory ?? Self.defaultAssetsDirectory()
        if fm.fileExists(atPath: targetAssets.path) {
            try? fm.removeItem(at: targetAssets)
        }
        if fm.fileExists(atPath: restoredAssets.path) {
            try fm.createDirectory(at: targetAssets.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: restoredAssets, to: targetAssets)
        }

        // Load vocabulary if included
        var restoredVocab: [VocabularyItem]?
        let vocabURL = unpackDir.appendingPathComponent("vocabulary.json")
        if let data = try? Data(contentsOf: vocabURL),
           let items = try? JSONDecoder().decode([VocabularyItem].self, from: data) {
            restoredVocab = items
        }

        return RestoredBackupPayload(vocabulary: restoredVocab)
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Exit \(process.terminationStatus)"
            throw BackupServiceError.zipFailed(errStr)
        }
    }
}
