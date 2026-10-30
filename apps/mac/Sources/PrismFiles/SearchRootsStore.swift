import Foundation
import PrismKit

/// An additional folder searched by filename, stored in the `roots` table of `library-v1.sqlite3`.
struct SearchRoot: Sendable, Hashable, Identifiable {
    let id: String
    let path: String
}

/// Reads and writes only the `roots` table. The rest of the library database belongs to PrismLibrary.
/// Schema, ID format and the 12-folder limit match `library_add_root` in `library.rs`.
struct SearchRootsStore: Sendable {
    static let maxRoots = 12
    static let fileName = "library-v1.sqlite3"

    enum StoreError: LocalizedError {
        case tooMany
        case inaccessible

        var errorDescription: String? {
            switch self {
            case .tooMany: String(localized: "You can add up to 12 search folders.", bundle: .module)
            case .inaccessible: String(localized: "Prism couldn't access that folder.", bundle: .module)
            }
        }
    }

    let url: URL

    private func open() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE IF NOT EXISTS roots(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return database
    }

    func load() throws -> [SearchRoot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let database = try open()
        return try database.query("SELECT id, path FROM roots ORDER BY rowid") { row in
            SearchRoot(id: row.string("id") ?? "", path: row.string("path") ?? "")
        }
    }

    /// Adds the canonical form of `folder`. Adding a folder that is already listed does nothing.
    @discardableResult
    func add(_ folder: URL) throws -> [SearchRoot] {
        guard let path = FolderSnapshot.canonicalPath(folder.path) else { throw StoreError.inaccessible }
        let database = try open()
        try database.transaction {
            let count = try database.scalar("SELECT count(*) FROM roots") ?? 0
            let exists = try database.scalar("SELECT count(*) FROM roots WHERE path = ?", [path]) ?? 0
            guard exists == 0 else { return }
            guard count < Self.maxRoots else { throw StoreError.tooMany }
            try database.run("INSERT OR IGNORE INTO roots VALUES(lower(hex(randomblob(16))),?)", [path])
        }
        return try load()
    }

    @discardableResult
    func remove(id: String) throws -> [SearchRoot] {
        try open().run("DELETE FROM roots WHERE id=?", [id])
        return try load()
    }
}
