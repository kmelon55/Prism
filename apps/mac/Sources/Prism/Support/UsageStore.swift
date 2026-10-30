import Foundation
import PrismCore
import PrismKit

/// Successful runs of palette rows, for frecency ranking and the empty query's Recent section.
///
/// Applications keep the Tauri table (`application_usage` in `application-index-v1.sqlite3`, keyed by the hex-encoded
/// bundle path) so launch history carries over from the Tauri app. Other rows use `command-usage-v1.json`.
/// Application usage is matched by resolved path: Tauri recorded Safari as `/Applications/Safari.app`, while the
/// native catalog finds it at its Cryptex location.
@MainActor
final class UsageStore {
    struct Usage: Codable, Equatable {
        var count: Int
        /// Unix seconds.
        var lastUsedAt: Int64
    }

    private struct File: Codable {
        var version = 1
        var commands: [String: Usage]
    }

    static let applicationPrefix = "app:"

    private(set) var usage: [String: Usage] = [:]
    private let commandStore: JSONFileStore<File>
    private let applicationDatabaseURL: URL
    private var applicationDatabase: SQLiteDatabase?
    private var resolvedKeys: [String: String] = [:]

    init(paths: AppPaths) {
        commandStore = JSONFileStore(url: paths.file("command-usage-v1.json"))
        applicationDatabaseURL = paths.file("application-index-v1.sqlite3")
        usage = commandStore.load()?.commands ?? [:]
        if let database = openApplicationDatabase(),
           let rows = try? database.query("SELECT application_id, launch_count, last_launched_at FROM application_usage", row: {
               ($0.string("application_id") ?? "", Int($0.int("launch_count")), $0.optionalInt("last_launched_at") ?? 0)
           }) {
            for (hex, count, last) in rows {
                guard let path = Frecency.path(fromApplicationID: hex) else { continue }
                let key = key(for: Self.applicationPrefix + path)
                // A resolved path can have rows under both its link and its target; add them up.
                let previous = usage[key]
                usage[key] = Usage(count: count + (previous?.count ?? 0), lastUsedAt: max(last, previous?.lastUsedAt ?? 0))
            }
        }
    }

    func record(_ id: String, now: Date = Date()) {
        let timestamp = Int64(now.timeIntervalSince1970)
        let key = key(for: id)
        var entry = usage[key] ?? Usage(count: 0, lastUsedAt: timestamp)
        entry.count += 1
        entry.lastUsedAt = timestamp
        usage[key] = entry
        if id.hasPrefix(Self.applicationPrefix) {
            let path = String(id.dropFirst(Self.applicationPrefix.count))
            _ = try? openApplicationDatabase()?.run("""
                INSERT INTO application_usage (application_id, launch_count, last_launched_at) VALUES (?, 1, ?)
                ON CONFLICT(application_id) DO UPDATE SET launch_count = launch_count + 1, last_launched_at = excluded.last_launched_at
                """, [Frecency.applicationID(path: path), timestamp])
        } else {
            try? commandStore.save(File(commands: usage.filter { !$0.key.hasPrefix(Self.applicationPrefix) }))
        }
    }

    func boost(for id: String, now: Date = Date()) -> Double {
        guard let entry = usage[key(for: id)] else { return 0 }
        return Frecency.bonus(count: entry.count, lastUsedAt: entry.lastUsedAt, now: Int64(now.timeIntervalSince1970))
    }

    private func key(for id: String) -> String {
        guard id.hasPrefix(Self.applicationPrefix) else { return id }
        if let key = resolvedKeys[id] { return key }
        let path = String(id.dropFirst(Self.applicationPrefix.count))
        let key = Self.applicationPrefix + URL(filePath: path).resolvingSymlinksInPath().path
        resolvedKeys[id] = key
        return key
    }

    private func openApplicationDatabase() -> SQLiteDatabase? {
        if let applicationDatabase { return applicationDatabase }
        guard let database = try? SQLiteDatabase(url: applicationDatabaseURL) else { return nil }
        // The Tauri schema; `applications` is its catalog cache, created so the file stays valid for it.
        try? database.execute("""
            PRAGMA busy_timeout = 5000;
            CREATE TABLE IF NOT EXISTS applications (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE, platform TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS application_usage (application_id TEXT PRIMARY KEY, launch_count INTEGER NOT NULL DEFAULT 0, last_launched_at INTEGER);
            """)
        applicationDatabase = database
        return database
    }
}
