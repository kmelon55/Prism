import Foundation
import PrismKit

/// Direct access to `entries` and `favorites` in `library-v1.sqlite3`, with the same save rules as `library.rs`.
///
/// Backup imports must commit in one SQLite transaction and compare the reviewed baseline inside it, which the
/// Library module's cached model cannot offer, so this opens its own connection to the same file. It leaves the
/// file's journal mode alone and never touches the `roots` table except to read it for the baseline.
final class BackupLibrary: Sendable {
    static let fileName = "library-v1.sqlite3"

    struct Snapshot: Equatable, Sendable {
        var entries: [BackupEntry] = []
        var favorites: [BackupFavorite] = []
    }

    let database: SQLiteDatabase

    init(database: SQLiteDatabase) throws {
        self.database = database
        try database.execute("""
            CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL,keyword TEXT);
            CREATE TABLE IF NOT EXISTS favorites(id TEXT PRIMARY KEY,title TEXT NOT NULL,position INTEGER NOT NULL);
            """)
        let hasKeyword = try database.scalar("SELECT COUNT(*) > 0 FROM pragma_table_info('entries') WHERE name='keyword'") ?? 0
        if hasKeyword == 0 { try database.execute("ALTER TABLE entries ADD COLUMN keyword TEXT") }
        try database.execute("CREATE UNIQUE INDEX IF NOT EXISTS entries_keyword_unique ON entries(keyword) WHERE keyword IS NOT NULL AND keyword != ''")
    }

    convenience init(url: URL) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        try self.init(database: SQLiteDatabase(url: url, journalMode: nil))
        if !existed { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    func read() throws -> Snapshot {
        let entries = try database.query("SELECT id,kind,title,value,keyword FROM entries ORDER BY title COLLATE NOCASE") { row in
            BackupEntry(id: row.string("id") ?? "", kind: row.string("kind") ?? "", title: row.string("title") ?? "",
                        value: row.string("value") ?? "", keyword: row.string("keyword"))
        }
        let favorites = try database.query("SELECT id,title FROM favorites ORDER BY position") { row in
            BackupFavorite(id: row.string("id") ?? "", title: row.string("title") ?? "")
        }
        return Snapshot(entries: entries, favorites: favorites)
    }

    /// Every library row, including search roots and kinds this version does not know. Any change between review
    /// and apply invalidates the review instead of silently changing the reviewed result.
    func baseline() throws -> Data {
        var rows: [[Any]] = try database.query("SELECT id,kind,title,value,keyword FROM entries ORDER BY id") { row in
            ["e", row.string("id") ?? "", row.string("kind") ?? "", row.string("title") ?? "", row.string("value") ?? "",
             row.string("keyword") as Any? ?? NSNull()]
        }
        rows += try database.query("SELECT id,title,position FROM favorites ORDER BY position, id") { row in
            ["f", row.string("id") ?? "", row.string("title") ?? "", row.int("position")]
        }
        if try database.tableExists("roots") {
            rows += try database.query("SELECT id,path FROM roots ORDER BY path") { row in ["r", row.string("id") ?? "", row.string("path") ?? ""] }
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    /// `library::save`: validation, unique keyword and capacity. Call inside `database.transaction`.
    func save(_ entry: BackupEntry) throws {
        try LibraryRules.validate(entry)
        let keyword = LibraryRules.normalizedKeyword(entry.keyword)
        if let keyword, try database.scalar("SELECT EXISTS(SELECT 1 FROM entries WHERE keyword=? AND id!=?)", [keyword, entry.id]) ?? 0 != 0 {
            throw BackupError(BackupMessage.keywordConflict)
        }
        let totals = try database.query(
            "SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes FROM entries WHERE id!=?", [entry.id]
        ) { (count: Int($0.int("count")), bytes: Int($0.int("bytes"))) }.first ?? (count: 0, bytes: 0)
        if totals.count >= LibraryRules.maxEntries || totals.bytes + entry.value.utf8.count > LibraryRules.maxTotalBytes {
            throw BackupError(BackupMessage.full)
        }
        try database.run(
            "INSERT INTO entries(id,kind,title,value,keyword) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,title=excluded.title,value=excluded.value,keyword=excluded.keyword",
            [entry.id, entry.kind, entry.title.trimmingCharacters(in: .whitespacesAndNewlines), entry.value, keyword]
        )
    }

    /// Appends a favorite after the existing ones. Call inside `database.transaction`.
    func appendFavorite(_ favorite: BackupFavorite) throws {
        try database.run("INSERT INTO favorites(id,title,position) VALUES(?,?,(SELECT COALESCE(MAX(position),0)+1 FROM favorites))",
                         [favorite.id, favorite.title])
    }

    /// `library_delete_entry`: the entry and its favorite together.
    func delete(id: String) throws {
        try database.transaction {
            try database.run("DELETE FROM entries WHERE id=?", [id])
            try database.run("DELETE FROM favorites WHERE id=?", ["library:\(id)"])
        }
    }
}
