import Foundation
import PrismKit
import Testing
@testable import PrismLibrary

/// Ported from the `library.rs` tests.
@Suite struct LibraryStoreTests {
    func makeStore() throws -> (LibraryStore, SQLiteDatabase) {
        let database = try SQLiteDatabase.inMemory()
        return (try LibraryStore(database: database), database)
    }

    @Test func notesRoundtripLiteralTextAndRejectSnippetKeywords() throws {
        let (store, _) = try makeStore()
        var note = LibraryEntry(id: "note", kind: .note, title: "회의 기록", value: "# 결정\n{clipboard} {date}\n  들여쓰기  ")
        try store.save(note)
        let stored = try #require(try store.load().entries.first)
        #expect(stored.kind == .note)
        #expect(stored.value == note.value)
        #expect(!stored.isDynamic)
        note.value = "수정한 메모"
        try store.save(note)
        #expect(try store.load().entries[0].value == "수정한 메모")
        note.keyword = ";note"
        #expect(throws: LibraryError.invalidKeyword) { try store.save(note) }
        note.keyword = nil
        note.value = String(repeating: "가", count: 128 * 1024)
        #expect(throws: LibraryError.invalidEntry) { try store.save(note) }
        #expect(try store.load().entries[0].value == "수정한 메모")
        note.value = ""
        try store.save(note)
        let cleared = try #require(try store.load().entries.first)
        #expect(cleared.title == "회의 기록")
        #expect(cleared.value == "")
        note.kind = .snippet
        #expect(throws: LibraryError.invalidEntry) { try store.save(note) }
    }

    @Test func legacyLibraryMigratesWithoutLosingTextAndKeywordsAreUnique() throws {
        let database = try SQLiteDatabase.inMemory()
        try database.execute("CREATE TABLE entries(id TEXT PRIMARY KEY,kind TEXT NOT NULL,title TEXT NOT NULL,value TEXT NOT NULL); INSERT INTO entries VALUES('legacy','snippet','인사','안녕하세요');")
        try LibraryStore.prepareSchema(database)
        let store = try LibraryStore(database: database)
        var entry = try #require(try store.load().entries.first)
        #expect(entry.value == "안녕하세요")
        #expect(entry.keyword == nil)
        entry.keyword = " ;hello "
        try store.save(entry)
        #expect(try store.load().entries[0].keyword == ";hello")
        entry.id = "duplicate"
        #expect(throws: LibraryError.duplicateKeyword) { try store.save(entry) }
        #expect(try store.load().entries.count == 1)
        entry.keyword = "ordinary"
        #expect(throws: LibraryError.invalidKeyword) { try store.save(entry) }
        entry.keyword = ";two words"
        #expect(throws: LibraryError.invalidKeyword) { try store.save(entry) }
        entry.keyword = ""
        try store.save(entry)
        entry.id = "legacy"
        try store.save(entry)
        #expect(try store.load().entries.allSatisfy { $0.keyword == nil })
    }

    @Test func roundtripAndUpdatePreserveOtherEntries() throws {
        let (store, _) = try makeStore()
        var entry = LibraryEntry(id: "one", kind: .snippet, title: "인사", value: "안녕하세요\n반갑습니다")
        try store.save(entry)
        entry.id = "two"
        try store.save(entry)
        entry.value = "수정"
        try store.save(entry)
        let entries = try store.load().entries
        #expect(entries.count == 2)
        #expect(entries.contains { $0.value.contains("안녕하세요") })
    }

    @Test func doesNotTouchFileSearchRoots() throws {
        let database = try SQLiteDatabase.inMemory()
        try database.execute("CREATE TABLE roots(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE); INSERT INTO roots VALUES('r','/tmp');")
        let store = try LibraryStore(database: database)
        try store.save(LibraryEntry(id: "a", kind: .link, title: "A", value: "https://example.com"))
        try store.delete(id: "a")
        #expect(try database.scalar("SELECT COUNT(*) FROM roots") == 1)
        let fresh = try SQLiteDatabase.inMemory()
        _ = try LibraryStore(database: fresh)
        #expect(try !fresh.tableExists("roots"))
    }

    @Test func rejectExecutableSchemesAndInvalidRecords() {
        for url in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.com", "https://", "ftp://example.com", "https://exa mple.com"] {
            #expect(throws: (any Error).self, "\(url)") {
                try LibraryValidation.validate(LibraryEntry(id: "one", kind: .link, title: "Test", value: url))
            }
        }
        #expect(throws: LibraryError.invalidPath) {
            try LibraryValidation.validate(LibraryEntry(id: "one", kind: .path, title: "Test", value: "relative/path"))
        }
        #expect(throws: LibraryError.invalidEntry) {
            try LibraryValidation.validate(LibraryEntry(id: "", kind: .snippet, title: "Test", value: "x"))
        }
        #expect(throws: LibraryError.invalidEntry) {
            try LibraryValidation.validate(LibraryEntry(id: "one", kind: .snippet, title: "  ", value: "x"))
        }
    }

    @Test func entryAndFavoriteDeletionShareATransaction() throws {
        let (store, _) = try makeStore()
        try store.save(LibraryEntry(id: "a", kind: .snippet, title: "A", value: "a"))
        try store.setFavorite(LibraryFavorite(id: "library:a", title: "A"), enabled: true)
        try store.setFavorite(LibraryFavorite(id: "native:com.apple.Safari", title: "Safari"), enabled: true)
        try store.delete(id: "a")
        let snapshot = try store.load()
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.favorites.map(\.id) == ["native:com.apple.Safari"])
    }

    @Test func favoritesKeepOrderAreBoundedAndReorderOnlyAsAPermutation() throws {
        let (store, _) = try makeStore()
        for index in 0..<3 { try store.setFavorite(LibraryFavorite(id: "prism:\(index)", title: "\(index)"), enabled: true) }
        #expect(try store.load().favorites.map(\.id) == ["prism:0", "prism:1", "prism:2"])
        try store.setFavorite(LibraryFavorite(id: "prism:1", title: "Renamed"), enabled: true)
        #expect(try store.load().favorites.map(\.title) == ["0", "Renamed", "2"])
        try store.reorderFavorites(["prism:2", "prism:0", "prism:1"])
        #expect(try store.load().favorites.map(\.id) == ["prism:2", "prism:0", "prism:1"])
        #expect(throws: LibraryError.favoritesChanged) { try store.reorderFavorites(["prism:2", "prism:0"]) }
        #expect(throws: LibraryError.favoritesChanged) { try store.reorderFavorites(["prism:2", "prism:2", "prism:1"]) }
        for index in 3..<50 { try store.setFavorite(LibraryFavorite(id: "prism:\(index)", title: ""), enabled: true) }
        #expect(throws: LibraryError.tooManyFavorites) { try store.setFavorite(LibraryFavorite(id: "prism:50", title: ""), enabled: true) }
        try store.setFavorite(LibraryFavorite(id: "prism:0", title: ""), enabled: false)
        #expect(try store.load().favorites.count == 49)
        #expect(throws: LibraryError.invalidFavorite) { try store.setFavorite(LibraryFavorite(id: "", title: ""), enabled: true) }
    }

    @Test func libraryCapacityIsEnforced() throws {
        let (store, _) = try makeStore()
        let big = String(repeating: "a", count: 120 * 1024)
        for index in 0..<136 { try store.save(LibraryEntry(id: "\(index)", kind: .snippet, title: "\(index)", value: big)) }
        #expect(throws: LibraryError.full) { try store.save(LibraryEntry(id: "x", kind: .snippet, title: "x", value: big)) }
        // Updating an existing entry does not count it twice.
        try store.save(LibraryEntry(id: "0", kind: .snippet, title: "0", value: big))
    }

    @Test func fileStoreUsesOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prism-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: LibraryStore.fileName)
        let store = try LibraryStore(url: url)
        try store.save(LibraryEntry(id: "a", kind: .note, title: "A", value: ""))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
