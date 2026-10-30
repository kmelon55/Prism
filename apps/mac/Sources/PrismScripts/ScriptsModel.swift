import AppKit
import Observation
import PrismKit

/// The palette's view of one script, like `ScriptSession` in `runStore.ts`. Arguments are never kept here.
struct ScriptSession: Equatable {
    enum Operation: Equatable { case start, cancel, save }

    var starting = false
    var cancelling = false
    var snapshot: ScriptRunSnapshot?
    /// English product message; display with `ScriptStrings.localize`.
    var error: String?
    var errorOperation: Operation?

    var isRunning: Bool { starting || snapshot?.state == .running }
}

/// Registry state, run sessions and configured folders for the palette and settings. Every disk or process
/// operation runs in a detached task; this type only publishes results on the main actor.
@MainActor
@Observable
final class ScriptsModel {
    private(set) var directories: [String] = []
    private(set) var commands: [ScriptCommandSummary] = []
    private(set) var sessions: [String: ScriptSession] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: ScriptRefreshResult?
    private(set) var refreshError: String?
    private(set) var historyError: String?
    /// Script IDs per configured folder, for the settings list.
    private(set) var commandCountByDirectory: [String: Int] = [:]

    @ObservationIgnored let registry: ScriptRegistry
    @ObservationIgnored private let directoryStore: ScriptDirectoriesStore
    @ObservationIgnored private let historyURL: URL?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<ScriptRunSnapshot?, Never>]] = [:]
    @ObservationIgnored private var inlineRefreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private lazy var watcher = ScriptDirectoryWatcher { [weak self] in self?.refresh() }
    @ObservationIgnored private var watching = false
    @ObservationIgnored let pollInterval: Duration

    init(registry: ScriptRegistry, directoryStore: ScriptDirectoriesStore, historyURL: URL?, pollInterval: Duration = .milliseconds(100)) {
        self.registry = registry
        self.directoryStore = directoryStore
        self.historyURL = historyURL
        self.pollInterval = pollInterval
    }

    convenience init(paths: AppPaths) {
        self.init(registry: ScriptRegistry(), directoryStore: ScriptDirectoriesStore(paths: paths), historyURL: paths.file("script-runs-v1.json"))
    }

    // MARK: Startup

    /// Loads history, restores sessions and runs the startup refresh once. Safe to await from anywhere.
    func bootstrap() async {
        if bootstrapTask == nil {
            bootstrapTask = Task { await performBootstrap() }
        }
        await bootstrapTask?.value
    }

    private func performBootstrap() async {
        let registry = registry, store = directoryStore, url = historyURL
        let (directories, historyError, runs) = await Task.detached { () -> ([String], String?, [ScriptRunSnapshot]) in
            let directories = store.load()
            var failure: String?
            if let url {
                do throws(ScriptError) { try registry.initialize(historyURL: url) } catch { failure = error.message }
            }
            return (directories, failure, (try? registry.listRuns()) ?? [])
        }.value
        self.directories = directories
        self.historyError = historyError
        // Oldest first; the newest retained run becomes the script's session. Recovery never starts anything.
        for snapshot in runs {
            if let current = sessions[snapshot.scriptId], current.starting || (current.snapshot.map { $0.runId > snapshot.runId } ?? false) { continue }
            sessions[snapshot.scriptId] = ScriptSession(snapshot: snapshot)
        }
        ensurePolling()
        await performRefresh()
    }

    /// Starts watching the configured folders. Called from `FeatureContribution.start`.
    func startWatching() {
        watching = true
        Task {
            await bootstrap()
            watcher.watch(directories)
        }
    }

    // MARK: Folders

    func addDirectories(_ urls: [URL]) {
        var updated = directories
        for url in urls {
            let path = url.standardizedFileURL.path
            if !updated.contains(path) && updated.count < ScriptLimits.maxDirectories { updated.append(path) }
        }
        setDirectories(updated)
    }

    func removeDirectory(_ path: String) {
        setDirectories(directories.filter { $0 != path })
    }

    var canAddDirectory: Bool { directories.count < ScriptLimits.maxDirectories }

    private func setDirectories(_ updated: [String]) {
        guard updated != directories else { return }
        directories = updated
        let store = directoryStore
        Task.detached { try? store.save(updated) }
        if watching { watcher.watch(updated) }
        refresh()
    }

    // MARK: Registry

    /// Rescans the folders. A refresh requested while one runs is coalesced into one more pass.
    func refresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task {
            await bootstrap()
            repeat {
                refreshAgain = false
                await performRefresh()
            } while refreshAgain
            refreshTask = nil
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let registry = registry, directories = directories
        let outcome = await Task.detached { () -> Result<(ScriptRefreshResult, [String: Int]), ScriptError> in
            do throws(ScriptError) {
                let result = try registry.refresh(directories: directories)
                return .success((result, registry.commandCountByRoot(configured: directories)))
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(let (result, counts)):
            commands = result.commands
            lastRefresh = result
            commandCountByDirectory = counts
            refreshError = nil
            let ids = Set(result.commands.map { $0.id })
            for (id, task) in inlineRefreshTasks where !ids.contains(id) || command(id)?.mode != .inline {
                task.cancel()
                inlineRefreshTasks[id] = nil
            }
        case .failure(let error):
            // The previous registry remains active.
            refreshError = error.message
        }
    }

    func command(_ id: String) -> ScriptCommandSummary? {
        commands.first { $0.id == id }
    }

    func session(_ scriptID: String) -> ScriptSession {
        sessions[scriptID] ?? ScriptSession()
    }

    // MARK: Argument drafts

    /// Unsent argument values per script, kept while Prism runs so Back and reopen keep what was typed.
    /// Password values are cleared on submit and never written anywhere.
    private(set) var drafts: [String: [String]] = [:]

    func draft(_ scriptID: String, _ index: Int) -> String {
        guard let values = drafts[scriptID], values.indices.contains(index) else { return "" }
        return values[index]
    }

    func setDraft(_ value: String, _ scriptID: String, _ index: Int, count: Int) {
        var values = drafts[scriptID] ?? []
        if values.count != count { values = Array(values.prefix(count)) + Array(repeating: "", count: max(0, count - values.count)) }
        guard values.indices.contains(index) else { return }
        values[index] = value
        drafts[scriptID] = values
    }

    // MARK: Runs

    /// `startScriptSession`. Without `rerun`, an existing session is shown rather than executed again.
    func start(_ scriptID: String, arguments: [String], rerun: Bool = true) async {
        await bootstrap()
        let current = session(scriptID)
        guard !current.isRunning, current.snapshot == nil || rerun else { return }
        publish(scriptID, ScriptSession(starting: true))
        let registry = registry
        let result = await Task.detached { () -> Result<ScriptRunSnapshot, ScriptError> in
            Result { () throws(ScriptError) in try registry.start(scriptID: scriptID, arguments: arguments) }
        }.value
        switch result {
        case .success(let snapshot):
            publish(scriptID, ScriptSession(snapshot: snapshot))
            ensurePolling()
            if snapshot.state.isTerminal { resume(snapshot.runId, with: snapshot) }
        case .failure(let error):
            publish(scriptID, ScriptSession(snapshot: current.snapshot, error: error.message, errorOperation: .start))
            // An inline refresh that could not start (for example, four runs active) tries again next interval.
            scheduleInlineRefreshIfNeeded(scriptID)
        }
    }

    func cancel(_ scriptID: String) async {
        let current = session(scriptID)
        guard !current.cancelling, let snapshot = current.snapshot, snapshot.state == .running else { return }
        var cancelling = current
        cancelling.cancelling = true
        cancelling.error = nil
        cancelling.errorOperation = nil
        publish(scriptID, cancelling)
        let registry = registry, runID = snapshot.runId
        let result = await Task.detached { Result { () throws(ScriptError) in try registry.cancel(runID) } }.value
        var latest = session(scriptID)
        guard latest.snapshot?.runId == runID, latest.snapshot?.state == .running else { return }
        switch result {
        case .success(let updated):
            latest.snapshot = updated
            latest.cancelling = updated.state == .running
        case .failure(let error):
            latest.cancelling = false
            latest.error = error.message
            latest.errorOperation = .cancel
        }
        publish(scriptID, latest)
    }

    /// Retries only the failed checkpoint through a status read; never starts or cancels a process.
    func retryPersistence(_ scriptID: String) async {
        guard let runID = session(scriptID).snapshot?.runId else { return }
        let registry = registry
        let result = await Task.detached { Result { () throws(ScriptError) in try registry.run(runID) } }.value
        var latest = session(scriptID)
        guard latest.snapshot?.runId == runID else { return }
        switch result {
        case .success(let snapshot):
            if latest.snapshot?.state.isTerminal == true && snapshot.state == .running { return }
            latest.snapshot = snapshot
            if latest.errorOperation == .save { latest.error = nil; latest.errorOperation = nil }
        case .failure(let error):
            latest.error = error.message
            latest.errorOperation = .save
        }
        publish(scriptID, latest)
    }

    /// Waits until the script's current run finishes. Returns nil when nothing is running.
    func waitForCompletion(_ scriptID: String) async -> ScriptRunSnapshot? {
        guard let snapshot = session(scriptID).snapshot else { return nil }
        if snapshot.state.isTerminal { return snapshot }
        return await withCheckedContinuation { continuation in
            waiters[snapshot.runId, default: []].append(continuation)
        }
    }

    private func resume(_ runID: String, with snapshot: ScriptRunSnapshot?) {
        waiters.removeValue(forKey: runID)?.forEach { $0.resume(returning: snapshot) }
    }

    private func publish(_ scriptID: String, _ session: ScriptSession) {
        sessions[scriptID] = session
        // Bound retained output without discarding any running operation.
        if sessions.count > ScriptLimits.maxRuns,
           let oldest = sessions.filter({ $0.key != scriptID && !$0.value.isRunning }).min(by: { ($0.value.snapshot?.runId ?? "") < ($1.value.snapshot?.runId ?? "") }) {
            sessions[oldest.key] = nil
        }
    }

    /// Live output is read from the registry's memory while any run is active.
    private func ensurePolling() {
        guard pollTask == nil, sessions.values.contains(where: { $0.snapshot?.state == .running }) else { return }
        pollTask = Task { [weak self, pollInterval] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard self.pollOnce() else { break }
            }
            self?.pollTask = nil
        }
    }

    /// Returns whether anything is still running.
    private func pollOnce() -> Bool {
        var anyRunning = false
        for (scriptID, current) in sessions {
            guard let snapshot = current.snapshot, snapshot.state == .running else { continue }
            guard let latest = try? registry.snapshot(snapshot.runId) else { continue }
            if latest != snapshot {
                var updated = current
                updated.snapshot = latest
                updated.cancelling = latest.state == .running && current.cancelling
                if latest.state.isTerminal && updated.errorOperation == .cancel { updated.error = nil; updated.errorOperation = nil }
                sessions[scriptID] = updated
            }
            if latest.state.isTerminal {
                resume(latest.runId, with: latest)
                scheduleInlineRefreshIfNeeded(scriptID)
            } else {
                anyRunning = true
            }
        }
        return anyRunning
    }

    // MARK: Inline mode

    /// Raycast refreshes inline commands on their `refreshTime`. Prism starts that schedule only after the user
    /// has run the command once in this session, so discovery alone never executes a script.
    func enableInlineRefresh(_ scriptID: String) {
        guard inlineRefreshTasks[scriptID] == nil, let command = command(scriptID), command.mode == .inline, command.refreshSeconds != nil else { return }
        inlineRefreshTasks[scriptID] = Task {}
    }

    private func scheduleInlineRefreshIfNeeded(_ scriptID: String) {
        guard inlineRefreshTasks[scriptID] != nil, let seconds = command(scriptID)?.refreshSeconds else { return }
        inlineRefreshTasks[scriptID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.command(scriptID)?.mode == .inline else { return }
            await self.start(scriptID, arguments: [])
        }
    }

    func inlineRefreshIsActive(_ scriptID: String) -> Bool { inlineRefreshTasks[scriptID] != nil }

    func stopInlineRefresh(_ scriptID: String) {
        inlineRefreshTasks.removeValue(forKey: scriptID)?.cancel()
    }
}

extension ScriptRegistry {
    /// How many registered commands each configured folder contributed, keyed by the configured path.
    func commandCountByRoot(configured directories: [String]) -> [String: Int] {
        let roots = commandRoots()
        var counts: [String: Int] = [:]
        for directory in directories {
            guard let canonical = ScriptFileRules.canonicalize(directory) else { continue }
            counts[directory] = roots.filter { $0 == canonical }.count
        }
        return counts
    }
}
