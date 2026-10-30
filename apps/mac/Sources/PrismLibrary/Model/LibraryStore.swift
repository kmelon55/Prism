import Foundation
import PrismKit

public struct LibraryFavorite: Hashable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

struct LibrarySnapshot: Sendable, Equatable {
    var entries: [LibraryEntry] = []
    var favorites: [LibraryFavorite] = []
}

/// `entries` and `favorites` in `library-v1.sqlite3`, compatible with `library.rs`.
///
/// The same file also holds the `roots` table of file search (PrismFiles). This store never creates, reads,
/// changes or drops that table. Writes are serialized by `SQLiteDatabase`; multi-step mutations use a transaction.
final class LibraryStore: Sendable {
    static let fileName = "library-v1.sqlite3"

    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) throws {
        self.database = database
        try Self.prepareSchema(database)
    }

    convenience init(url: URL) throws {
        let database = try SQLiteDatabase(url: url)
        // Local plaintext, readable only by the user, as in the Tauri app.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try self.init(database: database)
    }

    /// Creates the owned tables and adds the `keyword` column to pre-keyword libraries. Never destructive.
    static func prepareSchema(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL,keyword TEXT);
            CREATE TABLE IF NOT EXISTS favorites(id TEXT PRIMARY KEY,title TEXT NOT NULL,position INTEGER NOT NULL);
            """)
        let hasKeyword = try database.scalar("SELECT COUNT(*) > 0 FROM pragma_table_info('entries') WHERE name='keyword'") ?? 0
        if hasKeyword == 0 {
            try database.execute("ALTER TABLE entries ADD COLUMN keyword TEXT")
        }
        try database.execute("CREATE UNIQUE INDEX IF NOT EXISTS entries_keyword_unique ON entries(keyword) WHERE keyword IS NOT NULL AND keyword != ''")
    }

    func load() throws -> LibrarySnapshot {
        let entries = try database.query("SELECT id,kind,title,value,keyword FROM entries ORDER BY title COLLATE NOCASE") { row -> LibraryEntry? in
            // Rows of kinds this version does not know are kept on disk but not shown.
            guard let kind = row.string("kind").flatMap(LibraryEntry.Kind.init(rawValue:)) else { return nil }
            return LibraryEntry(id: row.string("id") ?? "", kind: kind, title: row.string("title") ?? "",
                                value: row.string("value") ?? "", keyword: row.string("keyword"))
        }
        let favorites = try database.query("SELECT id,title FROM favorites ORDER BY position") { row in
            LibraryFavorite(id: row.string("id") ?? "", title: row.string("title") ?? "")
        }
        return LibrarySnapshot(entries: entries.compactMap { $0 }, favorites: favorites)
    }

    func save(_ entry: LibraryEntry) throws {
        try LibraryValidation.validate(entry)
        let keyword = entry.normalizedKeyword
        try database.transaction {
            if let keyword {
                let exists = try database.scalar("SELECT EXISTS(SELECT 1 FROM entries WHERE keyword=? AND id!=?)", [keyword, entry.id]) ?? 0
                if exists != 0 { throw LibraryError.duplicateKeyword }
            }
            let totals = try database.query(
                "SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes FROM entries WHERE id!=?", [entry.id]
            ) { (count: Int($0.int("count")), bytes: Int($0.int("bytes"))) }.first ?? (count: 0, bytes: 0)
            if totals.count >= LibraryLimits.maxEntries || totals.bytes + entry.value.utf8.count > LibraryLimits.maxTotalBytes {
                throw LibraryError.full
            }
            try database.run(
                "INSERT INTO entries(id,kind,title,value,keyword) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,title=excluded.title,value=excluded.value,keyword=excluded.keyword",
                [entry.id, entry.kind.rawValue, entry.title.trimmingCharacters(in: .whitespacesAndNewlines), entry.value, keyword]
            )
        }
    }

    /// Deletes the entry and its favorite together.
    func delete(id: String) throws {
        try database.transaction {
            try database.run("DELETE FROM entries WHERE id=?", [id])
            try database.run("DELETE FROM favorites WHERE id=?", ["library:\(id)"])
        }
    }

    func setFavorite(_ favorite: LibraryFavorite, enabled: Bool) throws {
        guard LibraryValidation.isValidID(favorite.id), favorite.title.utf8.count <= LibraryLimits.maxFavoriteTitleBytes else {
            throw LibraryError.invalidFavorite
        }
        try database.transaction {
            if enabled {
                let exists = try database.scalar("SELECT EXISTS(SELECT 1 FROM favorites WHERE id=?)", [favorite.id]) ?? 0
                let count = try database.scalar("SELECT COUNT(*) FROM favorites") ?? 0
                if exists == 0 && count >= LibraryLimits.maxFavorites { throw LibraryError.tooManyFavorites }
                try database.run(
                    "INSERT INTO favorites VALUES(?,?,(SELECT COALESCE(MAX(position),0)+1 FROM favorites)) ON CONFLICT(id) DO UPDATE SET title=excluded.title",
                    [favorite.id, favorite.title]
                )
            } else {
                try database.run("DELETE FROM favorites WHERE id=?", [favorite.id])
            }
        }
    }

    /// `ids` must be a permutation of the current favorites.
    func reorderFavorites(_ ids: [String]) throws {
        try database.transaction {
            let current = try database.query("SELECT id FROM favorites") { $0.string("id") ?? "" }
            guard ids.count == current.count, Set(ids).count == ids.count, Set(current) == Set(ids) else {
                throw LibraryError.favoritesChanged
            }
            for (position, id) in ids.enumerated() {
                try database.run("UPDATE favorites SET position=? WHERE id=?", [position, id])
            }
        }
    }
}
