import Foundation

/// Serial note autosave, ported from `noteAutosave.ts`. Every edit starts a save; writes never overlap, and
/// edits made while a write is in flight coalesce into the next write, so an older version never lands last.
@MainActor
final class NoteAutosave {
    enum Status: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    private(set) var latest: LibraryEntry
    private var saved: LibraryEntry
    private var running: Task<Bool, Never>?
    private let persist: (LibraryEntry) async throws -> Void
    private let onStatus: (Status) -> Void

    init(initial: LibraryEntry, persist: @escaping (LibraryEntry) async throws -> Void, onStatus: @escaping (Status) -> Void) {
        latest = initial
        saved = initial
        self.persist = persist
        self.onStatus = onStatus
    }

    var hasUnsavedChanges: Bool { latest != saved }

    func update(_ note: LibraryEntry) {
        latest = note
        flush()
    }

    /// Starts saving the latest edit unless a save is running, and returns the task that finishes when the
    /// latest edit is stored (true) or a write failed (false).
    @discardableResult
    func flush() -> Task<Bool, Never> {
        if let running { return running }
        if latest == saved {
            onStatus(.saved)
            return Task { true }
        }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.running = nil }
            onStatus(.saving)
            while latest != saved {
                let snapshot = latest
                do {
                    try await persist(snapshot)
                    saved = snapshot
                } catch {
                    onStatus(.failed(error.localizedDescription))
                    return false
                }
            }
            onStatus(.saved)
            return true
        }
        running = task
        return task
    }

    /// Waits until the latest edit is stored. False when a write failed.
    func settle() async -> Bool {
        while true {
            let ok = await flush().value
            if !ok { return false }
            if latest == saved { return true }
        }
    }
}
