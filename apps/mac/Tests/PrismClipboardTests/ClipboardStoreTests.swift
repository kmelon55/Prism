import Foundation
import PrismKit
import Testing
@testable import PrismClipboard

// Ported from the tests in apps/desktop/src-tauri/src/clipboard_history.rs.

private let day = ClipboardLimits.dayMs
private func now() -> Int64 { ClipboardClock.nowMs() }

func makeStore(enabled: Bool = true) throws -> ClipboardStore {
    let store = try ClipboardStore(database: .inMemory())
    if enabled { try store.setEnabled(true) }
    return store
}

/// A database file in a fresh temporary directory, removed when the test ends.
final class TemporaryDatabase {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "prism-clipboard-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: ClipboardStore.fileName)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Test func captureCursorNeverBackfillsPauseOrPrivacyChanges() {
    var cursor = CaptureCursor()
    var observed: [Bool] = []
    func observe(_ generation: UInt64, _ revision: Int) { observed.append(cursor.observe(generation: generation, revision: revision)) }
    observe(0, 1)
    observe(0, 2)
    observe(0, 2)
    cursor.pause()
    #expect(cursor.previous(for: 0) == nil)
    observe(0, 3)
    observe(0, 4)
    #expect(cursor.previous(for: 1) == nil)
    observe(1, 5)
    observe(1, 6)
    #expect(observed == [false, true, false, false, true, false, true])
}

@Test func preferencesSurviveRestartWithoutDeletingPinsAndPauseBlocksCapture() throws {
    let file = TemporaryDatabase()
    let until = now() + 900_000
    do {
        let history = ClipboardStore.open(url: file.url)
        try history.setEnabled(true)
        try history.record(text: "keep me")
        let id = try history.search("", limit: 1)[0].id
        try history.setPinned(id: id, pinned: true)
        try history.updatePreferences { preferences in
            preferences.primaryAction = .copy
            preferences.pausedUntilMs = until
            preferences.excludedApplications.append(ExcludedApplication(id: "org.fixture.private", name: "Fixture"))
        }
        try history.record(text: "paused copy")
        #expect(try history.search("", limit: 10).count == 1)
    }
    let history = ClipboardStore.open(url: file.url)
    let preferences = history.testPreferences
    #expect(preferences.primaryAction == .copy)
    #expect(preferences.pausedUntilMs == until)
    #expect(try history.search("keep me", limit: 1)[0].pinned)
    #expect(preferences.excludes("org.fixture.private"))
    #expect(preferences.excludes(nil))
    #expect(!preferences.excludes("org.fixture.allowed"))
    try history.record(text: "after expiration", at: until + 1)
    #expect(try history.search("", limit: 10, at: until + 1).count == 2)
    try history.updatePreferences { $0.excludedApplications.removeAll() }
    #expect(!history.testPreferences.excludes(nil))
}

@Test func preferencesUseTheTauriJSONKeysAndDefaults() throws {
    let json = #"{"primaryAction":"copy","pausedUntilMs":5,"excludedApplications":[{"id":"a.b","name":"AB"}]}"#
    let decoded = try JSONDecoder().decode(ClipboardPreferences.self, from: Data(json.utf8))
    #expect(decoded.primaryAction == .copy)
    #expect(decoded.pausedUntilMs == 5)
    #expect(decoded.excludedApplications == [ExcludedApplication(id: "a.b", name: "AB")])
    #expect(try JSONDecoder().decode(ClipboardPreferences.self, from: Data("{}".utf8)) == ClipboardPreferences())
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
    #expect(Set(object?.keys.map { $0 } ?? []) == ["primaryAction", "pausedUntilMs", "excludedApplications"])
}

@Test func searchIsReadOnlyAndFiltersExpiredEntriesWithoutLosingPinsOrUnicode() throws {
    let history = try makeStore()
    try history.record(text: "한글 MixedCase fragment")
    let id = try history.search("", limit: 1)[0].id
    try history.setPinned(id: id, pinned: true)
    try history.record(text: "temporary")
    let changes = try history.testScalar("SELECT total_changes()")
    let later = now() + 91 * day
    #expect(try history.search("mixedCASE", limit: 20, at: later).count == 1)
    #expect(try history.search("한글", limit: 20, at: later)[0].id == id)
    #expect(try history.search("temporary", limit: 20, at: later).isEmpty)
    #expect(try history.testScalar("SELECT total_changes()") == changes)
    #expect(try history.testScalar("SELECT COUNT(*) FROM clipboard_entries") == 2)
}

@Test func dictationStyleRecordSurvivesRestartAndRespectsOptOut() throws {
    let file = TemporaryDatabase()
    let history = ClipboardStore.open(url: file.url)
    try history.setEnabled(true)
    try history.record(text: "Long dictation survives another clipboard write")
    #expect(ClipboardStore.open(url: file.url).settings().entryCount == 1)
    try history.setEnabled(false)
    try history.record(text: "Disabled history must stay empty")
    #expect(history.settings().entryCount == 0)
}

@Test func unavailableStorageNeverFallsBackToVolatileCapture() throws {
    let file = TemporaryDatabase()
    try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
    let store = ClipboardStore.open(url: file.url)
    #expect(!store.isEnabled)
    #expect(throws: ClipboardError.self) { try store.setEnabled(true) }
    #expect(!store.isEnabled)
    #expect(store.settings().persistenceError != nil)
    #expect(throws: ClipboardError.self) { try store.search("", limit: 10) }
}

@Test func optInPinsTextAndRetentionSurviveRestart() throws {
    let file = TemporaryDatabase()
    let id: Int64
    do {
        let store = ClipboardStore.open(url: file.url)
        #expect(!store.isEnabled)
        try store.record(text: "must not persist before consent")
        #expect(store.settings().entryCount == 0)
        try store.setEnabled(true)
        try store.setRetention(days: 7)
        try store.record(text: "지속되는 메모")
        id = try store.search("", limit: 1)[0].id
        try store.setPinned(id: id, pinned: true)
    }
    let reopened = ClipboardStore.open(url: file.url)
    #expect(reopened.isEnabled)
    #expect(reopened.testRetentionDays == 7)
    #expect(try reopened.text(id: id) == "지속되는 메모")
    #expect(try reopened.search("", limit: 1)[0].pinned)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    // Same journal mode as the Tauri app, so both can open the file.
    #expect(try reopened.testScalar("SELECT count(*) FROM pragma_journal_mode WHERE journal_mode='delete'") == 1)
}

@Test func boundedDeduplicationPreservesPinAndStableIdentity() throws {
    let store = try makeStore()
    let at = now()
    try store.record(text: "pinned", at: at)
    let id = try store.search("", limit: 1, at: at)[0].id
    try store.setPinned(id: id, pinned: true)
    for index in 0..<(ClipboardLimits.capacity + 5) {
        try store.record(text: "entry \(index)", at: at + Int64(index))
    }
    try store.record(text: "pinned", at: at + 9999)
    let entries = try store.search("", limit: ClipboardLimits.capacity + 100, at: at + 9999)
    #expect(entries.count == ClipboardLimits.capacity)
    #expect(entries[0].id == id)
    #expect(entries[0].pinned)
    #expect(entries.filter { $0.text == "pinned" }.count == 1)
    #expect(!entries.contains { $0.text == "entry 0" })
}

@Test func allPinnedCapacityRejectsNewContentWithoutEvictingPins() throws {
    let store = try makeStore()
    let at = now()
    for index in 0..<ClipboardLimits.capacity {
        try store.record(text: "pin \(index)", at: at)
    }
    try store.testExecute("UPDATE clipboard_entries SET pinned=1")
    try store.record(text: "overflow", at: at + 1)
    #expect(store.settings().entryCount == ClipboardLimits.capacity)
    #expect(store.settings().pinnedCount == ClipboardLimits.capacity)
    #expect(try store.search("overflow", limit: 1, at: at + 1).isEmpty)
}

@Test func shorteningRetentionExpiresUnpinnedButPreservesPins() throws {
    let store = try makeStore()
    let at = now()
    try store.record(text: "old pin", at: at - 2 * day)
    let id = try store.search("old pin", limit: 1, at: at)[0].id
    try store.setPinned(id: id, pinned: true)
    try store.record(text: "old unpinned", at: at - 2 * day)
    try store.record(text: "recent", at: at)
    try store.setRetention(days: 1)
    let entries = try store.search("", limit: 100, at: at)
    #expect(entries.count == 2)
    #expect(entries.contains { $0.id == id })
    #expect(!entries.contains { $0.text == "old unpinned" })
    try store.setPinned(id: id, pinned: false)
    #expect(throws: ClipboardError.self) { try store.text(id: id) }
    #expect(throws: ClipboardError.self) { try store.setRetention(days: 365) }
    #expect(store.testRetentionDays == 1)
}

@Test func restartPrunesExpiredUnpinnedEntries() throws {
    let file = TemporaryDatabase()
    do {
        let store = ClipboardStore.open(url: file.url)
        try store.setEnabled(true)
        try store.record(text: "expired", at: now() - 31 * day)
    }
    #expect(ClipboardStore.open(url: file.url).settings().entryCount == 0)
}

@Test func clearAndDisableRemovePinsDurablyButOnlyDisableTurnsCaptureOff() throws {
    let file = TemporaryDatabase()
    let store = ClipboardStore.open(url: file.url)
    try store.setEnabled(true)
    try store.record(text: "pin")
    let firstID = try store.search("", limit: 1)[0].id
    try store.setPinned(id: firstID, pinned: true)
    #expect(try store.clear() == 1)
    #expect(store.isEnabled)
    try store.record(text: "new text")
    let secondID = try store.search("", limit: 1)[0].id
    #expect(secondID > firstID)
    #expect(throws: ClipboardError.self) { try store.text(id: firstID) }
    try store.setEnabled(false)
    #expect(throws: ClipboardError.self) { try store.text(id: secondID) }
    let reopened = ClipboardStore.open(url: file.url)
    #expect(!reopened.isEnabled)
    #expect(reopened.settings().entryCount == 0)
}

@Test func deleteIsDurableIdempotentAndDoesNotDeleteOtherEntries() throws {
    let file = TemporaryDatabase()
    let store = ClipboardStore.open(url: file.url)
    try store.setEnabled(true)
    try store.record(text: "delete me")
    let id = try store.search("", limit: 1)[0].id
    try store.record(text: "keep me")
    try store.delete(id: id)
    try store.delete(id: id)
    let reopened = ClipboardStore.open(url: file.url)
    #expect(throws: ClipboardError.self) { try reopened.text(id: id) }
    #expect(try reopened.search("", limit: 100)[0].text == "keep me")
}

@Test func writeFailureIsVisibleAndFailedDeleteRollsBack() throws {
    let store = try makeStore()
    try store.record(text: "keep after failed deletion")
    try store.testExecute("PRAGMA query_only=ON")
    #expect(throws: ClipboardError.self) { try store.clear() }
    #expect(store.settings().entryCount == 1)
    #expect(store.settings().persistenceError != nil)
    #expect(throws: ClipboardError.self) { try store.setEnabled(false) }
    #expect(!store.isEnabled)
    try store.testExecute("PRAGMA query_only=OFF")
    try store.setEnabled(false)
    #expect(store.settings().entryCount == 0)
    #expect(store.settings().persistenceError == nil)
}

@Test func credentialsPrivacyMarkersAndSizeLimitsAreRejected() {
    for text in [
        "-----BEGIN PRIVATE KEY-----\nabc", "password=hunter2", "ghp_abcdefghijklmnopqrstuvwxyz",
        "eyJhbGciOiJIUzI1NiJ9.abcdefghijk.abcdefghijklmnop", "AKIAABCDEFGHIJKLMNOP",
    ] {
        #expect(!ClipboardPolicy.shouldCapture(text), "\(text)")
    }
    #expect(!ClipboardPolicy.shouldCapture(String(repeating: "a", count: ClipboardLimits.maxTextBytes + 1)))
    #expect(!ClipboardPolicy.shouldCapture("   \n "))
    #expect(ClipboardPolicy.shouldCapture("A normal clipboard note"))
    for kind in [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.private", "de.petermaurer.TransientPasteboardType", "com.agilebits.onepassword",
    ] {
        #expect(ClipboardPolicy.isPrivateType(kind), "\(kind)")
    }
    #expect(!ClipboardPolicy.isPrivateType("public.utf8-plain-text"))
}

@Test func fullTextIsPreservedWhilePreviewIsUnicodeSafeAndSearchIsCaseInsensitive() throws {
    let store = try makeStore()
    let text = "Prism \(String(repeating: "클립", count: 300)) tail"
    try store.record(text: text)
    let entry = try store.search("prism", limit: 1)[0]
    #expect(try store.text(id: entry.id) == text)
    #expect(entry.text.count == ClipboardLimits.searchPreviewCharacters + 1)
    #expect(entry.text.hasSuffix("…"))
    #expect(try store.search("TAIL", limit: 1).count == 1)
}

@Test func v1MigrationKeepsTextPinsConsentAndDeletedIDHighWater() throws {
    let db = try SQLiteDatabase.inMemory()
    try db.execute("""
        CREATE TABLE clipboard_settings(id INTEGER PRIMARY KEY,enabled INTEGER NOT NULL,retention_days INTEGER NOT NULL);
        INSERT INTO clipboard_settings VALUES(1,1,7);
        CREATE TABLE clipboard_entries(id INTEGER PRIMARY KEY AUTOINCREMENT,text TEXT NOT NULL UNIQUE,captured_at_ms INTEGER NOT NULL,pinned INTEGER NOT NULL DEFAULT 0);
        """)
    try db.run("INSERT INTO clipboard_entries(id,text,captured_at_ms,pinned) VALUES(42,'기존 메모',?,1)", [now()])
    try db.run("INSERT INTO clipboard_entries(id,text,captured_at_ms) VALUES(900,'deleted',?)", [now()])
    try db.run("DELETE FROM clipboard_entries WHERE id=900")
    let store = try ClipboardStore(database: db)
    #expect(store.isEnabled)
    #expect(store.testRetentionDays == 7)
    #expect(try store.text(id: 42) == "기존 메모")
    let entry = try store.search("", limit: 1)[0]
    #expect(entry.pinned)
    #expect(entry.kind == .text)
    try store.record(text: "after migration")
    #expect(try store.search("after migration", limit: 1)[0].id > 900)
    #expect(db.userVersion == 2)
}

@Test func referencesRemainMetadataAndMissingFilesFailReuse() throws {
    let file = TemporaryDatabase()
    try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
    let referenced = file.directory.appending(path: "secret.txt")
    try Data("password=must never enter the clipboard database".utf8).write(to: referenced)
    let url = referenced.absoluteString
    let store = try makeStore()
    try store.record(.files([url]))
    try store.record(text: "ordinary text")
    let entry = try store.search("", limit: 10, kind: .files)[0]
    #expect(entry.available == nil)
    #expect(entry.fileCount == 1)
    #expect(throws: ClipboardError.self) { try store.text(id: entry.id) }
    #expect(try store.payload(id: entry.id) == .files([url]))
    #expect(try store.testScalar("SELECT COUNT(*) FROM clipboard_entries WHERE kind='files' AND CAST(payload AS TEXT) LIKE '%password%'") == 0)
    try FileManager.default.removeItem(at: referenced)
    #expect(throws: ClipboardError.self) { try ClipboardPolicy.prepare(store.payload(id: entry.id)) }
    #expect(try store.search("", limit: 10, kind: .files)[0].available == nil)
    #expect(throws: ClipboardError.self) { try ClipboardPolicy.validateFileReferences(["https://example.com/file"]) }
    #expect(throws: ClipboardError.self) { try ClipboardPolicy.validateFileReferences(["file://remote/private/file"]) }
    #expect(throws: ClipboardError.self) {
        try ClipboardPolicy.validateFileReferences(Array(repeating: "file:///tmp", count: ClipboardLimits.maxFileReferences + 1))
    }
}

@Test func storedFileReferencesMatchTheTauriJSONBytes() throws {
    let store = try makeStore()
    try store.record(.files(["file:///Users/me/a%20b.txt"]))
    #expect(try store.testScalar("SELECT COUNT(*) FROM clipboard_entries WHERE CAST(payload AS TEXT)='[\"file:///Users/me/a%20b.txt\"]'") == 1)
    #expect(try store.search("a b.txt", limit: 1).count == 1)
}

@Test func fileSearchUsesOnlyMetadataAndReportsUnknownAvailability() throws {
    let missing = TemporaryDatabase()
    let store = try makeStore()
    try store.record(.files([missing.url.absoluteString]))
    try store.record(text: "plain text")
    let entry = try store.search("prism-clipboard-test", limit: 1, kind: .files)[0]
    #expect(entry.available == nil)
    #expect(try store.search("plain", limit: 1, kind: .text)[0].available == true)
    // Unreadable payload bytes cannot affect the list: it never loads the payload.
    try store.testExecute("UPDATE clipboard_entries SET payload=X'00' WHERE id=?", [entry.id])
    #expect(try store.search("prism-clipboard-test", limit: 1, kind: .files)[0] == entry)
    #expect(throws: ClipboardError.self) { try store.payload(id: entry.id) }
}

@Test(arguments: 0..<4)
func actionValidationRejectsHistoryChanges(change: Int) throws {
    let store = try makeStore()
    try store.record(text: "selected")
    let id = try store.search("", limit: 1)[0].id
    #expect(throws: ClipboardError.self) {
        try store.prepareForAction(id: id) { payload throws(ClipboardError) in
            switch change {
            case 0: _ = try store.clear()
            case 1: try store.delete(id: id)
            case 2: try store.setEnabled(false)
            // Capacity or retention eviction does not change the generation.
            default: try? store.testExecute("DELETE FROM clipboard_entries WHERE id=?", [id])
            }
            return try ClipboardPolicy.prepare(payload)
        }
    }
}

@Test func actionValidationAllowsAnUnchangedEntry() throws {
    let store = try makeStore()
    try store.record(text: "selected")
    let id = try store.search("", limit: 1)[0].id
    #expect(try store.prepareForAction(id: id) == .text("selected"))
}

@Test func actionValidationDoesNotHoldTheStoreLockWhilePreparing() async throws {
    let store = try makeStore()
    try store.record(text: "selected")
    let id = try store.search("", limit: 1)[0].id
    let result = try store.prepareForAction(id: id) { payload throws(ClipboardError) in
        // Another thread must be able to use the store while files are checked.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.settings()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 2) == .success else { throw ClipboardError("validation held history lock") }
        return payload
    }
    #expect(result == .text("selected"))
}

@Test func byteBudgetEvictsOldUnpinnedAndNeverEvictsPins() throws {
    let store = try makeStore()
    try store.record(text: "old")
    try store.testExecute("UPDATE clipboard_entries SET byte_size=?", [ClipboardLimits.maxStoredBytes])
    try store.record(text: "new")
    #expect(try store.search("old", limit: 1).isEmpty)
    let entry = try store.search("new", limit: 1)[0]
    try store.setPinned(id: entry.id, pinned: true)
    try store.testExecute("UPDATE clipboard_entries SET byte_size=?", [ClipboardLimits.maxStoredBytes])
    try store.record(text: "rejected")
    #expect(store.settings().entryCount == 1)
    #expect(store.settings().captureNotice != nil)
    #expect(try store.text(id: entry.id) == "new")
}

@Test func monitorCapturesAreDroppedAfterAGenerationChange() throws {
    let store = try makeStore()
    let generation = store.generation
    try store.record(text: "existing")
    try store.delete(id: try store.search("", limit: 1)[0].id)
    store.recordCapture(.success(.text("stale capture")), generation: generation)
    #expect(store.settings().entryCount == 0)
    store.recordCapture(.success(.text("fresh capture")), generation: store.generation)
    #expect(store.settings().entryCount == 1)
    store.recordCapture(.failure(.unsupported), generation: store.generation)
    #expect(store.settings().captureNotice == ClipboardError.unsupported.message)
}
