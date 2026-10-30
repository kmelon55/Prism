import AppKit
import Foundation
import Observation
import PrismKit
import UniformTypeIdentifiers

/// State and actions of Settings → Backup & Restore, ported from `BackupSettings.tsx`.
@MainActor
@Observable
final class BackupModel {
    enum Operation: Equatable { case backup, export, review, apply, preferences }

    struct Review {
        let token: UUID
        let fileName: String
        let categories: BackupCategories
        let summary: BackupSummary
        let pathReferences: [BackupPathReference]
        let missingFavorites: [BackupFavorite]
        let preferences: SafePreferences?
        let aliasReview: [SafePreferencesMerge.AliasReview]

        var libraryRows: [(kind: String, title: String, counts: BackupCounts)] {
            [("snippet", "Snippets", categories.snippets), ("note", "Notes", categories.notes), ("link", "Quicklinks", categories.quicklinks),
             ("path", "Path references", categories.pathLinks)]
                .filter(\.2).map { ($0.0, $0.1, summary[$0.0]) }
                + (categories.favorites ? [("favorite", "Favorites", summary.favorites)] : [])
        }

        var additions: Int { libraryRows.reduce(0) { $0 + $1.counts.added } }
    }

    var categories = BackupCategories() {
        didSet { if categories != oldValue { closeReview() } }
    }
    private(set) var review: Review?
    private(set) var libraryApplied = false
    private(set) var preferencesApplied = false
    private(set) var busy: Operation?
    /// Which action the current status message belongs to.
    private(set) var lastOperation: Operation?
    private(set) var status: String?
    private(set) var error: String?
    /// The action the error's retry button runs. A failed library apply always needs a fresh review.
    private(set) var retry: Operation?
    private(set) var location: URL?
    private(set) var lastBackup: Date?

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let preferences: NativePreferences
    @ObservationIgnored private let reviews = BackupReviews()
    @ObservationIgnored var onChange: (Set<BackupDataChange>) -> Void = { _ in }

    private enum Key {
        static let location = "PrismBackup.location"
        static let lastBackup = "PrismBackup.lastBackupDate"
    }

    init(paths: AppPaths, defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "dev.prism.native-dev") {
        self.paths = paths
        self.defaults = defaults
        preferences = NativePreferences(defaults: defaults, domain: domain,
                                        aliases: CommandAliasStore(url: paths.dataDirectory.appending(path: CommandAliasStore.fileName)))
        location = defaults.string(forKey: Key.location).map { URL(filePath: $0, directoryHint: .isDirectory) }
        lastBackup = defaults.object(forKey: Key.lastBackup) as? Date
    }

    var isBusy: Bool { busy != nil }

    private func library() throws -> BackupLibrary {
        do {
            return try BackupLibrary(url: paths.file(BackupLibrary.fileName))
        } catch {
            throw BackupError(BackupMessage.restoreFailed)
        }
    }

    // MARK: Back up

    func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Choose")
        panel.message = L10n.tr("Choose where Back Up Now saves backup files.")
        if let location { panel.directoryURL = location }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url
        defaults.set(url.path, forKey: Key.location)
    }

    func revealLocation() {
        guard let location else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }

    /// Writes a dated backup into the chosen folder, asking for a folder first when none is set.
    func backUpNow() async {
        if location == nil { chooseLocation() }
        guard let location else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        await write(to: location.appending(path: "prism-backup-\(formatter.string(from: Date())).json"), operation: .backup)
    }

    func exportAs() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "prism-backup-v2.json"
        panel.canCreateDirectories = true
        if let location { panel.directoryURL = location }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await write(to: url, operation: .export)
    }

    private func write(to url: URL, operation: Operation) async {
        await run(operation) {
            let categories = self.categories
            let safe = categories.preferences ? try self.preferences.current() : nil
            let library = try self.library()
            try await Task.detached(priority: .userInitiated) {
                let document = try BackupRestore.exportDocument(categories: categories, library: library, preferences: safe)
                try BackupFiles.write(try document.encoded(), to: url)
            }.value
            let now = Date()
            self.lastBackup = now
            self.defaults.set(now, forKey: Key.lastBackup)
            self.status = L10n.tr("Backup saved.")
        }
    }

    // MARK: Restore

    func chooseBackupToReview() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if let location { panel.directoryURL = location }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await review(url)
    }

    func review(_ url: URL) async {
        closeReview()
        await run(.review) {
            guard self.categories.any else { throw BackupError(BackupMessage.noCategory) }
            let categories = self.categories
            let library = try self.library()
            let prepared = try await Task.detached(priority: .userInitiated) {
                let document = try BackupDocument.parse(BackupFiles.read(url))
                return try BackupRestore.prepare(document, categories: categories, library: library)
            }.value
            let currentAliases = (try? self.preferences.aliases.load()) ?? [:]
            self.review = Review(
                token: self.reviews.issue(prepared), fileName: url.lastPathComponent, categories: categories,
                summary: prepared.summary, pathReferences: prepared.pathReferences, missingFavorites: prepared.missingFavorites,
                preferences: prepared.preferences,
                aliasReview: prepared.preferences.map { SafePreferencesMerge.reviewAliases(current: currentAliases, incoming: $0) } ?? []
            )
        }
    }

    func applyLibrary() async {
        guard let review, !libraryApplied else { return }
        await run(.apply) {
            // Consume the review before anything can fail: a retry must review the file again.
            let prepared = try self.reviews.take(review.token)
            let library = try self.library()
            _ = try await Task.detached(priority: .userInitiated) { try BackupRestore.apply(prepared, library: library) }.value
            self.libraryApplied = true
            self.status = L10n.tr("Library restored. Existing items were kept.")
            self.onChange([.library])
        }
        if error != nil, retry == .apply {
            self.review = nil
            retry = .review
        }
    }

    func restorePreferences() async {
        guard let incoming = review?.preferences, !preferencesApplied else { return }
        await run(.preferences) {
            let merged = try SafePreferencesMerge.merge(current: self.preferences.current(), incoming: incoming)
            try self.preferences.restore(merged)
            self.preferencesApplied = true
            self.status = L10n.tr("Safe preferences restored.")
            self.onChange([.aliases, .appearance])
        }
    }

    func closeReview() {
        reviews.discard()
        review = nil
        libraryApplied = false
        preferencesApplied = false
        status = nil
        error = nil
        retry = nil
    }

    func runRetry() async {
        switch retry {
        case .backup: await backUpNow()
        case .export: await exportAs()
        case .review: await chooseBackupToReview()
        case .preferences: await restorePreferences()
        case .apply, nil: break
        }
    }

    private func run(_ operation: Operation, _ body: () async throws -> Void) async {
        guard busy == nil else { return }
        busy = operation
        lastOperation = operation
        error = nil
        retry = nil
        status = nil
        defer { busy = nil }
        do {
            try await body()
        } catch {
            self.error = RaycastImporter.message(error)
            retry = operation
        }
    }
}
