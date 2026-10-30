import Foundation
import PrismKit

/// Durable clipboard history in `clipboard-history-v1.sqlite3`, with the Tauri app's schema, limits and
/// privacy rules (`clipboard_history.rs` is the specification). Thread-safe; call it off the main actor
/// for anything that reads payloads.
public final class ClipboardStore: @unchecked Sendable {
    public static let fileName = "clipboard-history-v1.sqlite3"

    private static let entryColumns = "id,text,captured_at_ms,pinned,kind,mime_type,byte_size,width,height,file_count"

    private let lock = NSRecursiveLock()
    private let database: SQLiteDatabase?
    private var enabled = false
    private var retentionDays = 30
    private var preferences = ClipboardPreferences()
    private var persistenceError: String?
    private var captureNotice: String?
    /// Changes on enable, disable, clear, delete and privacy edits. In-flight captures and previews from an
    /// older generation are discarded.
    var generation: UInt64 { lock.withLock { _generation } }
    private var _generation: UInt64 = 0

    /// Opens or creates the history file. A failure leaves a disabled store that reports the error and never
    /// falls back to volatile capture.
    public static func open(url: URL) -> ClipboardStore {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Create the database privately before SQLite opens it.
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw ClipboardError.unavailable
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try ClipboardStore(database: SQLiteDatabase(url: url, journalMode: "DELETE"))
        } catch {
            return ClipboardStore(failure: ClipboardError.unavailable.message)
        }
    }

    private init(failure: String) {
        database = nil
        persistenceError = failure
    }

    init(database: SQLiteDatabase) throws {
        self.database = database
        do {
            try Self.migrate(database)
            preferences = try database.query("SELECT value FROM clipboard_preferences WHERE id=1") { $0.string("value") }
                .first.flatMap { $0 }
                .map { value in try JSONDecoder().decode(ClipboardPreferences.self, from: Data(value.utf8)) } ?? ClipboardPreferences()
            let settings = try database.query("SELECT enabled,retention_days FROM clipboard_settings WHERE id=1") {
                ($0.bool("enabled"), Int($0.int("retention_days")))
            }
            guard let (enabled, retention) = settings.first else { throw ClipboardError.unavailable }
            self.enabled = enabled
            retentionDays = retention
        } catch {
            throw ClipboardError.unavailable
        }
        if !enabled { _ = try clear() }
        try prune(at: ClipboardClock.nowMs())
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
            PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS clipboard_settings (
                id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0,
                retention_days INTEGER NOT NULL DEFAULT 30 CHECK(retention_days IN (1,7,30,90)));
            INSERT OR IGNORE INTO clipboard_settings(id) VALUES(1);
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE,
                captured_at_ms INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)));
            CREATE INDEX IF NOT EXISTS clipboard_entries_recency ON clipboard_entries(captured_at_ms DESC, id DESC);
            """)
        // Text-only v1 tables move to the rich schema in one transaction, keeping IDs, pins, consent,
        // timestamps and the AUTOINCREMENT high water.
        let columns = try db.query("PRAGMA table_info(clipboard_entries)") { $0.string("name") ?? "" }
        if !columns.contains("kind") {
            do {
                try db.execute("""
                    BEGIN IMMEDIATE;
                    CREATE TEMP TABLE clipboard_old_sequence AS SELECT seq FROM sqlite_sequence WHERE name='clipboard_entries';
                    DROP INDEX IF EXISTS clipboard_entries_recency;
                    ALTER TABLE clipboard_entries RENAME TO clipboard_entries_v1;
                    CREATE TABLE clipboard_entries (
                        id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL,
                        captured_at_ms INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
                        kind TEXT NOT NULL DEFAULT 'text' CHECK(kind IN ('text','image','files')),
                        payload BLOB NOT NULL DEFAULT X'', mime_type TEXT, byte_size INTEGER NOT NULL DEFAULT 0,
                        width INTEGER, height INTEGER, file_count INTEGER NOT NULL DEFAULT 0);
                    INSERT INTO clipboard_entries(id,text,captured_at_ms,pinned,byte_size)
                        SELECT id,text,captured_at_ms,pinned,length(CAST(text AS BLOB)) FROM clipboard_entries_v1;
                    UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM clipboard_old_sequence),0)) WHERE name='clipboard_entries';
                    INSERT INTO sqlite_sequence(name,seq) SELECT 'clipboard_entries',seq FROM clipboard_old_sequence WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='clipboard_entries');
                    DROP TABLE clipboard_entries_v1;
                    DROP TABLE clipboard_old_sequence;
                    CREATE INDEX clipboard_entries_recency ON clipboard_entries(captured_at_ms DESC,id DESC);
                    PRAGMA user_version=2;
                    COMMIT;
                    """)
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
        // The v1 unique text index duplicated content; compact once and enable incremental vacuum.
        if try db.scalar("PRAGMA auto_vacuum") != 2 {
            try db.execute("PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")
        }
        // Bound the database high water even after repeated deletion.
        let pageSize = try db.scalar("PRAGMA page_size") ?? 4096
        let maxPages = 192 * 1024 * 1024 / max(pageSize, 512)
        try db.execute("PRAGMA max_page_count=\(maxPages)")
        guard let actual = try db.scalar("PRAGMA max_page_count"), actual <= maxPages else { throw ClipboardError.unavailable }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS clipboard_preferences (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS clipboard_entries_display ON clipboard_entries(pinned DESC,captured_at_ms DESC,id DESC);
            CREATE INDEX IF NOT EXISTS clipboard_entries_kind_display ON clipboard_entries(kind,pinned DESC,captured_at_ms DESC,id DESC);
            """)
    }

    // MARK: Writes

    /// Runs `body` in a transaction. Storage failures are remembered for Settings until a write succeeds;
    /// `ClipboardError`s thrown by `body` are rule violations and leave the error state alone.
    private func write<T>(_ body: (SQLiteDatabase) throws -> T) throws(ClipboardError) -> T {
        lock.lock(); defer { lock.unlock() }
        guard let database else {
            persistenceError = ClipboardError.storage.message
            throw .storage
        }
        do {
            let value = try database.transaction { try body(database) }
            // Deletion already committed; optional compaction must not report failure.
            try? database.execute("PRAGMA incremental_vacuum(256)")
            persistenceError = nil
            return value
        } catch let error as ClipboardError {
            throw error
        } catch {
            persistenceError = ClipboardError.storage.message
            throw .storage
        }
    }

    private func cutoff(at time: Int64, days: Int? = nil) -> Int64 {
        time - Int64(days ?? retentionDays) * ClipboardLimits.dayMs
    }

    func prune(at time: Int64) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        let prior = persistenceError
        let cutoff = cutoff(at: time)
        _ = try write { db in try db.run("DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?", [cutoff]) }
        persistenceError = prior
    }

    /// Records text the way capture does, including the credential filter. Used by tests and dictation.
    public func record(text: String, at time: Int64 = ClipboardClock.nowMs()) throws(ClipboardError) {
        guard isEnabled, ClipboardPolicy.shouldCapture(text) else { return }
        try record(.text(text), at: time)
    }

    func record(_ payload: ClipboardPayload, at time: Int64 = ClipboardClock.nowMs()) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, preferences.isCapturing(at: time) else { return }
        let stored = try StoredPayload(payload)
        let size = stored.text.utf8.count + stored.bytes.count
        let cutoff = cutoff(at: time)
        // SQLite binds empty Data as NULL, so empty payloads use a literal.
        let payloadSQL = stored.bytes.isEmpty ? "X''" : "?"
        let payloadBinding: [any SQLiteBindable] = stored.bytes.isEmpty ? [] : [stored.bytes]
        let saved = try write { db -> Bool in
            try db.run("DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?", [cutoff])
            let match: [any SQLiteBindable] = [stored.kind.rawValue, stored.text]
            let existing = try db.scalar("SELECT id FROM clipboard_entries WHERE kind=? AND text=? AND payload=\(payloadSQL)",
                                         match + payloadBinding)
            if let existing {
                try db.run("UPDATE clipboard_entries SET captured_at_ms=? WHERE id=?", [time, existing])
                return true
            }
            // Check pins first so an entry that cannot be accepted never removes unrelated history.
            let pins = try db.query("SELECT COUNT(*) AS count, COALESCE(SUM(byte_size),0) AS bytes FROM clipboard_entries WHERE pinned=1") {
                (Int($0.int("count")), Int($0.int("bytes")))
            }[0]
            if pins.0 >= ClipboardLimits.capacity || pins.1 + size > ClipboardLimits.maxStoredBytes { return false }
            while true {
                let totals = try db.query("SELECT COUNT(*) AS count, COALESCE(SUM(byte_size),0) AS bytes FROM clipboard_entries") {
                    (Int($0.int("count")), Int($0.int("bytes")))
                }[0]
                if totals.0 < ClipboardLimits.capacity && totals.1 + size <= ClipboardLimits.maxStoredBytes { break }
                let removed = try db.run("DELETE FROM clipboard_entries WHERE id=(SELECT id FROM clipboard_entries WHERE pinned=0 ORDER BY captured_at_ms,id LIMIT 1)")
                if removed == 0 { return false }
            }
            let head: [any SQLiteBindable] = [stored.text, time, stored.kind.rawValue]
            let tail: [any SQLiteBindable] = [stored.mimeType, size, stored.width, stored.height, stored.fileCount]
            try db.run("""
                INSERT INTO clipboard_entries(text,captured_at_ms,kind,payload,mime_type,byte_size,width,height,file_count)
                VALUES(?,?,?,\(payloadSQL),?,?,?,?,?)
                """, head + payloadBinding + tail)
            return true
        }
        captureNotice = saved ? nil : ClipboardError.pinnedStorageFull.message
    }

    /// Stores a capture only if nothing changed since the monitor read `generation`.
    func recordCapture(_ result: Result<ClipboardPayload?, ClipboardError>, generation expected: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, preferences.isCapturing(at: ClipboardClock.nowMs()), _generation == expected else { return }
        switch result {
        case .success(let payload?):
            do { try record(payload) } catch { captureNotice = error.message }
        case .success(nil): captureNotice = nil
        case .failure(let error): captureNotice = error.message
        }
    }

    func updatePreferences(_ update: (inout ClipboardPreferences) -> Void) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        var next = preferences
        update(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(next), let value = String(data: data, encoding: .utf8) else { throw .storage }
        _ = try write { db in
            try db.run("INSERT INTO clipboard_preferences(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [value])
        }
        let privacyChanged = preferences.pausedUntilMs != next.pausedUntilMs || preferences.excludedApplications != next.excludedApplications
        preferences = next
        // Return-action edits must not interrupt capture. Privacy edits establish a fresh baseline.
        if privacyChanged { _generation &+= 1 }
        captureNotice = nil
    }

    @discardableResult
    public func setEnabled(_ value: Bool) throws(ClipboardError) -> Bool {
        lock.lock(); defer { lock.unlock() }
        captureNotice = nil
        _generation &+= 1
        // Stop capture even when the disk write below fails.
        if !value { enabled = false }
        do {
            try write { db in
                try db.run("UPDATE clipboard_settings SET enabled=? WHERE id=1", [value])
                if !value { try db.run("DELETE FROM clipboard_entries") }
            }
        } catch {
            if !value {
                let message = "History capture stopped, but saved entries could not be deleted. Retry disabling before restarting Prism."
                persistenceError = message
                throw ClipboardError(message)
            }
            throw error
        }
        enabled = value
        return value
    }

    @discardableResult
    public func clear() throws(ClipboardError) -> Int {
        lock.lock(); defer { lock.unlock() }
        captureNotice = nil
        _generation &+= 1
        return try write { db in try db.run("DELETE FROM clipboard_entries") }
    }

    public func delete(id: Int64) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        captureNotice = nil
        _generation &+= 1
        try write { db in _ = try db.run("DELETE FROM clipboard_entries WHERE id=?", [id]) }
    }

    public func setPinned(id: Int64, pinned: Bool) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw .disabled }
        try prune(at: ClipboardClock.nowMs())
        try write { db in
            if try db.run("UPDATE clipboard_entries SET pinned=? WHERE id=?", [pinned, id]) == 0 { throw ClipboardError.missingEntry }
        }
    }

    public func setRetention(days: Int) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        guard ClipboardLimits.retentionChoices.contains(days) else { throw ClipboardError("Choose a supported clipboard retention period.") }
        let cutoff = cutoff(at: ClipboardClock.nowMs(), days: days)
        try write { db in
            try db.run("UPDATE clipboard_settings SET retention_days=? WHERE id=1", [days])
            try db.run("DELETE FROM clipboard_entries WHERE pinned=0 AND captured_at_ms < ?", [cutoff])
        }
        retentionDays = days
    }

    public func setPrimaryAction(_ action: ClipboardPrimaryAction) throws(ClipboardError) {
        try updatePreferences { $0.primaryAction = action }
    }

    /// Pauses capture for 5, 15 or 60 minutes, or resumes with 0.
    public func pauseCapture(minutes: Int) throws(ClipboardError) {
        guard ClipboardLimits.pauseChoices.contains(minutes) else { throw ClipboardError("Choose a supported pause duration.") }
        try updatePreferences { $0.pausedUntilMs = minutes == 0 ? 0 : ClipboardClock.nowMs() + Int64(minutes) * 60_000 }
    }

    public func addExcludedApplication(id: String, name: String) throws(ClipboardError) {
        lock.lock(); defer { lock.unlock() }
        guard preferences.excludedApplications.count < ClipboardLimits.maxExcludedApplications else {
            throw ClipboardError("Up to 128 applications can be excluded.")
        }
        try updatePreferences { preferences in
            if !preferences.excludedApplications.contains(where: { $0.id == id }) {
                preferences.excludedApplications.append(ExcludedApplication(id: id, name: name))
            }
        }
    }

    public func removeExcludedApplication(id: String) throws(ClipboardError) {
        try updatePreferences { $0.excludedApplications.removeAll { $0.id == id } }
    }

    // MARK: Reads

    public var isEnabled: Bool { lock.withLock { enabled } }

    /// What the monitor needs to decide whether to look at the pasteboard.
    func captureState(at time: Int64 = ClipboardClock.nowMs()) -> (generation: UInt64, preferences: ClipboardPreferences)? {
        lock.withLock { enabled && preferences.isCapturing(at: time) ? (_generation, preferences) : nil }
    }

    func setCaptureNotice(_ notice: String?) {
        lock.withLock { captureNotice = notice }
    }

    var hasPersistenceError: Bool { lock.withLock { persistenceError != nil } }

    public func settings() -> ClipboardSettingsState {
        lock.lock(); defer { lock.unlock() }
        let counts = try? database?.query("SELECT COUNT(*) AS count, COALESCE(SUM(pinned),0) AS pins FROM clipboard_entries") {
            (Int($0.int("count")), Int($0.int("pins")))
        }.first
        return ClipboardSettingsState(
            enabled: enabled,
            retentionDays: retentionDays == 0 ? 30 : retentionDays,
            entryCount: counts?.0 ?? 0,
            pinnedCount: counts?.1 ?? 0,
            capacity: ClipboardLimits.capacity,
            persistenceError: persistenceError ?? (counts == nil ? ClipboardError.unavailable.message : nil),
            captureNotice: captureNotice,
            preferences: preferences
        )
    }

    /// Pinned entries first, then newest. Read-only: expired rows are filtered here and removed by the
    /// monitor. Matching is a Unicode case-insensitive substring search over stored labels, and rows are
    /// scanned incrementally so large texts are never all in memory at once.
    public func search(_ query: String, limit: Int, kind: ClipboardKind? = nil, at time: Int64 = ClipboardClock.nowMs()) throws(ClipboardError) -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw .disabled }
        guard let database else { throw .storage }
        let limit = min(limit, ClipboardLimits.capacity)
        guard limit > 0 else { return [] }
        let kindClause = kind == nil ? "AND ?2 IS NULL" : "AND kind=?2"
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [ClipboardEntry] = []
        struct Enough: Error {}
        do {
            _ = try database.query(
                "SELECT \(Self.entryColumns) FROM clipboard_entries WHERE (pinned=1 OR captured_at_ms>=?1) \(kindClause) ORDER BY pinned DESC,captured_at_ms DESC,id DESC",
                [cutoff(at: time), kind?.rawValue]
            ) { row in
                let entry = try Self.entry(row)
                if needle.isEmpty || entry.text.lowercased().contains(needle) {
                    matches.append(entry)
                    if matches.count == limit { throw Enough() }
                }
            }
        } catch is Enough {
        } catch {
            throw .storage
        }
        return matches.map { entry in
            var entry = entry
            entry.text = ClipboardPolicy.displayPreview(entry.text)
            return entry
        }
    }

    public func entry(id: Int64) throws(ClipboardError) -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let database else { throw .storage }
        do {
            return try database.query("SELECT \(Self.entryColumns) FROM clipboard_entries WHERE id=?", [id], row: Self.entry).first
        } catch {
            throw .storage
        }
    }

    /// The full original text for the preview pane and snippets. Images and files have no text.
    public func text(id: Int64) throws(ClipboardError) -> String {
        guard case .text(let text) = try payload(id: id) else {
            throw ClipboardError("Only text clipboard entries can be saved as snippets.")
        }
        return text
    }

    public func payload(id: Int64) throws(ClipboardError) -> ClipboardPayload {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw .disabled }
        try prune(at: ClipboardClock.nowMs())
        guard let entry = try entry(id: id), let database else { throw .missingEntry }
        if entry.kind == .text { return .text(entry.text) }
        let bytes: Data
        do {
            bytes = try database.query("SELECT payload FROM clipboard_entries WHERE id=?", [id]) { $0.data("payload") ?? Data() }.first ?? Data()
        } catch {
            throw .storage
        }
        switch entry.kind {
        case .image:
            guard let mimeType = entry.mimeType, let width = entry.width, let height = entry.height else {
                throw ClipboardError("Invalid image metadata.")
            }
            return .image(bytes, mimeType: mimeType, width: width, height: height)
        case .files:
            guard let urls = try? JSONDecoder().decode([String].self, from: bytes) else { throw ClipboardError("Invalid file references.") }
            _ = try ClipboardPolicy.parseFileReferences(urls)
            return .files(urls)
        case .text:
            return .text(entry.text)
        }
    }

    /// Loads and validates an entry for copy or paste. Validation (file existence checks) runs without the
    /// store lock, then consent, generation and the entry's existence are checked again.
    func prepareForAction(
        id: Int64,
        prepare: (ClipboardPayload) throws(ClipboardError) -> ClipboardPayload = ClipboardPolicy.prepare
    ) throws(ClipboardError) -> ClipboardPayload {
        lock.lock()
        let loaded: (ClipboardPayload, UInt64)
        do {
            loaded = (try payload(id: id), _generation)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let (payload, generation) = loaded
        let prepared = try prepare(payload)
        lock.lock(); defer { lock.unlock() }
        guard enabled, _generation == generation else { throw .changed }
        // Retention or capacity eviction can remove an entry without changing the generation.
        try prune(at: ClipboardClock.nowMs())
        guard try entry(id: id) != nil else { throw .missingEntry }
        return prepared
    }

    private static func entry(_ row: SQLiteRow) throws -> ClipboardEntry {
        guard let kind = ClipboardKind(rawValue: row.string("kind") ?? "") else { throw ClipboardError.storage }
        return ClipboardEntry(
            id: row.int("id"),
            text: row.string("text") ?? "",
            capturedAtMs: row.int("captured_at_ms"),
            pinned: row.bool("pinned"),
            kind: kind,
            mimeType: row.string("mime_type"),
            byteSize: Int(row.int("byte_size")),
            width: row.optionalInt("width").map(Int.init),
            height: row.optionalInt("height").map(Int.init),
            fileCount: Int(row.int("file_count"))
        )
    }

    #if DEBUG
    /// Direct SQL for tests that simulate eviction or corrupted rows.
    func testExecute(_ sql: String, _ bindings: [any SQLiteBindable] = []) throws {
        try database?.run(sql, bindings)
    }

    func testScalar(_ sql: String) throws -> Int64? {
        try database?.scalar(sql)
    }

    var testRetentionDays: Int { lock.withLock { retentionDays } }
    var testPreferences: ClipboardPreferences { lock.withLock { preferences } }
    #endif
}

/// The row values for one payload. Ported from `ClipboardPayload::stored`.
struct StoredPayload {
    var kind: ClipboardKind
    var text: String
    var bytes: Data
    var mimeType: String?
    var width: Int?
    var height: Int?
    var fileCount: Int

    init(_ payload: ClipboardPayload) throws(ClipboardError) {
        switch payload {
        case .text(let text) where ClipboardPolicy.shouldCapture(text):
            self.init(kind: .text, text: text, bytes: Data(), fileCount: 0)
        case .image(let bytes, let mimeType, let width, let height)
            where !bytes.isEmpty && bytes.count <= ClipboardLimits.maxImageBytes
            && ClipboardPolicy.validDimensions(width: width, height: height)
            && ["image/png", "image/jpeg", "image/webp"].contains(mimeType):
            let format = mimeType.replacingOccurrences(of: "image/", with: "").uppercased()
            self.init(kind: .image, text: "\(format) image · \(width) × \(height)", bytes: bytes,
                      mimeType: mimeType, width: width, height: height, fileCount: 0)
        case .files(let urls):
            let paths = try ClipboardPolicy.parseFileReferences(urls)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(urls) else { throw ClipboardError("Invalid file references.") }
            guard bytes.count <= ClipboardLimits.maxReferenceBytes else { throw .referenceLimit }
            self.init(kind: .files, text: paths.joined(separator: "\n"), bytes: bytes, fileCount: urls.count)
        default:
            throw ClipboardError("Clipboard content exceeds supported limits.")
        }
    }

    private init(kind: ClipboardKind, text: String, bytes: Data, mimeType: String? = nil, width: Int? = nil, height: Int? = nil, fileCount: Int) {
        self.kind = kind
        self.text = text
        self.bytes = bytes
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.fileCount = fileCount
    }
}
