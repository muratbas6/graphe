import Foundation

public protocol VocabularyStoring: Sendable {
    func loadItems() -> [VocabularyItem]
    func saveItems(_ items: [VocabularyItem])
}

public final class UserDefaultsVocabularyStore: VocabularyStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "graphe.vocabulary.v1"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadItems() -> [VocabularyItem] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([VocabularyItem].self, from: data) else {
            return []
        }
        return items
    }

    public func saveItems(_ items: [VocabularyItem]) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
