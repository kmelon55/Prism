import Foundation
import Testing
@testable import PrismKit

@Test func roundTripsValuesAndTransactions() throws {
    let database = try SQLiteDatabase.inMemory()
    try database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, payload BLOB)")
    try database.run("INSERT INTO items (name, score, payload) VALUES (?, ?, ?)", ["한글", 1.5, Data([1, 2, 3])])
    #expect(database.lastInsertRowID == 1)

    struct Failure: Error {}
    #expect(throws: Failure.self) {
        try database.transaction {
            try database.run("INSERT INTO items (name) VALUES (?)", ["rolled back"])
            throw Failure()
        }
    }

    let rows = try database.query("SELECT * FROM items") { ($0.string("name"), $0.double("score"), $0.data("payload")) }
    #expect(rows.count == 1)
    #expect(rows[0].0 == "한글")
    #expect(rows[0].1 == 1.5)
    #expect(rows[0].2 == Data([1, 2, 3]))
    #expect(try database.scalar("SELECT count(*) FROM items") == 1)
    #expect(try database.tableExists("items"))
}

@Test func developmentBuildsNeverUseReleaseDataFolder() {
    let dev = AppPaths.current(bundleIdentifier: nil, environment: [:])
    #expect(dev.dataDirectory.lastPathComponent == "dev.prism.native-dev")
    let release = AppPaths.current(bundleIdentifier: "dev.prism.desktop", environment: [:])
    #expect(release.dataDirectory.lastPathComponent == "dev.prism.desktop")
    let overridden = AppPaths.current(bundleIdentifier: "dev.prism.desktop", environment: ["PRISM_DATA_DIR": "/tmp/prism-test"])
    #expect(overridden.dataDirectory.path == "/tmp/prism-test")
}

@Test func parsesTauriAccelerators() throws {
    let history = try #require(Shortcut(accelerator: "shift+super+KeyV"))
    #expect(history.displayName == "⇧⌘V")
    #expect(history.accelerator == "shift+super+KeyV")
    #expect(Shortcut(accelerator: "alt+Digit4")?.displayName == "⌥4")
    #expect(Shortcut(accelerator: "super+Space")?.displayName == "⌘Space")
    #expect(Shortcut(accelerator: "CommandOrControl+Shift+Space") == Shortcut(accelerator: "shift+super+Space"))
    #expect(Shortcut(accelerator: "DoubleControl") == nil)
}

@Test func storesEmptyDataAsEmptyBlobNotNull() throws {
    let database = try SQLiteDatabase.inMemory()
    try database.execute("CREATE TABLE blobs (payload BLOB)")
    try database.run("INSERT INTO blobs (payload) VALUES (?)", [Data()])
    #expect(try database.scalar("SELECT count(*) FROM blobs WHERE payload IS NOT NULL AND length(payload) = 0") == 1)
}

@Test func developmentLauncherAvoidsInputSourceShortcuts() {
    // ⌃Space and ⌃⌥Space switch input sources on many Korean setups.
    let dev = Shortcut.launcherDefault
    #expect(dev.displayName == "⌃⇧Space")
}
