import AppKit
import PrismCore
import PrismKit
import SwiftUI

/// Command IDs shared with the Tauri app (`apps/desktop/src/providers/prism.ts`).
public enum LibraryCommandID {
    public static let library = "prism:library"
    public static let notes = "prism:notes"
    public static let newNote = "prism:new-note"
    public static let links = "prism:links"
    public static let snippets = "prism:snippets"
}

/// Root rows: the library commands and every saved quicklink, snippet and note.
@MainActor
final class LibraryProvider: PaletteProvider {
    let id = "library"
    private let services: LibraryServices

    init(services: LibraryServices) {
        self.services = services
    }

    private var model: LibraryModel { services.model }

    func results(for query: String) async -> [PaletteItem] {
        await model.loadIfNeeded()
        let matchedNotes = await notesContaining(query)
        guard !Task.isCancelled else { return [] }
        return commandItems() + model.entries.map { item(for: $0, matchedQuery: matchedNotes.contains($0.id) ? query : nil) }
    }

    /// Notes whose full body contains the query. Bodies can be long, so this runs off the main actor and
    /// matches substrings instead of fuzzy subsequences, which would match almost any query in a long note.
    private func notesContaining(_ query: String) async -> Set<String> {
        let needle = TextMatching.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let index = model.noteSearchIndex
        guard !needle.isEmpty, !index.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var matches = Set<String>()
            for (id, body) in index {
                if Task.isCancelled { break }
                if body.contains(needle) { matches.insert(id) }
            }
            return matches
        }.value
    }

    // MARK: Commands

    private func commandItems() -> [PaletteItem] {
        let section = L10n.tr("Productivity")
        func command(_ id: String, title: String, subtitle: String, keywords: [String], symbol: String,
                     actionTitle: String, run: @escaping @MainActor () async -> PaletteActionOutcome) -> PaletteItem {
            PaletteItem(
                candidate: SearchCandidate(id: id, title: title, subtitle: subtitle, section: section, keywords: keywords,
                                           favoriteOrder: model.favoriteOrder(of: id)),
                icon: .symbol(symbol, tint: .orange),
                accessory: L10n.tr("Command"),
                actions: [
                    PaletteAction(id: "open", title: actionTitle, systemImage: "arrow.right.circle", run: run),
                    services.favorites.toggleAction(id: id, title: title),
                ]
            )
        }
        return [
            command(LibraryCommandID.notes, title: L10n.tr("Notes"), subtitle: L10n.tr("Write and search local notes"),
                    keywords: ["notes", "memo", "노트", "메모"], symbol: "note.text", actionTitle: L10n.tr("Open")) { [services] in
                services.notes.show()
                return .dismiss
            },
            command(LibraryCommandID.newNote, title: L10n.tr("New Note"), subtitle: L10n.tr("Capture a thought"),
                    keywords: ["new note", "write", "메모 작성", "새 노트"], symbol: "square.and.pencil", actionTitle: L10n.tr("New Note")) { [services] in
                services.notes.showNewNote()
                return .dismiss
            },
            command(LibraryCommandID.links, title: L10n.tr("Quicklinks"), subtitle: L10n.tr("Saved websites and file destinations"),
                    keywords: ["links", "quicklinks", "bookmarks", "링크", "바로가기"], symbol: "link", actionTitle: L10n.tr("Open")) { [services] in
                .push(services.libraryScreen(tab: .links))
            },
            command(LibraryCommandID.snippets, title: L10n.tr("Snippets"), subtitle: L10n.tr("Reusable text"),
                    keywords: ["snippet", "snippets", "text", "스니펫", "문구"], symbol: "text.quote", actionTitle: L10n.tr("Open")) { [services] in
                .push(services.libraryScreen(tab: .snippets))
            },
            command(LibraryCommandID.library, title: L10n.tr("Library"), subtitle: L10n.tr("Quicklinks, snippets and favorites"),
                    keywords: ["library", "snippets", "favorites", "quicklinks", "보관함", "링크", "스니펫", "즐겨찾기"],
                    symbol: "books.vertical", actionTitle: L10n.tr("Open Library")) { [services] in
                .push(services.libraryScreen(tab: .links))
            },
        ]
    }

    // MARK: Entries

    func item(for entry: LibraryEntry, matchedQuery: String? = nil) -> PaletteItem {
        let section: String
        let accessory: String
        var keywords: [String]
        switch entry.kind {
        case .note:
            section = L10n.tr("Notes")
            accessory = L10n.tr("Note")
            keywords = ["note notes memo 노트 메모"]
        case .snippet:
            section = L10n.tr("Snippets")
            accessory = entry.normalizedKeyword ?? L10n.tr("Snippet")
            keywords = ["snippet 스니펫 문구"]
        case .link, .path:
            section = L10n.tr("Saved Links")
            accessory = L10n.tr("Quicklink")
            keywords = ["quicklink 링크 바로가기"]
        }
        if let matchedQuery { keywords.append(matchedQuery) }
        let subtitle = entry.kind == .snippet || entry.kind == .note ? Self.preview(entry.value) : entry.value
        let candidate = SearchCandidate(
            id: entry.paletteID, title: entry.title, subtitle: subtitle, section: section, keywords: keywords,
            searchAliases: entry.kind == .snippet ? [entry.normalizedKeyword].compactMap { $0 } : [],
            favoriteOrder: model.favoriteOrder(of: entry.paletteID)
        )
        // Up to 1,000 saved entries would bury the empty root list; favorites still lead it.
        return PaletteItem(candidate: candidate, icon: Self.icon(for: entry), accessory: accessory, actions: services.actions(for: entry),
                           hiddenWhenQueryIsEmpty: candidate.favoriteOrder == nil)
    }

    static func icon(for entry: LibraryEntry) -> PaletteIcon {
        switch entry.kind {
        case .note: .symbol("note.text", tint: .yellow)
        case .snippet: .symbol("text.quote", tint: .purple)
        case .link: .symbol("globe", tint: .blue)
        case .path: FileManager.default.fileExists(atPath: entry.value) ? .file(path: entry.value) : .symbol("folder", tint: .blue)
        }
    }

    /// The first 140 characters on one line.
    static func preview(_ value: String) -> String {
        let collapsed = value.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(140))
    }
}
