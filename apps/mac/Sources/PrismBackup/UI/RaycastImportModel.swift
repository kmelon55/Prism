import AppKit
import Foundation
import Observation
import PrismCore
import PrismKit
import UniformTypeIdentifiers

/// State and actions of the Raycast import, ported from `RaycastImport.tsx`.
@MainActor
@Observable
final class RaycastImportModel {
    static let reviewLifetime: TimeInterval = 10 * 60

    private(set) var fileURL: URL?
    private(set) var needsPassword = false
    var password = ""
    private(set) var rows: [ImportItem]?
    var selected: Set<String> = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var journal: MigrationJournal?
    private(set) var journalLoaded = false

    @ObservationIgnored private var reviewedAt = Date.distantPast
    @ObservationIgnored let importer: RaycastImporter
    @ObservationIgnored let targets: NativeImportTargets
    @ObservationIgnored var commandTitles: @MainActor () async -> [String: String] = { [:] }
    @ObservationIgnored var onChange: (Set<BackupDataChange>) -> Void = { _ in }

    init(paths: AppPaths, access: @escaping () -> BackupShortcutAccess?) throws {
        let library = try BackupLibrary(url: paths.file(BackupLibrary.fileName))
        targets = NativeImportTargets(
            library: library,
            aliasStore: CommandAliasStore(url: paths.dataDirectory.appending(path: CommandAliasStore.fileName)),
            files: ShortcutFiles(commandsURL: paths.dataDirectory.appending(path: "command-shortcuts-v1.json"),
                                 launcherURL: paths.dataDirectory.appending(path: "global-shortcut-v1.json")),
            access: access
        )
        importer = RaycastImporter(journal: MigrationJournalStore(url: paths.dataDirectory.appending(path: MigrationJournalStore.fileName)),
                                   targets: targets)
    }

    var ready: Int { rows?.filter(\.isReady).count ?? 0 }
    var conflicts: Int { rows?.filter(\.isConflict).count ?? 0 }
    var unsupported: Int { rows?.filter { $0.reason != nil }.count ?? 0 }

    func loadJournal() {
        do {
            journal = try importer.journal.read()
        } catch {
            self.error = RaycastImporter.message(error)
        }
        journalLoaded = true
    }

    func chooseFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "rayconfig") ?? .data, .json]
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("Choose a .rayconfig file exported from Raycast.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        password = ""
        needsPassword = false
        await work { try await self.review(url, password: nil) }
    }

    func unlock() async {
        guard let fileURL, !password.isEmpty else { return }
        let password = self.password
        self.password = ""
        await work { try await self.review(fileURL, password: password) }
    }

    func cancel() {
        rows = nil
        selected = []
        fileURL = nil
        needsPassword = false
        password = ""
        error = nil
    }

    /// Reviews a file without the open panel, for tests and snapshots.
    func reviewFile(_ url: URL) async {
        fileURL = url
        await work { try await self.review(url, password: nil) }
    }

    private func review(_ url: URL, password: String?) async throws {
        rows = nil
        selected = []
        let data: Any
        do {
            data = try await Task.detached(priority: .userInitiated) { () throws -> SendableJSON in
                let bytes = try BackupFiles.read(url, limit: RaycastFile.maxBytes, readError: "This file is not a valid Raycast export.",
                                                 invalidError: "This file is not a valid Raycast export.", tooLarge: "File exceeds 20 MB.")
                return SendableJSON(value: try RaycastFile.decode(bytes, password: password))
            }.value.value
        } catch RaycastFile.Failure.password {
            needsPassword = true
            return
        } catch let failure as RaycastFile.Failure {
            throw BackupError(failure.message)
        }
        needsPassword = false
        let apps = await Task.detached(priority: .userInitiated) {
            ApplicationCatalog.scan().map { RaycastImportContext.Application(path: $0.path, name: $0.name) }
        }.value
        let context = RaycastImportContext(
            apps: apps, entries: try targets.libraryEntries(), aliases: try targets.aliases(), hotkeys: try targets.hotkeys(),
            disabled: targets.disabled(), commandTitles: await commandTitles()
        )
        let plan: [ImportItem]
        do {
            plan = try RaycastPlan.build(data, context: context)
        } catch let failure as RaycastPlan.Failure {
            throw BackupError(failure.message)
        }
        rows = plan
        selected = Set(plan.filter(\.isReady).map(\.id))
        reviewedAt = Date()
    }

    // MARK: Selection

    func candidates(in category: ImportItem.Category) -> [ImportItem] {
        rows?.filter { $0.category == category && $0.isReady } ?? []
    }

    func isCategorySelected(_ category: ImportItem.Category) -> Bool {
        let candidates = candidates(in: category)
        return !candidates.isEmpty && candidates.allSatisfy { selected.contains($0.id) }
    }

    func setCategory(_ category: ImportItem.Category, selected isOn: Bool) {
        for row in candidates(in: category) {
            if isOn { selected.insert(row.id) } else { selected.remove(row.id) }
        }
    }

    /// Unsupported rows never import; conflicts with an existing library item cannot replace it.
    func isSelectable(_ row: ImportItem) -> Bool {
        row.reason == nil && !(row.conflict == true && row.commandId == nil)
    }

    func toggle(_ row: ImportItem) {
        guard isSelectable(row) else { return }
        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
    }

    // MARK: Apply

    func apply() async {
        guard let rows, !selected.isEmpty else { return }
        await work {
            if Date().timeIntervalSince(self.reviewedAt) > Self.reviewLifetime {
                self.rows = nil
                throw BackupError("Review expired. Choose the file again.")
            }
            let items = rows.filter { self.selected.contains($0.id) && $0.reason == nil }
            defer { self.onChange(self.targets.takeChanges()) }
            _ = try self.importer.apply(items) { self.journal = $0 }
        }
    }

    func undo() async {
        guard let journal else { return }
        await work {
            defer { self.onChange(self.targets.takeChanges()) }
            _ = try self.importer.undo(journal) { self.journal = $0 }
        }
    }

    func discardRecovery() async {
        guard let journal else { return }
        await work {
            try self.importer.journal.clear(id: journal.id)
            self.journal = nil
            self.cancel()
        }
    }

    private func work(_ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
        } catch {
            self.error = RaycastImporter.message(error)
        }
    }
}

/// Decoded JSON crossing from the decoding task. JSONSerialization values are immutable once built.
struct SendableJSON: @unchecked Sendable {
    let value: Any
}
