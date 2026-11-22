import Foundation

public protocol ReadingPositionStoring: Sendable {
    func savePosition(_ position: ReadingPosition, for url: URL)
    func loadPosition(for url: URL) -> ReadingPosition?
    func migratePath(oldPrefix: String, newPrefix: String)
    func saveRecentFiles(_ items: [RecentFileItem])
    func loadRecentFiles() -> [RecentFileItem]
    func saveTheme(_ theme: ReadingTheme)
    func loadTheme() -> ReadingTheme
    func saveSession(_ session: SavedWorkspaceSession)
    func loadSession() -> SavedWorkspaceSession?
}

public extension ReadingPositionStoring {
    func migratePath(oldPrefix: String, newPrefix: String) {}
}

public final class UserDefaultsPositionStore: ReadingPositionStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let positionsKey = "graphe.readingPositions.v1"
    private let recentFilesKey = "graphe.recentFiles.v1"
    private let themeKey = "graphe.readingTheme.v1"
    private let sessionKey = "graphe.workspaceSession.v1"
    private let lock = NSLock()
    private var cachedPositions: [String: ReadingPosition]?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func savePosition(_ position: ReadingPosition, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadPositionsMapUnlocked()
        let key = url.standardizedFileURL.path
        if let existing = map[key],
           existing.pageIndex == position.pageIndex,
           abs(existing.scaleFactor - position.scaleFactor) < 0.0001 {
            return
        }
        map[key] = position
        cachedPositions = map
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: positionsKey)
        }
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
        defer { lock.unlock() }
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
        guard changed else { return }
        cachedPositions = map
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: positionsKey)
        }
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
