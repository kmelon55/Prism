import AppKit
import PrismCore
import PrismKit
import Testing
@testable import PrismLibrary

@MainActor
final class FakeContext: PrismContext {
    let paths: AppPaths
    var previousApplication: NSRunningApplication? { nil }
    var huds: [String] = []
    var hidden = 0
    var shownScreens: [String] = []

    init(directory: URL) { paths = AppPaths(dataDirectory: directory) }
    func showPalette() {}
    func hidePalette() { hidden += 1 }
    func showPalette(screen: PaletteScreen) { shownScreens.append(screen.id) }
    func openSettings(paneID: String?) {}
    func showHUD(_ message: String) { huds.append(message) }
}

@MainActor
@Suite struct LibraryProviderTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-library-tests-\(UUID().uuidString)")

    func makeServices() throws -> (LibraryServices, FakeContext) {
        let context = FakeContext(directory: directory)
        let store = try LibraryStore(database: try SQLiteDatabase.inMemory())
        let model = LibraryModel(store: store)
        let services = LibraryServices(context: context, model: model)
        services.runner.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.prism.tests.\(UUID().uuidString)"))
        return (services, context)
    }

    @Test func rowsUseTauriIDsSectionsAndAliases() async throws {
        let (services, _) = try makeServices()
        try await services.model.save(LibraryEntry(id: "s1", kind: .snippet, title: "Email", value: "me@example.com", keyword: ";em"))
        try await services.model.save(LibraryEntry(id: "l1", kind: .link, title: "Docs", value: "https://example.com/docs"))
        try await services.model.save(LibraryEntry(id: "n1", kind: .note, title: "Plan", value: "# Plan\nbody"))
        try await services.model.setFavorite(id: "library:l1", title: "Docs", enabled: true)
        let provider = LibraryProvider(services: services)
        let items = await provider.results(for: "")
        let ids = Set(items.map(\.id))
        for id in ["prism:notes", "prism:new-note", "prism:links", "prism:snippets", "prism:library", "library:s1", "library:l1", "library:n1"] {
            #expect(ids.contains(id), "\(id)")
        }
        let snippet = try #require(items.first { $0.id == "library:s1" })
        #expect(snippet.candidate.searchAliases == [";em"])
        #expect(snippet.section == "Snippets")
        #expect(snippet.actions.map(\.id) == ["library-copy", "library-paste", "library-edit", "toggle-favorite", "library-delete"])
        let link = try #require(items.first { $0.id == "library:l1" })
        #expect(link.candidate.favoriteOrder == 0)
        #expect(!link.hiddenWhenQueryIsEmpty)
        #expect(snippet.hiddenWhenQueryIsEmpty)
        #expect(link.actions.first?.id == "library-open")
        let note = try #require(items.first { $0.id == "library:n1" })
        #expect(note.actions.first?.id == "library-edit")
        // The keyword ranks the snippet first through its alias.
        let ranked = CommandSearch.rank(await provider.results(for: ";em"), query: ";em") { $0.candidate }
        #expect(ranked.first?.id == "library:s1")
    }

    @Test func notesMatchTheWholeBody() async throws {
        let (services, _) = try makeServices()
        let body = "# 회의\n" + String(repeating: "내용 ", count: 100) + "숨은단어"
        try await services.model.save(LibraryEntry(id: "n1", kind: .note, title: "회의", value: body))
        let provider = LibraryProvider(services: services)
        let ranked = CommandSearch.rank(await provider.results(for: "숨은단어"), query: "숨은단어") { $0.candidate }
        #expect(ranked.map(\.id) == ["library:n1"])
        #expect(CommandSearch.rank(await provider.results(for: "없는말"), query: "없는말") { $0.candidate }.allSatisfy { $0.id != "library:n1" })
    }

    @Test func staticEntriesRunAndDynamicEntriesOpenThePreview() async throws {
        let (services, _) = try makeServices()
        let snippet = LibraryEntry(id: "s", kind: .snippet, title: "Hi", value: "hello")
        let dated = LibraryEntry(id: "d", kind: .snippet, title: "Today", value: "Today is {date}")
        try await services.model.save(snippet)
        try await services.model.save(dated)
        guard case .notify = await services.perform(snippet, action: .copy) else { Issue.record("copy should notify"); return }
        #expect(services.runner.pasteboard.string(forType: .string) == "hello")
        guard case .push(let screen) = await services.perform(dated, action: .copy) else { Issue.record("expected preview screen"); return }
        #expect(screen.id == "library-run-d")
    }

    @Test func runRechecksTheEntryAfterThePreview() async throws {
        let (services, _) = try makeServices()
        var entry = LibraryEntry(id: "q", kind: .link, title: "Search", value: "https://example.com/?q={query}")
        try await services.model.save(entry)
        let preview = try services.runner.prepare(entry, query: "swift ui")
        #expect(preview == "https://example.com/?q=swift%20ui")
        entry.value = "https://example.org/?q={query}"
        try await services.model.save(entry)
        var stale = entry
        stale.value = "https://example.com/?q={query}"
        let result = await services.runner.run(stale, value: preview, action: .open)
        guard case .failure(let error) = result else { Issue.record("a changed entry must not run"); return }
        #expect(error as? LibraryError == .entryChanged)
        try await services.model.delete(id: "q")
        guard case .failure(let deleted) = await services.runner.run(entry, value: preview, action: .open) else { Issue.record("deleted"); return }
        #expect(deleted as? LibraryError == .entryDeleted)
    }

    @Test func runModelPreviewsQueryAndClipboardPlaceholders() async throws {
        let (services, _) = try makeServices()
        let link = LibraryEntry(id: "q", kind: .link, title: "Search", value: "https://example.com/?q={query}")
        try await services.model.save(link)
        let model = LibraryRunModel(entry: link, action: .open, services: services)
        #expect(model.preview == nil)
        #expect(model.error == nil)
        model.query = "가"
        #expect(model.preview == "https://example.com/?q=%EA%B0%80")
        services.runner.copy("clip")
        let snippet = LibraryEntry(id: "c", kind: .snippet, title: "Clip", value: "<{clipboard}>")
        try await services.model.save(snippet)
        #expect(LibraryRunModel(entry: snippet, action: .copy, services: services).preview == "<clip>")
    }

    @Test func favoritesAPIMovesAndRemoves() async throws {
        let (services, _) = try makeServices()
        let favorites = services.favorites
        try await favorites.add(id: "native:com.apple.Safari", title: "Safari")
        try await favorites.add(id: "prism:notes", title: "Notes")
        try await favorites.add(id: "window:left-half", title: "Left Half")
        #expect(favorites.ids == ["native:com.apple.Safari", "prism:notes", "window:left-half"])
        try await favorites.move(id: "window:left-half", by: -2)
        #expect(favorites.ids == ["window:left-half", "native:com.apple.Safari", "prism:notes"])
        try await favorites.move(id: "prism:notes", by: 1)
        #expect(favorites.order(of: "prism:notes") == 2)
        try await favorites.remove(id: "native:com.apple.Safari")
        #expect(favorites.ids == ["window:left-half", "prism:notes"])
        #expect(!favorites.contains("native:com.apple.Safari"))
        let item = PaletteItem(candidate: SearchCandidate(id: "prism:notes", title: "Notes"), icon: .none, actions: [])
        let action = favorites.toggleAction(for: item)
        #expect(action.title == "Remove from Favorites")
        _ = await action.run()
        #expect(!favorites.contains("prism:notes"))
    }

    @Test func screenFiltersByTabAndQuery() async throws {
        let (services, _) = try makeServices()
        try await services.model.save(LibraryEntry(id: "a", kind: .link, title: "GitHub", value: "https://github.com"))
        try await services.model.save(LibraryEntry(id: "b", kind: .path, title: "Downloads", value: "/tmp"))
        try await services.model.save(LibraryEntry(id: "c", kind: .snippet, title: "Signature", value: "Best"))
        let screen = LibraryScreenModel(services: services, tab: .links)
        #expect(Set(screen.rows.map(\.id)) == ["library:a", "library:b"])
        screen.query = "git"
        #expect(screen.rows.map(\.id) == ["library:a"])
        screen.tab = .snippets
        #expect(screen.query == "")
        #expect(screen.rows.map(\.id) == ["library:c"])
        screen.cycleTab(by: 1)
        #expect(screen.tab == .favorites)
        #expect(screen.rows.isEmpty)
    }

    @Test func notesModelAutosavesAndDerivesTitles() async throws {
        let (services, _) = try makeServices()
        let notes = NotesModel(library: services.model)
        await notes.openInitial(noteID: nil)
        #expect(notes.document?.value == "")
        #expect(!notes.isPersisted)
        // Untouched blank notes are not created.
        #expect(await notes.settle())
        #expect(services.model.entries.isEmpty)
        notes.documentText = "# 장보기\n- 우유"
        #expect(await notes.settle())
        let saved = try #require(services.model.entries.first)
        #expect(saved.title == "장보기")
        #expect(saved.value == "# 장보기\n- 우유")
        #expect(notes.isPersisted)
        await notes.delete()
        #expect(services.model.entries.isEmpty)
    }
}
