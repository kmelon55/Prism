import Foundation
import Observation
import PrismCore

/// The in-memory library that the palette, screens, windows and settings share. Reads come from the cache;
/// every mutation goes to SQLite on a background task, then the cache reloads and `didChange` is posted.
@MainActor
@Observable
final class LibraryModel {
    static let didChange = Notification.Name("PrismLibraryDidChange")

    private(set) var entries: [LibraryEntry] = []
    private(set) var favorites: [LibraryFavorite] = []
    private(set) var loadError: String?
    private(set) var hasLoaded = false

    /// Normalized note bodies for full-text search, built off the main actor after each load.
    @ObservationIgnored private(set) var noteSearchIndex: [String: String] = [:]
    @ObservationIgnored let store: LibraryStore?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: LibraryStore?) {
        self.store = store
        if store == nil { loadError = LibraryError.storage.localizedDescription }
    }

    func entry(id: String) -> LibraryEntry? { entries.first { $0.id == id } }

    func entries(of kinds: Set<LibraryEntry.Kind>) -> [LibraryEntry] { entries.filter { kinds.contains($0.kind) } }

    func favoriteOrder(of paletteID: String) -> Int? { favorites.firstIndex { $0.id == paletteID } }

    func isFavorite(_ paletteID: String) -> Bool { favoriteOrder(of: paletteID) != nil }

    /// Loads once; later calls wait for the first load.
    func loadIfNeeded() async {
        if hasLoaded { return }
        if let loading { return await loading.value }
        await reload()
    }

    func reload() async {
        guard let store else { return }
        let task = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(LibrarySnapshot, [String: String]), Error> in
                Result {
                    let snapshot = try store.load()
                    var index: [String: String] = [:]
                    for entry in snapshot.entries where entry.kind == .note {
                        index[entry.id] = TextMatching.normalize(entry.value)
                    }
                    return (snapshot, index)
                }
            }.value
            switch result {
            case .success(let (snapshot, index)):
                if snapshot.entries != entries { entries = snapshot.entries }
                if snapshot.favorites != favorites { favorites = snapshot.favorites }
                noteSearchIndex = index
                loadError = nil
            case .failure:
                loadError = LibraryError.storage.localizedDescription
            }
            hasLoaded = true
        }
        loading = task
        await task.value
        if loading == task { loading = nil }
    }

    // MARK: Mutations

    func save(_ entry: LibraryEntry) async throws {
        try await write { try $0.save(entry) }
    }

    func delete(id: String) async throws {
        try await write { try $0.delete(id: id) }
    }

    func setFavorite(id: String, title: String, enabled: Bool) async throws {
        try await write { try $0.setFavorite(LibraryFavorite(id: id, title: title), enabled: enabled) }
    }

    func reorderFavorites(_ ids: [String]) async throws {
        // Show the new order at once; the reload confirms or restores it.
        let byID = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = ids.compactMap { byID[$0] }
        if reordered.count == favorites.count { favorites = reordered }
        try await write { try $0.reorderFavorites(ids) }
    }

    private func write(_ body: @escaping @Sendable (LibraryStore) throws -> Void) async throws {
        guard let store else { throw LibraryError.storage }
        let result = await Task.detached(priority: .userInitiated) { Result { try body(store) } }.value
        await reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        try result.get()
    }

    /// Test seam: replaces the cache without touching storage.
    func replaceForTesting(entries: [LibraryEntry], favorites: [LibraryFavorite] = []) {
        self.entries = entries
        self.favorites = favorites
        noteSearchIndex = Dictionary(entries.filter { $0.kind == .note }.map { ($0.id, TextMatching.normalize($0.value)) },
                                     uniquingKeysWith: { first, _ in first })
        hasLoaded = true
    }
}
