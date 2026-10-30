import Foundation
import PrismKit

/// `raycast-import-recovery-v1.json`, the durable record written before a reviewed import changes anything
/// (`migration_journal.rs`). Same JSON as the Tauri app, so an interrupted import from either app can be undone.
struct MigrationJournal: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case pending, applied, failed, undone }
        var item: ImportItem
        var before: String?
        var state: State
        var error: String?
    }

    var version = 1
    var id: String
    var changes: [Change]

    var applied: Int { changes.filter { $0.state == .applied }.count }
    var failed: Int { changes.filter { $0.state == .failed }.count }
    var undone: Int { changes.filter { $0.state == .undone }.count }
    var isInterrupted: Bool { changes.contains { $0.state == .pending } }
    var canUndo: Bool { changes.contains { $0.state != .undone && $0.state != .failed } }
}

struct MigrationJournalStore: Sendable {
    static let fileName = "raycast-import-recovery-v1.json"
    static let limit = 20 * 1024 * 1024
    static let invalid = "Invalid import recovery record."
    static let changed = "Import recovery changed. Review it again."

    let url: URL

    /// A malformed record is reported, never silently discarded or replaced.
    func read() throws -> MigrationJournal? {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
        let unreadable = "Could not read import recovery record."
        let data = try BackupFiles.read(url, limit: Self.limit, readError: unreadable, invalidError: unreadable, tooLarge: unreadable)
        guard let object = try? JSONSerialization.jsonObject(with: data), Self.isValid(object),
              let journal = try? JSONDecoder().decode(MigrationJournal.self, from: data)
        else { throw BackupError(Self.invalid) }
        return journal
    }

    /// `create` requires that no record exists; otherwise the record on disk must have the same ID.
    func write(_ journal: MigrationJournal, create: Bool) throws {
        let data = try JSONEncoder().encode(journal)
        guard let object = try? JSONSerialization.jsonObject(with: data), Self.isValid(object) else { throw BackupError(Self.invalid) }
        let existing = try read()
        if create ? existing != nil : existing?.id != journal.id { throw BackupError(Self.changed) }
        guard data.count <= Self.limit else { throw BackupError("Import recovery is too large.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BackupFiles.write(data, to: url, limit: Self.limit, writeError: "Could not preserve import recovery.")
    }

    func clear(id: String) throws {
        guard try read()?.id == id else { throw BackupError(Self.changed) }
        do { try FileManager.default.removeItem(at: url) } catch { throw BackupError("Could not clear import recovery.") }
    }

    /// The structural checks of `migration_journal.rs::validate`.
    static func isValid(_ value: Any) -> Bool {
        guard let root = value as? [String: Any], JSONValue.number(root["version"]) == 1,
              let id = root["id"] as? String, id.utf8.count == 36, id.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              let changes = root["changes"] as? [Any], changes.count <= RaycastPlan.maxItems
        else { return false }
        func string(_ value: Any?, _ max: Int) -> Bool {
            guard let text = value as? String else { return false }
            return text.utf8.count <= max && !text.contains("\0")
        }
        func optional(_ value: Any?, _ max: Int) -> Bool { value == nil || value is NSNull || string(value, max) }
        for raw in changes {
            guard let change = raw as? [String: Any], let item = change["item"] as? [String: Any],
                  ["pending", "applied", "failed", "undone"].contains(change["state"] as? String ?? ""),
                  string(item["id"], 100), string(item["title"], 4096), string(item["value"], 128 * 1024),
                  optional(change["before"], 1024), optional(change["error"], 8192)
            else { return false }
            switch item["category"] as? String ?? "" {
            case "hotkeys", "aliases":
                guard string(item["commandId"], 512) else { return false }
            case "snippets", "quicklinks":
                guard let entry = item["entry"] as? [String: Any], string(entry["id"], 512), string(entry["title"], 300),
                      string(entry["value"], 128 * 1024), ["snippet", "link"].contains(entry["kind"] as? String ?? ""),
                      optional(entry["keyword"], 48)
                else { return false }
            default:
                return false
            }
        }
        return true
    }
}

/// The stores an import writes to.
@MainActor
protocol RaycastImportTargets: AnyObject {
    /// Accelerators by command ID, plus the launcher under `launcher`.
    func hotkeys() throws -> [String: String]
    /// `value` is a hotkey in any accepted spelling; `nil` removes the command's hotkey.
    func setHotkey(_ value: String?, for commandID: String) throws
    func aliases() throws -> [String: String]
    func setAliases(_ aliases: [String: String]) throws
    func disabled() -> Set<String>
    func libraryEntries() throws -> [ImportEntry]
    func favoriteIDs() throws -> Set<String>
    func saveEntry(_ entry: ImportEntry) throws
    func deleteEntry(id: String) throws
}

/// Applies selected review rows one by one and undoes them, ported from `raycastApply.ts`. Every row rechecks
/// its conflicts when it is applied. This is recoverable, not one transaction: each row's result is journaled.
@MainActor
final class RaycastImporter {
    static let busy = "An import is already running."

    let journal: MigrationJournalStore
    let targets: any RaycastImportTargets
    private var running = false

    init(journal: MigrationJournalStore, targets: any RaycastImportTargets) {
        self.journal = journal
        self.targets = targets
    }

    func apply(_ items: [ImportItem], id: String = UUID().uuidString.lowercased(),
               progress: (MigrationJournal) -> Void = { _ in }) throws -> MigrationJournal {
        try exclusive {
            var record = MigrationJournal(id: id, changes: items.map { .init(item: $0, before: $0.before, state: .pending) })
            // A recovery copy is a prerequisite: if it cannot be written, nothing changes.
            try journal.write(record, create: true)
            progress(record)
            for index in record.changes.indices {
                do {
                    try applyChange(record.changes[index])
                    record.changes[index].state = .applied
                } catch {
                    record.changes[index].state = .failed
                    record.changes[index].error = Self.message(error)
                }
                // Stop if progress cannot be recorded. Pending rows can still be undone after a crash.
                try journal.write(record, create: false)
                progress(record)
            }
            return record
        }
    }

    /// Restores only values that still match the import, keeping anything changed since.
    func undo(_ record: MigrationJournal, progress: (MigrationJournal) -> Void = { _ in }) throws -> MigrationJournal {
        try exclusive {
            var record = record
            for index in record.changes.indices.reversed() {
                let change = record.changes[index]
                if change.state == .undone || change.state == .failed { continue }
                do {
                    try undoChange(change)
                    record.changes[index].state = .undone
                    record.changes[index].error = nil
                } catch {
                    record.changes[index].error = Self.message(error)
                }
                try journal.write(record, create: false)
                progress(record)
            }
            return record
        }
    }

    private func applyChange(_ change: MigrationJournal.Change) throws {
        let item = change.item
        if let commandID = item.commandId, targets.disabled().contains(commandID) { throw BackupError("Command is disabled in Prism") }
        switch (item.category, item.commandId, item.entry) {
        case (.hotkeys, let commandID?, _):
            let current = try targets.hotkeys()
            if current[commandID] != change.before
                || current.contains(where: { $0.key != commandID && RaycastPlan.sameHotkey($0.value, item.value) }) {
                throw BackupError("Shortcut changed or is already in use")
            }
            try targets.setHotkey(item.value, for: commandID)
        case (.aliases, let commandID?, _):
            let current = try targets.aliases()
            let key = SafePreferencesMerge.aliasKey(item.value)
            if current[commandID] != change.before
                || current.contains(where: { $0.key != commandID && SafePreferencesMerge.aliasKey($0.value) == key }) {
                throw BackupError("Alias changed or is already in use")
            }
            var next = current
            next[commandID] = item.value
            try targets.setAliases(next)
        case (_, _, let entry?):
            let existing = try targets.libraryEntries()
            if existing.contains(where: { $0.id == entry.id || $0.kind == entry.kind
                && ($0.title == entry.title || $0.value == entry.value || (entry.keyword != nil && $0.keyword == entry.keyword)) }) {
                throw BackupError("Existing item kept")
            }
            try targets.saveEntry(entry)
        default:
            throw BackupError("Invalid import item")
        }
    }

    private func undoChange(_ change: MigrationJournal.Change) throws {
        let item = change.item
        let kept = BackupError("Changed after import; kept")
        switch (item.category, item.commandId, item.entry) {
        case (.hotkeys, let commandID?, _):
            let current = try targets.hotkeys()[commandID]
            if current == change.before { return }
            guard let current, RaycastPlan.sameHotkey(current, item.value) else { throw kept }
            if commandID == RaycastPlan.launcherID && change.before == nil { throw BackupError("Original launcher shortcut is missing") }
            try targets.setHotkey(change.before, for: commandID)
        case (.aliases, let commandID?, _):
            let current = try targets.aliases()
            if current[commandID] == change.before { return }
            guard current[commandID] == item.value else { throw kept }
            var next = current
            next[commandID] = change.before
            try targets.setAliases(next)
        case (_, _, let entry?):
            guard let existing = try targets.libraryEntries().first(where: { $0.id == entry.id }) else { return }
            let same = existing.kind == entry.kind && existing.title == entry.title && existing.value == entry.value
                && (existing.keyword ?? "") == (entry.keyword ?? "")
            let favorites = try targets.favoriteIDs()
            if !same || favorites.contains("library:\(entry.id)") { throw kept }
            try targets.deleteEntry(id: entry.id)
        default:
            return
        }
    }

    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        guard !running else { throw BackupError(Self.busy) }
        running = true
        defer { running = false }
        return try body()
    }

    static func message(_ error: Error) -> String {
        if let error = error as? BackupError { return error.message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
