import AppKit
import Foundation
import PrismKit
import SwiftUI
import Testing
@testable import PrismFiles

struct SpotlightQueryTests {
    @Test func buildsEscapedNameClausesForEveryTokenInBothNormalizationForms() {
        #expect(SpotlightSearch.queryString(for: FilenameQuery("Report")) == #"kMDItemFSName == "*report*"cd"#)
        #expect(SpotlightSearch.queryString(for: FilenameQuery("a\"b *c")) == #"kMDItemFSName == "*a\"b*"cd && kMDItemFSName == "*\*c*"cd"#)
        let korean = SpotlightSearch.queryString(for: FilenameQuery("계획"))!
        #expect(korean.contains("계획".precomposedStringWithCanonicalMapping))
        #expect(korean.contains("계획".decomposedStringWithCanonicalMapping))
        #expect(korean.hasPrefix("(") && korean.contains(" || "))
        #expect(SpotlightSearch.queryString(for: FilenameQuery("   ")) == nil)
    }

    @Test func acceptsOnlyRegularFilesAndFoldersInsideTheScope() throws {
        let fixture = Fixture()
        fixture.write("Docs/plan.txt")
        fixture.write(".hidden/plan.txt")
        fixture.write("node_modules/plan.txt")
        fixture.write("Tool.app/Contents/plan.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/link.txt", withDestinationPath: fixture.root + "/Docs/plan.txt")
        #expect(SpotlightSearch.accept(path: fixture.root + "/Docs/plan.txt", scope: fixture.root)?.isDirectory == false)
        #expect(SpotlightSearch.accept(path: fixture.root + "/Docs", scope: fixture.root)?.isDirectory == true)
        #expect(SpotlightSearch.accept(path: fixture.root + "/.hidden/plan.txt", scope: fixture.root) == nil)
        #expect(SpotlightSearch.accept(path: fixture.root + "/node_modules/plan.txt", scope: fixture.root) == nil)
        #expect(SpotlightSearch.accept(path: fixture.root + "/Tool.app/Contents/plan.txt", scope: fixture.root) == nil)
        #expect(SpotlightSearch.accept(path: fixture.root + "/link.txt", scope: fixture.root) == nil)
        #expect(SpotlightSearch.accept(path: "/etc/hosts", scope: fixture.root) == nil)
        #expect(SpotlightSearch.accept(path: fixture.root, scope: fixture.root) == nil)
    }

    @Test func liveQueryReturnsPromptlyAndHonorsCancellation() async {
        let clock = ContinuousClock()
        let started = clock.now
        let hits = await SpotlightSearch.search(FilenameQuery("prism-no-such-file-\(UUID().uuidString)"), timeout: .seconds(2))
        #expect(hits.isEmpty)
        #expect(clock.now - started < .seconds(3))
        let task = Task { await SpotlightSearch.search(FilenameQuery("a"), timeout: .seconds(5)) }
        task.cancel()
        _ = await task.value
        #expect(clock.now - started < .seconds(6))
    }
}

@MainActor
struct FileSearchServiceTests {
    let fixture = Fixture()
    let data = Fixture()
    var store: SearchRootsStore { SearchRootsStore(url: URL(filePath: data.root + "/library-v1.sqlite3")) }

    func makeService(spotlight: [FileHit] = [], enabled: Bool = true) -> FileSearchService {
        let defaults = UserDefaults(suiteName: "prism-files-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: FileSearchService.spotlightDefaultsKey)
        return FileSearchService(store: store, defaults: defaults, spotlight: { _ in spotlight }, recent: { spotlight })
    }

    @Test func rootsUseTheTauriTableAndLeaveOtherLibraryTablesAlone() throws {
        let database = try SQLiteDatabase(url: store.url)
        try database.execute("CREATE TABLE entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL,keyword TEXT); INSERT INTO entries VALUES('e','snippet','인사','안녕',NULL);")
        try database.execute("CREATE TABLE roots(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE); INSERT INTO roots VALUES('legacy','/Volumes/Archive');")
        #expect(try store.load() == [SearchRoot(id: "legacy", path: "/Volumes/Archive")])

        fixture.mkdir("Projects")
        let roots = try store.add(URL(filePath: fixture.root + "/Projects/../Projects"))
        #expect(roots.count == 2)
        #expect(roots[1].path == fixture.root + "/Projects")
        #expect(roots[1].id.count == 32 && roots[1].id == roots[1].id.lowercased())
        #expect(try store.add(URL(filePath: fixture.root + "/Projects")).count == 2)
        #expect(try store.remove(id: "legacy").map(\.path) == [fixture.root + "/Projects"])
        #expect(try database.scalar("SELECT count(*) FROM entries") == 1)
    }

    @Test func limitsSearchFoldersToTwelve() throws {
        for index in 0..<SearchRootsStore.maxRoots {
            fixture.mkdir("f\(index)")
            try store.add(URL(filePath: fixture.root + "/f\(index)"))
        }
        fixture.mkdir("extra")
        #expect(throws: SearchRootsStore.StoreError.self) { try store.add(URL(filePath: fixture.root + "/extra")) }
        #expect(throws: SearchRootsStore.StoreError.self) { try store.add(URL(filePath: fixture.root + "/missing")) }
    }

    @Test func missingDatabaseIsNotCreatedJustToReadRoots() throws {
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func mergesSpotlightWithTheFolderIndexAndRevokesRemovedFolders() async throws {
        fixture.write("Projects/trip plan.md")
        let service = makeService(spotlight: [FileHit(path: "/Users/someone/plan.md", isDirectory: false)])
        try service.addRoot(URL(filePath: fixture.root + "/Projects"))
        await service.waitForIndex()
        #expect(service.indexedCount == 1)
        let found = await service.search("plan", limit: 10)
        #expect(found.hits.map(\.name) == ["plan.md", "trip plan.md"])

        try service.removeRoot(service.roots[0])
        #expect(service.indexedCount == 0)
        #expect(await service.search("plan", limit: 10).hits.map(\.name) == ["plan.md"])
    }

    @Test func spotlightCanBeTurnedOff() async throws {
        let service = makeService(spotlight: [FileHit(path: "/Users/someone/plan.md", isDirectory: false)], enabled: false)
        #expect(await service.search("plan", limit: 10).hits.isEmpty)
        #expect(await service.recent().isEmpty)
        service.spotlightEnabled = true
        #expect(await service.search("plan", limit: 10).hits.count == 1)
    }

    @Test func rootProviderWaitsForASecondLatinCharacter() {
        #expect(!FileResultsProvider.isSearchable(""))
        #expect(!FileResultsProvider.isSearchable(" a "))
        #expect(FileResultsProvider.isSearchable("ab"))
        #expect(FileResultsProvider.isSearchable("문"))
    }

    @Test func browserSearchesFiltersAndMatchesActionShortcuts() async throws {
        fixture.write("Projects/plan.md")
        fixture.write("Projects/plan.png")
        let service = makeService()
        try service.addRoot(URL(filePath: fixture.root + "/Projects"))
        await service.waitForIndex()
        let model = FileBrowserModel(service: service, context: nil, query: "plan")
        model.scheduleSearch(immediately: true)
        while !model.isCurrent { await Task.yield() }
        #expect(model.results.map(\.name) == ["plan.md", "plan.png"])
        model.filter = .image
        while !model.isCurrent { await Task.yield() }
        #expect(model.results.map(\.name) == ["plan.png"])
        model.cycleFilter(by: 1)
        #expect(model.filter == .document)
        model.filter = .all
        while !model.isCurrent { await Task.yield() }

        #expect(model.handle(.down))
        #expect(model.selectedHit?.name == "plan.png")
        #expect(model.selectedActions.map(\.id) == ["file-open", "file-reveal", "file-open-with", "file-quick-look", "file-copy", "file-copy-file"])
        let quickLook = model.selectedActions[3].shortcut!
        #expect(FileBrowserModel.matches(quickLook, key: "y", modifiers: .command))
        #expect(!FileBrowserModel.matches(quickLook, key: "y", modifiers: [.command, .shift]))
        let copyPath = model.selectedActions[4].shortcut!
        #expect(FileBrowserModel.matches(copyPath, key: "c", modifiers: [.command, .shift, .capsLock]))

        model.toggleActions()
        #expect(model.showsActions)
        #expect(model.handle(.down) && model.actionSelection == 1)
        #expect(model.handle(.cancel) && !model.showsActions)
        #expect(model.handle(.cancel) && model.query.isEmpty)
        #expect(!model.handle(.cancel))
    }
}
