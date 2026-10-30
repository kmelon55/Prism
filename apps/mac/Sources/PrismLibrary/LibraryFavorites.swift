import Foundation
import PrismKit
import SwiftUI

/// Favorite palette items, stored in the `favorites` table of `library-v1.sqlite3` like the Tauri app.
///
/// A favorite may refer to any palette item ID (applications, built-in commands, library entries). The shell
/// applies `order(of:)` as `SearchCandidate.favoriteOrder` to every provider's rows, so favorites lead the empty
/// query, and appends `toggleAction(for:)` to rows that can be favorited.
@MainActor
public final class LibraryFavorites {
    /// Posted on the main actor after favorites or library entries change.
    public static let didChangeNotification = LibraryModel.didChange

    /// Set by `LibraryFeature.make(context:)`.
    public private(set) static var shared: LibraryFavorites?

    let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    static func install(_ favorites: LibraryFavorites) { shared = favorites }

    /// Palette item IDs in favorite order.
    public var ids: [String] { model.favorites.map(\.id) }

    public var favorites: [LibraryFavorite] { model.favorites }

    public func order(of id: String) -> Int? { model.favoriteOrder(of: id) }

    public func contains(_ id: String) -> Bool { model.isFavorite(id) }

    public func add(id: String, title: String) async throws {
        try await model.setFavorite(id: id, title: title, enabled: true)
    }

    public func remove(id: String) async throws {
        try await model.setFavorite(id: id, title: "", enabled: false)
    }

    /// Moves one favorite up (negative) or down (positive). Out-of-range moves are ignored.
    public func move(id: String, by offset: Int) async throws {
        var ids = ids
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + offset
        guard ids.indices.contains(target), target != index else { return }
        ids.remove(at: index)
        ids.insert(id, at: target)
        try await model.reorderFavorites(ids)
    }

    /// Replaces the whole order. `ids` must contain exactly the current favorites.
    public func reorder(_ ids: [String]) async throws {
        try await model.reorderFavorites(ids)
    }

    /// "Add to Favorites" or "Remove from Favorites" for one palette row, bound to ⌘⇧F.
    public func toggleAction(for item: PaletteItem) -> PaletteAction {
        toggleAction(id: item.id, title: item.title)
    }

    func toggleAction(id: String, title: String) -> PaletteAction {
        let isFavorite = contains(id)
        return PaletteAction(
            id: "toggle-favorite",
            title: isFavorite ? L10n.tr("Remove from Favorites") : L10n.tr("Add to Favorites"),
            systemImage: isFavorite ? "star.slash" : "star",
            shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])
        ) { [model] in
            do {
                try await model.setFavorite(id: id, title: title, enabled: !isFavorite)
                return .notify(isFavorite ? L10n.tr("Removed from Favorites") : L10n.tr("Added to Favorites"))
            } catch {
                return .notify(error.localizedDescription)
            }
        }
    }
}
