import Foundation

public struct ScriptRefreshResult: Sendable {
    public var commands: [ScriptCommandSummary]
    public var scannedDirectories: Int
    public var skippedEntries: Int
}

/// The native script registry: discovery, opaque IDs, bounded runs and durable history. A port of
/// `ScriptCommandRegistry` in `script_commands.rs`. Thread-safe; every method may block on disk or process
/// work, so call it from a background task.
public final class ScriptRegistry: @unchecked Sendable {
    private let stateLock = NSLock()
    private var scripts: [String: RegisteredScript] = [:]
    private var ordered: [ScriptCommandSummary] = []
    private let idLock = NSLock()
    private var nextScriptID: UInt64 = 0
    private var nextRunID: UInt64 = 0
    private let runsLock = NSLock()
    private var runs: [String: ScriptRun] = [:]
    let history: ScriptRunHistory
    let environment: [String: String]

    /// A registry without durable history, for tests and previews.
    init(inMemory: Void = (), environment: [String: String] = ProcessInfo.processInfo.environment) {
        history = ScriptRunHistory(location: .memory)
        self.environment = environment
    }

    /// A registry that must be initialized with `initialize(historyURL:)` before it can run anything.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        history = ScriptRunHistory(location: .unavailable)
        self.environment = environment
    }

    // MARK: History

    /// Loads `script-runs-v1.json`. Corrupt or oversized history is preserved and initialization fails, so
    /// execution and recovery fail closed. Saved `running` records become `interrupted`; nothing is resumed.
    public func initialize(historyURL url: URL) throws(ScriptError) {
        history.lock.lock(); defer { history.lock.unlock() }
        if case .file = history.location { throw ScriptError("Script history is already initialized.") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ScriptError("Could not create script history directory: \(error.localizedDescription)")
        }
        var saved = try Self.readHistory(url)
        if saved.version != 1 || saved.runs.count > ScriptLimits.maxRuns || saved.identities.count > ScriptLimits.maxEntries {
            throw ScriptError("Script history has an unsupported format or exceeds its limits.")
        }
        var ids = Set<String>()
        for identity in saved.identities {
            try ScriptIdentifiers.validateScriptID(identity.id)
            guard ids.insert(identity.id).inserted, identity.path.hasPrefix("/"), identity.root.hasPrefix("/") else {
                throw ScriptError("Script history contains invalid identities.")
            }
            saved.nextScriptId = max(saved.nextScriptId, ScriptIdentifiers.sequence(identity.id))
        }
        var restoredRuns: [String: ScriptRun] = [:]
        for index in saved.runs.indices {
            var snapshot = saved.runs[index]
            guard snapshot.runId.hasPrefix("sr_") else { throw ScriptError("Invalid saved script run.") }
            try ScriptIdentifiers.validateRunID(snapshot.runId)
            try ScriptIdentifiers.validateScriptID(snapshot.scriptId)
            saved.nextRunId = max(saved.nextRunId, ScriptIdentifiers.sequence(snapshot.runId))
            saved.nextScriptId = max(saved.nextScriptId, ScriptIdentifiers.sequence(snapshot.scriptId))
            if !(1...UInt64(ScriptLimits.maxTimeoutSeconds)).contains(snapshot.timeoutSeconds)
                || snapshot.stdout.utf8.count > ScriptLimits.maxCaptureBytes * 3
                || snapshot.stderr.utf8.count > ScriptLimits.maxCaptureBytes * 3 {
                throw ScriptError("Script history contains an invalid run.")
            }
            if snapshot.state == .running {
                snapshot.state = .interrupted
                snapshot.result = nil
                snapshot.error = ScriptRegistry.interruptedMessage
            }
            snapshot.persistenceError = nil
            snapshot.result?.stdout = snapshot.stdout
            snapshot.result?.stderr = snapshot.stderr
            saved.runs[index] = snapshot
            let run = ScriptRun(scriptID: snapshot.scriptId, restored: snapshot, completion: .failure(ScriptError("Recovered terminal run.")))
            guard restoredRuns.updateValue(run, forKey: snapshot.runId) == nil else {
                throw ScriptError("Script history contains duplicate runs.")
            }
        }
        // Recovery itself is durable: interrupted records are written before anything is served.
        try ScriptRunHistory.write(saved, to: url)
        idLock.lock()
        nextScriptID = saved.nextScriptId
        nextRunID = saved.nextRunId
        idLock.unlock()
        runsLock.lock(); runs = restoredRuns; runsLock.unlock()
        history.file = saved
        history.location = .file(url)
    }

    static let interruptedMessage = "Prism restarted before this run finished. The process was not resumed. Review any side effects before running again."

    private static func readHistory(_ url: URL) throws(ScriptError) -> ScriptHistoryFile {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return ScriptHistoryFile() }
            throw ScriptError("Could not read script history: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: ScriptLimits.maxHistoryFileBytes + 1) ?? Data()
        } catch {
            throw ScriptError("Could not read script history: \(error.localizedDescription)")
        }
        if bytes.count > ScriptLimits.maxHistoryFileBytes { throw ScriptError("Script history exceeded its storage limit.") }
        do {
            return try JSONDecoder().decode(ScriptHistoryFile.self, from: bytes)
        } catch {
            throw ScriptError("Could not read script history: \(error.localizedDescription)")
        }
    }

    public var isHistoryAvailable: Bool {
        history.lock.lock(); defer { history.lock.unlock() }
        if case .unavailable = history.location { return false }
        return true
    }

    // MARK: Discovery

    public var commands: [ScriptCommandSummary] {
        stateLock.lock(); defer { stateLock.unlock() }
        return ordered
    }

    func registered(_ scriptID: String) throws(ScriptError) -> RegisteredScript {
        try ScriptIdentifiers.validateScriptID(scriptID)
        stateLock.lock(); defer { stateLock.unlock() }
        guard let script = scripts[scriptID] else { throw ScriptError("The script command is not present in the current registry.") }
        return script
    }

    func commandRoots() -> [String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return scripts.values.map(\.root)
    }

    /// The script's file, for Show in Finder and Edit. Never part of a summary or snapshot.
    public func scriptURL(for scriptID: String) -> URL? {
        (try? registered(scriptID)).map { URL(filePath: $0.path) }
    }

    /// `refresh_registry`: a non-recursive scan of each configured folder. IDs are reused for the same canonical
    /// path and root, including across restarts; new scripts get the next monotonic ID.
    public func refresh(directories: [String]) throws(ScriptError) -> ScriptRefreshResult {
        if directories.count > ScriptLimits.maxDirectories {
            throw ScriptError("Prism accepts at most \(ScriptLimits.maxDirectories) script directories.")
        }
        let roots = try ScriptFileRules.canonicalizeDirectories(directories)
        var discovered: [(path: String, root: String, metadata: ScriptMetadata, title: String)] = []
        var skipped = 0
        var inspected = 0
        for root in roots {
            guard let directory = opendir(root) else {
                throw ScriptError("Prism could not read a configured script directory: \(String(cString: strerror(errno)))")
            }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                inspected += 1
                if inspected > ScriptLimits.maxEntries {
                    throw ScriptError("Prism stopped after inspecting \(ScriptLimits.maxEntries) script directory entries.")
                }
                let path = (root as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      let canonical = try? ScriptFileRules.canonicalScriptPath(root: root, candidate: path),
                      ScriptFileRules.isSupportedExecutable(canonical) else {
                    skipped += 1
                    continue
                }
                let metadata = ScriptMetadataParser.read(url: URL(filePath: canonical))
                let stem = ((canonical as NSString).lastPathComponent as NSString).deletingPathExtension
                let fallback = ScriptMetadataParser.cleanFallbackTitle(stem.isEmpty ? (canonical as NSString).lastPathComponent : stem)
                discovered.append((canonical, root, metadata, metadata.name ?? (fallback.isEmpty ? "Untitled script" : fallback)))
            }
        }
        discovered.sort { left, right in
            let l = left.title.lowercased(), r = right.title.lowercased()
            return l != r ? l < r : left.path.utf8.lexicographicallyPrecedes(right.path.utf8)
        }

        // Hold the registry lock through ID reuse and publication so concurrent refreshes cannot publish
        // different identities for the same path.
        stateLock.lock(); defer { stateLock.unlock() }
        history.lock.lock(); defer { history.lock.unlock() }
        var previous: [String: String] = [:]
        for identity in history.file.identities { previous[identity.path + "\0" + identity.root] = identity.id }
        for script in scripts.values { previous[script.path + "\0" + script.root] = script.summary.id }
        var newScripts: [String: RegisteredScript] = [:]
        var newOrdered: [ScriptCommandSummary] = []
        for item in discovered {
            let id: String
            if let existing = previous[item.path + "\0" + item.root] { id = existing } else { id = try allocateScriptID() }
            let metadata = item.metadata
            let summary = ScriptCommandSummary(
                id: id, title: item.title, description: metadata.description, keywords: metadata.keywords,
                arguments: metadata.arguments, argumentError: metadata.argumentError,
                timeoutSeconds: metadata.timeoutSeconds ?? ScriptLimits.defaultTimeoutSeconds,
                mode: metadata.mode ?? .fullOutput, packageName: metadata.packageName,
                needsConfirmation: metadata.needsConfirmation, refreshSeconds: metadata.refreshSeconds,
                icon: Self.icon(metadata.icon, root: item.root), iconDark: Self.icon(metadata.iconDark, root: item.root)
            )
            newScripts[id] = RegisteredScript(summary: summary, path: item.path, root: item.root, workingDirectory: metadata.currentDirectoryPath)
            newOrdered.append(summary)
        }
        history.file.identities = newOrdered.map { summary in
            let script = newScripts[summary.id]!
            return ScriptIdentity(path: script.path, root: script.root, id: summary.id)
        }
        idLock.lock(); history.file.nextScriptId = nextScriptID; idLock.unlock()
        history.file.version = 1
        try history.write()
        scripts = newScripts
        ordered = newOrdered
        return ScriptRefreshResult(commands: newOrdered, scannedDirectories: roots.count, skippedEntries: skipped)
    }

    private func allocateScriptID() throws(ScriptError) -> String {
        idLock.lock(); defer { idLock.unlock() }
        guard nextScriptID < UInt64.max else { throw ScriptError("The script command identifier space is exhausted.") }
        nextScriptID += 1
        return ScriptIdentifiers.scriptID(nextScriptID)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "icns", "pdf", "svg", "webp"]

    /// Raycast icons are an emoji, a local image path (relative to the script folder or absolute) or a URL. URLs are
    /// not fetched; Prism keeps script discovery offline.
    static func icon(_ value: String?, root: String) -> ScriptIcon? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        if imageExtensions.contains((expanded as NSString).pathExtension.lowercased()) {
            let path = expanded.hasPrefix("/") ? expanded : (root as NSString).appendingPathComponent(expanded)
            return FileManager.default.isReadableFile(atPath: path) ? .image(path: path) : nil
        }
        return value.count <= 4 ? .emoji(value) : nil
    }

    // MARK: Runs

    /// `start_registered_run`. The initial record must be saved before the process starts; the process then runs
    /// on its own thread and this returns the first snapshot.
    public func start(scriptID: String, arguments: [String]) throws(ScriptError) -> ScriptRunSnapshot {
        let script = try registered(scriptID)
        let validated = try ScriptArgumentValidation.validate(script.summary, arguments)
        try ScriptFileRules.validateRegisteredPath(script)
        runsLock.lock()
        if runs.values.contains(where: { $0.scriptID == scriptID && !$0.isFinished }) {
            runsLock.unlock()
            throw ScriptError("This script is already running. Restore its status before starting again.")
        }
        if runs.values.filter({ !$0.isFinished }).count >= ScriptLimits.maxActiveRuns {
            runsLock.unlock()
            throw ScriptError("At most four script commands can run at once.")
        }
        if runs.count >= ScriptLimits.maxRuns, let oldest = runs.filter({ $0.value.isFinished }).keys.min() {
            runs[oldest] = nil
        }
        idLock.lock()
        guard nextRunID < UInt64.max else {
            idLock.unlock(); runsLock.unlock()
            throw ScriptError("Script run identifiers exhausted.")
        }
        nextRunID += 1
        let runID = ScriptIdentifiers.runID(nextRunID)
        idLock.unlock()
        let timeout = UInt64(script.summary.timeoutSeconds)
        let run = ScriptRun(
            scriptID: scriptID, runID: runID, startedAtMs: UInt64(Date().timeIntervalSince1970 * 1_000), timeoutSeconds: timeout,
            sensitiveOutput: script.summary.hasPasswordArgument, history: history
        )
        // Never launch if the initial durable record cannot be acknowledged.
        do {
            try run.checkpoint()
        } catch {
            history.lock.lock(); history.file.runs.removeAll { $0.runId == runID }; history.lock.unlock()
            runsLock.unlock()
            throw error
        }
        runs[runID] = run
        runsLock.unlock()
        let environment = environment
        let worker = Thread {
            let result = Result { () throws(ScriptError) in
                try ScriptExecutor.execute(script, arguments: validated, run: run, timeout: TimeInterval(timeout), environment: environment)
            }
            run.complete(result)
        }
        worker.name = "prism-script"
        worker.start()
        return run.snapshot()
    }

    /// `list_registered_runs`: durable and live snapshots, oldest first. Never executes anything.
    public func listRuns() throws(ScriptError) -> [ScriptRunSnapshot] {
        guard isHistoryAvailable else { throw ScriptError("Script history is unavailable. Restart Prism to retry initialization.") }
        runsLock.lock(); let current = runs; runsLock.unlock()
        return current.map { $0.value.snapshot() }.sorted { $0.runId < $1.runId }
    }

    func resolveRun(_ runID: String) throws(ScriptError) -> ScriptRun {
        try ScriptIdentifiers.validateRunID(runID)
        runsLock.lock(); defer { runsLock.unlock() }
        guard let run = runs[runID] else { throw ScriptError("Script run is no longer available.") }
        return run
    }

    /// `get_script_command_run`. When the last checkpoint failed this retries only the checkpoint.
    public func run(_ runID: String) throws(ScriptError) -> ScriptRunSnapshot {
        let run = try resolveRun(runID)
        if run.persistenceError != nil { run.saveProgress() }
        return run.snapshot()
    }

    /// A live read without the checkpoint retry, cheap enough for polling.
    public func snapshot(_ runID: String) throws(ScriptError) -> ScriptRunSnapshot {
        try resolveRun(runID).snapshot()
    }

    /// Requests cancellation. The returned snapshot may still be `running` while the process group is killed.
    public func cancel(_ runID: String) throws(ScriptError) -> ScriptRunSnapshot {
        let run = try resolveRun(runID)
        run.requestCancel()
        return run.snapshot()
    }

    var nextRunSequence: UInt64 {
        idLock.lock(); defer { idLock.unlock() }
        return nextRunID
    }

    var activeRunCount: Int {
        runsLock.lock(); defer { runsLock.unlock() }
        return runs.values.filter { !$0.isFinished }.count
    }
}
