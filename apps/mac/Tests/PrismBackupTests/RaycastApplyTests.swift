import Foundation
import Testing
@testable import PrismBackup

@MainActor
final class FakeTargets: RaycastImportTargets {
    var shortcuts: [String: String] = [:]
    var launcher = "alt+Space"
    var aliasMap: [String: String] = [:]
    var entries: [ImportEntry] = []
    var favorites: Set<String> = []
    var failShortcut = false

    func hotkeys() throws -> [String: String] { shortcuts.merging([RaycastPlan.launcherID: launcher]) { $1 } }

    func setHotkey(_ value: String?, for commandID: String) throws {
        if failShortcut { throw BackupError("registration conflict") }
        if commandID == RaycastPlan.launcherID { launcher = value ?? launcher } else { shortcuts[commandID] = value }
    }

    func aliases() throws -> [String: String] { aliasMap }
    func setAliases(_ aliases: [String: String]) throws { aliasMap = aliases }
    func disabled() -> Set<String> { [] }
    func libraryEntries() throws -> [ImportEntry] { entries }
    func favoriteIDs() throws -> Set<String> { favorites }
    func saveEntry(_ entry: ImportEntry) throws { entries.append(entry) }
    func deleteEntry(id: String) throws { entries.removeAll { $0.id == id } }
}

/// Ports of `raycastApply.test.ts` and `migration_journal.rs`.
@Suite @MainActor struct RaycastApplyTests {
    let directory: URL
    let targets = FakeTargets()
    let importer: RaycastImporter

    init() throws {
        directory = try Fixtures.temporaryDirectory()
        importer = RaycastImporter(journal: MigrationJournalStore(url: directory.appending(path: MigrationJournalStore.fileName)), targets: targets)
    }

    static let hotkey = ImportItem(id: "1", category: .hotkeys, title: "Left Half", value: "Control+Alt+Left", commandId: "window:left-half")

    @Test func registersAndUndoesWindowShortcutsAndAliases() throws {
        let rows = try RaycastPlan.build(["settings": ["commands": [
            ["id": "c:r:window-management::-::leftHalf", "hotkey": "option-18", "alias": "left"],
            ["id": "c:r:window-management::-::moveNextDisplay", "hotkey": "control-command-14"],
        ]]], context: RaycastImportContext())
        #expect(rows.allSatisfy { $0.reason == nil })
        let journal = try importer.apply(rows)
        #expect(targets.shortcuts == ["window:left-half": "Alt+1", "window:next-display": "Control+Super+E"])
        #expect(targets.aliasMap == ["window:left-half": "left"])
        #expect(journal.changes.allSatisfy { $0.state == .applied })
        _ = try importer.undo(journal)
        #expect(targets.shortcuts.isEmpty)
        #expect(targets.aliasMap.isEmpty)
    }

    @Test func importsAndUndoesLibraryEntriesButKeepsNewFavorites() throws {
        let rows = try RaycastPlan.build(RaycastFileTests.classic, context: RaycastImportContext()).filter { $0.entry != nil && $0.isReady }
        let journal = try importer.apply(rows)
        #expect(targets.entries.count == 2)
        targets.favorites = ["library:\(targets.entries[0].id)"]
        let undone = try importer.undo(journal)
        #expect(targets.entries.count == 1)
        #expect(undone.changes.compactMap(\.error) == ["Changed after import; kept"])
        // A recovery record blocks a new import until it is discarded; then repeated entries are kept out.
        #expect(throws: BackupError(MigrationJournalStore.changed)) { try importer.apply(rows) }
        try importer.journal.clear(id: journal.id)
        let again = try importer.apply(rows, id: UUID().uuidString.lowercased())
        #expect(again.changes.map(\.state).contains(.failed))
    }

    @Test func abortsBeforeMutationIfTheRecoveryCopyCannotBeSaved() throws {
        try Data("{}".utf8).write(to: directory.appending(path: MigrationJournalStore.fileName))
        #expect(throws: BackupError.self) { try importer.apply([Self.hotkey]) }
        #expect(targets.shortcuts.isEmpty)
    }

    @Test func doesNotOverwriteAShortcutChangedSinceThePreview() throws {
        targets.shortcuts["window:left-half"] = "super+KeyJ"
        var item = Self.hotkey
        item.before = "super+KeyK"
        let journal = try importer.apply([item])
        #expect(journal.changes[0].state == .failed)
        #expect(targets.shortcuts["window:left-half"] == "super+KeyJ")
    }

    @Test func reportsRegistrationFailureAndStillImportsOtherItems() throws {
        targets.failShortcut = true
        let journal = try importer.apply([Self.hotkey, ImportItem(id: "2", category: .aliases, title: "Right Half", value: "right", commandId: "window:right-half")])
        #expect(journal.changes.map(\.state) == [.failed, .applied])
        #expect(targets.aliasMap == ["window:right-half": "right"])
    }

    @Test func undoesReplacementsButPreservesSubsequentEdits() throws {
        targets.shortcuts["window:left-half"] = "super+KeyK"
        var item = Self.hotkey
        item.before = "super+KeyK"
        let journal = try importer.apply([item, ImportItem(id: "2", category: .aliases, title: "Right", value: "right", commandId: "window:right-half")])
        targets.aliasMap["window:right-half"] = "new-alias"
        let undone = try importer.undo(journal)
        #expect(targets.shortcuts["window:left-half"] == "super+KeyK")
        #expect(targets.aliasMap["window:right-half"] == "new-alias")
        #expect(undone.changes[1].error?.contains("kept") == true)
    }

    @Test func recoversAWriteInterruptedBeforeTheAppliedMarker() throws {
        targets.shortcuts["window:left-half"] = Self.hotkey.value
        let journal = MigrationJournal(id: UUID().uuidString.lowercased(), changes: [.init(item: Self.hotkey, state: .pending)])
        try importer.journal.write(journal, create: true)
        let undone = try importer.undo(journal)
        #expect(targets.shortcuts.isEmpty)
        #expect(undone.changes[0].state == .undone)
    }

    @Test func journalRoundTripsAndIsClearedOnlyByItsID() throws {
        let store = importer.journal
        #expect(try store.read() == nil)
        let journal = try importer.apply([Self.hotkey])
        #expect(try store.read() == journal)
        #expect(throws: BackupError(MigrationJournalStore.changed)) { try store.clear(id: UUID().uuidString.lowercased()) }
        #expect(throws: BackupError(MigrationJournalStore.changed)) { try importer.apply([Self.hotkey]) }
        try store.clear(id: journal.id)
        #expect(try store.read() == nil)
        let mode = try? FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions]
        #expect(mode == nil)
    }

    @Test func malformedRecoveryIsNeverSilentlyDiscarded() throws {
        let store = importer.journal
        try Data("corrupt".utf8).write(to: store.url)
        #expect(throws: BackupError(MigrationJournalStore.invalid)) { try store.read() }
        #expect(try Data(contentsOf: store.url) == Data("corrupt".utf8))
        #expect(!MigrationJournalStore.isValid(["version": 2, "id": "bad", "changes": []]))
    }

    /// A record the Tauri app wrote (JSON from `raycastApply.ts`), including optional fields it omits.
    @Test func readsTauriRecoveryRecords() throws {
        let text = """
        {"version":1,"id":"0f8fad5b-d9cb-469f-a165-70867728950e","changes":[
          {"item":{"id":"0","category":"snippets","title":"Greeting","value":"Hello","entry":{"id":"a1","kind":"snippet","title":"Greeting","value":"Hello","keyword":";hello"},"conflict":false},"state":"applied"},
          {"item":{"id":"1","category":"hotkeys","title":"Left Half","value":"Control+Alt+Left","commandId":"window:left-half","conflict":false},"state":"pending"}
        ]}
        """
        try Data(text.utf8).write(to: importer.journal.url)
        let journal = try #require(try importer.journal.read())
        #expect(journal.isInterrupted)
        #expect(journal.changes[0].item.entry?.keyword == ";hello")
    }
}
