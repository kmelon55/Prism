import Darwin
import Foundation

/// Keeps only the first 64 KiB of a stream and records whether anything was dropped.
final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncatedFlag = false
    private let limit: Int

    init(limit: Int = ScriptLimits.maxCaptureBytes) {
        self.limit = limit
        bytes.reserveCapacity(min(limit, 8 * 1_024))
    }

    func append(_ chunk: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        if remaining > 0, let base = chunk.baseAddress {
            bytes.append(base.assumingMemoryBound(to: UInt8.self), count: min(chunk.count, remaining))
        }
        if chunk.count > remaining { truncatedFlag = true }
    }

    func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    func markTruncated() {
        lock.lock(); truncatedFlag = true; lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return bytes.isEmpty
    }

    func snapshot() -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), truncatedFlag)
    }
}

/// One execution. Mirrors `ScriptRun` in Rust: completion is published only after the process is reaped and its
/// output drained, and every publication goes through `publication` together with its checkpoint outcome.
final class ScriptRun: @unchecked Sendable {
    let scriptID: String
    let runID: String
    let startedAtMs: UInt64
    let timeoutSeconds: UInt64
    let sensitiveOutput: Bool
    let history: ScriptRunHistory?
    let restored: ScriptRunSnapshot?
    let stdout = BoundedOutput()
    let stderr = BoundedOutput()

    let publication = NSLock()
    private let stateLock = NSLock()
    private var completionValue: Result<ScriptCommandRunResult, ScriptError>?
    private var persistenceErrorValue: String?
    private var cancelRequested = false

    init(
        scriptID: String, runID: String = "", startedAtMs: UInt64 = 0, timeoutSeconds: UInt64 = UInt64(ScriptLimits.defaultTimeoutSeconds),
        sensitiveOutput: Bool = false, history: ScriptRunHistory? = nil, restored: ScriptRunSnapshot? = nil,
        completion: Result<ScriptCommandRunResult, ScriptError>? = nil
    ) {
        self.scriptID = scriptID
        self.runID = runID
        self.startedAtMs = startedAtMs
        self.timeoutSeconds = timeoutSeconds
        self.sensitiveOutput = sensitiveOutput
        self.history = history
        self.restored = restored
        self.completionValue = completion
    }

    var completion: Result<ScriptCommandRunResult, ScriptError>? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return completionValue }
        set { stateLock.lock(); completionValue = newValue; stateLock.unlock() }
    }

    var isFinished: Bool { completion != nil }

    var persistenceError: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return persistenceErrorValue }
        set { stateLock.lock(); persistenceErrorValue = newValue; stateLock.unlock() }
    }

    var isCancelRequested: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelRequested
    }

    func requestCancel() {
        stateLock.lock(); cancelRequested = true; stateLock.unlock()
    }

    func snapshot() -> ScriptRunSnapshot {
        publication.lock(); defer { publication.unlock() }
        return snapshotUnlocked()
    }

    func snapshotUnlocked() -> ScriptRunSnapshot {
        if let restored { return restored }
        let state: ScriptRunState
        var result: ScriptCommandRunResult?
        var error: String?
        switch completion {
        case nil: state = .running
        case .success(let value):
            state = value.cancelled ? .cancelled : value.timedOut ? .timedOut : value.succeeded ? .success : .failure
            result = value
        case .failure(let failure):
            state = .failure
            error = failure.message
        }
        let (out, outTruncated) = stdout.snapshot()
        let (err, errTruncated) = stderr.snapshot()
        return ScriptRunSnapshot(
            startedAtMs: startedAtMs, timeoutSeconds: timeoutSeconds, outputWithheld: false, persistenceError: persistenceError,
            runId: runID, scriptId: scriptID, state: state, result: result, error: error,
            stdout: out, stderr: err, stdoutTruncated: outTruncated, stderrTruncated: errTruncated
        )
    }

    /// `checkpoint_run`. Arguments are never serialized; password scripts never persist either stream.
    func checkpoint() throws(ScriptError) {
        guard let history else { return }
        var snapshot = snapshotUnlocked()
        snapshot.persistenceError = nil
        if sensitiveOutput {
            snapshot.stdout = ""
            snapshot.stderr = ""
            snapshot.outputWithheld = true
        }
        snapshot.result?.stdout = ""
        snapshot.result?.stderr = ""
        history.lock.lock(); defer { history.lock.unlock() }
        history.file.runs.removeAll { $0.runId == snapshot.runId }
        history.file.runs.append(snapshot)
        history.file.runs.sort { $0.runId < $1.runId }
        while history.file.runs.count > ScriptLimits.maxRuns {
            guard let index = history.file.runs.firstIndex(where: { $0.state != .running }) else {
                throw ScriptError("Too many active script runs.")
            }
            history.file.runs.remove(at: index)
        }
        history.file.nextRunId = max(history.file.nextRunId, ScriptIdentifiers.sequence(runID))
        try history.write()
    }

    func saveProgress() {
        publication.lock(); defer { publication.unlock() }
        saveProgressUnlocked()
    }

    func complete(_ result: Result<ScriptCommandRunResult, ScriptError>) {
        publication.lock(); defer { publication.unlock() }
        completion = result
        // Publish terminal state together with its checkpoint outcome.
        saveProgressUnlocked()
    }

    private func saveProgressUnlocked() {
        do { try checkpoint(); persistenceError = nil } catch { persistenceError = error.message }
    }
}

/// A registered script with its private location.
struct RegisteredScript: Sendable {
    var summary: ScriptCommandSummary
    var path: String
    var root: String
    var workingDirectory: String?
}

enum ScriptExecutor {
    static let checkpointInterval: TimeInterval = 1
    /// How long to keep reading after the process group is killed. Pipes normally reach EOF at once; a
    /// descendant that left the group can hold them open, and then the remainder is marked truncated.
    static let outputDrainLimit: TimeInterval = 2

    /// `execute_script`. Blocks the calling thread until the process is reaped and its output drained; never
    /// call it on the main actor. Both pipes are read on this thread with `poll`, so output never depends on
    /// another thread being scheduled before the terminal snapshot.
    static func execute(
        _ script: RegisteredScript, arguments: [String], run: ScriptRun, timeout: TimeInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ScriptError) -> ScriptCommandRunResult {
        try ScriptFileRules.validateRegisteredPath(script)
        let started = Date()
        let directory = try workingDirectory(for: script)
        let child = try spawn(path: script.path, arguments: arguments, directory: directory, environment: environment)
        var streams = OutputStreams(stdout: child.stdout, stderr: child.stderr, run: run)
        defer { streams.close() }

        let deadline = started.addingTimeInterval(timeout)
        var checkpointAt = Date().addingTimeInterval(checkpointInterval)
        var status: Int32 = 0
        var timedOut = false
        var cancelled = false
        while true {
            streams.pump(waitingAtMost: 0.01)
            if Date() >= checkpointAt {
                run.saveProgress()
                checkpointAt = Date().addingTimeInterval(checkpointInterval)
            }
            let reaped = waitpid(child.pid, &status, WNOHANG)
            if reaped == child.pid { break }
            if reaped < 0 && errno != EINTR {
                let error = String(cString: strerror(errno))
                _ = try? terminate(child.pid)
                throw ScriptError("Prism could not observe the script command: \(error)")
            }
            if run.isCancelRequested {
                status = try terminate(child.pid)
                cancelled = true
                break
            }
            if Date() >= deadline {
                status = try terminate(child.pid)
                timedOut = true
                break
            }
        }

        // A foreground script must not leave background descendants holding its pipes open.
        kill(-child.pid, SIGKILL)
        let drainDeadline = Date().addingTimeInterval(outputDrainLimit)
        while !streams.isFinished, Date() < drainDeadline {
            streams.pump(waitingAtMost: drainDeadline.timeIntervalSinceNow)
        }
        streams.finish()
        let (stdout, stdoutTruncated) = run.stdout.snapshot()
        let (stderr, stderrTruncated) = run.stderr.snapshot()
        let exited = status & 0x7f == 0
        let exitCode: Int32? = exited ? (status >> 8) & 0xff : nil
        return ScriptCommandRunResult(
            scriptId: script.summary.id,
            succeeded: !timedOut && !cancelled && exitCode == 0,
            timedOut: timedOut, cancelled: cancelled, exitCode: exitCode,
            durationMs: UInt64(max(0, Date().timeIntervalSince(started) * 1_000)),
            stdout: stdout, stderr: stderr, stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated
        )
    }

    /// Non-blocking reads of both pipes into the run's bounded buffers.
    struct OutputStreams {
        private var descriptors: [Int32]
        private let outputs: [BoundedOutput]
        private var chunk = [UInt8](repeating: 0, count: 16 * 1_024)

        init(stdout: Int32, stderr: Int32, run: ScriptRun) {
            descriptors = [stdout, stderr]
            outputs = [run.stdout, run.stderr]
            for descriptor in descriptors { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
        }

        /// Both pipes reached EOF.
        var isFinished: Bool { descriptors.allSatisfy { $0 < 0 } }

        /// Waits up to `seconds` for output, then reads everything currently available.
        mutating func pump(waitingAtMost seconds: TimeInterval) {
            let milliseconds = Int32(max(0, min(seconds, 1)) * 1_000)
            var fds = descriptors.filter { $0 >= 0 }.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            // A process that closed both streams but keeps running must not turn the wait loop into a spin.
            guard !fds.isEmpty else { usleep(useconds_t(milliseconds) * 1_000); return }
            guard poll(&fds, nfds_t(fds.count), milliseconds) > 0 else { return }
            for index in descriptors.indices where descriptors[index] >= 0 { drain(index) }
        }

        /// Reads what is buffered right now. A pipe still held open after the drain limit is marked truncated.
        mutating func finish() {
            for index in descriptors.indices where descriptors[index] >= 0 {
                drain(index)
                if descriptors[index] >= 0 { outputs[index].markTruncated() }
            }
        }

        mutating func close() {
            for index in descriptors.indices where descriptors[index] >= 0 {
                Darwin.close(descriptors[index])
                descriptors[index] = -1
            }
        }

        private mutating func drain(_ index: Int) {
            let descriptor = descriptors[index]
            while true {
                let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    chunk.withUnsafeBytes { outputs[index].append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                // EOF or a read error: this stream is complete.
                Darwin.close(descriptor)
                descriptors[index] = -1
                return
            }
        }
    }

    /// The script's folder, or Raycast's `currentDirectoryPath` (absolute, `~`-relative or relative to the folder).
    static func workingDirectory(for script: RegisteredScript) throws(ScriptError) -> String {
        guard let requested = script.workingDirectory else { return script.root }
        let expanded = (requested as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : (script.root as NSString).appendingPathComponent(expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScriptError("The script's working directory does not exist.")
        }
        return path
    }

    /// Kills the whole process group, falling back to the child, then reaps it.
    private static func terminate(_ pid: pid_t) throws(ScriptError) -> Int32 {
        if kill(-pid, SIGKILL) != 0, kill(pid, SIGKILL) != 0, errno != ESRCH {
            throw ScriptError("Prism could not terminate the timed-out script command: \(String(cString: strerror(errno)))")
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else {
                throw ScriptError("Prism terminated the script command but could not reap it: \(String(cString: strerror(errno)))")
            }
        }
        return status
    }

    struct Child {
        var pid: pid_t
        var stdout: Int32
        var stderr: Int32
    }

    /// `posix_spawn` in its own process group with stdin from /dev/null and no inherited descriptors, so
    /// cancellation and timeouts can kill every descendant. Arguments go to argv literally; no shell is involved.
    static func spawn(path: String, arguments: [String], directory: String, environment: [String: String]) throws(ScriptError) -> Child {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw spawnError(errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw spawnError(code)
        }
        defer { close(outPipe[1]); close(errPipe[1]) }
        // Other processes the app starts meanwhile must not inherit these pipes and hold them open.
        for descriptor in outPipe + errPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t()
        var noSignals = sigset_t()
        sigfillset(&everySignal)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw spawnError(status)
        }
        return Child(pid: pid, stdout: outPipe[0], stderr: errPipe[0])
    }

    private static func spawnError(_ code: Int32) -> ScriptError {
        ScriptError("Prism could not start the script command: \(String(cString: strerror(code)))")
    }
}

/// Discovery rules from `script_commands.rs`.
enum ScriptFileRules {
    /// Tauri's allowlist plus Raycast's JavaScript, Swift and AppleScript commands. Files without an extension are
    /// accepted when executable.
    static let allowedExtensions: Set<String> = ["bash", "command", "fish", "pl", "py", "rb", "sh", "zsh", "js", "swift", "applescript"]

    static func isSupportedExecutable(_ path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard fileExtension.isEmpty || allowedExtensions.contains(fileExtension) else { return false }
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0
    }

    static func canonicalize(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The canonical path, which must sit directly inside `root`.
    static func canonicalScriptPath(root: String, candidate: String) throws(ScriptError) -> String {
        guard let canonical = canonicalize(candidate) else {
            throw ScriptError("Prism could not resolve a script command: \(String(cString: strerror(errno)))")
        }
        guard (canonical as NSString).deletingLastPathComponent == root else {
            throw ScriptError("Prism rejected a script command outside its configured directory.")
        }
        return canonical
    }

    static func validateRegisteredPath(_ script: RegisteredScript) throws(ScriptError) {
        var info = stat()
        guard lstat(script.path, &info) == 0 else {
            throw ScriptError("Prism could not inspect the script command: \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ScriptError("The registered script command is no longer a regular file.")
        }
        let canonical = try canonicalScriptPath(root: script.root, candidate: script.path)
        guard canonical == script.path, isSupportedExecutable(canonical) else {
            throw ScriptError("The registered script command is no longer executable.")
        }
    }

    static func canonicalizeDirectories(_ directories: [String]) throws(ScriptError) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        for directory in directories {
            if directory.isEmpty || directory.utf8.count > 4_096 || directory.unicodeScalars.contains(where: ScriptMetadataParser.isControl) {
                throw ScriptError("A configured script directory path is invalid.")
            }
            guard directory.hasPrefix("/") else { throw ScriptError("Configured script directories must be absolute paths.") }
            guard let root = canonicalize(directory) else {
                throw ScriptError("Prism could not resolve a configured script directory: \(String(cString: strerror(errno)))")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ScriptError("A configured script directory is not a directory.")
            }
            if seen.insert(root).inserted { roots.append(root) }
        }
        return roots
    }
}
