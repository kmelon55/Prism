import AppKit
import PrismCore
import PrismKit

/// Filename search through Spotlight and indexed folders: file rows in root search, the `prism:files`
/// browser with previews, and the Files settings pane.
public enum FileSearchFeature {
    public static let commandID = "prism:files"
    /// Root results shown per query. The browser shows more.
    static let rootLimit = 8

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let service = FileSearchService(store: SearchRootsStore(url: context.paths.file(SearchRootsStore.fileName)))
        return FeatureContribution(
            providers: [FileCommandProvider(service: service, context: context), FileResultsProvider(service: service, context: context)],
            settingsPanes: [FilesSettingsPane.make(service: service)],
            start: { service.refresh(force: true) }
        )
    }

    @MainActor
    static func browserScreen(service: FileSearchService, context: any PrismContext, query: String = "") -> PaletteScreen {
        // Built once per opening: the palette may evaluate the screen's content many times.
        let model = FileBrowserModel(service: service, context: context, query: query)
        return PaletteScreen(id: "files", title: String(localized: "File Search", bundle: .module), expanded: true) { [weak context] in
            FileBrowserView(model: model, onClose: { context?.popScreen() })
        }
    }

    @MainActor
    static func openWithScreen(_ hit: FileHit, context: any PrismContext) -> PaletteScreen {
        PaletteScreen(id: "files-open-with", title: String(localized: "Open With…", bundle: .module)) { [weak context] in
            OpenWithView(hit: hit, onOpen: { context?.hidePalette() }, onCancel: { context?.popScreen() })
        }
    }
}

/// The `prism:files` command row. Also refreshes a stale folder index whenever the palette opens.
@MainActor
final class FileCommandProvider: PaletteProvider {
    let id = "files-command"
    private let service: FileSearchService
    private weak var context: (any PrismContext)?

    init(service: FileSearchService, context: any PrismContext) {
        self.service = service
        self.context = context
    }

    func results(for query: String) async -> [PaletteItem] {
        if query.isEmpty { service.refresh() }
        let candidate = SearchCandidate(
            id: FileSearchFeature.commandID,
            title: String(localized: "File Search", bundle: .module),
            subtitle: String(localized: "Search filenames directly in the palette", bundle: .module),
            section: String(localized: "Productivity", bundle: .module),
            keywords: ["files", "파일", "검색", "folders", "finder", "폴더"],
            searchAliases: ["File Search", "파일 검색", "Search Files"]
        )
        let service = service
        return [PaletteItem(
            candidate: candidate,
            icon: .symbol("doc.text.magnifyingglass", tint: .blue),
            accessory: String(localized: "Command", bundle: .module),
            actions: [
                PaletteAction(id: "open-files", title: String(localized: "Open", bundle: .module), systemImage: "doc.text.magnifyingglass") { [weak context] in
                    guard let context else { return .keepOpen }
                    return .push(FileSearchFeature.browserScreen(service: service, context: context))
                },
            ]
        )]
    }
}

/// File and folder rows for the typed query, after the ranked commands and apps.
@MainActor
final class FileResultsProvider: PaletteProvider {
    let id = "files"
    let ranking = PaletteRanking.appended
    private let service: FileSearchService
    private weak var context: (any PrismContext)?

    init(service: FileSearchService, context: any PrismContext) {
        self.service = service
        self.context = context
    }

    /// One Latin letter matches most of the disk; wait for a second character. A Hangul syllable is enough.
    static func isSearchable(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return false }
        return trimmed.count >= 2 || !first.isASCII
    }

    func results(for query: String) async -> [PaletteItem] {
        guard Self.isSearchable(query) else { return [] }
        // Typing replaces this task; a short pause avoids a Spotlight query for every keystroke.
        try? await Task.sleep(for: .milliseconds(70))
        guard !Task.isCancelled else { return [] }
        let found = await service.search(query, limit: FileSearchFeature.rootLimit)
        guard !Task.isCancelled else { return [] }
        let section = String(localized: "Files", bundle: .module)
        var items = found.hits.map { item(for: $0, section: section) }
        if found.total > found.hits.count {
            items.append(showAllItem(query: query, total: found.total, section: section))
        }
        return items
    }

    private func item(for hit: FileHit, section: String) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(id: "file:\(hit.path)", title: hit.name, subtitle: hit.displayLocation, section: section),
            icon: .file(path: hit.path),
            accessory: FileActions.kind(of: hit),
            actions: FileActions.actions(for: hit) { [weak context] hit in
                guard let context else { return .keepOpen }
                return .push(FileSearchFeature.openWithScreen(hit, context: context))
            }
        )
    }

    private func showAllItem(query: String, total: Int, section: String) -> PaletteItem {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = service
        return PaletteItem(
            candidate: SearchCandidate(
                id: "files:search-broader", title: String(localized: "Show All \(total) Files", bundle: .module),
                subtitle: trimmed, section: section
            ),
            icon: .symbol("doc.text.magnifyingglass"),
            actions: [
                PaletteAction(id: "files-search-broader", title: String(localized: "Open in File Search", bundle: .module), systemImage: "doc.text.magnifyingglass") { [weak context] in
                    guard let context else { return .keepOpen }
                    return .push(FileSearchFeature.browserScreen(service: service, context: context, query: trimmed))
                },
            ]
        )
    }
}
