import Foundation

struct BackupCounts: Equatable, Sendable {
    var total = 0
    var added = 0
    var conflicts = 0
    var skipped = 0
}

struct BackupSummary: Equatable, Sendable {
    var snippets = BackupCounts()
    var notes = BackupCounts()
    var quicklinks = BackupCounts()
    var pathLinks = BackupCounts()
    var favorites = BackupCounts()

    subscript(kind: String) -> BackupCounts {
        get {
            switch kind {
            case "snippet": snippets
            case "note": notes
            case "path": pathLinks
            default: quicklinks
            }
        }
        set {
            switch kind {
            case "snippet": snippets = newValue
            case "note": notes = newValue
            case "path": pathLinks = newValue
            default: quicklinks = newValue
            }
        }
    }
}

struct BackupPathReference: Equatable, Sendable, Identifiable {
    enum Status: String, Sendable { case existing, missing, unavailable }
    var id: String
    var title: String
    var path: String
    var status: Status
    /// An existing library item with the same ID wins.
    var conflict: Bool

    /// Metadata only: never reads or lists the target, adds a search root or grants AI access.
    static func status(of path: String) -> Status {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return .existing
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unavailable
        }
    }
}

/// A validated merge of one backup file into one exact library state. Single-use; expires after 10 minutes.
struct PreparedRestore: Sendable {
    static let lifetime: TimeInterval = 10 * 60

    var created: Date
    var baseline: Data
    var entries: [BackupEntry]
    var favorites: [BackupFavorite]
    var summary: BackupSummary
    var pathReferences: [BackupPathReference]
    var missingFavorites: [BackupFavorite]
    /// Only when the preferences category is selected.
    var preferences: SafePreferences?
}

/// Library restore, ported from `prepare` and `apply` in `library_backup.rs`. Existing IDs win, nothing is
/// replaced or deleted, every limit is checked before writing, and the write is one immediate transaction.
enum BackupRestore {
    static func prepare(_ document: BackupDocument, categories: BackupCategories, library: BackupLibrary,
                        now: Date = Date()) throws -> PreparedRestore {
        try document.validate()
        guard categories.any else { throw BackupError(BackupMessage.noCategory) }
        let current = try library.read()
        var ids = Set(current.entries.map(\.id))
        var keywords = Set(current.entries.compactMap { LibraryRules.normalizedKeyword($0.keyword) })
        var prepared = PreparedRestore(created: now, baseline: try library.baseline(), entries: [], favorites: [],
                                       summary: BackupSummary(), pathReferences: [], missingFavorites: [], preferences: nil)
        for entry in document.entries where categories.includes(kind: entry.kind) {
            if entry.kind == "path" {
                prepared.pathReferences.append(BackupPathReference(
                    id: entry.id, title: entry.title, path: entry.value, status: BackupPathReference.status(of: entry.value),
                    conflict: ids.contains(entry.id)))
            }
            var counts = prepared.summary[entry.kind]
            counts.total += 1
            if !ids.insert(entry.id).inserted {
                counts.conflicts += 1
            } else {
                if let keyword = LibraryRules.normalizedKeyword(entry.keyword), !keywords.insert(keyword).inserted {
                    throw BackupError(BackupMessage.keywordConflict)
                }
                counts.added += 1
                prepared.entries.append(entry)
            }
            prepared.summary[entry.kind] = counts
        }
        let currentBytes = current.entries.reduce(0) { $0 + $1.value.utf8.count }
        let addedBytes = prepared.entries.reduce(0) { $0 + $1.value.utf8.count }
        if current.entries.count + prepared.entries.count > LibraryRules.maxEntries || currentBytes + addedBytes > LibraryRules.maxTotalBytes {
            throw BackupError(BackupMessage.full)
        }
        var favorites = Set(current.favorites.map(\.id))
        if categories.favorites {
            for favorite in document.favorites {
                prepared.summary.favorites.total += 1
                if favorites.contains(favorite.id) {
                    prepared.summary.favorites.conflicts += 1
                } else if favorite.id.hasPrefix("library:"), !ids.contains(String(favorite.id.dropFirst("library:".count))) {
                    prepared.summary.favorites.skipped += 1
                    prepared.missingFavorites.append(favorite)
                } else {
                    favorites.insert(favorite.id)
                    prepared.summary.favorites.added += 1
                    prepared.favorites.append(favorite)
                }
            }
        }
        if favorites.count > LibraryRules.maxFavorites { throw BackupError(BackupMessage.full) }
        prepared.preferences = categories.preferences ? document.preferences : nil
        return prepared
    }

    @discardableResult
    static func apply(_ prepared: PreparedRestore, library: BackupLibrary, now: Date = Date()) throws -> BackupSummary {
        if now.timeIntervalSince(prepared.created) > PreparedRestore.lifetime || now < prepared.created {
            throw BackupError(BackupMessage.stale)
        }
        do {
            try library.database.transaction {
                guard try library.baseline() == prepared.baseline else { throw BackupError(BackupMessage.stale) }
                for entry in prepared.entries { try library.save(entry) }
                for favorite in prepared.favorites { try library.appendFavorite(favorite) }
            }
        } catch let error as BackupError where error.message == BackupMessage.stale {
            throw error
        } catch {
            throw BackupError(BackupMessage.restoreFailed)
        }
        return prepared.summary
    }

    /// The document an export writes: the selected kinds, favorites when selected, and safe preferences.
    static func exportDocument(categories: BackupCategories, library: BackupLibrary, preferences: SafePreferences?) throws -> BackupDocument {
        guard categories.any else { throw BackupError(BackupMessage.noCategory) }
        let current = try library.read()
        let entries = current.entries.filter { categories.includes(kind: $0.kind) }
        var document = BackupDocument(version: entries.contains { $0.kind == "note" } ? 3 : 2, entries: entries,
                                      favorites: categories.favorites ? current.favorites : [], preferences: nil)
        if categories.preferences {
            guard let preferences else { throw BackupError(BackupMessage.invalid) }
            document.preferences = preferences
        }
        try document.validate()
        return document
    }
}

/// Holds the one usable review. A new review replaces the previous one, and taking a review consumes it, so a
/// failed apply always needs a fresh review of the file.
@MainActor
final class BackupReviews {
    private var token: UUID?
    private var prepared: PreparedRestore?

    func issue(_ review: PreparedRestore) -> UUID {
        let token = UUID()
        self.token = token
        prepared = review
        return token
    }

    func take(_ token: UUID) throws -> PreparedRestore {
        guard token == self.token, let prepared else { throw BackupError(BackupMessage.stale) }
        discard()
        return prepared
    }

    func discard() {
        token = nil
        prepared = nil
    }
}
