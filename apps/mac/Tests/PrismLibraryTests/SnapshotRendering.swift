import AppKit
import PrismKit
import SwiftUI
import Testing
@testable import PrismLibrary

/// Renders the library's screens and windows to PNG for visual review. Runs only when
/// `PRISM_LIBRARY_SNAPSHOTS=<dir>` is set; `PRISM_LIBRARY_APPEARANCE=dark` switches the appearance.
@MainActor
@Suite struct SnapshotRendering {
    nonisolated static let directory = ProcessInfo.processInfo.environment["PRISM_LIBRARY_SNAPSHOTS"]

    @Test(.enabled(if: directory != nil)) func renderLibrarySurfaces() async throws {
        let output = URL(filePath: Self.directory!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dark = ProcessInfo.processInfo.environment["PRISM_LIBRARY_APPEARANCE"] == "dark"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let korean = ProcessInfo.processInfo.environment["PRISM_LIBRARY_LANGUAGE"] == "ko"
        if korean {
            L10n.overrideBundle = Bundle(path: try #require(L10n.moduleBundle.path(forResource: "ko", ofType: "lproj")))
        }
        locale = Locale(identifier: korean ? "ko" : "en")
        _ = NSApplication.shared
        NSApp.appearance = appearance

        let context = FakeContext(directory: FileManager.default.temporaryDirectory.appending(path: "prism-snap-\(UUID().uuidString)"))
        let model = LibraryModel(store: try LibraryStore(database: try SQLiteDatabase.inMemory()))
        let services = LibraryServices(context: context, model: model)
        services.runner.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.prism.snap"))
        services.runner.copy("Prism")
        for entry in [
            LibraryEntry(id: "l1", kind: .link, title: "GitHub", value: "https://github.com"),
            LibraryEntry(id: "l2", kind: .link, title: "Google Search", value: "https://www.google.com/search?q={query}"),
            LibraryEntry(id: "l3", kind: .path, title: "Shared", value: "/Users/Shared"),
            LibraryEntry(id: "s1", kind: .snippet, title: "Email Signature", value: "Best regards,\nKim", keyword: ";sig"),
            LibraryEntry(id: "s2", kind: .snippet, title: "Today", value: "Today is {date} at {time}. Clipboard: {clipboard}"),
            LibraryEntry(id: "s3", kind: .snippet, title: "주소", value: "서울특별시 강남구 테헤란로 123", keyword: ";addr"),
            LibraryEntry(id: "n1", kind: .note, title: "회의 기록", value: "# 회의 기록\n\n결정한 내용을 **정리**합니다.\n\n- [x] 디자인 검토\n- [ ] 출시 준비\n1. 첫째\n\n> 인용문\n\n| 항목 | 담당 |\n| - | - |\n| UI | 김 |\n\n```swift\nlet ready = true\n```"),
            LibraryEntry(id: "n2", kind: .note, title: "Groceries", value: "# Groceries\nMilk, eggs, coffee"),
        ] { try await model.save(entry) }
        try await model.setFavorite(id: "library:l1", title: "GitHub", enabled: true)
        try await model.setFavorite(id: "prism:notes", title: "Notes", enabled: true)

        let palette = CGSize(width: 760, height: 480)
        let links = LibraryScreenModel(services: services, tab: .links)
        try await render(LibraryScreenView(model: links), size: palette, to: output.appending(path: "screen-links.png"))
        let snippets = LibraryScreenModel(services: services, tab: .snippets)
        snippets.selection = 1
        try await render(LibraryScreenView(model: snippets), size: palette, to: output.appending(path: "screen-snippets.png"))
        let favorites = LibraryScreenModel(services: services, tab: .favorites)
        try await render(LibraryScreenView(model: favorites), size: palette, to: output.appending(path: "screen-favorites.png"))
        let deleting = LibraryScreenModel(services: services, tab: .snippets)
        deleting.requestDelete()
        try await render(LibraryScreenView(model: deleting), size: palette, to: output.appending(path: "screen-delete.png"))
        let empty = LibraryScreenModel(services: LibraryServices(context: context, model: LibraryModel(store: nil)), tab: .snippets)
        try await render(LibraryScreenView(model: empty), size: palette, to: output.appending(path: "screen-empty.png"))

        let query = LibraryRunModel(entry: model.entry(id: "l2")!, action: .open, services: services)
        query.query = "swift 마크다운"
        try await render(LibraryRunView(model: query), size: palette, to: output.appending(path: "run-query.png"))
        let template = LibraryRunModel(entry: model.entry(id: "s2")!, action: .copy, services: services)
        try await render(LibraryRunView(model: template), size: palette, to: output.appending(path: "run-template.png"))
        try await render(DeleteConfirmationView(entry: model.entry(id: "s1")!, onConfirm: {}), size: palette,
                         to: output.appending(path: "delete-root.png"))

        let editLink = EntryEditorModel(entry: model.entry(id: "l2")!, isNew: false, model: model)
        try await render(EntryEditorView(model: editLink, onCancel: {}, onSave: {}), size: nil, to: output.appending(path: "editor-link.png"))
        let newPath = EntryEditorModel(entry: LibraryEntry(kind: .path, title: "Shared", value: "/Users/Shared"), isNew: true, model: model)
        try await render(EntryEditorView(model: newPath, onCancel: {}, onSave: {}), size: nil, to: output.appending(path: "editor-path.png"))
        var badSnippet = model.entry(id: "s1")!
        badSnippet.keyword = "sig"
        let snippetEditor = EntryEditorModel(entry: badSnippet, isNew: false, model: model)
        try await render(EntryEditorView(model: snippetEditor, onCancel: {}, onSave: {}), size: nil, to: output.appending(path: "editor-snippet.png"))

        let notes = NotesModel(library: model)
        await notes.openInitial(noteID: "n1")
        try await render(NotesView(model: notes), size: CGSize(width: 900, height: 580), to: output.appending(path: "notes-edit.png"))
        try await render(NotesSidebarList(model: notes).listStyle(.inset), size: CGSize(width: 260, height: 300),
                         to: output.appending(path: "notes-sidebar.png"))
        notes.isPreviewing = true
        try await render(NotesView(model: notes), size: CGSize(width: 900, height: 580), to: output.appending(path: "notes-preview.png"))

        let expander = SnippetExpander(configURL: context.paths.file(SnippetExpansionConfig.fileName), library: model)
        expander.reloadSnippets()
        try await render(LibrarySettingsView(services: services, expander: expander, state: LibrarySettingsState()),
                         size: CGSize(width: 560, height: 1100), to: output.appending(path: "settings.png"))
    }

    @MainActor static var locale = Locale(identifier: "en")
    var locale: Locale {
        get { Self.locale }
        nonmutating set { Self.locale = newValue }
    }

    private func render<Content: View>(_ view: Content, size: CGSize?, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, locale))
        let fitting = size ?? hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: fitting),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
