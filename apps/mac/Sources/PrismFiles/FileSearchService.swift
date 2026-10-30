import Foundation
import Observation

/// Owns the additional search folders and their index, and answers filename queries by merging Spotlight
/// with the index. Indexing is demand-driven: opening the palette refreshes a stale index in the background,
/// rereading only folders whose modification time changed. There is no watcher or idle scan.
@MainActor
@Observable
final class FileSearchService {
    static let spotlightDefaultsKey = "files.spotlightEnabled"
    static let staleAfter: Duration = .seconds(30)

    private(set) var roots: [SearchRoot] = []
    private(set) var snapshot = FolderSnapshot.empty
    private(set) var isIndexing = false
    private(set) var lastError: String?
    var spotlightEnabled: Bool {
        didSet { defaults.set(spotlightEnabled, forKey: Self.spotlightDefaultsKey) }
    }

    @ObservationIgnored private let store: SearchRootsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let spotlight: @Sendable (FilenameQuery) async -> [FileHit]
    @ObservationIgnored private let recentFiles: @Sendable () async -> [FileHit]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    /// Fences publication: a scan started before the folder list changed never replaces a newer index.
    @ObservationIgnored private var generation = 0

    init(
        store: SearchRootsStore, defaults: UserDefaults = .standard,
        spotlight: @escaping @Sendable (FilenameQuery) async -> [FileHit] = { await SpotlightSearch.search($0) },
        recent: @escaping @Sendable () async -> [FileHit] = { await SpotlightSearch.recent() }
    ) {
        recentFiles = recent
        self.store = store
        self.defaults = defaults
        self.spotlight = spotlight
        // `bool(forKey:)` also reads `-files.spotlightEnabled NO` from the command line.
        spotlightEnabled = defaults.object(forKey: Self.spotlightDefaultsKey) == nil || defaults.bool(forKey: Self.spotlightDefaultsKey)
        reloadRoots()
    }

    var indexedCount: Int { snapshot.files.count }
    var isLimited: Bool { snapshot.limited }

    func reloadRoots() {
        do {
            roots = try store.load()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addRoot(_ folder: URL) throws {
        roots = try store.add(folder)
        invalidate()
    }

    func removeRoot(_ root: SearchRoot) throws {
        roots = try store.remove(id: root.id)
        invalidate()
    }

    /// Clears the index immediately so removed folders never show stale rows, then rescans.
    private func invalidate() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        snapshot = .empty
        lastRefresh = nil
        refresh(force: true)
    }

    /// Rescans when the index is older than `staleAfter`, or always with `force`.
    func refresh(force: Bool = false) {
        guard refreshTask == nil else { return }
        if !force, let lastRefresh, ContinuousClock.now - lastRefresh < Self.staleAfter { return }
        let paths = roots.map(\.path)
        guard !paths.isEmpty else {
            snapshot = .empty
            lastRefresh = .now
            return
        }
        let previous = force ? nil : snapshot
        let generation = generation
        isIndexing = true
        refreshTask = Task {
            let next = await Task.detached(priority: .utility) {
                FolderSnapshot.scan(roots: paths, previous: previous)
            }.value
            guard generation == self.generation else { return }
            snapshot = next
            lastRefresh = .now
            isIndexing = false
            refreshTask = nil
        }
    }

    func waitForIndex() async {
        await refreshTask?.value
    }

    /// Spotlight and indexed matches for `query`, best first, with the total match count.
    func search(_ text: String, filter: FileTypeFilter = .all, limit: Int) async -> (hits: [FileHit], total: Int) {
        let query = FilenameQuery(text)
        guard !query.isEmpty else { return ([], 0) }
        let snapshot = snapshot
        let spotlight = spotlightEnabled ? spotlight : nil
        async let indexed = Task.detached(priority: .userInitiated) {
            snapshot.page(query, filter: filter, limit: 500).hits
        }.value
        async let system = spotlight?(query) ?? []
        let sources = await [indexed, system]
        if Task.isCancelled { return ([], 0) }
        return await Task.detached(priority: .userInitiated) {
            FileRanking.merge(sources, query: query, filter: filter, limit: limit)
        }.value
    }

    /// Recently used files from Spotlight, shown before anything is typed.
    func recent(filter: FileTypeFilter = .all) async -> [FileHit] {
        guard spotlightEnabled else { return [] }
        return await recentFiles().filter { filter.matches(name: $0.name, isDirectory: $0.isDirectory) }
    }
}
