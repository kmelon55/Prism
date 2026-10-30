import Foundation
import Observation

/// What the picker does with a chosen emoji. The feature wires these to `PasteService` and the palette; tests
/// pass fakes.
struct EmojiActions {
    var copy: @MainActor (String) throws -> Void
    /// Hides the palette and pastes into the app that was frontmost before it opened.
    var paste: @MainActor (String) async throws -> Void
    /// False without Accessibility permission. The picker then stays open and offers Copy instead.
    var canPaste: @MainActor () -> Bool
}

enum EmojiOperation: Equatable {
    case copy, paste
}

/// A failed copy or paste. Keeps its exact emoji so a retry never picks up a newer selection.
struct EmojiFailure: Equatable {
    var emoji: String
    var operation: EmojiOperation
    var detail: String?
    var needsAccessibility = false
}

@MainActor
@Observable
final class EmojiPickerModel {
    /// Columns of the 1080-point workspace grid, as in the Tauri picker.
    static let columns = 18

    private(set) var catalog: EmojiCatalog?
    private(set) var loadFailed = false
    var query = "" { didSet { if query != oldValue { refresh() } } }
    var category: String { didSet { if category != oldValue { refresh() } } }
    var tone: SkinTone { didSet { if tone != oldValue { defaults.set(tone.rawValue, forKey: Self.toneKey); refresh() } } }
    private(set) var recent: [String]
    private(set) var items: [EmojiRecord] = []
    var selection = 0
    private(set) var busy = false
    private(set) var failure: EmojiFailure?
    private(set) var status: String?
    private(set) var storageFailed = false

    let useKorean: Bool
    @ObservationIgnored private let actions: EmojiActions
    @ObservationIgnored private let recents: EmojiRecents
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loader: () async -> EmojiCatalog?
    private static let toneKey = "emoji.skinTone"

    init(
        actions: EmojiActions, recents: EmojiRecents, defaults: UserDefaults = .standard,
        useKorean: Bool = Bundle.module.preferredLocalizations.first?.hasPrefix("ko") == true,
        loader: @escaping () async -> EmojiCatalog?
    ) {
        self.actions = actions
        self.recents = recents
        self.defaults = defaults
        self.useKorean = useKorean
        self.loader = loader
        let recent = recents.load()
        self.recent = recent
        category = recent.isEmpty ? EmojiCategory.groups[0].id : EmojiCategory.recent.id
        tone = SkinTone(rawValue: defaults.string(forKey: Self.toneKey) ?? "") ?? .none
    }

    var categories: [EmojiCategory] { [.recent, .all] + EmojiCategory.groups }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedItem: EmojiRecord? { items.indices.contains(selection) ? items[selection] : nil }
    var canPaste: Bool { actions.canPaste() }

    func load() async {
        loadFailed = false
        if let catalog = await loader() {
            self.catalog = catalog
            recent = recent.filter { catalog.byEmoji[$0] != nil }
            refresh()
        } else {
            loadFailed = true
        }
    }

    func label(_ record: EmojiRecord) -> String { useKorean ? record.nameKo : record.name }

    private func refresh() {
        items = catalog?.search(query, category: category, tone: tone, recent: recent) ?? []
        selection = 0
    }

    // MARK: Keyboard

    func move(_ command: SearchFieldCommand) -> Bool {
        let rowsPerPage = 5
        let offset: Int? = switch command {
        case .left: -1
        case .right: 1
        case .up: -Self.columns
        case .down: Self.columns
        case .pageUp: -Self.columns * rowsPerPage
        case .pageDown: Self.columns * rowsPerPage
        default: nil
        }
        guard let offset else { return false }
        guard !items.isEmpty else { return true }
        let next = selection + offset
        let columns = Self.columns
        if command == .down, next >= items.count {
            // Down from a row above a shorter last row lands on its last item.
            if selection / columns < (items.count - 1) / columns { selection = items.count - 1 }
        } else if command == .up, next < 0 {
            return true
        } else {
            selection = min(max(next, 0), items.count - 1)
        }
        return true
    }

    /// Tab moves to the next category and leaves search, as clicking a category does.
    func cycleCategory(by delta: Int) {
        let ids = categories.map(\.id)
        let current = isSearching ? nil : ids.firstIndex(of: category)
        let next = current.map { ($0 + delta + ids.count) % ids.count } ?? ids.firstIndex(of: category) ?? 0
        select(category: ids[next])
    }

    func select(category id: String) {
        query = ""
        category = id
    }

    // MARK: Actions

    func performPrimary() async {
        guard let item = selectedItem, failure == nil else { return }
        await perform(item.emoji, .paste)
    }

    func performCopy() async {
        guard let item = selectedItem, failure == nil else { return }
        await perform(item.emoji, .copy)
    }

    func retry() async {
        guard let failure else { return }
        await perform(failure.emoji, failure.operation)
    }

    func copyInstead() async {
        guard let failure else { return }
        await perform(failure.emoji, .copy)
    }

    func dismissFailure() { failure = nil }

    func perform(_ emoji: String, _ operation: EmojiOperation) async {
        guard let catalog, !busy else { return }
        if operation == .paste, !actions.canPaste() {
            failure = EmojiFailure(
                emoji: emoji, operation: .paste,
                detail: String(localized: "Allow Prism in Privacy & Security › Accessibility to paste into other apps.", bundle: .module),
                needsAccessibility: true
            )
            return
        }
        busy = true
        status = nil
        failure = nil
        defer { busy = false }
        do {
            switch operation {
            case .copy: try actions.copy(emoji)
            case .paste: try await actions.paste(emoji)
            }
        } catch {
            failure = EmojiFailure(emoji: emoji, operation: operation, detail: Self.detail(error))
            return
        }
        let saved = recents.remember(emoji, in: recent, isKnown: { catalog.byEmoji[$0] != nil })
        recent = saved.recent
        storageFailed = !saved.saved
        status = operation == .paste ? String(localized: "Pasted", bundle: .module) : String(localized: "Copied", bundle: .module)
        if category == EmojiCategory.recent.id, !isSearching {
            let selected = selectedItem?.emoji
            refresh()
            selection = selected.flatMap { emoji in items.firstIndex { $0.emoji == emoji } } ?? 0
        }
    }

    /// Bounded plain text from an error, as the Tauri picker shows beneath the failure summary.
    static func detail(_ error: any Error) -> String? {
        let text = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        let cleaned = String(text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(300))
    }
}
