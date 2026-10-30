import AppKit
import Observation
import PrismKit
import SwiftUI

/// State for the Clipboard History screen. One instance lives as long as its pushed screen.
@MainActor
@Observable
final class ClipboardHistoryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, text, image, files
        var id: String { rawValue }

        var kind: ClipboardKind? {
            switch self {
            case .all: nil
            case .text: .text
            case .image: .image
            case .files: .files
            }
        }

        var title: String {
            switch self {
            case .all: ClipboardText.localize("All types")
            case .text: ClipboardText.localize("Text")
            case .image: ClipboardText.localize("Images")
            case .files: ClipboardText.localize("Files")
            }
        }
    }

    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var entries: [ClipboardEntry]
    }

    /// Entries are only previews; the list never holds image bytes or full texts.
    nonisolated static let searchLimit = 200

    var query = "" {
        didSet { if query != oldValue { refresh(debounce: !query.trimmingCharacters(in: .whitespaces).isEmpty) } }
    }
    var filter: Filter = .all {
        didSet { if filter != oldValue { refresh() } }
    }
    private(set) var entries: [ClipboardEntry] = []
    private(set) var sections: [Section] = []
    var selectedID: Int64?
    private(set) var settings: ClipboardSettingsState?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var isActionPanelOpen = false
    var actionSelection = 0
    var isConfirmingClear = false

    @ObservationIgnored let history: ClipboardHistory
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(history: ClipboardHistory) {
        self.history = history
    }

    var store: ClipboardStore { history.store }
    var isEnabled: Bool { settings?.enabled ?? false }
    var selectedIndex: Int? { selectedID.flatMap { id in entries.firstIndex { $0.id == id } } }
    var selectedEntry: ClipboardEntry? { selectedIndex.map { entries[$0] } }

    func load() {
        refresh()
    }

    /// Searches off the main actor. Typing waits 60 ms so fast typing runs one search; newer requests
    /// replace older ones and keep the selected entry when it is still listed.
    func refresh(debounce: Bool = false) {
        generation += 1
        let generation = generation
        let query = query
        let kind = filter.kind
        searchTask?.cancel()
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let settings = await history.settings()
            var result: Result<[ClipboardEntry], ClipboardError> = .success([])
            if settings.enabled {
                do throws(ClipboardError) {
                    result = .success(try await history.read { store throws(ClipboardError) in
                        try store.search(query, limit: Self.searchLimit, kind: kind)
                    })
                } catch {
                    result = .failure(error)
                }
            }
            guard generation == self.generation else { return }
            self.settings = settings
            switch result {
            case .success(let entries):
                errorMessage = nil
                apply(entries)
            case .failure(let error):
                errorMessage = error.localizedDescription
                apply([])
            }
            hasLoaded = true
        }
    }

    private func apply(_ entries: [ClipboardEntry]) {
        let previous = selectedIndex
        self.entries = entries
        sections = Self.group(entries)
        if selectedIndex == nil {
            selectedID = entries.isEmpty ? nil : entries[min(previous ?? 0, entries.count - 1)].id
        }
        if entries.isEmpty { isActionPanelOpen = false }
    }

    /// Pinned first, then by day. `entries` is already in this order.
    static func group(_ entries: [ClipboardEntry], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        var sections: [Section] = []
        for entry in entries {
            let title: String
            if entry.pinned {
                title = ClipboardText.localize("Pinned")
            } else if calendar.isDate(entry.capturedAt, inSameDayAs: now) {
                title = ClipboardText.localize("Today")
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(entry.capturedAt, inSameDayAs: yesterday) {
                title = ClipboardText.localize("Yesterday")
            } else {
                title = ClipboardText.localize("Earlier")
            }
            if sections.last?.title == title {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(Section(title: title, entries: [entry]))
            }
        }
        return sections
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        if isActionPanelOpen {
            let count = actions.count
            actionSelection = min(max(actionSelection + delta, 0), max(count - 1, 0))
            return
        }
        guard !entries.isEmpty else { return }
        let index = min(max((selectedIndex ?? -1) + delta, 0), entries.count - 1)
        selectedID = entries[index].id
    }

    func cycleFilter() {
        let all = Filter.allCases
        filter = all[(all.firstIndex(of: filter)! + 1) % all.count]
    }

    func toggleActionPanel() {
        guard selectedEntry != nil else { return }
        isActionPanelOpen.toggle()
        actionSelection = 0
    }

    /// Return: the selected action in the ⌘K panel, otherwise the primary action.
    func activate() {
        if isConfirmingClear { return confirmClear() }
        let actions = actions
        let index = isActionPanelOpen ? actionSelection : 0
        isActionPanelOpen = false
        guard actions.indices.contains(index) else { return }
        perform(actions[index])
    }

    func performShortcut(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard let action = actions.first(where: { $0.shortcut?.key == key && $0.shortcut?.modifiers == modifiers }) else { return false }
        isActionPanelOpen = false
        perform(action)
        return true
    }

    /// Escape closes the panel or confirmation first. Returns false to let the palette leave the screen.
    func handleEscape() -> Bool {
        if isConfirmingClear { isConfirmingClear = false; return true }
        if isActionPanelOpen { isActionPanelOpen = false; return true }
        return false
    }

    // MARK: Actions

    var primaryAction: ClipboardPrimaryAction { settings?.preferences.primaryAction ?? .paste }

    var pasteTitle: String {
        if let name = history.context?.previousApplication?.localizedName, !name.isEmpty {
            return String(format: ClipboardText.localize("Paste to %@"), name)
        }
        return ClipboardText.localize("Paste to previous app")
    }

    /// Return runs the configured action and ⌘Return the other, as in the Tauri app.
    var actions: [PaletteAction] {
        guard let entry = selectedEntry else { return [] }
        let id = entry.id
        let paste = PaletteAction(id: "paste-clipboard-history-entry", title: pasteTitle, systemImage: "doc.on.clipboard") { [weak self] in
            await self?.history.paste(id: id) ?? .keepOpen
        }
        let copy = PaletteAction(id: "copy-clipboard-history-entry", title: ClipboardText.localize("Copy to Clipboard"), systemImage: "doc.on.doc") { [weak self] in
            guard let self else { return .keepOpen }
            do {
                try await history.copy(id: id)
                return .notify(ClipboardText.localize("Copied to Clipboard"))
            } catch {
                return .notify(error.localizedDescription)
            }
        }
        var (first, second) = primaryAction == .paste ? (paste, copy) : (copy, paste)
        second.shortcut = KeyboardShortcut(.return, modifiers: .command)
        var actions = [first, second]
        if case .files = EntryPresentation(entry: entry).style {
            actions.append(PaletteAction(id: "reveal-clipboard-files", title: ClipboardText.localize("Show in Finder"), systemImage: "folder",
                                         shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])) { [weak self] in
                await self?.revealFiles(id: id) ?? .keepOpen
            })
        }
        if entry.kind == .text, ClipboardFeature.onSaveAsSnippet != nil {
            actions.append(PaletteAction(id: "save-clipboard-as-snippet", title: ClipboardText.localize("Save as Snippet"),
                                         systemImage: "text.badge.plus", shortcut: KeyboardShortcut("s", modifiers: .command)) { [weak self] in
                await self?.saveAsSnippet(id: id) ?? .keepOpen
            })
        }
        actions.append(PaletteAction(
            id: "pin-clipboard-history-entry", title: ClipboardText.localize(entry.pinned ? "Unpin entry" : "Pin entry"),
            systemImage: entry.pinned ? "pin.slash" : "pin", shortcut: KeyboardShortcut("p", modifiers: [.command, .shift])
        ) { [weak self] in
            await self?.setPinned(id: id, pinned: !entry.pinned) ?? .keepOpen
        })
        actions.append(PaletteAction(id: "delete-clipboard-history-entry", title: ClipboardText.localize("Delete Entry"), systemImage: "trash",
                                     shortcut: KeyboardShortcut("x", modifiers: .control), isDestructive: true) { [weak self] in
            await self?.delete(id: id) ?? .keepOpen
        })
        actions.append(PaletteAction(id: "clear-clipboard-history", title: ClipboardText.localize("Delete All Entries…"), systemImage: "trash.slash",
                                     shortcut: KeyboardShortcut("x", modifiers: [.control, .shift]), isDestructive: true) { [weak self] in
            self?.isConfirmingClear = true
            return .keepOpen
        })
        return actions
    }

    func perform(_ action: PaletteAction) {
        Task {
            switch await action.run() {
            case .dismiss: history.context?.hidePalette()
            case .keepOpen: break
            case .notify(let message): history.context?.showHUD(message)
            case .push(let screen): history.context?.showPalette(screen: screen)
            case .refresh: refresh()
            }
        }
    }

    private func setPinned(id: Int64, pinned: Bool) async -> PaletteActionOutcome {
        do {
            try await history.perform { store throws(ClipboardError) in try store.setPinned(id: id, pinned: pinned) }
            return .keepOpen
        } catch {
            return .notify(error.localizedDescription)
        }
    }

    private func delete(id: Int64) async -> PaletteActionOutcome {
        // Keep the cursor in place: select the next entry, or the previous one at the end.
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let next = index + 1 < entries.count ? index + 1 : index - 1
            selectedID = entries.indices.contains(next) ? entries[next].id : nil
        }
        do {
            try await history.perform { store throws(ClipboardError) in try store.delete(id: id) }
            return .keepOpen
        } catch {
            return .notify(error.localizedDescription)
        }
    }

    func confirmClear() {
        isConfirmingClear = false
        Task {
            do {
                let removed = try await history.perform { store throws(ClipboardError) in try store.clear() }
                ThumbnailLoader.shared.removeAll()
                history.context?.showHUD(ClipboardFeature.clearedMessage(removed))
            } catch {
                history.context?.showHUD(error.localizedDescription)
            }
        }
    }

    /// Hands the full original text (not the 500-character preview) to the snippet editor.
    private func saveAsSnippet(id: Int64) async -> PaletteActionOutcome {
        do {
            let text = try await history.read { store throws(ClipboardError) in try store.text(id: id) }
            guard let save = ClipboardFeature.onSaveAsSnippet else { return .keepOpen }
            history.context?.hidePalette()
            save(text)
            return .dismiss
        } catch {
            return .notify(error.localizedDescription)
        }
    }

    private func revealFiles(id: Int64) async -> PaletteActionOutcome {
        do {
            let payload = try await history.read { store throws(ClipboardError) in try store.prepareForAction(id: id) }
            guard case .files(let urls) = payload else { return .keepOpen }
            NSWorkspace.shared.activateFileViewerSelecting(urls.compactMap(URL.init(string:)))
            return .dismiss
        } catch {
            return .notify(error.localizedDescription)
        }
    }

    /// The back arrow: returns to the root results, like Escape.
    func goBack() {
        history.context?.popScreen()
    }

    func openSettings() {
        history.context?.openSettings(paneID: ClipboardFeature.settingsPaneID)
    }
}
