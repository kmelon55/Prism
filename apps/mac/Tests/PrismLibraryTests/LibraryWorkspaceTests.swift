import AppKit
import PrismKit
import Testing
@testable import PrismLibrary

/// The Tauri library workspace: a Notes tab, and notes opening inside the palette instead of a window.
@MainActor
@Suite struct LibraryWorkspaceTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-library-workspace-\(UUID().uuidString)")

    func makeServices() throws -> (LibraryServices, FakeContext) {
        let context = FakeContext(directory: directory)
        let model = LibraryModel(store: try LibraryStore(database: try SQLiteDatabase.inMemory()))
        let services = LibraryServices(context: context, model: model)
        services.runner.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.prism.tests.\(UUID().uuidString)"))
        return (services, context)
    }

    @Test func notesTabListsNotesAndLeadsTheTabs() async throws {
        let (services, _) = try makeServices()
        try await services.model.save(LibraryEntry(id: "n1", kind: .note, title: "Plan", value: "# Plan\nShip it"))
        try await services.model.save(LibraryEntry(id: "s1", kind: .snippet, title: "Sig", value: "Best"))
        #expect(LibraryScreenModel.Tab.allCases == [.notes, .links, .snippets, .favorites])
        let screen = LibraryScreenModel(services: services, tab: .notes)
        #expect(screen.rows.map(\.id) == ["library:n1"])
        #expect(screen.rows.first?.subtitle == "# Plan Ship it")
        screen.cycleTab(by: -1)
        #expect(screen.tab == .favorites)
        screen.cycleTab(by: 1)
        #expect(screen.tab == .notes)
    }

    @Test func notesOpenAsAnExpandedPaletteScreen() async throws {
        let (services, context) = try makeServices()
        try await services.model.save(LibraryEntry(id: "n1", kind: .note, title: "Plan", value: "# Plan"))
        services.notes.show(noteID: "n1")
        #expect(context.shownScreens == ["notes"])
        #expect(context.hidden == 0)
        services.create(.note)
        #expect(context.hidden == 0, "A new note opens in the palette without hiding it")

        let entry = try #require(services.model.entry(id: "n1"))
        let open = try #require(services.actions(for: entry).first)
        guard case .push(let screen) = await open.run() else {
            Issue.record("Opening a note should push the notes screen")
            return
        }
        #expect(screen.id == "notes")
        #expect(screen.expanded)
    }
}
