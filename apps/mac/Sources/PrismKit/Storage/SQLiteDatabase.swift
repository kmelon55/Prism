import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLiteBindable {
    var sqliteValue: SQLiteValue { get }
}

extension Int: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int64: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self) } }
extension Double: SQLiteBindable { public var sqliteValue: SQLiteValue { .real(self) } }
extension Bool: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) } }
extension String: SQLiteBindable { public var sqliteValue: SQLiteValue { .text(self) } }
extension Data: SQLiteBindable { public var sqliteValue: SQLiteValue { .blob(self) } }
extension SQLiteValue: SQLiteBindable { public var sqliteValue: SQLiteValue { self } }
extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self?.sqliteValue ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// One result row. Columns can be read by index or by name.
public struct SQLiteRow {
    fileprivate let statement: OpaquePointer
    fileprivate let columns: [String: Int32]

    public func int(_ column: String) -> Int64 { sqlite3_column_int64(statement, index(column)) }
    public func double(_ column: String) -> Double { sqlite3_column_double(statement, index(column)) }
    public func bool(_ column: String) -> Bool { int(column) != 0 }
    public func isNull(_ column: String) -> Bool { sqlite3_column_type(statement, index(column)) == SQLITE_NULL }

    public func string(_ column: String) -> String? {
        let i = index(column)
        guard let text = sqlite3_column_text(statement, i) else { return nil }
        return String(cString: text)
    }

    public func data(_ column: String) -> Data? {
        let i = index(column)
        guard let bytes = sqlite3_column_blob(statement, i) else { return sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
    }

    public func optionalInt(_ column: String) -> Int64? { isNull(column) ? nil : int(column) }

    private func index(_ column: String) -> Int32 {
        guard let index = columns[column] else { preconditionFailure("No column named \(column)") }
        return index
    }
}

/// A small wrapper around the system SQLite library. Opened in serialized mode, so it is safe to share
/// between threads; use `transaction` when several statements must apply together.
public final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    /// `journalMode` must match what the Tauri app used for the same file (`nil` leaves the file's mode alone),
    /// so opening an existing database never converts it.
    public convenience init(url: URL, readOnly: Bool = false, journalMode: String? = "WAL") throws {
        if !readOnly {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try self.init(path: url.path, readOnly: readOnly, journalMode: journalMode)
    }

    private init(path: String, readOnly: Bool, journalMode: String? = "WAL") throws {
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close(handle)
            throw SQLiteError(code: status, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 3000)
        if !readOnly {
            try execute("PRAGMA foreign_keys = ON;")
            if let journalMode { try execute("PRAGMA journal_mode = \(journalMode);") }
        }
    }

    /// An in-memory database for tests.
    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:", readOnly: false)
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? currentMessage
            sqlite3_free(error)
            throw SQLiteError(code: status, message: message)
        }
    }

    /// Runs a statement that returns no rows. Returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ bindings: [any SQLiteBindable] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw SQLiteError(code: status, message: currentMessage) }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ bindings: [any SQLiteBindable] = [], row transform: (SQLiteRow) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            columns[String(cString: sqlite3_column_name(statement, index))] = index
        }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteError(code: status, message: currentMessage) }
            rows.append(try transform(SQLiteRow(statement: statement, columns: columns)))
        }
        return rows
    }

    /// The first column of the first row as an integer, or `nil` for no rows or NULL.
    public func scalar(_ sql: String, _ bindings: [any SQLiteBindable] = []) throws -> Int64? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw SQLiteError(code: status, message: currentMessage) }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside `BEGIN IMMEDIATE`. Rolls back when it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// `PRAGMA user_version`, for simple schema migrations.
    public var userVersion: Int {
        get { Int((try? scalar("PRAGMA user_version")) ?? 0) }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    public func tableExists(_ name: String) throws -> Bool {
        try scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) ?? 0 > 0
    }

    private var currentMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ bindings: [any SQLiteBindable]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw SQLiteError(code: status, message: currentMessage) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch binding.sqliteValue {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            // Empty Data has no base address, which SQLite would store as NULL instead of an empty blob.
            case .blob(let value) where value.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let value): value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            if result != SQLITE_OK {
                sqlite3_finalize(statement)
                throw SQLiteError(code: result, message: currentMessage)
            }
        }
        return statement
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
