import AppKit
import PrismKit

/// Quicklinks, snippets, notes, favorites and snippet expansion.
public enum LibraryFeature {
    @MainActor private static var services: LibraryServices?

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let store = try? LibraryStore(url: context.paths.file(LibraryStore.fileName))
        let model = LibraryModel(store: store)
        let services = LibraryServices(context: context, model: model)
        Self.services = services
        LibraryFavorites.install(services.favorites)
        services.editor.onSaved = { [weak context] _ in context?.showHUD(L10n.tr("Saved")) }
        let expander = SnippetExpander(configURL: context.paths.file(SnippetExpansionConfig.fileName), library: model)
        let settingsState = LibrarySettingsState()
        Task { await model.loadIfNeeded() }

        return FeatureContribution(
            providers: [LibraryProvider(services: services)],
            settingsPanes: [
                SettingsPane(id: "library", title: L10n.tr("Snippets"), systemImage: "keyboard", group: .tools, order: 20,
                             keywords: LibrarySettingsView.keywords) {
                    LibrarySettingsView(services: services, expander: expander, state: settingsState)
                },
            ],
            start: { expander.start() }
        )
    }

    /// Opens the snippet editor prefilled with `text`, for "Save as Snippet" in clipboard history.
    @MainActor
    public static func createSnippet(text: String) {
        services?.create(.snippet, value: text)
    }

    /// Reloads entries and favorites from disk after another module (restore, Raycast import) changed them.
    @MainActor
    public static func reload() {
        guard let services else { return }
        Task { await services.model.reload() }
    }

    /// Opens the notes window, optionally on a new blank note.
    @MainActor
    public static func showNotes(newNote: Bool = false) {
        guard let services else { return }
        if newNote { services.notes.showNewNote() } else { services.notes.show() }
    }
}
