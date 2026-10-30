import Darwin
import Foundation
import PrismKit
import Testing
@testable import PrismBackup

/// Ports of the `library_backup.rs` tests.
@Suite struct BackupRestoreTests {
    @Test func notesBackupRoundTripsAndObeysCategorySelection() throws {
        let library = try Fixtures.library()
        var document = Fixtures.document()
        document.version = 3
        document.entries[0].kind = "note"
        document.entries[0].value = "# 메모\n{clipboard}"
        let bytes = try document.encoded()
        var prepared = try BackupRestore.prepare(BackupDocument.parse(bytes), categories: Fixtures.categories, library: library)
        #expect(prepared.summary.notes.added == 1)
        #expect(prepared.summary.snippets.added == 0)
        var selected = Fixtures.categories
        selected.notes = false
        prepared = try BackupRestore.prepare(BackupDocument.parse(bytes), categories: selected, library: library)
        #expect(prepared.summary.notes.total == 0)
        try library.database.transaction { try library.save(document.entries[0]) }
        prepared = try BackupRestore.prepare(BackupDocument.parse(bytes), categories: Fixtures.categories, library: library)
        #expect(prepared.summary.notes.conflicts == 1)
        document.entries[0].value = ""
        #expect(throws: Never.self) { try BackupDocument.parse(document.encoded()) }
        document.version = 2
        #expect(throws: BackupError.self) { try document.validate() }
    }

    @Test func pathReferencesAreOptInAndNeverRestoreRoots() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Fixtures.library()
        var document = Fixtures.document()
        document.entries = [("existing", directory.path), ("missing", directory.appending(path: "absent").path)].map {
            BackupEntry(id: $0.0, kind: "path", title: $0.0, value: $0.1)
        }
        document.favorites = []
        var prepared = try BackupRestore.prepare(document, categories: Fixtures.categories, library: library)
        #expect(prepared.entries.isEmpty)
        #expect(prepared.pathReferences.isEmpty)
        var selected = Fixtures.categories
        selected.pathLinks = true
        prepared = try BackupRestore.prepare(document, categories: selected, library: library)
        #expect(prepared.summary.pathLinks.added == 2)
        #expect(prepared.pathReferences.map(\.status) == [.existing, .missing])
        try BackupRestore.apply(prepared, library: library)
        #expect(try library.read().entries.count == 2)
        #expect(try !library.database.tableExists("roots"))
    }

    @Test func keywordRoundTripAndConflictsAreReviewedBeforeMutation() throws {
        let library = try Fixtures.library()
        var document = Fixtures.document()
        document.version = 2
        document.entries[0].keyword = ";hello"
        let prepared = try BackupRestore.prepare(BackupDocument.parse(document.encoded()), categories: Fixtures.categories, library: library)
        try BackupRestore.apply(prepared, library: library)
        #expect(try library.read().entries[0].keyword == ";hello")
        let before = try library.baseline()
        document.entries[0].id = "another"
        #expect(throws: BackupError(BackupMessage.keywordConflict)) {
            try BackupRestore.prepare(document, categories: Fixtures.categories, library: library)
        }
        #expect(try library.baseline() == before)
        let empty = try Fixtures.library()
        document.entries.append(document.entries[0])
        document.entries[1].id = "third"
        #expect(throws: BackupError.self) { try BackupRestore.prepare(document, categories: Fixtures.categories, library: empty) }
        #expect(try empty.read().entries.isEmpty)
    }

    @Test func errorsDistinguishMalformedFutureAndUnsupportedData() throws {
        #expect(throws: BackupError(BackupMessage.malformed)) { try BackupDocument.parse(Data("{".utf8)) }
        #expect(throws: BackupError(BackupMessage.newer)) { try BackupDocument.parse(Data(#"{"version":999,"futurePayload":true}"#.utf8)) }
        var value = Fixtures.object(Fixtures.document())
        value["permissionGrants"] = ["/"]
        #expect(throws: BackupError(BackupMessage.unsupported)) { try BackupDocument.parse(Fixtures.json(value)) }
        value["permissionGrants"] = nil
        var entries = value["entries"] as! [[String: Any]]
        entries[0]["keyword"] = "invalid keyword"
        value["entries"] = entries
        #expect(throws: BackupError(BackupMessage.invalid)) { try BackupDocument.parse(Fixtures.json(value)) }
    }

    @Test func conservativeConflictsPreserveExistingValuesAndOrder() throws {
        let library = try Fixtures.library()
        var old = Fixtures.document().entries[0]
        old.value = "Keep me"
        try library.database.transaction { try library.save(old) }
        try library.database.run("INSERT INTO favorites VALUES('app:existing','Existing',0)")
        let prepared = try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        #expect(prepared.summary.snippets.conflicts == 1)
        #expect(prepared.summary.favorites.added == 1)
        try BackupRestore.apply(prepared, library: library)
        let data = try library.read()
        #expect(data.entries[0].value == "Keep me")
        #expect(data.favorites.map(\.id) == ["app:existing", "library:one"])
    }

    @Test func selectionSkipsDanglingLibraryFavorites() throws {
        var selected = Fixtures.categories
        selected.snippets = false
        let prepared = try BackupRestore.prepare(Fixtures.document(), categories: selected, library: Fixtures.library())
        #expect(prepared.entries.isEmpty)
        #expect(prepared.summary.favorites.skipped == 1)
        #expect(prepared.missingFavorites.map(\.id) == ["library:one"])
    }

    @Test func malformedOversizedFutureAndDuplicateDocumentsAreRejected() throws {
        #expect(throws: BackupError.self) { try BackupDocument.parse(Data("{".utf8)) }
        #expect(throws: BackupError(BackupMessage.tooLarge)) { try BackupDocument.parse(Data(repeating: 0x20, count: BackupDocument.maxBytes + 1)) }
        var document = Fixtures.document()
        document.version = 4
        #expect(throws: BackupError(BackupMessage.newer)) { try document.validate() }
        document.version = 1
        document.entries.append(document.entries[0])
        #expect(throws: BackupError.self) { try document.validate() }
        var value = Fixtures.object(Fixtures.document())
        value["preferences"] = ["language": "en", "scriptDirectories": ["/tmp"]]
        #expect(throws: BackupError(BackupMessage.unsupported)) { try BackupDocument.parse(Fixtures.json(value)) }
        #expect(throws: BackupError(BackupMessage.invalid)) { try BackupDocument.parse(Data(#"{"version":2.5}"#.utf8)) }
        #expect(throws: BackupError(BackupMessage.invalid)) { try BackupDocument.parse(Data("[]".utf8)) }
    }

    @Test func rejectUnsafeEntriesEvenInUnselectedCategories() throws {
        var document = Fixtures.document()
        document.entries[0].kind = "path"
        document.entries[0].value = "relative/path"
        let selected = BackupCategories(snippets: false, notes: false, quicklinks: false, pathLinks: false, favorites: true, preferences: false)
        #expect(throws: BackupError.self) { try BackupRestore.prepare(document, categories: selected, library: Fixtures.library()) }
        document = Fixtures.document()
        document.entries[0].kind = "link"
        document.entries[0].value = "javascript:alert(1)"
        #expect(throws: BackupError.self) { try document.validate() }
    }

    @Test func failedApplyRollsBackAllWritesAndFreshReviewCanRetry() throws {
        let library = try Fixtures.library()
        let before = try library.baseline()
        try library.database.execute("CREATE TRIGGER fail_import BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
        var prepared = try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        #expect(throws: BackupError(BackupMessage.restoreFailed)) { try BackupRestore.apply(prepared, library: library) }
        #expect(try library.baseline() == before)
        try library.database.execute("DROP TRIGGER fail_import")
        prepared = try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        try BackupRestore.apply(prepared, library: library)
        #expect(try library.read().entries.count == 1)
    }

    @Test func concurrentMutationInvalidatesReviewWithoutApplying() throws {
        let library = try Fixtures.library()
        let prepared = try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        try library.database.execute("CREATE TABLE roots(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE); INSERT INTO roots VALUES('root','/fixture');")
        let before = try library.baseline()
        #expect(throws: BackupError(BackupMessage.stale)) { try BackupRestore.apply(prepared, library: library) }
        #expect(try library.baseline() == before)
    }

    @Test @MainActor func tokensAreSingleUseAndNewReviewInvalidatesPrevious() throws {
        let library = try Fixtures.library()
        let reviews = BackupReviews()
        let first = reviews.issue(try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library))
        let second = reviews.issue(try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library))
        #expect(first != second)
        #expect(throws: BackupError.self) { try reviews.take(first) }
        #expect(throws: Never.self) { try reviews.take(second) }
        #expect(throws: BackupError.self) { try reviews.take(second) }
    }

    @Test func expiredReviewPreservesData() throws {
        let library = try Fixtures.library()
        var prepared = try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        prepared.created = Date().addingTimeInterval(-PreparedRestore.lifetime - 1)
        #expect(throws: BackupError(BackupMessage.stale)) { try BackupRestore.apply(prepared, library: library) }
        #expect(try library.read().entries.isEmpty)
    }

    @Test func capacityIsCheckedBeforeAnyWrites() throws {
        let library = try Fixtures.library()
        for index in 0..<50 { try library.database.run("INSERT INTO favorites VALUES(?,'Fixture',?)", ["app:\(index)", index]) }
        #expect(throws: BackupError(BackupMessage.full)) {
            try BackupRestore.prepare(Fixtures.document(), categories: Fixtures.categories, library: library)
        }
        #expect(try library.read().entries.isEmpty)
    }

    @Test func safePreferencesRejectExtraAuthorityAndOutOfRangeValues() throws {
        let value: [String: Any] = ["language": "ko", "theme": "dark", "reduceMotion": true, "backgroundOpacity": 97, "backgroundBlur": 44,
                                    "showApplicationIcons": true, "commandAliases": ["prism:settings": "설정"]]
        var preferences = try #require(SafePreferences(json: value))
        try preferences.validate()
        var unsafe = value
        unsafe["scriptDirectories"] = ["/tmp"]
        #expect(SafePreferences(json: unsafe) == nil)
        var mistyped = value
        mistyped["reduceMotion"] = 1
        #expect(SafePreferences(json: mistyped) == nil)
        preferences.commandAliases["native:fixture"] = String(repeating: "가", count: 80)
        try preferences.validate()
        preferences.commandAliases["native:fixture"] = String(repeating: "가", count: 81)
        #expect(throws: BackupError.self) { try preferences.validate() }
        preferences.commandAliases["native:fixture"] = nil
        for opacity in [10.0, 40, 64, 100] { preferences.backgroundOpacity = opacity; try preferences.validate() }
        for opacity in [9.0, 101, 0] {
            preferences.backgroundOpacity = opacity
            #expect(throws: BackupError.self) { try preferences.validate() }
        }
        preferences.backgroundOpacity = 97
        for blur in [0.0, 60, 120, 180, 240] { preferences.backgroundBlur = blur; try preferences.validate() }
        for blur in [-1.0, 241, .nan] {
            preferences.backgroundBlur = blur
            #expect(throws: BackupError.self) { try preferences.validate() }
        }
        preferences.backgroundBlur = 28
        preferences.commandAliases["__proto__"] = "unsafe"
        #expect(throws: BackupError.self) { try preferences.validate() }
    }

    @Test func exportIsCompleteAndFailedRenamePreservesDestination() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "backup.json")
        try Data("old".utf8).write(to: url)
        #expect(throws: BackupError(BackupMessage.tooLarge)) { try BackupFiles.write(Data(count: BackupDocument.maxBytes + 1), to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "old")
        let bytes = try Fixtures.document().encoded()
        try BackupFiles.write(bytes, to: url)
        #expect(try BackupFiles.read(url) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let blocked = directory.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: blocked.appending(path: "keep"))
        #expect(throws: BackupError(BackupMessage.writeError)) { try BackupFiles.write(Data("new".utf8), to: blocked) }
        #expect(try String(contentsOf: blocked.appending(path: "keep"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func chooserReaderRejectsSymlinksSpecialFilesAndOversizeFiles() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appending(path: "large")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(BackupDocument.maxBytes + 1))
        try handle.close()
        #expect(throws: BackupError(BackupMessage.tooLarge)) { try BackupFiles.read(large) }
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
        #expect(throws: BackupError.self) { try BackupFiles.read(link) }
        #expect(throws: BackupError(BackupMessage.invalid)) { try BackupFiles.read(directory) }
        let fifo = directory.appending(path: "pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: BackupError(BackupMessage.invalid)) { try BackupFiles.read(fifo) }
    }

    @Test func exportDocumentMatchesTheTauriFormat() throws {
        let library = try Fixtures.library()
        try library.database.transaction {
            try library.save(BackupEntry(id: "s", kind: "snippet", title: "Greeting", value: "Hi", keyword: ";hi"))
            try library.save(BackupEntry(id: "p", kind: "path", title: "Docs", value: "/Users/Shared"))
        }
        var document = try BackupRestore.exportDocument(categories: Fixtures.categories, library: library, preferences: nil)
        #expect(document.version == 2)
        #expect(document.entries.map(\.id) == ["s"])
        let object = Fixtures.object(document)
        #expect(Set(object.keys) == ["format", "version", "entries", "favorites", "preferences"])
        #expect(object["preferences"] is NSNull)
        #expect((object["entries"] as? [[String: Any]])?.first?["keyword"] as? String == ";hi")
        #expect(try BackupDocument.parse(document.encoded()) == document)
        var categories = Fixtures.categories
        categories.preferences = true
        #expect(throws: BackupError.self) { try BackupRestore.exportDocument(categories: categories, library: library, preferences: nil) }
        document = try BackupRestore.exportDocument(categories: categories, library: library, preferences: Fixtures.preferences())
        #expect(try BackupDocument.parse(document.encoded()).preferences == Fixtures.preferences())
        #expect(throws: BackupError(BackupMessage.noCategory)) {
            try BackupRestore.exportDocument(categories: BackupCategories(snippets: false, notes: false, quicklinks: false, pathLinks: false,
                                                                          favorites: false, preferences: false), library: library, preferences: nil)
        }
    }

    /// A file shaped like one the Tauri app writes (serde field order, `97.0` floats, no `keyword`).
    @Test func readsTauriWrittenBackups() throws {
        let text = """
        {
          "format": "prism-backup",
          "version": 2,
          "entries": [
            {"id": "a", "kind": "link", "title": "Search", "value": "https://example.com/?q={query}"},
            {"id": "b", "kind": "snippet", "title": "Sig", "value": "Thanks", "keyword": ";sig"}
          ],
          "favorites": [{"id": "library:a", "title": "Search"}],
          "preferences": {"language": "ko", "theme": "system", "reduceMotion": false, "backgroundOpacity": 97.0,
            "backgroundBlur": 12.0, "showApplicationIcons": true, "commandAliases": {"window:left-half": "왼쪽"}}
        }
        """
        let document = try BackupDocument.parse(Data(text.utf8))
        #expect(document.entries.count == 2)
        #expect(document.preferences?.commandAliases == ["window:left-half": "왼쪽"])
        var categories = Fixtures.categories
        categories.preferences = true
        let prepared = try BackupRestore.prepare(document, categories: categories, library: Fixtures.library())
        #expect(prepared.summary.quicklinks.added == 1)
        #expect(prepared.summary.favorites.added == 1)
        #expect(prepared.preferences?.language == "ko")
    }
}
