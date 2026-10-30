import AppKit
import Observation
import PrismCore
import PrismKit
import SwiftUI

/// The library workspace in the palette, as in the Tauri `LibraryPanel`: Notes, Quicklinks, Snippets and
/// Favorites tabs over one searchable list.
@MainActor
@Observable
final class LibraryScreenModel {
    enum Tab: String, CaseIterable, Identifiable {
        case notes, links, snippets, favorites
        var id: String { rawValue }

        var title: String {
            switch self {
            case .notes: L10n.tr("Notes")
            case .links: L10n.tr("Quicklinks")
            case .snippets: L10n.tr("Snippets")
            case .favorites: L10n.tr("Favorites")
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let entry: LibraryEntry?
        let favorite: LibraryFavorite?
        let title: String
        let subtitle: String
        let accessory: String
        let icon: PaletteIcon
        let isFavorite: Bool
    }

    enum Mode {
        case list
        case run(LibraryRunModel)
        case confirmDelete(Row)
    }

    var tab: Tab { didSet { if tab != oldValue { query = ""; selection = 0; mode = .list } } }
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    var mode: Mode = .list
    @ObservationIgnored let services: LibraryServices

    init(services: LibraryServices, tab: Tab) {
        self.services = services
        self.tab = tab
    }

    var rows: [Row] {
        let model = services.model
        switch tab {
        case .notes, .links, .snippets:
            let kinds: Set<LibraryEntry.Kind> = switch tab {
            case .notes: [.note]
            case .links: [.link, .path]
            default: [.snippet]
            }
            let rows = model.entries(of: kinds).map(row(for:))
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
            return CommandSearch.rank(rows, query: query) { row in
                SearchCandidate(id: row.id, title: row.title, subtitle: row.entry?.value ?? "",
                                searchAliases: [row.entry?.normalizedKeyword].compactMap { $0 })
            }
        case .favorites:
            return model.favorites.map { favorite in
                if let entry = model.entries.first(where: { $0.paletteID == favorite.id }) {
                    let row = row(for: entry)
                    return Row(id: favorite.id, entry: entry, favorite: favorite, title: row.title, subtitle: row.subtitle,
                               accessory: row.accessory, icon: row.icon, isFavorite: true)
                }
                return Row(id: favorite.id, entry: nil, favorite: favorite, title: favorite.title, subtitle: "",
                           accessory: Self.favoriteSource(favorite.id), icon: .symbol("star.fill", tint: .yellow), isFavorite: true)
            }
        }
    }

    private func row(for entry: LibraryEntry) -> Row {
        let subtitle = entry.kind == .snippet || entry.kind == .note ? LibraryProvider.preview(entry.value) : entry.value
        let accessory = entry.kind == .snippet ? (entry.normalizedKeyword ?? "") : ""
        return Row(id: entry.paletteID, entry: entry, favorite: nil, title: entry.title, subtitle: subtitle, accessory: accessory,
                   icon: LibraryProvider.icon(for: entry), isFavorite: services.model.isFavorite(entry.paletteID))
    }

    /// A short label for favorites of other features, from the ID prefix.
    static func favoriteSource(_ id: String) -> String {
        if id.hasPrefix("native:") || id.hasPrefix("app:") || id.hasPrefix("/") { return L10n.tr("Application") }
        return L10n.tr("Command")
    }

    var selectedRow: Row? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func cycleTab(by delta: Int) {
        let all = Tab.allCases
        let index = all.firstIndex(of: tab) ?? 0
        tab = all[(index + delta + all.count) % all.count]
    }

    // MARK: Actions

    func activate() {
        guard let row = selectedRow, let entry = row.entry else { return }
        perform(entry, action: entry.kind == .snippet || entry.kind == .note ? (entry.kind == .note ? .open : .copy) : .open)
    }

    func paste() {
        guard let entry = selectedRow?.entry, entry.kind == .snippet else { return }
        perform(entry, action: .paste)
    }

    private func perform(_ entry: LibraryEntry, action: LibraryRunner.Action) {
        if entry.kind == .note {
            services.edit(entry)
            return
        }
        if entry.isDynamic {
            mode = .run(runModel(entry, action: action))
            return
        }
        Task {
            switch await services.runner.run(entry, action: action) {
            case .success(let outcome): services.apply(outcome)
            case .failure(let error): services.context?.showHUD(error.localizedDescription)
            }
        }
    }

    private func runModel(_ entry: LibraryEntry, action: LibraryRunner.Action) -> LibraryRunModel {
        let model = LibraryRunModel(entry: entry, action: action, services: services)
        model.onFinished = { [weak self] in self?.mode = .list }
        return model
    }

    func copy() {
        guard let entry = selectedRow?.entry else { return }
        if entry.isDynamic && entry.kind == .snippet {
            mode = .run(runModel(entry, action: .copy))
            return
        }
        services.runner.copy(entry.value)
        services.context?.showHUD(L10n.tr("Copied to Clipboard"))
    }

    func edit() {
        guard let entry = selectedRow?.entry else { return }
        services.edit(entry)
    }

    /// The back arrow: returns to the root results, like Escape.
    func goBack() {
        services.context?.popScreen()
    }

    func create() {
        switch tab {
        case .notes: services.create(.note)
        case .links: services.create(.link)
        case .snippets: services.create(.snippet)
        case .favorites: break
        }
    }

    func requestDelete() {
        guard let row = selectedRow else { return }
        if tab == .favorites {
            Task { await removeFavorite(row) }
        } else {
            mode = .confirmDelete(row)
        }
    }

    func confirmDelete() {
        guard case .confirmDelete(let row) = mode, let entry = row.entry else { return }
        mode = .list
        Task {
            await services.delete(entry, returnToRoot: false)
            selection = min(selection, max(rows.count - 1, 0))
        }
    }

    func toggleFavorite() {
        guard let row = selectedRow else { return }
        let id = row.id
        let enabled = !services.model.isFavorite(id)
        Task {
            do {
                try await services.model.setFavorite(id: id, title: row.title, enabled: enabled)
                services.context?.showHUD(enabled ? L10n.tr("Added to Favorites") : L10n.tr("Removed from Favorites"))
            } catch {
                services.context?.showHUD(error.localizedDescription)
            }
        }
    }

    private func removeFavorite(_ row: Row) async {
        do {
            try await services.model.setFavorite(id: row.id, title: row.title, enabled: false)
            selection = min(selection, max(rows.count - 1, 0))
        } catch {
            services.context?.showHUD(error.localizedDescription)
        }
    }

    func moveFavorite(by offset: Int) {
        guard tab == .favorites, let row = selectedRow else { return }
        let target = selection + offset
        guard rows.indices.contains(target) else { return }
        selection = target
        Task {
            do {
                try await services.favorites.move(id: row.id, by: offset)
            } catch {
                services.context?.showHUD(error.localizedDescription)
            }
        }
    }
}

struct LibraryScreenView: View {
    @Bindable var model: LibraryScreenModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        switch model.mode {
        case .run(let runModel):
            LibraryRunView(model: runModel) { model.mode = .list }
                .onKeyPress(.escape) { model.mode = .list; return .handled }
        case .list, .confirmDelete:
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.library-heading`: back arrow and the tab's name.
            HStack(spacing: 12) {
                PrismBackButton(help: Text("Back", bundle: .module), action: model.goBack)
                Text(verbatim: model.tab.title)
                    .font(.prism(15, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 66)
            .overlay(alignment: .bottom) { PrismRule(strong: true) }
            PrismTabStrip(LibraryScreenModel.Tab.allCases.map { ($0, $0.title) }, selection: $model.tab)
                .padding(.horizontal, 23)
                .padding(.top, 12)
            toolbar
            ZStack(alignment: .bottom) {
                results
                if case .confirmDelete(let row) = model.mode {
                    LibraryConfirmation(message: String(format: L10n.tr("Delete “%@”?"), row.title), confirmTitle: L10n.tr("Delete"),
                                        onCancel: { model.mode = .list }, onConfirm: { model.confirmDelete() })
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                }
            }
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.tab) { searchFocused = true }
    }

    /// `.library-toolbar`: the search well and the Add button.
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.textMuted)
                TextField(text: $model.query, prompt: Text("Search", bundle: .module).foregroundStyle(PrismTheme.textMuted)) {
                    Text(searchPrompt)
                }
                .textFieldStyle(.plain)
                .font(.prism(13))
                .foregroundStyle(PrismTheme.text)
                .focused($searchFocused)
                .onSubmit { if !TextInputState.isComposing { submit() } }
                .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
                .onKeyPress(.tab) { model.cycleTab(by: 1); return .handled }
                .onKeyPress(.escape) { handleEscape() }
                .onKeyPress(phases: .down) { handle($0) }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.line))
            if model.tab != .favorites {
                Button { model.create() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .regular))
                        Text("Add", bundle: .module)
                    }
                }
                .buttonStyle(.prism)
                .focusable(false)
                .help(Text(verbatim: "⌘N"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { PrismRule() }
    }

    private var searchPrompt: String {
        switch model.tab {
        case .notes: L10n.tr("Search notes")
        case .links: L10n.tr("Search quicklinks")
        case .snippets: L10n.tr("Search snippets")
        case .favorites: L10n.tr("Favorites")
        }
    }

    @ViewBuilder
    private var results: some View {
        let rows = model.rows
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            LibraryRowView(row: row, tab: model.tab, isSelected: index == model.selection,
                                           onPrimary: { model.selection = index; submit() },
                                           onDelete: { model.selection = index; model.requestDelete() })
                                .id(row.id)
                                .onTapGesture(count: 2) { model.selection = index; submit() }
                                .onTapGesture { model.selection = index }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 15)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    guard rows.indices.contains(selection) else { return }
                    proxy.scrollTo(rows[selection].id)
                }
            }
        }
    }

    /// The Tauri panel's quiet, left-aligned hint instead of a centered illustration.
    private var emptyState: some View {
        let message: String = if !model.query.isEmpty {
            L10n.tr("No results found.")
        } else {
            switch model.tab {
            case .notes: L10n.tr("Press ⌘N to write a note.")
            case .links: L10n.tr("Press ⌘N to save a website, file or folder. Use {query} in the URL query to ask for a search term.")
            case .snippets: L10n.tr("Press ⌘N to save text you type often.")
            case .favorites: L10n.tr("Add favorites from a search result's actions with ⌘⇧F.")
            }
        }
        return Text(verbatim: message)
            .font(.prism(12))
            .foregroundStyle(PrismTheme.textSecondary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 36)
    }

    private var footer: some View {
        PrismStatusBar {
            EmptyView()
        } trailing: {
            if let row = model.selectedRow {
                if let entry = row.entry {
                    PrismStatusAction(Text(verbatim: primaryTitle(entry)), keys: "↵", isPrimary: true) { submit() }
                    if entry.kind == .snippet {
                        PrismStatusDivider()
                        PrismStatusAction(Text("Paste", bundle: .module), keys: "⌘↵") { model.paste() }
                    }
                    if model.tab != .favorites, entry.kind != .note {
                        PrismStatusDivider()
                        PrismStatusAction(Text("Edit", bundle: .module), keys: "⌘E") { model.edit() }
                    }
                }
                PrismStatusDivider()
                if model.tab == .favorites {
                    PrismStatusAction(Text("Move", bundle: .module), keys: "⌥⌘↑↓") { model.moveFavorite(by: 1) }
                    PrismStatusDivider()
                    PrismStatusAction(Text("Remove", bundle: .module), keys: "⌃X") { model.requestDelete() }
                } else {
                    PrismStatusAction(Text("Delete", bundle: .module), keys: "⌃X") { model.requestDelete() }
                }
            }
            if model.tab != .favorites {
                if model.selectedRow != nil { PrismStatusDivider() }
                PrismStatusAction(Text("New", bundle: .module), keys: "⌘N") { model.create() }
            }
        }
    }

    private func primaryTitle(_ entry: LibraryEntry) -> String {
        switch entry.kind {
        case .snippet: L10n.tr("Copy")
        case .link, .path, .note: L10n.tr("Open")
        }
    }

    private func submit() {
        if case .confirmDelete = model.mode {
            model.confirmDelete()
        } else {
            model.activate()
        }
    }

    private func handleEscape() -> KeyPress.Result {
        if case .confirmDelete = model.mode {
            model.mode = .list
            return .handled
        }
        return .ignored
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !TextInputState.isComposing else { return .ignored }
        let modifiers = press.modifiers.subtracting(.numericPad)
        switch (modifiers, press.key) {
        case (.control, "n"): model.move(by: 1)
        case (.control, "p"): model.move(by: -1)
        case (.command, "n"): model.create()
        case (.command, "e"): model.edit()
        case (.command, .return): model.paste()
        case ([.command, .shift], "c"), ([.command, .shift], "C"): model.copy()
        case ([.command, .shift], "f"), ([.command, .shift], "F"): model.toggleFavorite()
        case (.control, "x"): model.requestDelete()
        case ([.command, .option], .upArrow): model.moveFavorite(by: -1)
        case ([.command, .option], .downArrow): model.moveFavorite(by: 1)
        case (.command, "1"): model.tab = .notes
        case (.command, "2"): model.tab = .links
        case (.command, "3"): model.tab = .snippets
        case (.command, "4"): model.tab = .favorites
        case (.shift, .tab): model.cycleTab(by: -1)
        default: return .ignored
        }
        return .handled
    }
}
