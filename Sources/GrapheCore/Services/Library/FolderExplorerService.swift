#if canImport(AppKit)
import AppKit
#endif
import Foundation

public struct WatchedRootFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var displayName: String

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, displayName: String? = nil) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        self.path = standardized
        self.displayName = displayName ?? URL(fileURLWithPath: standardized).lastPathComponent
    }
}

public struct FileTreeNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isRootFolder: Bool
    public let pdfCount: Int
    public let children: [FileTreeNode]

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isRootFolder: Bool = false,
        pdfCount: Int = 0,
        children: [FileTreeNode] = []
    ) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        self.name = name
        self.isDirectory = isDirectory
        self.isRootFolder = isRootFolder
        self.pdfCount = pdfCount
        self.children = children
    }
}

public enum FolderExplorerError: Error, LocalizedError {
    case invalidName
    case destinationExists
    case cannotMoveIntoSelf

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Geçerli bir dosya veya klasör adı girin."
        case .destinationExists:
            return "Hedef konumda aynı isimde bir dosya veya klasör zaten var."
        case .cannotMoveIntoSelf:
            return "Bir klasör kendi içine taşınamaz."
        }
    }
}

public final class FolderExplorerService: @unchecked Sendable {
    private let defaults: UserDefaults
    private let rootsKey = "graphe.vault.roots.v1"

    private let watchLock = NSLock()
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?
    private let watchQueue = DispatchQueue(label: "com.graphe.folderwatcher", qos: .utility)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        stopWatching()
    }

    // MARK: - Persistence

    public func loadWatchedFolders() -> [WatchedRootFolder] {
        guard let data = defaults.data(forKey: rootsKey),
              let saved = try? JSONDecoder().decode([WatchedRootFolder].self, from: data) else {
            return []
        }
        return saved.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func saveWatchedFolders(_ folders: [WatchedRootFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: rootsKey)
        }
    }

    // MARK: - Tree Builder

    public func buildTree(for root: WatchedRootFolder) -> FileTreeNode {
        let fm = FileManager.default
        let rootURL = root.url.standardizedFileURL
        var visitedCanonicalPaths = Set<String>([rootURL.resolvingSymlinksInPath().path])
        let (children, totalPDFs) = scanDirectory(
            at: rootURL,
            fileManager: fm,
            visitedCanonicalPaths: &visitedCanonicalPaths
        )
        return FileTreeNode(
            url: rootURL,
            name: root.displayName,
            isDirectory: true,
            isRootFolder: true,
            pdfCount: totalPDFs,
            children: children
        )
    }

    private func scanDirectory(
        at directoryURL: URL,
        fileManager fm: FileManager,
        visitedCanonicalPaths: inout Set<String>
    ) -> ([FileTreeNode], Int) {
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var folders: [FileTreeNode] = []
        var pdfs: [FileTreeNode] = []
        var totalPDFs = 0

        for entry in entries {
            let entryName = entry.lastPathComponent
            if entryName == CloudSyncService.syncDirectoryName || entryName == CloudSyncService.legacyHiddenSyncDirectoryName {
                continue
            }
            let std = entry.standardizedFileURL
            let values = try? std.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                let canonical = std.resolvingSymlinksInPath().path
                if values?.isSymbolicLink == true && visitedCanonicalPaths.contains(canonical) {
                    continue
                }
                guard visitedCanonicalPaths.insert(canonical).inserted else {
                    continue
                }
                let (subChildren, subCount) = scanDirectory(
                    at: std,
                    fileManager: fm,
                    visitedCanonicalPaths: &visitedCanonicalPaths
                )
                totalPDFs += subCount
                folders.append(
                    FileTreeNode(
                        url: std,
                        name: std.lastPathComponent,
                        isDirectory: true,
                        isRootFolder: false,
                        pdfCount: subCount,
                        children: subChildren
                    )
                )
            } else if std.pathExtension.lowercased() == "pdf" {
                totalPDFs += 1
                pdfs.append(
                    FileTreeNode(
                        url: std,
                        name: std.deletingPathExtension().lastPathComponent,
                        isDirectory: false,
                        isRootFolder: false,
                        pdfCount: 0,
                        children: []
                    )
                )
            }
        }

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        pdfs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders + pdfs, totalPDFs)
    }

    /// Collects all directories (root + subdirectories) for live watching and "Move to folder" menus.
    public func collectAllDirectories(from trees: [FileTreeNode]) -> [FileTreeNode] {
        var result: [FileTreeNode] = []
        func visit(_ node: FileTreeNode) {
            guard node.isDirectory else { return }
            result.append(node)
            for child in node.children where child.isDirectory {
                visit(child)
            }
        }
        for tree in trees {
            visit(tree)
        }
        return result
    }

    // MARK: - Live File System Watching

    public func startWatching(directories: [URL], onChange: @escaping @Sendable () -> Void) {
        stopWatching()

        watchLock.lock()
        defer { watchLock.unlock() }

        // Cap watched descriptors to stay well within macOS fd limits
        for dirURL in directories.prefix(128) {
            let fd = open(dirURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: watchQueue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.watchLock.lock()
                self.debounceWorkItem?.cancel()
                let work = DispatchWorkItem {
                    onChange()
                }
                self.debounceWorkItem = work
                self.watchLock.unlock()
                self.watchQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            watchers.append(source)
        }
    }

    public func stopWatching() {
        watchLock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        let activeWatchers = watchers
        watchers.removeAll()
        watchLock.unlock()

        for source in activeWatchers {
            source.cancel()
        }
    }

    // MARK: - File Manager Operations

    @discardableResult
    public func createSubfolder(named rawName: String, inside parentURL: URL) throws -> URL {
        let cleaned = sanitizeFileName(rawName)
        guard !cleaned.isEmpty else { throw FolderExplorerError.invalidName }

        let targetURL = parentURL.standardizedFileURL.appendingPathComponent(cleaned, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            throw FolderExplorerError.destinationExists
        }
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
        return targetURL
    }

    @discardableResult
    public func renameItem(at sourceURL: URL, toNewName rawName: String) throws -> URL {
        let stdSource = sourceURL.standardizedFileURL
        let cleaned = sanitizeFileName(rawName)
        guard !cleaned.isEmpty else { throw FolderExplorerError.invalidName }

        let isDir = (try? stdSource.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let finalName: String
        if !isDir && stdSource.pathExtension.lowercased() == "pdf" && !cleaned.lowercased().hasSuffix(".pdf") {
            finalName = "\(cleaned).pdf"
        } else {
            finalName = cleaned
        }

        let targetURL = stdSource.deletingLastPathComponent().appendingPathComponent(finalName)
        if targetURL.path == stdSource.path {
            return stdSource
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            throw FolderExplorerError.destinationExists
        }

        try FileManager.default.moveItem(at: stdSource, to: targetURL)
        return targetURL.standardizedFileURL
    }

    @discardableResult
    public func moveItem(at sourceURL: URL, toFolder targetFolderURL: URL) throws -> URL {
        let stdSource = sourceURL.standardizedFileURL
        let stdTargetDir = targetFolderURL.standardizedFileURL

        if stdSource.deletingLastPathComponent().path == stdTargetDir.path {
            return stdSource
        }
        // Prevent moving a folder into itself or its descendant
        if stdTargetDir.path == stdSource.path || stdTargetDir.path.hasPrefix(stdSource.path + "/") {
            throw FolderExplorerError.cannotMoveIntoSelf
        }

        let destinationURL = stdTargetDir.appendingPathComponent(stdSource.lastPathComponent)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw FolderExplorerError.destinationExists
        }

        try FileManager.default.moveItem(at: stdSource, to: destinationURL)
        return destinationURL.standardizedFileURL
    }

    public func trashItem(at url: URL) throws {
        #if os(macOS)
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url.standardizedFileURL, resultingItemURL: &trashedURL)
        #else
        try FileManager.default.removeItem(at: url.standardizedFileURL)
        #endif
    }

    public func revealInFinder(at url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
        #endif
    }

    private func sanitizeFileName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
