import AppKit
import Observation
import PrismCore
import PrismKit
import SwiftUI

@MainActor
@Observable
final class PaletteModel {
    struct Section: Identifiable {
        struct Row: Identifiable {
            var id: String { item.id }
            /// Position in `results`, so selection stays a single flat index.
            let index: Int
            let item: PaletteItem
        }

        var id: String { title }
        var title: String
        /// Rows carry their items so a view never reads `results` with an index from an older ranking.
        var rows: [Row]
    }

    var query = ""
    var selection = 0
    private(set) var results: [PaletteItem] = []
    private(set) var sections: [Section] = []
    private(set) var screens: [PaletteScreen] = []
    /// The item whose actions are listed in the ⌘K panel.
    private(set) var actionPanelItem: PaletteItem?
    var actionSelection = 0
    /// Filters the ⌘K panel's actions ("Search actions…").
    var actionQuery = "" { didSet { if actionQuery != oldValue { actionSelection = 0 } } }
    /// Counts pushed screens, so an action that opened a screen through the app context keeps the palette open
    /// even when it then asks to dismiss (for example Notes, which opens inside the palette).
    @ObservationIgnored private(set) var pushCount = 0
    /// Incremented whenever the palette opens or returns to the root so the view can focus the search field.
    private(set) var focusToken = 0

    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Favorite position of a row ID, applied to every searchable row so favorites lead the empty query.
    @ObservationIgnored var favoriteOrder: ((String) -> Int?)?
    /// User aliases by row ID. An exact alias match outranks a title match.
    @ObservationIgnored var aliases: () -> [String: [String]] = { [:] }
    /// Commands turned off in Settings → Commands; they stay out of results but remain listed in that table.
    @ObservationIgnored var isDisabled: (String) -> Bool = { _ in false }
    /// Adds "Add to Favorites" to rows that do not offer their own favorite action.
    @ObservationIgnored var favoriteAction: ((PaletteItem) -> PaletteAction?)?
    @ObservationIgnored var onNotify: ((String) -> Void)?
    /// Frecency of a row ID from past runs. It breaks ties inside a match tier and fills the empty query's Recent section.
    @ObservationIgnored var usageBoost: (String) -> Double = { _ in 0 }
    /// Called when a row's primary action runs, so its usage can be recorded.
    @ObservationIgnored var onUse: ((String) -> Void)?
    @ObservationIgnored private var providers: [any PaletteProvider] = []
    @ObservationIgnored private var published: [String: [PaletteItem]] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    /// Selection follows the best row until the user moves it, as in the Tauri app. A slower provider's
    /// better answer then takes the top without stealing a row the user chose.
    @ObservationIgnored private var userMovedSelection = false

    var hasPendingProviders: Bool { !tasks.isEmpty }

    /// Whether the top screen wants the larger workspace.
    var isExpanded: Bool { screens.last?.expanded == true }

    func install(_ providers: [any PaletteProvider]) {
        self.providers = providers
    }

    /// Finds a searchable row by ID across providers, for command hotkeys.
    func item(withID id: String) async -> PaletteItem? {
        for provider in providers where provider.ranking == .search {
            if let item = await provider.results(for: "").first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// Every searchable row for the empty query, for the shortcut settings.
    func allSearchableItems() async -> [PaletteItem] {
        var items: [PaletteItem] = []
        for provider in providers where provider.ranking == .search {
            items += await provider.results(for: "")
        }
        return items
    }

    func prepareForPresentation() {
        screens = []
        actionPanelItem = nil
        query = ""
        refresh()
        focusToken += 1
    }

    /// Asks every provider for the current query. Each publishes as soon as it finishes; answers for an older
    /// query are dropped, and rows from the previous query stay visible until their provider replaces them.
    func refresh() {
        userMovedSelection = false
        generation += 1
        let generation = generation
        let query = query
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        rerank()
        for provider in providers {
            let id = provider.id
            tasks[id] = Task {
                let items = await provider.results(for: query)
                guard generation == self.generation, !Task.isCancelled else { return }
                published[id] = items
                tasks[id] = nil
                rerank(keepingSelection: true)
            }
        }
    }

    /// Re-runs one provider for the current query, keeping the selection.
    func reload(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        let generation = generation
        let query = query
        tasks[providerID]?.cancel()
        tasks[providerID] = Task {
            let items = await provider.results(for: query)
            guard generation == self.generation, !Task.isCancelled else { return }
            published[providerID] = items
            tasks[providerID] = nil
            rerank(keepingSelection: true)
        }
    }

    private func rerank(keepingSelection: Bool = false) {
        let keep = keepingSelection && userMovedSelection
        let selectedID = keep && results.indices.contains(selection) ? results[selection].id : nil
        var searchable: [PaletteItem] = []
        var appended: [PaletteItem] = []
        for provider in providers {
            let items = published[provider.id] ?? []
            switch provider.ranking {
            case .search: searchable += items
            case .appended: appended += items
            }
        }
        searchable.removeAll { isDisabled($0.id) }
        appended.removeAll { isDisabled($0.id) }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchable.removeAll(where: \.hiddenWhenQueryIsEmpty)
            appended.removeAll(where: \.hiddenWhenQueryIsEmpty)
        }
        searchable = searchable.map(applyingFavorites)
        // Leave room for externally matched rows (files) so a loose query cannot push them out.
        let appendedRoom = min(appended.count, 40)
        var ranked = Array(CommandSearch.rank(searchable, query: query, aliases: aliases()) { $0.candidate }.prefix(120 - appendedRoom))
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = leadingEmptyQuery(ranked)
        }
        var seen = Set(ranked.map(\.id))
        ranked += appended.filter { seen.insert($0.id).inserted }.prefix(appendedRoom)
        group(ranked)
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    /// The empty query opens with timely rows, then favorites, then up to eight recently used rows, each under its
    /// own heading, followed by everything else in provider order.
    private func leadingEmptyQuery(_ ranked: [PaletteItem]) -> [PaletteItem] {
        let leads = ranked.filter(\.leadsEmptyQuery)
        var rest = ranked.filter { !$0.leadsEmptyQuery }
        let favorites = rest.filter { $0.candidate.favoriteOrder != nil }.map {
            relabeled($0, String(localized: "Favorites", bundle: .module))
        }
        rest.removeAll { $0.candidate.favoriteOrder != nil }
        let recentIDs = Set(rest.filter { usageBoost($0.id) > 0 }
            .sorted { $0.candidate.rankingBoost > $1.candidate.rankingBoost }
            .prefix(Self.recentLimit).map(\.id))
        let recent = rest.filter { recentIDs.contains($0.id) }
            .sorted { $0.candidate.rankingBoost > $1.candidate.rankingBoost }
            .map { relabeled($0, String(localized: "Recent", bundle: .module)) }
        rest.removeAll { recentIDs.contains($0.id) }
        return leads + favorites + recent + rest
    }

    static let recentLimit = 8

    private func relabeled(_ item: PaletteItem, _ section: String) -> PaletteItem {
        var item = item
        item.candidate.section = section
        return item
    }

    private func applyingFavorites(_ item: PaletteItem) -> PaletteItem {
        // Query-specific answers are never favorites.
        guard item.candidate.matchedQuery == nil else { return item }
        var item = item
        item.candidate.favoriteOrder = favoriteOrder?(item.id)
        item.candidate.rankingBoost = max(item.candidate.rankingBoost, usageBoost(item.id))
        if !item.actions.isEmpty, !item.actions.contains(where: { $0.id == "toggle-favorite" }),
           let action = favoriteAction?(item) {
            item.actions.append(action)
        }
        return item
    }

    /// Groups rows by section, ordering sections by their best row and keeping rank order inside each section.
    private func group(_ ranked: [PaletteItem]) {
        var order: [String] = []
        var buckets: [String: [PaletteItem]] = [:]
        for item in ranked {
            if buckets[item.section] == nil { order.append(item.section) }
            buckets[item.section, default: []].append(item)
        }
        var flat: [PaletteItem] = []
        var sections: [Section] = []
        for title in order {
            let items = buckets[title] ?? []
            sections.append(Section(title: title, rows: items.enumerated().map { Section.Row(index: flat.count + $0, item: $1) }))
            flat += items
        }
        results = flat
        self.sections = sections
    }

    /// The ⌘K panel's actions matching `actionQuery`, in their original order.
    var actionPanelActions: [PaletteAction] {
        guard let item = actionPanelItem else { return [] }
        let needle = TextMatching.normalize(actionQuery.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return item.actions }
        return item.actions.filter { TextMatching.normalize($0.title).contains(needle) }
    }

    func moveSelection(by delta: Int) {
        if actionPanelItem != nil {
            actionSelection = min(max(actionSelection + delta, 0), max(actionPanelActions.count - 1, 0))
            return
        }
        guard !results.isEmpty else { return }
        userMovedSelection = true
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    var selectedItem: PaletteItem? { results.indices.contains(selection) ? results[selection] : nil }

    func activate(index: Int? = nil) {
        if actionPanelItem != nil {
            let actions = actionPanelActions
            guard actions.indices.contains(actionSelection), let item = actionPanelItem else { return }
            closeActionPanel()
            if actions[actionSelection].id == item.actions.first?.id { recordUse(item) }
            perform(actions[actionSelection])
            return
        }
        let index = index ?? selection
        guard results.indices.contains(index), let action = results[index].actions.first else { return }
        selection = index
        recordUse(results[index])
        perform(action)
    }

    /// Runs the selected item's action bound to this shortcut. Returns false when nothing matched.
    func performShortcut(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard let item = actionPanelItem ?? selectedItem else { return false }
        guard let action = item.actions.first(where: { $0.shortcut?.key == key && $0.shortcut?.modifiers == modifiers }) else { return false }
        closeActionPanel()
        perform(action)
        return true
    }

    /// Query-specific answers (a calculation, a web search) are not remembered.
    private func recordUse(_ item: PaletteItem) {
        guard item.candidate.matchedQuery == nil else { return }
        onUse?(item.id)
    }

    func perform(_ action: PaletteAction) {
        let pushes = pushCount
        Task {
            switch await action.run() {
            case .dismiss:
                // The action opened a screen of its own; hiding now would close it.
                if pushCount == pushes { onDismiss?() }
            case .keepOpen: break
            case .push(let screen): push(screen)
            case .notify(let message): onNotify?(message)
            case .refresh: refresh()
            }
        }
    }

    /// Runs the first action of a row published for the current query, such as Tab asking AI about the query.
    @discardableResult
    func runPublishedCommand(id: String) -> Bool {
        let candidates = results + providers.flatMap { published[$0.id] ?? [] }
        guard let action = candidates.first(where: { $0.id == id })?.actions.first else { return false }
        perform(action)
        return true
    }

    /// Runs a modified shortcut (⌘↵, ⇧⌘C, ⌘K) that reached the panel as a key equivalent before the search
    /// field saw it. Only the root list handles these; screens own their keys.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard screens.isEmpty else { return false }
        let modifiers = EventModifiers(event.modifierFlags)
        guard !modifiers.intersection([.command, .control, .option]).isEmpty, let key = KeyEquivalent(event) else { return false }
        if modifiers == .command, key == "k" {
            toggleActionPanel()
            return true
        }
        return performShortcut(key: key, modifiers: modifiers)
    }

    func toggleActionPanel() {
        if actionPanelItem != nil {
            closeActionPanel()
        } else if let item = selectedItem, !item.actions.isEmpty {
            actionSelection = 0
            actionQuery = ""
            actionPanelItem = item
        }
    }

    func closeActionPanel() {
        actionPanelItem = nil
        focusToken += 1
    }

    func push(_ screen: PaletteScreen) {
        actionPanelItem = nil
        pushCount += 1
        screens.append(screen)
    }

    func popScreen() {
        guard !screens.isEmpty else { return }
        screens.removeLast()
        focusToken += 1
    }

    /// Escape: closes the action panel, then the top screen, then clears the query. Returns false when the
    /// palette is already at an empty root and should hide.
    func handleEscape() -> Bool {
        if actionPanelItem != nil {
            closeActionPanel()
        } else if !screens.isEmpty {
            screens.removeLast()
            focusToken += 1
        } else if !query.isEmpty {
            query = ""
        } else {
            return false
        }
        return true
    }
}

private extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}

private extension KeyEquivalent {
    init?(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 36, 76: self = .return
        case 51: self = .delete
        case 117: self = .deleteForward
        case 48: self = .tab
        case 49: self = .space
        case 126: self = .upArrow
        case 125: self = .downArrow
        case 123: self = .leftArrow
        case 124: self = .rightArrow
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            self = KeyEquivalent(character)
        }
    }
}
