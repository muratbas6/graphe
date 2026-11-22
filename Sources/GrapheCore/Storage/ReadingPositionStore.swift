#if canImport(AppKit)
import AppKit
#endif
import Foundation

public protocol ReadingPositionStoring: Sendable {
    func savePosition(_ position: ReadingPosition, for url: URL)
    func loadPosition(for url: URL) -> ReadingPosition?
    func migratePath(oldPrefix: String, newPrefix: String)
    func flush()
    func saveRecentFiles(_ items: [RecentFileItem])
    func loadRecentFiles() -> [RecentFileItem]
    func saveTheme(_ theme: ReadingTheme)
    func loadTheme() -> ReadingTheme
    func saveSession(_ session: SavedWorkspaceSession)
    func loadSession() -> SavedWorkspaceSession?
}

public extension ReadingPositionStoring {
    func migratePath(oldPrefix: String, newPrefix: String) {}
    func flush() {}
}

public final class UserDefaultsPositionStore: ReadingPositionStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let positionsKey = "graphe.readingPositions.v1"
    private let recentFilesKey = "graphe.recentFiles.v1"
    private let themeKey = "graphe.readingTheme.v1"
    private let sessionKey = "graphe.workspaceSession.v1"
    private let lock = NSLock()
    private let persistLock = NSLock()
    private var cachedPositions: [String: ReadingPosition]?
    private var positionsGeneration: UInt64 = 0
    private var persistedGeneration: UInt64 = 0
    private let persistQueue = DispatchQueue(label: "com.graphe.positionStore.persist", qos: .utility)
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if canImport(AppKit)
        self.terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
        #endif
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        pendingPersistWorkItem?.cancel()
        flushPositionsNow()
    }

    public func flush() {
        persistQueue.sync {
            pendingPersistWorkItem?.cancel()
            pendingPersistWorkItem = nil
        }
        flushPositionsNow()
    }

    public func savePosition(_ position: ReadingPosition, for url: URL) {
        lock.lock()
        var map = loadPositionsMapUnlocked()
        let key = url.standardizedFileURL.path
        if let existing = map[key],
           existing.pageIndex == position.pageIndex,
           abs(existing.scaleFactor - position.scaleFactor) < 0.0001 {
            lock.unlock()
            return
        }
        map[key] = position
        cachedPositions = map
        positionsGeneration &+= 1
        lock.unlock()

        schedulePersistPositions()
    }

    private func schedulePersistPositions() {
        persistQueue.async { [weak self] in
            guard let self else { return }
            self.pendingPersistWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flushPositionsNow()
            }
            self.pendingPersistWorkItem = work
            self.persistQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func flushPositionsNow() {
        persistLock.lock()
        defer { persistLock.unlock() }

        lock.lock()
        guard positionsGeneration != persistedGeneration, let snapshot = cachedPositions else {
            lock.unlock()
            return
        }
        let targetGeneration = positionsGeneration
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: positionsKey)

        lock.lock()
        if positionsGeneration == targetGeneration {
            persistedGeneration = targetGeneration
        }
        lock.unlock()
    }

    public func loadPosition(for url: URL) -> ReadingPosition? {
        lock.lock()
        defer { lock.unlock() }
        let map = loadPositionsMapUnlocked()
        return map[url.standardizedFileURL.path]
    }

    public func migratePath(oldPrefix: String, newPrefix: String) {
        guard oldPrefix != newPrefix else { return }
        lock.lock()
        var map = loadPositionsMapUnlocked()
        var changed = false
        let prefixWithSlash = oldPrefix + "/"
        var updates: [(oldKey: String, newKey: String, value: ReadingPosition)] = []
        for (key, value) in map {
            if key == oldPrefix {
                updates.append((key, newPrefix, value))
            } else if key.hasPrefix(prefixWithSlash) {
                let suffix = String(key.dropFirst(oldPrefix.count))
                updates.append((key, newPrefix + suffix, value))
            }
        }
        for item in updates {
            map.removeValue(forKey: item.oldKey)
            map[item.newKey] = item.value
            changed = true
        }
        guard changed else {
            lock.unlock()
            return
        }
        cachedPositions = map
        positionsGeneration &+= 1
        lock.unlock()

        flushPositionsNow()
    }

    public func saveRecentFiles(_ items: [RecentFileItem]) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = Array(items.prefix(30))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: recentFilesKey)
        }
    }

    public func loadRecentFiles() -> [RecentFileItem] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: recentFilesKey),
              let items = try? JSONDecoder().decode([RecentFileItem].self, from: data) else {
            return []
        }
        return items
    }

    public func saveTheme(_ theme: ReadingTheme) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(theme.rawValue, forKey: themeKey)
    }

    public func loadTheme() -> ReadingTheme {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = defaults.string(forKey: themeKey),
              let theme = ReadingTheme(rawValue: raw) else {
            return .original
        }
        return theme
    }

    public func saveSession(_ session: SavedWorkspaceSession) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    public func loadSession() -> SavedWorkspaceSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SavedWorkspaceSession.self, from: data) else {
            return nil
        }
        return session
    }

    private func loadPositionsMapUnlocked() -> [String: ReadingPosition] {
        if let cachedPositions {
            return cachedPositions
        }
        let map: [String: ReadingPosition]
        if let data = defaults.data(forKey: positionsKey),
           let decoded = try? JSONDecoder().decode([String: ReadingPosition].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
        cachedPositions = map
        return map
    }
}
